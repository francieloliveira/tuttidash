"""Utilitários dos testes: copia as fixtures para uma pasta temporária com mtimes fixos."""
import datetime as dt
import hashlib
import os
import shutil
import tempfile
import time
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures"
LOGS = FIXTURES / "logs"
ESTADO = FIXTURES / "estado"

# mtime = início + estes minutos (simula a última escrita do log)
MINUTOS_ATE_ULTIMA_ESCRITA = {
    "FRA-251-claude-20261005-090000.jsonl": 90,   # morta no timeout de 90 min
    "FRA-252-grok-20261005-140000.jsonl": 2,
    "FRA-253-claude-20261005-200000.jsonl": 15,
}


def local_epoch(d: dt.datetime) -> float:
    return time.mktime(d.timetuple())


class Sandbox:
    """Pasta temporária com logs/, estado/ e tools/ (onde fica o ledger)."""

    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.logs = self.root / "logs"
        self.estado = self.root / "estado"
        self.tools = self.root / "tools"
        shutil.copytree(LOGS, self.logs)
        shutil.copytree(ESTADO, self.estado)
        self.ledger = self.tools / "ledger.jsonl"
        for f in self.logs.glob("FRA-*.jsonl"):
            stamp = dt.datetime.strptime(f.stem.rsplit("-", 2)[-2] + f.stem.rsplit("-", 2)[-1], "%Y%m%d%H%M%S")
            mins = MINUTOS_ATE_ULTIMA_ESCRITA.get(f.name, 5)
            t = local_epoch(stamp + dt.timedelta(minutes=mins))
            os.utime(f, (t, t))

    def cleanup(self):
        self._tmp.cleanup()

    def args(self):
        return ["--logs", str(self.logs), "--estado", str(self.estado), "--ledger", str(self.ledger)]


def snapshot(folder: Path) -> dict:
    """nome -> (sha256, tamanho, mtime_ns): prova de que nada foi alterado/criado/apagado."""
    out = {}
    for f in sorted(folder.rglob("*")):
        if f.is_file():
            st = f.stat()
            out[str(f.relative_to(folder))] = (hashlib.sha256(f.read_bytes()).hexdigest(), st.st_size,
                                               st.st_mtime_ns)
    return out
