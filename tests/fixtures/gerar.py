#!/usr/bin/env python3
"""Gera as fixtures sintéticas (imitam o formato real dos logs das lanes).

    python3 tests/fixtures/gerar.py

Nada aqui vem de log real: ids, textos e números são inventados.
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOGS = HERE / "logs"
ESTADO = HERE / "estado"


def claude_init(model="claude-opus-4-1"):
    return {"type": "system", "subtype": "init", "cwd": "/Users/x/Developer/projeto-worktrees/fra-0",
            "session_id": "s-claude", "tools": ["Bash", "Read", "Edit"], "mcp_servers": [],
            "model": model, "permissionMode": "acceptEdits", "slash_commands": [],
            "apiKeySource": "none", "claude_code_version": "2.0.0", "output_style": "default", "uuid": "u0"}


def grok_init(auth="oauth", model="grok-4.7"):
    return {"type": "system", "subtype": "init", "session_id": "s-grok", "apiKeySource": auth,
            "model": model, "cwd": "/Users/x/Developer/projeto-worktrees/fra-0",
            "permissionMode": "acceptEdits", "tools": ["read_file", "run_terminal_command"],
            "slash_commands": [], "mcp_servers": [], "skills": [], "uuid": "u0"}


def assistant(mid, text="ok", inp=10, out=50, cread=1000, ccreate=0, model="claude-opus-4-1"):
    return {"type": "assistant", "message": {
        "id": mid, "type": "message", "role": "assistant", "model": model,
        "content": [{"type": "text", "text": text}], "stop_reason": None,
        "usage": {"input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": cread,
                  "cache_creation_input_tokens": ccreate, "service_tier": "standard"}},
        "parent_tool_use_id": None, "session_id": "s", "uuid": "u"}


def tool_result():
    return {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "ok", "is_error": False}]},
        "parent_tool_use_id": None, "session_id": "s", "uuid": "u"}


def result(subtype="success", is_error=False, cost=None, turns=10, dur=60000, usage=None, errors=None,
           stop="end_turn"):
    r = {"type": "result", "subtype": subtype, "is_error": is_error, "duration_ms": dur,
         "duration_api_ms": dur // 2, "num_turns": turns, "result": "feito", "stop_reason": stop,
         "session_id": "s", "usage": usage or {"input_tokens": 0, "output_tokens": 0,
                                               "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
         "modelUsage": {}, "uuid": "u"}
    if cost is not None:
        r["total_cost_usd"] = cost
    if errors is not None:
        r["errors"] = errors
    return r


def usage(inp, out, cread, ccreate):
    return {"input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": cread,
            "cache_creation_input_tokens": ccreate, "server_tool_use": {"web_search_requests": 0}}


FILES = {
    # claude ok (sábado, semana 40)
    "FRA-250-claude-20261003-101500.jsonl": [
        claude_init(), assistant("msg_a1"), tool_result(), assistant("msg_a2"),
        result(cost=2.3141, turns=42, dur=1_500_000, usage=usage(120, 30_000, 1_200_000, 45_000)),
    ],
    # grok com API key: custo informado pelo servidor (domingo, semana 40)
    "FRA-259-grok-20261004-153012.jsonl": [
        grok_init(auth="user"), assistant("resp_1", model="grok-4.7"), tool_result(),
        result(cost=0.48, turns=16, dur=175_000, usage=usage(7_000, 2_000, 40_000, 0)),
    ],
    # grok OAuth/SuperGrok: custo vem 0 = desconhecido (semana 40)
    "FRA-260-grok-20261004-180000.jsonl": [
        grok_init(auth="oauth"), assistant("resp_1", model="grok-4.7"),
        result(cost=0, turns=22, dur=600_000, usage=usage(9_000, 3_000, 80_000, 0)),
    ],
    # claude morta por timeout: sem linha result; stderr misturado (run_lane.sh faz 2>&1)
    "FRA-251-claude-20261005-090000.jsonl": [
        claude_init(),
        assistant("msg_b1", inp=5, out=100, cread=2_000, ccreate=500),
        assistant("msg_b1", inp=5, out=100, cread=2_000, ccreate=500),   # mesma mensagem, outro bloco
        tool_result(),
        assistant("msg_b2", inp=5, out=200, cread=3_000, ccreate=0),
        "Terminated: 15",
    ],
    # grok cancelado por ação fora da lista permitida: erro, custo 0, usage todo zero
    "FRA-252-grok-20261005-140000.jsonl": [
        grok_init(auth="oauth"),
        result(subtype="error_during_execution", is_error=True, cost=0, turns=3, dur=0,
               errors=["cancelled"], stop="cancelled"),
    ],
    # claude ainda rodando (lane-claude.json aponta para este log)
    "FRA-253-claude-20261005-200000.jsonl": [
        claude_init(), assistant("msg_c1"),
    ],
    # claude estourou o teto em US$: erro, mas com custo estimado (domingo, semana 39)
    "FRA-248-claude-20260927-230000.jsonl": [
        claude_init(model="claude-sonnet-4-5"), assistant("msg_d1", model="claude-sonnet-4-5"),
        result(subtype="error_max_budget_usd", is_error=True, cost=3.02, turns=55, dur=2_400_000,
               usage=usage(300, 50_000, 2_000_000, 60_000)),
    ],
    # nome fora do padrão: ignorado
    "notas.jsonl": [{"type": "nota"}],
}

ESTADO_FILES = {
    "heartbeat.json": {"at": "2026-10-05 20:30:00", "dry_run": False, "enabled": ["claude", "grok"],
                       "implemented": ["claude", "grok"]},
    "lane-claude.json": {"lane": "claude", "card": "FRA-253", "issue_id": "x", "title": "card de teste",
                         "url": "https://linear.app/x", "branch": "b", "worktree": "/w", "effort": "medio",
                         "started": 0, "started_at": "2026-10-05 20:00:00",
                         "log": "/Users/x/Library/Logs/TranscentIA/lanes/FRA-253-claude-20261005-200000.jsonl",
                         "session": "lane-claude"},
    # Arquivos que convivem na pasta de estado real e NÃO são estado de lane.
    # lane-mcp.json começa com lane- e é JSON, mas é config MCP das lanes.
    "lane-mcp.json": {"mcpServers": {"transcentia-docs": {"command": "/usr/bin/python3",
                                                          "args": ["/x/docs_mcp.py"]}}},
    "lane-prompt.md": "# Prompt da lane {{LANE}} para {{CARD}}\n",
    "lane-prompt-grok.md": "Regras extras da lane grok.\n",
    "claude-settings.json": {"permissions": {"allow": ["Read"], "deny": ["WebFetch"]}},
    "enabled": "claude grok\n",
    "last_mode": "real · lanes: claude, grok",
}


def main():
    LOGS.mkdir(parents=True, exist_ok=True)
    ESTADO.mkdir(parents=True, exist_ok=True)
    for name, lines in FILES.items():
        text = "".join((ln if isinstance(ln, str) else json.dumps(ln, ensure_ascii=False)) + "\n"
                       for ln in lines)
        (LOGS / name).write_text(text, encoding="utf-8", newline="\n")
    for name, data in ESTADO_FILES.items():
        text = data if isinstance(data, str) else json.dumps(data, ensure_ascii=False, indent=2)
        (ESTADO / name).write_text(text, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
