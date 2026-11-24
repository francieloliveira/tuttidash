"""Retenção de JSONL (eventos e ledger): planeja ou aplica corte por data.

Linha sem data reconhecível é mantida: não se apaga o que não se sabe datar.
Sem `aplicar=True`, só conta; o arquivo não muda. A gravação é atômica.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import tempfile
from pathlib import Path
from typing import Optional


def _data(registro: dict, campo: str) -> Optional[dt.date]:
    valor = registro.get(campo) if isinstance(registro, dict) else None
    if not isinstance(valor, str) or len(valor) < 10:
        return None
    try:
        return dt.date.fromisoformat(valor[:10])
    except ValueError:
        return None


def planejar(caminho, campo: str = "ts", dias: int = 0,
             hoje: Optional[dt.date] = None) -> dict:
    """Conta linhas que ficariam e que sairiam. `dias<=0` = não poda."""
    p = Path(caminho)
    resumo = {"arquivo": str(p), "dias": max(0, int(dias or 0)), "manter": 0,
              "remover": 0, "sem_data": 0, "existe": p.is_file()}
    if resumo["dias"] <= 0 or not p.is_file():
        return resumo
    hoje = hoje or dt.date.today()
    corte = hoje - dt.timedelta(days=resumo["dias"])
    for bruto in p.read_text(encoding="utf-8", errors="replace").splitlines():
        if not bruto.strip():
            continue
        try:
            r = json.loads(bruto)
        except ValueError:
            resumo["sem_data"] += 1
            continue
        d = _data(r, campo)
        if d is None:
            resumo["sem_data"] += 1
        elif d < corte:
            resumo["remover"] += 1
        else:
            resumo["manter"] += 1
    return resumo


def podar(caminho, campo: str = "ts", dias: int = 0,
          hoje: Optional[dt.date] = None, aplicar: bool = False) -> dict:
    """Planeja e, com `aplicar=True`, regrava sem as linhas antigas."""
    p = Path(caminho)
    resumo = planejar(p, campo, dias, hoje)
    if not aplicar or resumo["dias"] <= 0 or not p.is_file() or resumo["remover"] == 0:
        resumo["gravou"] = False
        return resumo
    hoje = hoje or dt.date.today()
    corte = hoje - dt.timedelta(days=resumo["dias"])
    manter = []
    for bruto in p.read_text(encoding="utf-8", errors="replace").splitlines():
        if not bruto.strip():
            continue
        try:
            r = json.loads(bruto)
        except ValueError:
            manter.append(bruto)
            continue
        d = _data(r, campo)
        if d is None or d >= corte:
            manter.append(bruto)
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".retencao-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            if manter:
                fh.write("\n".join(manter) + "\n")
        os.replace(tmp, p)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    resumo["gravou"] = True
    return resumo
