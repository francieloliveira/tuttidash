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


def cota_ok(lane: str, effort: str, medidas: dict) -> bool:
    """Há folga de cota para este esforço nesta lane?"""
    medida = medidas.get(lane)
    if not medida or medida[0] is None:
        return False
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
