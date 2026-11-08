"""Regras puras da fila: o vigia promove e o dispatcher escolhe a lane com o mesmo filtro.

Este módulo não fala com Linear, tmux, git nem com o catálogo: recebe o card e os
dados de cota/vagas. É importado pelos dois scripts instalados (bots/watch.py e
lanes/dispatcher.py), para não existirem duas réguas diferentes de lane.
"""
from __future__ import annotations

import re
import time
from typing import Callable, Optional

HEADROOM_PCT = {"baixo": 90, "medio": 80, "alto": 60}
# Medida sem % que ainda tem folga: o motivo tipado do lanepct (5ª coluna) diz que a conta
# não tem janela de limite. Qualquer outro motivo sem % é falha de leitura e fecha a fila.
SEM_LIMITE = frozenset({"sem_janelas", "sem_limite_incluido", "cota_compartilhada"})
# Conta pré-paga (ex.: DeepSeek): sem janela, com saldo em US$ na 6ª coluna.
CODIGO_SALDO = "saldo"
# Saldo mínimo para o esforço entrar. Ajustável em `cota.piso_saldo_usd` na config.
PISO_SALDO_USD = {"baixo": 0.5, "medio": 1.0, "alto": 2.0}
# Lugar de uma conta de saldo na ordem por %: paga por uso, fica atrás das cotas incluídas com folga.
PCT_ORDEM_SALDO = 50.0
HEADROOM_PCT_LONGA = {"baixo": 95, "medio": 90, "alto": 85}
JANELA_LONGA_RE = re.compile(r"\d+\s*dias?\b|semana|m[êe]s\b|mensal", re.I)
EFFORT_EN = {"baixo": "low", "medio": "medium", "alto": "high"}

Manifesto = Callable[[str], dict]


def contexto_card(ci: dict) -> dict:
    """O que o card pede: lane, esforço, risco e pessoa atribuída."""
    nodes = ci.get("labels", {}).get("nodes", [])
    lanes = [n["name"] for n in nodes if (n.get("parent") or {}).get("name") == "lane"]
    esforcos = [n["name"] for n in nodes if (n.get("parent") or {}).get("name") == "esforco"]
    riscos = [n["name"] for n in nodes if n["name"].startswith("risco:")]
    return {
        "lane": lanes[0] if len(lanes) == 1 else None,
        "lane_invalida": len(lanes) > 1,
        "effort": esforcos[0] if len(esforcos) == 1 else None,
        "effort_invalido": len(esforcos) > 1,
        "risk": riscos[0] if riscos else "",
        "assignee": (ci.get("assignee") or {}).get("id") or "",
    }


def cap_esforco(effort: str, janela: str) -> int:
    tabela = HEADROOM_PCT_LONGA if JANELA_LONGA_RE.search(janela or "") else HEADROOM_PCT
    return tabela.get(effort, tabela["medio"])


def codigo_medida(medida) -> str:
    """Motivo tipado da medida (5ª coluna do lanepct). Formato antigo, de 2 campos, = ""."""
    if not medida or len(medida) < 3 or not medida[2]:
        return ""
    return str(medida[2])


def saldo_medida(medida) -> Optional[float]:
    """Saldo em US$ da medida (6ª coluna do lanepct), ou None."""
    if not medida or len(medida) < 4 or medida[3] in (None, ""):
        return None
    try:
        v = float(medida[3])
    except (TypeError, ValueError):
        return None
    return v if v == v and v not in (float("inf"), float("-inf")) else None


_pisos_cache: dict = {"at": 0.0, "v": None}


def _obter_config(chave: str):
    try:
        import config as _config  # gasto_lanes no sys.path (dispatcher/vigia instalados)
    except ImportError:
        from gasto_lanes import config as _config  # type: ignore
    return _config.obter(chave)


def pisos_saldo() -> dict:
    """Pisos de saldo por esforço: padrão + `cota.piso_saldo_usd` da config (lido a cada minuto)."""
    agora = time.time()
    if _pisos_cache["v"] is not None and agora - _pisos_cache["at"] < 60:
        return _pisos_cache["v"]
    pisos = dict(PISO_SALDO_USD)
    try:
        extra = _obter_config("cota.piso_saldo_usd") or {}
    except Exception:  # noqa: BLE001 - config ilegível não derruba a fila
        extra = {}
    if isinstance(extra, dict):
        for k, v in extra.items():
            if k in pisos and isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0:
                pisos[k] = float(v)
    _pisos_cache.update(at=agora, v=pisos)
    return pisos


def piso_saldo(effort: str, pisos: Optional[dict] = None) -> float:
    tabela = pisos if pisos is not None else pisos_saldo()
    return tabela.get(effort, tabela.get("medio", PISO_SALDO_USD["medio"]))


def folga_sem_pct(medida, effort: str, pisos: Optional[dict] = None) -> bool:
    """Medida sem %: só tem folga se o motivo tipado diz que não há janela, ou se o saldo
    cobre o piso do esforço. Formato antigo (sem código) e falha de leitura: sem folga."""
    codigo = codigo_medida(medida)
    if codigo in SEM_LIMITE:
        return True
    if codigo == CODIGO_SALDO:
        saldo = saldo_medida(medida)
        return saldo is not None and saldo >= piso_saldo(effort, pisos)
    return False


