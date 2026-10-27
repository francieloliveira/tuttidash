#!/bin/bash
# Coluna das lanes no painel: a janela 'lanes' (claude em cima, grok embaixo) aninhada.
# Anexa direto na sessão 'lanes'; com o painel aberto, o dispatcher não abre outra janela
# (ele só abre quando ninguém está anexado). Fechar o painel não para nenhuma lane.
C=~/.transcentia/tools/cfg; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
TM=$(cfg painel.tmux /opt/homebrew/bin/tmux)
while true; do
  /usr/bin/python3 ~/.transcentia/lanes/lanes_window.py ensure
  TMUX= $TM attach -t lanes
  sleep 2
done
