"""Leitura de um log de execução de lane (somente leitura).

Formato do nome (dispatcher.py, claim()):
    <CARD>-<lane>-<AAAAMMDD-HHMMSS>.jsonl      ex.: FRA-259-grok-20261004-153012.jsonl

Conteúdo: stream JSON por linha. claude usa --output-format stream-json e o grok
usa streaming-messages-json; os dois abrem com system/init e fecham com uma linha
type=result (custo, turnos, duração, tokens). Execução morta (timeout, SIGTERM,
parada pelo menu) não tem linha result. Como o run_lane.sh faz 2>&1, linhas de
stderr que não são JSON podem aparecer no meio: são contadas e ignoradas.
"""
from __future__ import annotations

import datetime as dt
import json
import re
from pathlib import Path
from typing import Iterable, Optional

NAME_RE = re.compile(
    r"^(?P<card>[A-Za-z][A-Za-z0-9]*-\d+)-(?P<lane>[a-z][a-z0-9_-]*)-(?P<stamp>\d{8}-\d{6})\.jsonl$")

STATUS_OK = "ok"
STATUS_ERRO = "erro"
STATUS_MORTA = "morta"
STATUS_ANDAMENTO = "em_andamento"
STATUS_CANCELADA = "cancelada"     # parada pedida (cancelled/aborted), não é falha do agente

CUSTO_ESTIMADO = "estimado"        # claude: calculado pelo cliente a preço de tabela
CUSTO_INFORMADO = "informado"      # grok com API key: informado pelo servidor
CUSTO_DESCONHECIDO = "desconhecido"
CUSTO_GRATIS = "gratis"            # modelo grátis (opencode free): zero de verdade
CUSTO_PLANO = "plano"              # assinatura de preço fixo (codex, opencode-go)

OPENCODE_TIPOS = {"step_start", "step_finish", "text", "tool_use", "reasoning"}


class FormatoOutro:
    """Logs do opencode e do codex (sem a linha `result` do Claude). Igual ao ParserLog.swift."""

    def __init__(self):
        self.formato = None
        self.ultimo = None
        self.ultimo_motivo = None
        self.erros = []
        self.cancelou = False
        self.concluiu = False
        self.custo = 0.0
        self.tokens = 0

    def ver(self, t: str, ev: dict) -> None:
        if t in OPENCODE_TIPOS:
            self.formato = "opencode"
        if t.startswith(("thread.", "turn.", "item.")):
            self.formato = "codex"
        if t in ("error", "turn.failed"):
            if self.formato is None:
                self.formato = "opencode" if "sessionID" in ev else "codex"
            e = ev.get("error") if isinstance(ev.get("error"), dict) else {}
            msg = e.get("message") or e.get("name") or ev.get("message") or t
            nome = f"{e.get('name') or ''} {msg}".lower()
            if "abort" in nome or "cancel" in nome:
                self.cancelou = True
            self.erros.append(str(msg)[:200])
        elif t == "turn.completed":
            self.concluiu = True
            u = ev.get("usage") or {}
            self.tokens += (_int(u.get("input_tokens")) or 0) + (_int(u.get("output_tokens")) or 0)
        elif t == "step_finish":
            part = ev.get("part") or {}
            self.ultimo_motivo = part.get("reason")
            c = part.get("cost")
            if isinstance(c, (int, float)) and not isinstance(c, bool) and c > 0:
                self.custo += float(c)
            tk = part.get("tokens") or {}
            cache = tk.get("cache") or {}
            self.tokens += sum(_int(tk.get(k)) or 0 for k in ("input", "output", "reasoning"))
            self.tokens += (_int(cache.get("read")) or 0) + (_int(cache.get("write")) or 0)
        self.ultimo = t

    def status(self, rodando: bool):
        if self.formato is None:
            return None
        if self.cancelou:
            return STATUS_CANCELADA
        if self.erros:
            return STATUS_ERRO
        if rodando:
            return STATUS_ANDAMENTO
        if self.formato == "codex":
            return STATUS_OK if self.concluiu else STATUS_MORTA
        if self.ultimo == "text" or (self.ultimo == "step_finish" and self.ultimo_motivo == "stop"):
            return STATUS_OK
        return STATUS_MORTA

    def classificar_custo(self, lane: str) -> tuple:
        if self.custo > 0:
            return self.custo, CUSTO_INFORMADO
        if self.formato == "opencode" and lane == "opencode":
            return 0.0, CUSTO_GRATIS
        return 0.0, CUSTO_PLANO

# Catálogo de agentes: fonte única em `agentes.py` (FRA-372).
from .agentes import AGENTES_CONHECIDOS, custo_para

# Aliases de compatibilidade (a fonte é `agentes.AGENTES`).
CUSTO_TIPO_POR_AGENTE = {nome: custo_para(nome) for nome in AGENTES_CONHECIDOS}


def tipo_custo_para_agente(lane: str) -> str:
    """Tipo de custo padrão de um agente com custo > 0. Desconhecido vira informado."""
    return custo_para(lane)

TOKEN_KEYS = (
    ("entrada", "input_tokens"),
    ("saida", "output_tokens"),
    ("cache_leitura", "cache_read_input_tokens"),
    ("cache_criacao", "cache_creation_input_tokens"),
)


def parse_name(name: str) -> Optional[dict]:
    m = NAME_RE.match(name)
    if not m:
        return None
    try:
        inicio = dt.datetime.strptime(m.group("stamp"), "%Y%m%d-%H%M%S")
    except ValueError:
        return None
    iso = inicio.isocalendar()
    return {
        "id": name[: -len(".jsonl")],
        "arquivo": name,
        "card": m.group("card").upper(),
        "lane": m.group("lane"),
        "inicio": inicio.isoformat(),
        "dia": inicio.date().isoformat(),
        "semana": f"{iso[0]}-W{iso[1]:02d}",
    }