def cota_ok(lane: str, effort: str, medidas: dict, pisos: Optional[dict] = None) -> bool:
    """Há folga de cota para este esforço nesta lane?"""
    medida = medidas.get(lane)
    if not medida:
        return False
    if medida[0] is None:
        return folga_sem_pct(medida, effort, pisos)
    try:
        pct = float(medida[0])
    except (TypeError, ValueError):
        return False
    janela = str(medida[1] if len(medida) > 1 else "")
    return pct < cap_esforco(effort, janela)


def esforco_suportado(lane: str, effort: str, manifesto: dict) -> bool:
    esforcos = {str(e).lower() for e in (manifesto or {}).get("esforcos") or []}
    if not esforcos:
        return True
    return EFFORT_EN.get(effort, effort).lower() in esforcos


def card_em_cooldown(ci: dict, st: dict, cooldown_s: float) -> bool:
    per_card = (st.get("stops") or {}).get(ci.get("identifier") or "") or {}
    try:
        ultimo = float(per_card.get("ultimo") or 0)
    except (TypeError, ValueError):
        return False
    return bool(ultimo and time.time() - ultimo < cooldown_s)


def lane_em_cooldown(st: dict, lane: str, cooldown_s: float) -> bool:
    try:
        ultimo = float((st.get("lane_falhas") or {}).get(lane) or 0)
    except (TypeError, ValueError):
        return False
    return bool(ultimo and time.time() - ultimo < cooldown_s)


def atribuido_a_outro(ci: dict, viewer: str) -> bool:
    assignee = (ci.get("assignee") or {}).get("id") or ""
    return bool(assignee and viewer and assignee != viewer)


def escolher_lane(ci: dict, com_folga: set[str], medidas: dict, usados: dict,
                  max_per_lane: int, manifesto_de: Manifesto,
                  risco_alto: set[str] | tuple[str, ...] = ()) -> Optional[str]:
    """Lane concreta que consegue rodar o card agora, ou None.

    Não conhece arquivos/comentários: quem chama aplica esses freios antes.
    """
    ctx = contexto_card(ci)
    if ctx["lane_invalida"] or ctx["effort_invalido"]:
        return None
    effort = ctx["effort"] or "medio"
    candidatas = [ctx["lane"]] if ctx["lane"] else sorted(com_folga)
    validas = []
    for lane in candidatas:
        if lane not in com_folga:
            continue
        if not esforco_suportado(lane, effort, manifesto_de(lane)):
            continue
        if not cota_ok(lane, effort, medidas):
            continue
        if usados.get(lane, 0) >= max_per_lane:
            continue
        validas.append(lane)
    if not validas:
        return None
    if ctx["risk"] == "risco:alto" and not ctx["lane"]:
        # Preferência, não bloqueio: risco alto tenta Claude/Grok primeiro.
        validas.sort(key=lambda l: (0 if l in risco_alto else 1, usados.get(l, 0), l))
        return validas[0]
    return min(validas, key=lambda l: (usados.get(l, 0), l))


def ler_saude(caminho) -> dict:
    """Lê a saúde compartilhada das lanes; arquivo ausente/ilegível = sem bloqueio."""
    import json
    from pathlib import Path
    try:
        dados = json.loads(Path(caminho).read_text())
        return dados if isinstance(dados, dict) else {}
    except (OSError, ValueError, AttributeError):
        return {}


def gravar_saude(caminho, saude: dict) -> None:
    import json
    from pathlib import Path
    p = Path(caminho)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(saude, ensure_ascii=False, indent=1))
    tmp.replace(p)


def marcar_falha_lane(caminho, lane: str, motivo: str, cooldown_s: float,
                      quando: Optional[float] = None) -> None:
    quando = time.time() if quando is None else float(quando)
    saude = ler_saude(caminho)
    saude[lane] = {"ate": quando + cooldown_s, "motivo": motivo}
    gravar_saude(caminho, saude)


def lane_saudavel(saude: dict, lane: str, agora: Optional[float] = None) -> bool:
    agora = time.time() if agora is None else float(agora)
    try:
        return float((saude.get(lane) or {}).get("ate") or 0) <= agora
    except (TypeError, ValueError):
        return True


_ARQUIVO_RE = re.compile(
    r"((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\."
    r"(?:swift|plist|json|ya?ml|py|sh|xcstrings|strings|entitlements))")
_LANE_FILES = {"result.json", "settings.json", "settings.local.json", ".mcp.json", "mcp.json"}


def arquivos_card(ci: dict) -> set[str]:
    """Nomes de arquivo citados no card, ignorando a infraestrutura das lanes."""
    out = set()
    for achado in _ARQUIVO_RE.finditer(ci.get("description") or ""):
        caminho = achado.group(1)
        nome = caminho.rsplit("/", 1)[-1]
        if caminho.startswith(".lane") or "/.lane/" in caminho or nome in _LANE_FILES:
            continue
        out.add(nome)
    return out


def conflita(card: dict, ocupados: dict) -> Optional[str]:
    """Outro card ativo que toca os mesmos arquivos (nome), ou None."""
    meus = arquivos_card(card)
    if not meus:
        return None
    for ident, arquivos in (ocupados or {}).items():
        if ident != card.get("identifier") and meus & set(arquivos or ()):
            return ident
    return None
