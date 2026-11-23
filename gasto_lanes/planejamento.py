"""Visão de planejamento do portfólio: ordem, ocupação e sinais por projeto.

Leitura pura: usa cadastro, estado das lanes, ledger e eventos. Não muda fila,
prioridade nem config. O objetivo é responder «quem vem agora, quem está
ocupado e quem está sem sinal» antes de o dispatcher decidir.
"""
from __future__ import annotations

import datetime as dt
from typing import Iterable

from . import agenda, fluxo, report


def _data(ts):
    if not isinstance(ts, str) or len(ts) < 10:
        return None
    try:
        return dt.date.fromisoformat(ts[:10])
    except ValueError:
        return None


def quadro(projetos: Iterable, execucoes: Iterable[dict], eventos: Iterable[dict],
           estado_lanes: Iterable = (), hoje: dt.date | None = None) -> dict:
    hoje = hoje or dt.date.today()
    inicio = hoje - dt.timedelta(days=6)
    projetos = list(projetos or ())
    recs = []
    for r in execucoes or ():
        try:
            d = dt.date.fromisoformat(r["dia"])
        except (KeyError, TypeError, ValueError):
            continue
        if inicio <= d <= hoje:
            recs.append(r)
    evs = [e for e in (eventos or ()) if (d := _data(e.get("ts"))) is not None and inicio <= d <= hoje]
    fluxos = {p["projeto"]: p for p in fluxo.resumo(evs)["projetos"]}
    rodando = {}
    for lane in estado_lanes or ():
        pid = getattr(lane, "projeto", "") if not isinstance(lane, dict) else lane.get("projeto")
        if pid:
            rodando[pid] = rodando.get(pid, 0) + 1
    ordem = agenda.ordenar(projetos)
    proximo = agenda.escolher(projetos, "") if ordem else None

    itens = []
    for p in projetos:
        pid = getattr(p, "id", "")
        lista = [r for r in recs if r.get("projeto") == pid]
        totais = report.totais(lista)
        f = fluxos.get(pid)
        itens.append({
            "projeto": pid,
            "nome": getattr(p, "nome", pid),
            "ativo": bool(getattr(p, "ativo", False)),
            "prioridade": int(getattr(p, "prioridade", 0) or 0),
            "max_lanes": int(getattr(p, "max_lanes", 0) or 0),
            "rodando": rodando.get(pid, 0),
            "custo_7d_usd": totais["custo_conhecido_usd"],
            "execucoes_7d": totais["execucoes"],
            "claims": f["claims"] if f else 0,
            "merges": f["merges"] if f else 0,
            "abertos": f["abertos"] if f else 0,
            "objetivo": getattr(p, "objetivo", "") or "",
            "situacao": getattr(p, "situacao", "") or "",
            "inicio": getattr(p, "inicio", "") or "",
            "alvo": getattr(p, "alvo", "") or "",
            "marcos": list(getattr(p, "marcos", ()) or ()),
            "sinal": "sem sinal" if not lista and not (f and (f["claims"] or f["merges"])) else "com sinal",
        })
    pos = {pid: i for i, pid in enumerate(getattr(p, "id", "") for p in ordem)}
    itens.sort(key=lambda it: (0, pos[it["projeto"]]) if it["projeto"] in pos else (1, it["nome"]))
    alertas = []
    for it in itens:
        if it["ativo"] and it["sinal"] == "sem sinal":
            alertas.append(f"{it['nome']}: ativo, mas sem execução/evento nos últimos 7 dias")
        if it["ativo"] and it["max_lanes"] == 0 and it["rodando"]:
            alertas.append(f"{it['nome']}: rodando sem limite de lanes próprio")
    return {"inicio": inicio.isoformat(), "fim": hoje.isoformat(),
            "proximo": getattr(proximo, "id", "") if proximo else "",
            "ordem": [getattr(p, "id", "") for p in ordem],
            "projetos": itens, "alertas": alertas}


def texto(r: dict) -> str:
    linhas = [f"Planejamento — {r['inicio']} a {r['fim']}"]
    nomes = {p["projeto"]: p["nome"] for p in r["projetos"]}
    if r.get("ordem"):
        linhas.append("ordem: " + " > ".join(nomes.get(i, i) for i in r["ordem"]))
    if r.get("proximo"):
        linhas.append("próximo: " + nomes.get(r["proximo"], r["proximo"]))
    for p in r["projetos"]:
        estado = "ligado" if p["ativo"] else "desligado"
        limite = p["max_lanes"] or "global"
        linha = (f"- {p['nome']} [{estado}] prioridade {p['prioridade']}, "
                 f"lanes {p['rodando']}/{limite}, custo {report.usd(p['custo_7d_usd'])}, "
                 f"{p['claims']} claims, {p['merges']} merges, {p['sinal']}")
        if p.get("objetivo"):
            linha += f", objetivo: {p['objetivo']}"
        if p.get("alvo"):
            linha += f", alvo: {p['alvo']}"
        linhas.append(linha)
    if r.get("alertas"):
        linhas.append("alertas:")
        linhas += [f"- {a}" for a in r["alertas"]]
    return "\n".join(linhas)
