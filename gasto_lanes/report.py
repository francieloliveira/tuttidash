"""Agregação e saída (texto e JSON) do gasto das lanes."""
from __future__ import annotations

import datetime as dt
from typing import Iterable, Optional

from .parser import (CUSTO_DESCONHECIDO, CUSTO_ESTIMADO, CUSTO_INFORMADO, STATUS_ANDAMENTO,
                     STATUS_CANCELADA, STATUS_ERRO, STATUS_MORTA, STATUS_OK, week_label)

DIMENSOES = ("dia", "semana", "card", "lane")
STATUSES = (STATUS_OK, STATUS_ERRO, STATUS_MORTA, STATUS_ANDAMENTO, STATUS_CANCELADA)

TETO_OK = "ok"
TETO_PERTO = "perto"
TETO_ESTOURADO = "estourado"
EXIT_TETO = {TETO_OK: 0, TETO_PERTO: 3, TETO_ESTOURADO: 4}


def filtrar(recs: Iterable[dict], desde: Optional[dt.date] = None, ate: Optional[dt.date] = None,
            lanes: Optional[set] = None, cards: Optional[set] = None) -> list:
    out = []
    for r in recs:
        dia = dt.date.fromisoformat(r["dia"])
        if desde and dia < desde:
            continue
        if ate and dia > ate:
            continue
        if lanes and r.get("lane") not in lanes:
            continue
        if cards and r.get("card") not in cards:
            continue
        out.append(r)
    return sorted(out, key=lambda r: (r.get("inicio") or "", r.get("id") or ""))


def _vazio(grupo: str) -> dict:
    row = {"grupo": grupo, "execucoes": 0}
    row.update({s: 0 for s in STATUSES})
    row.update({
        "custo_conhecido_usd": 0.0,
        "custo_estimado_usd": 0.0,      # claude (preço de tabela)
        "custo_informado_usd": 0.0,     # grok com API key
        "execucoes_custo_desconhecido": 0,
        "turnos": 0,
        "duracao_ms": 0,              # informada na linha result
        "duracao_estimada_ms": 0,     # sem duração informada: pela última escrita do log
        "tokens_total": 0,
    })
    return row


def _soma(row: dict, r: dict) -> None:
    row["execucoes"] += 1
    row[r.get("status", STATUS_MORTA)] = row.get(r.get("status", STATUS_MORTA), 0) + 1
    custo, tipo = r.get("custo_usd"), r.get("custo")
    if tipo == CUSTO_DESCONHECIDO or custo is None:
        row["execucoes_custo_desconhecido"] += 1
    else:
        row["custo_conhecido_usd"] += custo
        if tipo == CUSTO_ESTIMADO:
            row["custo_estimado_usd"] += custo
        elif tipo == CUSTO_INFORMADO:
            row["custo_informado_usd"] += custo
    row["turnos"] += r.get("turnos") or 0
    if r.get("duracao_ms"):
        row["duracao_ms"] += r["duracao_ms"]
    else:
        row["duracao_estimada_ms"] += r.get("duracao_estimada_ms") or 0
    toks = r.get("tokens") or (r.get("parcial") or {}).get("tokens") or {}
    row["tokens_total"] += toks.get("total", 0)


def _arredonda(row: dict) -> dict:
    for k in ("custo_conhecido_usd", "custo_estimado_usd", "custo_informado_usd"):
        row[k] = round(row[k], 4)
    return row


def agrupar(recs: list, dim: str) -> list:
    rows: dict = {}
    for r in recs:
        k = r.get(dim) or "?"
        rows.setdefault(k, _vazio(k))
        _soma(rows[k], r)
    if dim in ("dia", "semana"):
        ordem = sorted(rows)
    else:  # card e lane: maior gasto primeiro, depois mais execuções
        ordem = sorted(rows, key=lambda k: (-rows[k]["custo_conhecido_usd"], -rows[k]["execucoes"], k))
    return [_arredonda(rows[k]) for k in ordem]


def totais(recs: list) -> dict:
    row = _vazio("total")
    for r in recs:
        _soma(row, r)
    return _arredonda(row)


