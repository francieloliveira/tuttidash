#!/bin/bash
# Coluna das lanes no painel: a janela 'lanes' (claude em cima, grok embaixo) aninhada.
# Anexa direto na sessão 'lanes'; com o painel aberto, o dispatcher não abre outra janela
# (ele só abre quando ninguém está anexado). Fechar o painel não para nenhuma lane.
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/script-controle.sh"
C="$DIR/cfg"; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
TM=$(cfg painel.tmux /opt/homebrew/bin/tmux)
while true; do
  SCRIPT="$(script_controle lanes/lanes_window.py)" || {
    echo "lanes: lanes_window.py não está no bundle assinado" >&2
    exit 70
  }
  /usr/bin/python3 "$SCRIPT" ensure
  TMUX= $TM attach -t lanes
  sleep 2
done
