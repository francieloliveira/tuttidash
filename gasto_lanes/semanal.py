"""Relatório semanal por projeto, a partir do ledger e do log de eventos.

Semana aqui é a janela dos últimos 7 dias (hoje + 6), a mesma do painel. O
relatório não inventa número: projeto sem execução/evento aparece como
«sem medida» e evento sem par claim→finalize não vira duração.
"""
from __future__ import annotations

import datetime as dt
from typing import Iterable, Optional

from . import fluxo as fluxomod
from . import report


def _dia_evento(ev: dict) -> Optional[dt.date]:
    ts = ev.get("ts") if isinstance(ev, dict) else None
    if not isinstance(ts, str) or len(ts) < 10:
        return None
    try:
        return dt.date.fromisoformat(ts[:10])
    except ValueError:
        return None


def _nome_por_id(projetos: Iterable):
    saida = {}
    for p in projetos or ():
        pid = getattr(p, "id", None) or (p.get("id") if isinstance(p, dict) else None)
        nome = getattr(p, "nome", None) or (p.get("nome") if isinstance(p, dict) else None)
        if pid:
            saida[str(pid)] = str(nome or pid)
    return saida


def gerar(execucoes: Iterable[dict], eventos: Iterable[dict], projetos: Iterable = (),
          hoje: Optional[dt.date] = None, dias: int = 7) -> dict:
    """Retrato da janela. Devolve {"semana", "inicio", "fim", "projetos": [...]}."""
    hoje = hoje or dt.date.today()
    dias = max(1, int(dias or 7))
    inicio = hoje - dt.timedelta(days=dias - 1)
    nomes = _nome_por_id(projetos)

    recs = []
    for r in execucoes or ():
        try:
            dia = dt.date.fromisoformat(r["dia"])
        except (KeyError, TypeError, ValueError):
            continue
        if inicio <= dia <= hoje:
            recs.append(r)
    evs = [e for e in (eventos or ()) if (d := _dia_evento(e)) is not None and inicio <= d <= hoje]

    # Execuções por projeto (id vazio = «sem projeto»).
    por_id: dict[str, list] = {}
    for r in recs:
        por_id.setdefault(str(r.get("projeto") or ""), []).append(r)
    # Eventos por projeto; o fluxo já devolve id vazio fora.
    por_fluxo = {p["projeto"]: p for p in fluxomod.resumo(evs)["projetos"]}

    ids = sorted(set(por_id) | set(por_fluxo) | set(nomes))
    saida = []
    for pid in ids:
        lista = por_id.get(pid, [])
        totais = report.totais(lista)
        f = por_fluxo.get(pid)
        nome = nomes.get(pid) or (pid or "sem projeto")
        saida.append({
            "projeto": pid,
            "nome": nome,
            "execucoes": totais["execucoes"],
            "ok": totais[report.STATUS_OK],
            "erro": totais[report.STATUS_ERRO],
            "morta": totais[report.STATUS_MORTA],
            "cancelada": totais[report.STATUS_CANCELADA],
            "custo_conhecido_usd": totais["custo_conhecido_usd"],
            "custo_desconhecido": totais["execucoes_custo_desconhecido"],
            "claims": f["claims"] if f else 0,
            "finalizes": f["finalizes"] if f else 0,
            "merges": f["merges"] if f else 0,
            "falhas": f["falhas"] if f else 0,
            "paradas": f["paradas"] if f else 0,
            "abertos": f["abertos"] if f else 0,
            "duracao_media_min": f["duracao_media_min"] if f else None,
        })
    return {"semana": f"{inicio.isoformat()} a {hoje.isoformat()}",
            "inicio": inicio.isoformat(), "fim": hoje.isoformat(), "projetos": saida}


def texto(resumo: dict) -> str:
    linhas = [f"# Relatório semanal — {resumo.get('semana', '')}", ""]
    for p in resumo.get("projetos", []):
        linhas.append(f"## {p['nome']}")
        if p["execucoes"] or p["claims"] or p["finalizes"] or p["merges"]:
            custo = report.usd(p["custo_conhecido_usd"])
            if p["custo_desconhecido"]:
                custo += f" + {p['custo_desconhecido']} sem custo"
            linhas.append(f"- Execuções: {p['execucoes']} (ok {p['ok']}, erro {p['erro']}, "
                          f"morta {p['morta']}, cancelada {p['cancelada']})")
            linhas.append(f"- Custo conhecido: {custo}")
            linhas.append(f"- Fluxo: {p['claims']} claims, {p['finalizes']} finais, "
                          f"{p['merges']} merges, {p['falhas']} falhas, {p['paradas']} paradas, "
                          f"{p['abertos']} abertos")
            media = ("sem medida" if p["duracao_media_min"] is None
                     else f"{str(p['duracao_media_min']).replace('.', ',')} min")
            linhas.append(f"- Duração média claim→finalize: {media}")
        else:
            linhas.append("- sem medida nesta janela")
        linhas.append("")
    if not resumo.get("projetos"):
        linhas.append("Nenhum projeto no cadastro e nenhuma execução na janela.")
    return "\n".join(linhas).rstrip() + "\n"