def avaliar_teto(recs: list, teto: Optional[float], aviso_pct: float, hoje: dt.date) -> Optional[dict]:
    """Só avalia e avisa. Não cria PAUSE nem toca em nada das lanes."""
    if teto is None or teto <= 0:
        return None
    semana = week_label(hoje)
    da_semana = [r for r in recs if r.get("semana") == semana]
    t = totais(da_semana)
    gasto = t["custo_conhecido_usd"]
    pct = gasto / teto * 100
    if gasto >= teto:
        status = TETO_ESTOURADO
    elif pct >= aviso_pct:
        status = TETO_PERTO
    else:
        status = TETO_OK
    return {
        "semana": semana,
        "teto_usd": round(teto, 4),
        "aviso_pct": aviso_pct,
        "gasto_conhecido_usd": gasto,
        "pct": round(pct, 1),
        "execucoes": t["execucoes"],
        "execucoes_custo_desconhecido": t["execucoes_custo_desconhecido"],
        "status": status,
        "exit_code": EXIT_TETO[status],
    }


# --- Texto ------------------------------------------------------------------
def usd(v: float) -> str:
    s = f"{v:,.2f}"                       # 1,234.56
    s = s.replace(",", "_").replace(".", ",").replace("_", ".")
    return f"US$ {s}"


