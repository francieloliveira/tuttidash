"""Trilha de auditoria a partir dos eventos: decisão, final e merge por card.

É leitura pura. Não substitui o log operacional; responde «o que aconteceu com
este card/projeto e por quê» com os campos que o evento já guarda.
"""
from __future__ import annotations

import datetime as dt
from typing import Iterable


def _ts(ev):
    valor = ev.get("ts") if isinstance(ev, dict) else None
    if not isinstance(valor, str):
        return None
    try:
        return dt.datetime.fromisoformat(valor)
    except ValueError:
        return None


def filtrar(eventos: Iterable[dict], *, projeto: str = "", card: str = "",
            etapa: str = "", desde: dt.date | None = None, ate: dt.date | None = None) -> list:
    out = []
    card = (card or "").upper()
    for ev in eventos or ():
        if not isinstance(ev, dict):
            continue
        if projeto and ev.get("projeto") != projeto:
            continue
        if card and str(ev.get("card") or "").upper() != card:
            continue
        if etapa and ev.get("etapa") != etapa:
            continue
        d = _ts(ev)
        if desde and (d is None or d.date() < desde):
            continue
        if ate and (d is None or d.date() > ate):
            continue
        out.append(ev)
    return sorted(out, key=lambda e: (str(e.get("ts") or ""), str(e.get("id") or "")))


def linhas(eventos: Iterable[dict]) -> list:
    saida = []
    for ev in eventos:
        partes = [str(ev.get("ts") or ""), str(ev.get("projeto") or ""),
                  str(ev.get("card") or ""), str(ev.get("lane") or ""), str(ev.get("etapa") or "")]
        if ev.get("status"):
            partes.append(str(ev["status"]))
        if ev.get("motivo"):
            partes.append(str(ev["motivo"]))
        if ev.get("sha"):
            partes.append("SHA " + str(ev["sha"])[:12])
        if ev.get("pr"):
            partes.append(str(ev["pr"]))
        saida.append("  ".join(p for p in partes if p))
    return saida
