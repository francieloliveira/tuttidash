"""Eventos de fluxo: uma linha JSONL por transição relevante.

É a fonte para métricas, relatórios e auditoria, em vez de parsear mensagem de
log. O arquivo é compartilhado pelos projetos e cada evento diz a que projeto
pertence. Não grava token, prompt, caminho pessoal nem conteúdo de card.

Formato (schema 1):
    {"schema": 1, "ts": "2026-11-22T22:00:00", "projeto": "<id>", "card": "FRA-1",
     "lane": "claude", "etapa": "claim", "status": "iniciado", "motivo": "",
     "sha": "<base>", "pr": "", "custo_usd": null}

`registrar` nunca levanta: um evento perdido não pode derrubar o ciclo.
"""
from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path
from typing import Optional

SCHEMA = 1
#: Teto de cada texto livre. O evento é resumo, não o card.
TETO_TEXTO = 500


def _limpar(valor, teto: int = TETO_TEXTO) -> str:
    if valor is None:
        return ""
    texto = " ".join(str(valor).split())
    return texto[:teto]


def registrar(caminho, *, projeto: str, card: str, lane: str, etapa: str,
              status: str = "", motivo: str = "", sha: str = "", pr: str = "",
              custo_usd: Optional[float] = None, quando: Optional[dt.datetime] = None) -> bool:
    """Acrescenta um evento. Devolve False (sem exceção) se faltar chave ou não gravar."""
    projeto, card, lane, etapa = (_limpar(x, 120) for x in (projeto, card, lane, etapa))
    if not (projeto and card and lane and etapa):
        return False
    evento = {
        "schema": SCHEMA,
        "ts": (quando or dt.datetime.now()).replace(microsecond=0).isoformat(),
        "projeto": projeto,
        "card": card.upper(),
        "lane": lane,
        "etapa": etapa,
        "status": _limpar(status, 80),
        "motivo": _limpar(motivo),
        "sha": _limpar(sha, 64),
        "pr": _limpar(pr, 80),
        "custo_usd": (round(float(custo_usd), 6)
                      if isinstance(custo_usd, (int, float)) and not isinstance(custo_usd, bool)
                      else None),
    }
    p = Path(caminho)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps(evento, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8"))
        finally:
            os.close(fd)
        return True
    except OSError:
        return False


def ler(caminho, *, projeto: str = "", card: str = "", limite: int = 0) -> list:
    """Eventos na ordem do arquivo, opcionalmente filtrados. Linha inválida é pulada."""
    p = Path(caminho)
    out = []
    try:
        with p.open("r", encoding="utf-8") as fh:
            for bruto in fh:
                bruto = bruto.strip()
                if not bruto:
                    continue
                try:
                    ev = json.loads(bruto)
                except ValueError:
                    continue
                if not isinstance(ev, dict) or ev.get("schema") != SCHEMA:
                    continue
                if projeto and ev.get("projeto") != projeto:
                    continue
                if card and ev.get("card") != card.upper():
                    continue
                out.append(ev)
    except OSError:
        return []
    if limite and limite > 0:
        out = out[-limite:]
    return out