def dur(ms: int) -> str:
    m = int(ms // 60000)
    if m < 60:
        return f"{m} min"
    return f"{m // 60} h {m % 60:02d}"


def tok(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M".replace(".", ",")
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def _custo_txt(row: dict) -> str:
    n_desc = row["execucoes_custo_desconhecido"]
    if n_desc and n_desc == row["execucoes"]:
        return f"desconhecido ({n_desc})"
    base = usd(row["custo_conhecido_usd"])
    if row["execucoes_custo_desconhecido"]:
        base += f" + {row['execucoes_custo_desconhecido']} desconh."
    return base


def _status_txt(row: dict) -> str:
    parts = []
    for s, nome in ((STATUS_OK, "ok"), (STATUS_ERRO, "erro"), (STATUS_MORTA, "morta"),
                    (STATUS_ANDAMENTO, "andamento"), (STATUS_CANCELADA, "cancelada")):
        if row[s]:
            parts.append(f"{row[s]} {nome}")
    return ", ".join(parts) or "0"


def _dur_txt(row: dict) -> str:
    txt = dur(row["duracao_ms"]) if row["duracao_ms"] else ("" if row["duracao_estimada_ms"] else "0 min")
    if row["duracao_estimada_ms"]:
        txt += (" +" if txt else "") + f"~{dur(row['duracao_estimada_ms'])}"
    return txt


def tabela(rows: list, titulo: str) -> list:
    head = (titulo, "execs", "status", "custo", "turnos", "duração", "tokens")
    body = [(r["grupo"], str(r["execucoes"]), _status_txt(r), _custo_txt(r), str(r["turnos"]),
             _dur_txt(r), tok(r["tokens_total"])) for r in rows]
    widths = [max(len(x[i]) for x in [head] + body) for i in range(len(head))]
    fmt = lambda cols: "  ".join(c.ljust(widths[i]) for i, c in enumerate(cols)).rstrip()  # noqa: E731
    out = [fmt(head), fmt(tuple("-" * w for w in widths))]
    out += [fmt(b) for b in body]
    return out


def teto_txt(t: dict) -> str:
    base = (f"Teto semanal {t['semana']}: {usd(t['gasto_conhecido_usd'])} de {usd(t['teto_usd'])} "
            f"({str(t['pct']).replace('.', ',')}%)")
    if t["status"] == TETO_ESTOURADO:
        msg = f"AVISO: teto semanal atingido. {base}."
    elif t["status"] == TETO_PERTO:
        msg = f"Atenção: perto do teto semanal (aviso em {t['aviso_pct']:g}%). {base}."
    else:
        msg = f"{base}. Dentro do teto."
    if t["execucoes_custo_desconhecido"]:
        msg += (f" O gasto real pode ser maior: {t['execucoes_custo_desconhecido']} execução(ões) "
                "da semana com custo desconhecido.")
    msg += " (Só aviso: nada foi pausado.)"
    return msg


def estado_txt(estado: Optional[dict]) -> list:
    """Linhas de estado atual. Campo ausente fica de fora: nunca imprime 'None'."""
    if not estado:
        return []
    out = []
    hb = estado.get("heartbeat")
    if isinstance(hb, dict) and isinstance(hb.get("at"), str) and hb["at"].strip():
        modo = "simulação" if hb.get("dry_run", True) else "real"
        enabled = hb.get("enabled")
        nomes = [str(x) for x in enabled if x] if isinstance(enabled, list) else []
        out.append(f"Dispatcher: último ciclo {hb['at'].strip()} ({modo}); "
                   f"habilitadas: {', '.join(nomes) or 'nenhuma'}")
    for lane, st in sorted((estado.get("lanes") or {}).items()):
        if not isinstance(st, dict) or not st.get("card"):
            continue
        line = f"lane:{lane} ocupada com {st['card']}"
        if st.get("started_at"):
            line += f" desde {st['started_at']}"
        if st.get("stuck"):
            line += " (TRAVADA)"
        out.append(line)
    return out


def render_text(recs: list, dims: list, teto: Optional[dict], estado: Optional[dict] = None,
                filtros: str = "") -> str:
    lines = ["Gasto das lanes" + (f" ({filtros})" if filtros else "")]
    t = totais(recs)
    lines.append(f"Total: {t['execucoes']} execuções ({_status_txt(t)}), custo conhecido {usd(t['custo_conhecido_usd'])}"
                 f" (estimado {usd(t['custo_estimado_usd'])}, informado {usd(t['custo_informado_usd'])})"
                 f", custo desconhecido em {t['execucoes_custo_desconhecido']}.")
    lines += estado_txt(estado)
    for dim in dims:
        lines.append("")
        lines += tabela(agrupar(recs, dim), dim)
    if teto:
        lines.append("")
        lines.append(teto_txt(teto))
    lines.append("")
    lines.append("custo: estimado é a preço de tabela; 'desconh.' = sem linha result, "
                 "custo 0/ausente (ex.: OAuth sem custo) ou parcial. Desconhecido não entra na soma.")
    lines.append("~ = estimado pela última escrita do log (execução sem duração informada).")
    return "\n".join(lines)


def render_json(recs: list, dims: list, teto: Optional[dict], estado: Optional[dict] = None,
                filtros: Optional[dict] = None) -> dict:
    est = None
    if estado:
        est = {"heartbeat": estado.get("heartbeat"), "lanes": estado.get("lanes")}
    return {
        "filtros": filtros or {},
        "total": totais(recs),
        "por": {dim: agrupar(recs, dim) for dim in dims},
        "teto": teto,
        "estado": est,
    }


def execucoes_txt(recs: list) -> str:
    head = ("início", "card", "lane", "status", "custo", "turnos", "duração", "tokens", "modelo")
    body = []
    for r in recs:
        if r.get("custo_usd") is None:
            c = "desconhecido"
        else:
            c = usd(r["custo_usd"]) + (" (est.)" if r.get("custo") == CUSTO_ESTIMADO else "")
        d = r.get("duracao_ms")
        dtxt = dur(d) if d else (f"~{dur(r['duracao_estimada_ms'])}" if r.get("duracao_estimada_ms") else "?")
        toks = r.get("tokens")
        if toks:
            ttxt = tok(toks["total"])
        elif (r.get("parcial") or {}).get("tokens"):
            ttxt = f"~{tok(r['parcial']['tokens']['total'])}"
        else:
            ttxt = "?"
        turnos = r.get("turnos")
        if turnos is None and r.get("parcial"):
            ttn = f"~{r['parcial']['respostas']}"
        else:
            ttn = "?" if turnos is None else str(turnos)
        status = r.get("status", "?")
        if r.get("subtipo") and status == STATUS_ERRO:
            status += f" ({r['subtipo']})"
        body.append((r["inicio"].replace("T", " "), r["card"], r["lane"], status, c, ttn, dtxt, ttxt,
                     r.get("modelo") or "?"))
    if not body:
        return "Nenhuma execução encontrada."
    widths = [max(len(x[i]) for x in [head] + body) for i in range(len(head))]
    fmt = lambda cols: "  ".join(c.ljust(widths[i]) for i, c in enumerate(cols)).rstrip()  # noqa: E731
    out = [fmt(head), fmt(tuple("-" * w for w in widths))] + [fmt(b) for b in body]
    out.append("")
    out.append("~ = parcial/estimado (execução sem linha result: turnos e tokens até onde o log foi).")
    return "\n".join(out)
