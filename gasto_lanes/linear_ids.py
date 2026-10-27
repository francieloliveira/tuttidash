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
            "nodes { id name isGroup parent { name } team { id } } pageInfo { hasNextPage endCursor } } }")
M_CRIAR_LABEL = ("mutation($input: IssueLabelCreateInput!) { issueLabelCreate(input: $input) { "
                 "success issueLabel { id name } } }")

#: Cores das etiquetas que o TuttiDash cria (FRA-569); as do Linear, sem importância para o fluxo.
CORES = {"dono": "#F2994A", FALHOU: "#EB5757", PARADA: "#F2994A",
         "alto": "#EB5757", "medio": "#F2C94C", "baixo": "#4CB782", "lane": "#26B5CE"}


def time_do_projeto(consultar: Callable[[str, dict], dict], project_id: str) -> str:
    if not project_id:
        return ""
    nos = (((consultar(Q_TIME_DO_PROJETO, {"id": project_id}) or {}).get("project") or {})
           .get("teams") or {}).get("nodes") or []
    return (nos[0] or {}).get("id", "") if nos else ""


def ler_etiquetas(consultar: Callable[[str, dict], dict]) -> list:
    etiquetas, cursor = [], None
    for _ in range(20):  # 5000 etiquetas no máximo
        pagina = (consultar(Q_LABELS, {"after": cursor}) or {}).get("issueLabels") or {}
        etiquetas += pagina.get("nodes") or []
        info = pagina.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            break
        cursor = info.get("endCursor")
    return etiquetas


def _achar(etiquetas: list, time: str, nome: str, grupo: Optional[str], so_grupo: bool = False) -> str:
    """Id da etiqueta pelo nome (e pelo grupo-pai). A do próprio time vence a do workspace."""
    cands = [e for e in etiquetas
             if (e.get("name") or "").strip().lower() == nome.lower()
             and ((e.get("parent") or {}).get("name") or "").strip().lower() == (grupo or "").lower()
             and (not so_grupo or e.get("isGroup"))]
    cands.sort(key=lambda e: 0 if ((e.get("team") or {}).get("id") == time and time) else 1)
    return (cands[0].get("id") or "") if cands else ""


def resolver(consultar: Callable[[str, dict], dict], *, team_id: str = "", project_id: str = "",
             dono: str = DONO_PADRAO, lanes=(), nomes_estado: Optional[dict] = None,
             etiquetas: Optional[list] = None) -> dict:
    """Busca pelo nome os IDs que faltam. `consultar(query, variaveis)` devolve o `data` do GraphQL.

    Etiqueta do próprio time vence a do workspace; sem time, vale a do workspace."""
    d = vazio()
    time = team_id or time_do_projeto(consultar, project_id)
    nomes = {k: n for k, (_c, n) in ESTADOS.items()}
    nomes.update({k: v for k, v in (nomes_estado or {}).items() if v})
    if time:
        estados = (((consultar(Q_ESTADOS, {"id": time}) or {}).get("team") or {})
                   .get("states") or {}).get("nodes") or []
        por_nome = {(e.get("name") or "").strip().lower(): e.get("id") for e in estados}
        for k, nome in nomes.items():
            d["estados"][k] = por_nome.get(nome.strip().lower()) or ""
    if etiquetas is None:
        etiquetas = ler_etiquetas(consultar)
    for nome in (dono, FALHOU, PARADA):
        if nome and (i := _achar(etiquetas, time, nome, None)):
            d["labels"][nome] = i
    for e in ESFORCOS:
        if i := _achar(etiquetas, time, e, GRUPO_ESFORCO):
            d["esforco"][e] = i
    for lane in lanes:
        if i := _achar(etiquetas, time, lane, GRUPO_LANE):
            d["lanes"][lane] = i
    return d


def criar_faltando(consultar: Callable[[str, dict], dict], *, project_id: str, dono: str, lanes=(),
                   log: Callable[[str], None] = lambda _m: None) -> list:
    """Cria no time do projeto as etiquetas e os grupos que o fluxo usa e que não existem (FRA-569).

    Só cria o que a busca pelo nome, feita agora, confirmou que falta: com erro de rede a
    exceção sobe e nada é criado. Devolve os nomes criados."""
    time = time_do_projeto(consultar, project_id)
    if not time:
        return []
    etiquetas = ler_etiquetas(consultar)
    criadas: list = []
    pai_nome = ""

    def criar(nome: str, cor: str, pai: str = "", grupo: bool = False) -> str:
        entrada = {"name": nome, "teamId": time, "color": cor}
        if pai:
            entrada["parentId"] = pai
        if grupo:
            entrada["isGroup"] = True
        r = ((consultar(M_CRIAR_LABEL, {"input": entrada}) or {}).get("issueLabelCreate") or {})
        novo = (r.get("issueLabel") or {}).get("id", "") if r.get("success") else ""
        if novo:
            criadas.append(f"{pai_nome}/{nome}" if pai else (f"{nome} (grupo)" if grupo else nome))
            etiquetas.append({"id": novo, "name": nome, "isGroup": grupo, "team": {"id": time},
                              "parent": {"name": pai_nome} if pai else None})
        return novo

    for nome in (dono, FALHOU, PARADA):
        if nome and not _achar(etiquetas, time, nome, None):
            criar(nome, CORES.get(nome, CORES["dono"]))
    for grupo_nome, filhas in ((GRUPO_ESFORCO, ESFORCOS), (GRUPO_LANE, tuple(lanes))):
        faltam = [f for f in filhas if not _achar(etiquetas, time, f, grupo_nome)]
        if not faltam:
            continue
        pai_nome = grupo_nome
        pai = _achar(etiquetas, time, grupo_nome, None, so_grupo=True) or criar(
            grupo_nome, CORES["lane"] if grupo_nome == GRUPO_LANE else CORES["medio"], grupo=True)
        if not pai:
            continue
        for f in faltam:
            criar(f, CORES.get(f, CORES["lane"]), pai=pai)
    if criadas:
        log(f"linear: etiquetas criadas no time do projeto: {', '.join(criadas)}")
    return criadas


def garantir(get: Callable, consultar: Callable[[str, dict], dict], *, dono: str, lanes=(),
             project_id: str = "", caminho: Optional[Path] = None,
             log: Callable[[str], None] = lambda _m: None, criar: bool = True) -> dict:
    """Carrega; se faltar algo, resolve pela API, junta e grava o cache. Erro de rede não derruba.

    Com `criar`, as etiquetas e os grupos que faltam no time do projeto são criados (FRA-569)."""
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
    ainda = [f for f in faltando(ids, dono, lanes) if not f.startswith("estado:")]
    if ainda and criar and project_id:
        try:
            if criar_faltando(consultar, project_id=project_id, dono=dono, lanes=lanes, log=log):
                novos = resolver(consultar, project_id=project_id, dono=dono, lanes=lanes)
                cache = _juntar(ler_cache(caminho, project_id), novos)
                gravar_cache(cache, caminho, project_id)
                ids = _juntar(cache, da_config(get))
        except Exception as exc:  # noqa: BLE001 — sem permissão ou sem rede: avisa e segue
            log(f"linear: não consegui criar as etiquetas que faltam ({exc})")
    ainda = faltando(ids, dono, lanes)
    if ainda:
        log(f"linear: sem id no Linear para {', '.join(ainda)} (crie com esse nome ou ponha em linear.labels)")
    return ids