def week_label(day: dt.date) -> str:
    iso = day.isocalendar()
    return f"{iso[0]}-W{iso[1]:02d}"


def _int(v) -> Optional[int]:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return int(v)


def tokens_from_usage(usage) -> Optional[dict]:
    """Converte usage (formato Messages) para chaves em pt-BR. Tudo zero = desconhecido."""
    if not isinstance(usage, dict):
        return None
    out = {}
    for pt, en in TOKEN_KEYS:
        out[pt] = _int(usage.get(en)) or 0
    out["total"] = sum(out.values())
    return out if out["total"] > 0 else None


def _sum_tokens(items: Iterable[dict]) -> Optional[dict]:
    acc = {pt: 0 for pt, _ in TOKEN_KEYS}
    for t in items:
        for pt, _ in TOKEN_KEYS:
            acc[pt] += t.get(pt, 0)
    acc["total"] = sum(acc.values())
    return acc if acc["total"] > 0 else None


def classify_cost(lane: str, result: Optional[dict], auth: Optional[str]) -> tuple:
    """(custo_usd ou None, tipo). Zero, ausente ou parcial = desconhecido, nunca 'grátis'."""
    if not result:
        return None, CUSTO_DESCONHECIDO
    if result.get("cost_is_partial") or result.get("usage_is_incomplete"):
        return None, CUSTO_DESCONHECIDO
    cost = result.get("total_cost_usd")
    if isinstance(cost, bool) or not isinstance(cost, (int, float)) or cost <= 0:
        return None, CUSTO_DESCONHECIDO
    return float(cost), tipo_custo_para_agente(lane)


def parse_log(path: Path, running: Optional[set] = None) -> Optional[dict]:
    """Extrai uma execução do log. Abre só para leitura. None se o nome não segue o padrão."""
    meta = parse_name(path.name)
    if meta is None:
        return None
    running = running or set()

    st = path.stat()
    init: Optional[dict] = None
    result: Optional[dict] = None
    invalid = 0
    partial_usage: dict = {}      # message.id -> tokens (a mesma mensagem se repete por bloco)
    anon_responses = 0
    outro = FormatoOutro()

    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
            except ValueError:
                invalid += 1
                continue
            if not isinstance(ev, dict):
                invalid += 1
                continue
            t = ev.get("type")
            if t == "system" and ev.get("subtype") == "init" and init is None:
                init = ev
            elif t == "assistant" and ev.get("parent_tool_use_id") in (None, ""):
                msg = ev.get("message") or {}
                toks = tokens_from_usage(msg.get("usage")) or {}
                mid = msg.get("id")
                if mid:
                    partial_usage[mid] = toks
                else:
                    anon_responses += 1
                    partial_usage[f"_anon{anon_responses}"] = toks
            elif t == "result":
                result = ev   # vale a última
            elif isinstance(t, str):
                outro.ver(t, ev)

    auth = (init or {}).get("apiKeySource")
    model = (init or {}).get("model")
    rec = dict(meta)
    rec["modelo"] = model if model and model != "unknown" else None
    rec["auth"] = auth

    if result is not None:
        subtype = result.get("subtype")
        errors = result.get("errors") or []
        is_error = bool(result.get("is_error")) or (isinstance(subtype, str) and subtype.startswith("error"))
        cancelada = "cancelled" in errors or result.get("stop_reason") == "cancelled"
        rec["status"] = STATUS_CANCELADA if cancelada else (STATUS_ERRO if is_error else STATUS_OK)
        rec["subtipo"] = subtype
        rec["erros"] = [str(e) for e in errors][:5]
        rec["turnos"] = _int(result.get("num_turns"))
        dur = _int(result.get("duration_ms"))
        rec["duracao_ms"] = dur if dur and dur > 0 else None
        rec["tokens"] = tokens_from_usage(result.get("usage"))
        rec["parcial"] = None
    elif outro.status(path.name in running) is not None:
        rec["status"] = outro.status(path.name in running)
        rec["subtipo"] = None
        rec["erros"] = outro.erros[:5]
        rec["turnos"] = None
        rec["duracao_ms"] = None
        rec["tokens"] = {"total": outro.tokens} if outro.tokens > 0 else None
        rec["parcial"] = None
    else:
        rec["status"] = STATUS_ANDAMENTO if path.name in running else STATUS_MORTA
        rec["subtipo"] = None
        rec["erros"] = []
        rec["turnos"] = None
        rec["duracao_ms"] = None
        rec["tokens"] = None
        rec["parcial"] = {
            "respostas": len(partial_usage),
            "tokens": _sum_tokens(partial_usage.values()),
        }

    if result is None and outro.formato is not None:
        rec["custo_usd"], rec["custo"] = outro.classificar_custo(meta["lane"])
    else:
        rec["custo_usd"], rec["custo"] = classify_cost(meta["lane"], result, auth)

    # Sem duration_ms (morta ou placeholder 0): estimativa pela última escrita do arquivo.
    rec["duracao_estimada_ms"] = None
    if rec["duracao_ms"] is None:
        try:
            fim = dt.datetime.fromtimestamp(st.st_mtime)
            delta = (fim - dt.datetime.fromisoformat(meta["inicio"])).total_seconds()
            if delta > 0:
                rec["duracao_estimada_ms"] = int(delta * 1000)
        except (OverflowError, OSError, ValueError):
            pass

    rec["linhas_invalidas"] = invalid
    rec["fonte"] = {"tamanho": st.st_size, "mtime": round(st.st_mtime, 3)}
    return rec
