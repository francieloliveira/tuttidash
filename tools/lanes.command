#!/bin/bash
# Janela única das lanes (tmux 'lanes'): claude em cima, grok embaixo.
# Fechar esta janela não para nenhuma lane.
C=~/.transcentia/tools/cfg; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
TM=$(cfg painel.tmux /opt/homebrew/bin/tmux)
/usr/bin/python3 ~/.transcentia/lanes/lanes_window.py ensure
exec $TM attach -t lanes
