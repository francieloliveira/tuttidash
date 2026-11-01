#!/bin/bash
# Janela única das lanes (tmux 'lanes'): claude em cima, grok embaixo.
# Fechar esta janela não para nenhuma lane.
# lanes_window.py sai do bundle assinado (ou do repo, ao lado deste arquivo).
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/script-controle.sh"
C="$DIR/cfg"; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
TM=$(cfg painel.tmux /opt/homebrew/bin/tmux)
SCRIPT="$(script_controle lanes/lanes_window.py)" || {
  echo "lanes: lanes_window.py não está no bundle assinado" >&2
  exit 70
}
/usr/bin/python3 "$SCRIPT" ensure
exec $TM attach -t lanes
