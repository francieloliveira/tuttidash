"""IDs do Linear que o dispatcher e o vigia usam (FRA-565).

Nenhum UUID fica no código. A ordem é:

1. a config (`linear.state_*_id` e `linear.labels.*`), que vence sempre;
2. o cache `~/.transcentia/lanes/linear-ids.json`;
3. a API do Linear, pelo nome (estados do time e etiquetas), uma vez, gravando o cache.

Quem chama decide quando ir à rede (`resolver`); ler (`carregar`) nunca vai.
Etiqueta sem id é pulada por quem aplica, com aviso no log: o ciclo não cai.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Callable, Optional

CACHE = Path.home() / ".transcentia" / "lanes" / "linear-ids.json"
#: Um cache por projeto (FRA-567): as colunas são do time de cada projeto.
CACHE_DIR = Path.home() / ".transcentia" / "lanes" / "linear-ids"


def caminho_cache(project_id: str = "") -> Path:
    """Cache do projeto; sem projeto, o arquivo único de antes."""
    pid = "".join(c for c in str(project_id or "") if c.isalnum() or c == "-")
    return CACHE_DIR / f"{pid}.json" if pid else CACHE

#: chave interna -> (chave da config, nome padrão do estado no Linear)
ESTADOS = {
    "todo": ("state_todo_id", "Todo"),
    "in_progress": ("state_in_progress_id", "In Progress"),
    "in_review": ("state_in_review_id", "In Review"),
}
#: etiquetas soltas que o fluxo aplica (o nome do dono vem de `linear.owner_label`)
FALHOU = "lane:falhou"
PARADA = "lane:parada"
DONO_PADRAO = "needs:dono"
GRUPO_ESFORCO = "esforco"
GRUPO_LANE = "lane"
ESFORCOS = ("baixo", "medio", "alto")


def vazio() -> dict:
    return {"estados": {k: "" for k in ESTADOS}, "labels": {}, "esforco": {}, "lanes": {}}


def _texto(v) -> str:
    return v.strip() if isinstance(v, str) else ""


def _mapa(v) -> dict:
    if not isinstance(v, dict):
        return {}
    return {str(k): _texto(x) for k, x in v.items() if _texto(x)}


def _juntar(base: dict, por_cima: dict) -> dict:
    """`por_cima` vence onde tem valor; vazio não apaga o que `base` tem."""
    saida = vazio()
    for k in ESTADOS:
        saida["estados"][k] = por_cima["estados"].get(k) or base["estados"].get(k) or ""
    for campo in ("labels", "esforco", "lanes"):
        saida[campo] = {**base.get(campo, {}), **por_cima.get(campo, {})}
    return saida


def da_config(get: Callable) -> dict:
    """IDs escritos na config. `get(chave, padrao)` é o leitor do `tools/cfg`."""
    d = vazio()
    for k, (chave, _nome) in ESTADOS.items():
        d["estados"][k] = _texto(get(f"linear.{chave}", ""))
    labels = get("linear.labels", {}) or {}
    if isinstance(labels, dict):
        d["labels"] = _mapa(labels.get("nomes"))
        d["esforco"] = _mapa(labels.get("esforco"))
        d["lanes"] = _mapa(labels.get("lanes"))
    return d


def ler_cache(caminho: Optional[Path] = None, project_id: str = "") -> dict:
    p = Path(caminho) if caminho else caminho_cache(project_id)
    try:
        bruto = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return vazio()
    if not isinstance(bruto, dict):
        return vazio()
    d = vazio()
    estados = bruto.get("estados") if isinstance(bruto.get("estados"), dict) else {}
    for k in ESTADOS:
        d["estados"][k] = _texto(estados.get(k))
    for campo in ("labels", "esforco", "lanes"):
        d[campo] = _mapa(bruto.get(campo))
    return d


def gravar_cache(ids: dict, caminho: Optional[Path] = None, project_id: str = "") -> None:
    p = Path(caminho) if caminho else caminho_cache(project_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(ids, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(p)


def carregar(get: Callable, caminho: Optional[Path] = None, project_id: str = "") -> dict:
    """Config por cima do cache do projeto. Não vai à rede."""
    return _juntar(ler_cache(caminho, project_id), da_config(get))


def faltando(ids: dict, dono: str, lanes=()) -> list:
    """O que ainda não tem id, para decidir se vale ir à API."""
    falta = [f"estado:{k}" for k in ESTADOS if not ids["estados"].get(k)]
    falta += [f"label:{n}" for n in (dono, FALHOU, PARADA) if n and not ids["labels"].get(n)]
    falta += [f"esforco:{e}" for e in ESFORCOS if not ids["esforco"].get(e)]
    falta += [f"lane:{l}" for l in lanes if not ids["lanes"].get(l)]
    return falta


Q_TIME_DO_PROJETO = "query($id: String!) { project(id: $id) { teams(first: 5) { nodes { id } } } }"
Q_ESTADOS = "query($id: String!) { team(id: $id) { states { nodes { id name } } } }"
Q_LABELS = ("query($after: String) { issueLabels(first: 250, after: $after) { "
            "nodes { id name parent { name } team { id } } pageInfo { hasNextPage endCursor } } }")


def resolver(consultar: Callable[[str, dict], dict], *, team_id: str = "", project_id: str = "",
             dono: str = DONO_PADRAO, lanes=(), nomes_estado: Optional[dict] = None) -> dict:
    """Busca pelo nome os IDs que faltam. `consultar(query, variaveis)` devolve o `data` do GraphQL.

    Etiqueta do próprio time vence a do workspace; sem time, vale a do workspace."""
    d = vazio()
    time = team_id
    if not time and project_id:
        nos = (((consultar(Q_TIME_DO_PROJETO, {"id": project_id}) or {}).get("project") or {})
               .get("teams") or {}).get("nodes") or []
        time = (nos[0] or {}).get("id", "") if nos else ""
    nomes = {k: n for k, (_c, n) in ESTADOS.items()}
    nomes.update({k: v for k, v in (nomes_estado or {}).items() if v})
    if time:
        estados = (((consultar(Q_ESTADOS, {"id": time}) or {}).get("team") or {})
                   .get("states") or {}).get("nodes") or []
        por_nome = {(e.get("name") or "").strip().lower(): e.get("id") for e in estados}
        for k, nome in nomes.items():
            d["estados"][k] = por_nome.get(nome.strip().lower()) or ""
    etiquetas, cursor = [], None
    for _ in range(20):  # 5000 etiquetas no máximo
        pagina = (consultar(Q_LABELS, {"after": cursor}) or {}).get("issueLabels") or {}
        etiquetas += pagina.get("nodes") or []
        info = pagina.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            break
        cursor = info.get("endCursor")

    def achar(nome: str, grupo: Optional[str]) -> str:
        cands = [e for e in etiquetas
                 if (e.get("name") or "").strip().lower() == nome.lower()
                 and ((e.get("parent") or {}).get("name") or "").strip().lower() == (grupo or "").lower()]
        cands.sort(key=lambda e: 0 if ((e.get("team") or {}).get("id") == time and time) else 1)
        return (cands[0].get("id") or "") if cands else ""

    for nome in (dono, FALHOU, PARADA):
        if nome and (i := achar(nome, None)):
            d["labels"][nome] = i
    for e in ESFORCOS:
        if i := achar(e, GRUPO_ESFORCO):
            d["esforco"][e] = i
    for lane in lanes:
        if i := achar(lane, GRUPO_LANE):
            d["lanes"][lane] = i
    return d


def garantir(get: Callable, consultar: Callable[[str, dict], dict], *, dono: str, lanes=(),
             project_id: str = "", caminho: Optional[Path] = None,
             log: Callable[[str], None] = lambda _m: None) -> dict:
    """Carrega; se faltar algo, resolve pela API, junta e grava o cache. Erro de rede não derruba."""
    ids = carregar(get, caminho, project_id)
    falta = faltando(ids, dono, lanes)
    if not falta:
        return ids
    try:
        # O time sai do projeto (FRA-567): sem `linear.team_id` global.
        novos = resolver(consultar, project_id=project_id, dono=dono, lanes=lanes)
    except Exception as exc:  # noqa: BLE001 — sem rede, fica o que já tinha
        log(f"linear: não resolvi os ids pelo nome ({exc}); faltam {', '.join(falta)}")
        return ids
    cache = _juntar(ler_cache(caminho, project_id), novos)
    gravar_cache(cache, caminho, project_id)
    ids = _juntar(cache, da_config(get))
    ainda = faltando(ids, dono, lanes)
    if ainda:
        log(f"linear: sem id no Linear para {', '.join(ainda)} (crie com esse nome ou ponha em linear.labels)")
    return ids
