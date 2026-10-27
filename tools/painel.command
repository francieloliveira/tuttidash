#!/bin/bash
# Painel único: 6 partes numa janela do Terminal (tmux); a coluna da direita são as lanes.
C=~/.transcentia/tools/cfg; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
TM=$(cfg painel.tmux /opt/homebrew/bin/tmux); T=~/.transcentia/tools; L=~/Library/Logs/TranscentIA; N=$(cfg painel.linhas_log 30)
W=$(cfg painel.largura_lanes 40%)
if ! $TM has-session -t painel 2>/dev/null; then
  a=$($TM new-session -d -P -F '#{pane_id}' -s painel -x 300 -y 60 "bash $T/acompanhar-testes.command")
  b=$($TM split-window -P -F '#{pane_id}' -h -t "$a" "bash $T/seguir-gestor.sh")
  c=$($TM split-window -P -F '#{pane_id}' -v -t "$a" "bash $T/seguir-dispatcher.sh $N")
  d=$($TM split-window -P -F '#{pane_id}' -v -t "$b" "tail -n $N -F $L/bots-watch.log $L/bots-chave.log | bash $T/colorir.sh")
  e=$($TM split-window -P -F '#{pane_id}' -v -t "$c" "bash $T/seguir-build.sh")
  f=$($TM split-window -P -F '#{pane_id}' -h -f -l "$W" -t "$b" "bash $T/seguir-lanes.sh")
  $TM source-file $T/tema.tmux
  $TM set -t painel allow-rename off
  $TM set -t painel mouse on
  $TM select-pane -t "$a" -T "Testes da lane (ao vivo)"
  $TM select-pane -t "$b" -T "Testes do gestor"
  $TM select-pane -t "$c" -T "Dispatcher: fila e paradas"
  $TM select-pane -t "$d" -T "Vigia e chave dos bots"
  $TM select-pane -t "$e" -T "Build e instalação"
  $TM set -p -t "$f" pane-border-format ""   # as lanes já têm título próprio dentro da coluna
fi
exec $TM attach -t painel
