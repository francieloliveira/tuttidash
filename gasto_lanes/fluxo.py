"""Resumo do fluxo a partir do log de eventos.

Conta claims, finalizações, merges e o tempo entre o claim e o finalize de cada
card/lane. Não é lead time do Linear (o evento não tem a entrada em Todo): é o
tempo de execução da lane, separado por projeto. Dado ausente não vira zero.
"""
from __future__ import annotations

import datetime as dt
from typing import Iterable


def _ts(valor):
    if not isinstance(valor, str) or not valor:
        return None
    try:
        return dt.datetime.fromisoformat(valor)
    except ValueError:
        return None


def resumo(eventos: Iterable[dict]) -> dict:
    """Totais por projeto, sem inventar medida quando falta o par claim/finalize."""
    por: dict[str, dict] = {}
    abertos: dict[tuple, dt.datetime] = {}
    for ev in eventos:
        if not isinstance(ev, dict):
            continue
        projeto = str(ev.get("projeto") or "").strip()
        card = str(ev.get("card") or "").strip()
        lane = str(ev.get("lane") or "").strip()
        etapa = str(ev.get("etapa") or "").strip()
        if not projeto or not card or not lane or not etapa:
            continue
        p = por.setdefault(projeto, {"projeto": projeto, "claims": 0, "finalizes": 0,
                                     "merges": 0, "falhas": 0, "paradas": 0,
                                     "duracoes_s": []})
        chave = (projeto, card, lane)
        if etapa == "claim":
            p["claims"] += 1
            ts = _ts(ev.get("ts"))
            if ts is not None:
                abertos[chave] = ts
        elif etapa == "finalize":
            p["finalizes"] += 1
            status = str(ev.get("status") or "").lower()
            if "falhou" in status:
                p["falhas"] += 1
            elif "parada" in status:
                p["paradas"] += 1
            ts = _ts(ev.get("ts"))
            inicio = abertos.pop(chave, None)
            if ts is not None and inicio is not None and ts >= inicio:
                p["duracoes_s"].append((ts - inicio).total_seconds())
        elif etapa == "merge":
            p["merges"] += 1

    saida = []
    for p in por.values():
        duracoes = p.pop("duracoes_s")
        p["abertos"] = sum(1 for k in abertos if k[0] == p["projeto"])
        p["duracao_media_min"] = (round(sum(duracoes) / len(duracoes) / 60, 1)
                                  if duracoes else None)
        p["finalizes_com_duracao"] = len(duracoes)
        saida.append(p)
    return {"projetos": sorted(saida, key=lambda x: x["projeto"]),
            "abertos_total": len(abertos)}


def texto(resumo_: dict) -> str:
    linhas = ["Fluxo por projeto (eventos)"]
    if not resumo_.get("projetos"):
        linhas.append("nenhum evento de claim/finalize/merge")
        return "\n".join(linhas)
    for p in resumo_["projetos"]:
        media = ("sem medida" if p["duracao_media_min"] is None
                 else f"{p['duracao_media_min']} min".replace(".", ","))
        linhas.append(
            f"{p['projeto']}: {p['claims']} claims, {p['finalizes']} finais, "
            f"{p['merges']} merges, {p['falhas']} falhas, {p['paradas']} paradas, "
            f"{p['abertos']} abertos, duração média {media}")
    linhas.append(f"abertos no total: {resumo_.get('abertos_total', 0)}")
    return "\n".join(linhas)
