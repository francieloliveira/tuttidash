"""Ledger idempotente: uma linha JSON por execução, chave = nome do log.

- Rodar a coleta duas vezes sem log novo não muda o arquivo (nem o mtime).
- Log que mudou (tamanho/mtime) ou execução que estava em andamento é relida.
- Log apagado do disco continua no ledger (o ledger é o histórico).
- Gravação atômica (arquivo temporário + os.replace).
"""
from __future__ import annotations

import datetime as dt
import json
import os
import tempfile
from pathlib import Path
from typing import Optional

from .parser import STATUS_ANDAMENTO, STATUS_MORTA, parse_log, parse_name

VOLATILE = ("coletado_em",)


def load(ledger: Path) -> dict:
    recs: dict = {}
    if not ledger.exists():
        return recs
    with ledger.open("r", encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                r = json.loads(raw)
            except ValueError:
                continue
            if isinstance(r, dict) and r.get("id"):
                recs[r["id"]] = r
    return recs


def _sort_key(r: dict) -> tuple:
    return (r.get("inicio") or "", r.get("id") or "")


def dumps(recs: dict) -> str:
    lines = [json.dumps(r, ensure_ascii=False, sort_keys=True) for r in sorted(recs.values(), key=_sort_key)]
    return "".join(line + "\n" for line in lines)


def save(ledger: Path, recs: dict) -> bool:
    """Grava só se o conteúdo mudou. Devolve True se gravou."""
    text = dumps(recs)
    if not recs and not ledger.exists():
        return False
    if ledger.exists() and ledger.read_text(encoding="utf-8") == text:
        return False
    ledger.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(ledger.parent), prefix=".ledger-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.replace(tmp, ledger)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return True


def _same(a: dict, b: dict) -> bool:
    strip = lambda r: {k: v for k, v in r.items() if k not in VOLATILE}  # noqa: E731
    return strip(a) == strip(b)


def collect(logs_dir: Path, ledger: Path, running: Optional[set] = None,
            now: Optional[dt.datetime] = None) -> dict:
    """Lê os logs e atualiza o ledger. Devolve contadores e os registros."""
    recs = load(ledger)
    stats = {"novas": 0, "atualizadas": 0, "sem_mudanca": 0, "ignorados": [],
             "logs_dir_existe": logs_dir.is_dir(), "gravou": False}
    stamp = (now or dt.datetime.now()).replace(microsecond=0).isoformat()
    running = running or set()

    if stats["logs_dir_existe"]:
        for path in sorted(logs_dir.iterdir()):
            if not path.is_file():
                continue
            if parse_name(path.name) is None:
                if path.suffix == ".jsonl":
                    stats["ignorados"].append(path.name)
                continue
            key = path.name[: -len(".jsonl")]
            old = recs.get(key)
            try:
                st = path.stat()
            except OSError:
                continue
            fonte = {"tamanho": st.st_size, "mtime": round(st.st_mtime, 3)}
            in_running = path.name in running
            # morta é relida: o parser passou a entender opencode/codex (FRA-528)
            was_running = bool(old) and old.get("status") in (STATUS_ANDAMENTO, STATUS_MORTA)
            if old and old.get("fonte") == fonte and not was_running and not in_running:
                stats["sem_mudanca"] += 1
                continue
            try:
                new = parse_log(path, running)
            except OSError as exc:
                stats["ignorados"].append(f"{path.name} ({exc})")
                continue
            if new is None:
                continue
            if old and _same(old, {**new, "coletado_em": old.get("coletado_em")}):
                stats["sem_mudanca"] += 1
                continue
            new["coletado_em"] = stamp
            recs[key] = new
            stats["atualizadas" if old else "novas"] += 1

    stats["gravou"] = save(ledger, recs)
    stats["registros"] = recs
    return stats
