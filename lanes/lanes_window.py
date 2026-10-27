"""Janela única das lanes: sessão tmux 'lanes', um painel por lane habilitada.

Uma responsabilidade só: mostrar as sessões de lane (lane-<x>) num lugar fixo.
O painel faz um attach aninhado na sessão da tarefa; fechar o painel ou a
janela derruba só esse attach, nunca a lane. Usado pelo dispatcher e por
~/.transcentia/tools/lanes.command.
"""
from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

SESSION = "lanes"
# Ordem dos painéis = de cima para baixo. Vem do catálogo (`agents.d/`, a mesma
# fonte do dispatcher e do vigia): a lane entra quando está habilitada no arquivo
# `enabled` (mesmo que o dispatcher lê); sem o arquivo, as duas primeiras.
_AQUI = Path(__file__).resolve().parent
for _cand in (_AQUI, _AQUI.parent / "gasto_lanes"):   # 1º: instalado; 2º: dev no repo
    if (_cand / "catalogo.py").is_file():
        sys.path.insert(0, str(_cand))
        break
import catalogo  # noqa: E402

LANES_ORDEM = catalogo.lanes_por_prioridade()
TMUX = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
HERE = Path(__file__).resolve()


def _enabled() -> set[str]:
    try:
        return {l.strip() for l in (HERE.parent / "enabled").read_text().split() if l.strip()}
    except OSError:
        return set(LANES_ORDEM[:2])


LANES = tuple(l for l in LANES_ORDEM if l in _enabled()) or LANES_ORDEM[:2]
OPEN_GUARD = HERE.parent / "lanes-window.opened"   # evita abrir duas janelas seguidas
OPEN_GUARD_SECONDS = 90
TEMA = Path.home() / ".transcentia" / "tools" / "tema.tmux"
BOUNDS = "{40, 60, 1040, 760}"     # ~1000x700, nunca tela cheia


def _tmux(*args: str) -> str:
    r = subprocess.run([TMUX, *args], capture_output=True, text=True, timeout=45)
    return r.stdout.strip() if r.returncode == 0 else ""


def idle_title(lane: str) -> str:
    return f"lane {lane} · livre"


def task_title(lane: str, card: str) -> str:
    return f"lane {lane} · {card}"


PYTHON = "/usr/bin/python3"   # fixo: o launchd pode rodar o dispatcher com outro python


def _idle_cmd(lane: str) -> str:
    return f"{PYTHON} {shlex.quote(str(HERE))} idle {lane}"


def _task_cmd(lane: str, session: str, card: str) -> str:
    # Título, attach aninhado (TMUX vazio) e, quando a tarefa acaba, volta a ocioso.
    t = shlex.quote(task_title(lane, card))
    return (f"{TMUX} select-pane -t \"$TMUX_PANE\" -T {t}; "
            f"TMUX= {TMUX} attach -t {shlex.quote(session)}; "
            f"exec {_idle_cmd(lane)}")


def _panes() -> dict:
    out = _tmux("list-panes", "-t", SESSION, "-F", "#{pane_id} #{@lane}")
    found = {}
    for line in out.splitlines():
        pid, _, lane = line.partition(" ")
        if lane in LANES:
            found[lane] = pid
    return found


def _exists(session: str) -> bool:
    return subprocess.run([TMUX, "has-session", "-t", session],
                          capture_output=True).returncode == 0


def _initial_cmd(lane: str) -> str:
    session = f"lane-{lane}"
    if _exists(session):
        card = _tmux("show-options", "-v", "-t", session, "@card") or "tarefa"
        return _task_cmd(lane, session, card)
    return _idle_cmd(lane)


def ensure_session() -> dict:
    """Cria a sessão e os painéis que faltarem. Devolve {lane: pane_id}."""
    if not _exists(SESSION):
        a = _tmux("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", SESSION,
                  "-x", "160", "-y", "45", _initial_cmd(LANES[0]))
        _tmux("set-option", "-p", "-t", a, "@lane", LANES[0])
        _tmux("source-file", str(TEMA))   # tema único, compartilhado com o painel
        for opt, val in (("allow-rename", "off"), ("mouse", "on")):
            _tmux("set-option", "-t", SESSION, opt, val)
        _tmux("set-option", "-w", "-t", SESSION, "allow-set-title", "off")
    panes = _panes()
    for lane, pane in list(panes.items()):  # painel morto: volta ao estado certo
        if _tmux("display", "-p", "-t", pane, "#{pane_dead}") == "1":
            _tmux("respawn-pane", "-k", "-t", pane, _initial_cmd(lane))
    for lane in LANES:
        if lane not in panes:  # painel fechado pelo usuário: recria
            # a primeira da ordem fica em cima (-b = antes do painel de referência)
            ref = next(iter(panes.values()), SESSION)
            above = ["-b"] if lane == LANES[0] else []
            p = _tmux("split-window", "-v", *above, "-P", "-F", "#{pane_id}", "-t", ref,
                      _initial_cmd(lane))
            _tmux("set-option", "-p", "-t", p, "@lane", lane)
            panes[lane] = p
    _tmux("select-layout", "-t", SESSION, "even-vertical")
    return panes


def plain_nested(session: str) -> None:
    """A sessão da tarefa aparece aninhada: sem borda nem status próprios,
    para ficar só o título do painel de fora."""
    _tmux("set-option", "-t", session, "status", "off")
    _tmux("set-option", "-w", "-t", session, "pane-border-status", "off")


def show_task(lane: str, session: str, card: str) -> bool:
    """Mostra a sessão da tarefa no painel da lane. Devolve True só se o painel
    ficou mesmo com a tarefa; quem chama tenta de novo no próximo ciclo."""
    _tmux("set-option", "-t", session, "@card", card)
    plain_nested(session)
    pane = ensure_session().get(lane)
    if not pane:
        return False
    _tmux("respawn-pane", "-k", "-t", pane, _task_cmd(lane, session, card))
    _tmux("select-pane", "-t", pane, "-T", task_title(lane, card))
    return showing(lane, card)


def showing(lane: str, card: str) -> bool:
    """O painel da lane está mostrando este card?"""
    pane = _panes().get(lane)
    return bool(pane) and _tmux("display", "-p", "-t", pane, "#{pane_title}") == task_title(lane, card)


def window_open() -> bool:
    return bool(_tmux("list-clients", "-t", SESSION))


def open_window_once(command_path: Path) -> None:
    """Abre UMA janela do Terminal com lanes.command se nenhuma estiver anexada."""
    if window_open():
        return
    if OPEN_GUARD.exists() and time.time() - OPEN_GUARD.stat().st_mtime < OPEN_GUARD_SECONDS:
        return
    OPEN_GUARD.write_text(str(time.time()))
    script = f'''
tell application "Terminal"
    set t to do script "bash {command_path}"
    delay 0.5
    set w to first window whose tabs contains t
    try
        set zoomed of w to false
    end try
    set bounds of w to {BOUNDS}
end tell
'''
    subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, timeout=30)


def idle(lane: str) -> None:
    pane = os.environ.get("TMUX_PANE", "")
    if pane:
        _tmux("select-pane", "-t", pane, "-T", idle_title(lane))
    print("\033[H\033[2J\033[3J", end="")  # limpa o "[exited]" do attach anterior
    print("\n  A próxima tarefa desta lane aparece aqui.\n", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "ensure"
    if cmd == "idle":
        idle(sys.argv[2])
    elif cmd == "ensure":
        ensure_session()
