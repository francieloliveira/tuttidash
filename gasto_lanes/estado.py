"""Leitura (somente) do estado das lanes: heartbeat.json e lane-*.json."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Optional


def _load(p: Path) -> Optional[dict]:
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def _basename(s: str) -> str:
    # O caminho vem do Mac; no Windows a cópia pode ter outro prefixo. Compara pelo nome.
    return re.split(r"[\\/]", s)[-1]


LANE_NAME_RE = re.compile(r"^[a-z][a-z0-9_-]*$")


def is_lane_state(name: str, data) -> bool:
    """Forma do estado gravado por save_state() no dispatcher.py (claim):
    {"lane", "card", "issue_id", "title", "url", "branch", "worktree", "effort",
     "started", "started_at", "log", "session"}. Exige lane igual ao nome do arquivo
    (lane-<lane>.json), card e log como texto não vazio. Outros lane-*.json da pasta
    (ex.: lane-mcp.json, config MCP das lanes) não têm essa forma e ficam de fora."""
    if not isinstance(data, dict):
        return False
    stem = name[len("lane-"):-len(".json")] if name.startswith("lane-") and name.endswith(".json") else ""
    if not LANE_NAME_RE.match(stem):
        return False
    if data.get("lane") != stem:
        return False
    for key in ("card", "log"):
        v = data.get(key)
        if not isinstance(v, str) or not v.strip():
            return False
    return True


def _texto(v) -> Optional[str]:
    return v.strip() if isinstance(v, str) and v.strip() else None


def read_state(state_dir: Path) -> dict:
    """{"heartbeat": {...}|None, "lanes": {lane: {...}}, "logs_em_andamento": set(nomes)}"""
    out = {"heartbeat": None, "lanes": {}, "logs_em_andamento": set()}
    if not state_dir.is_dir():
        return out
    out["heartbeat"] = _load(state_dir / "heartbeat.json")
    for f in sorted(state_dir.glob("lane-*.json")):
        if not f.is_file():
            continue
        st = _load(f)
        if not is_lane_state(f.name, st):
            continue   # não é estado de lane: ignora em silêncio
        out["lanes"][st["lane"]] = {k: _texto(st.get(k)) for k in
                                    ("card", "title", "effort", "started_at", "log", "stuck")}
        out["logs_em_andamento"].add(_basename(st["log"]))
    return out
