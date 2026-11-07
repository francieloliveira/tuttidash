#!/bin/bash
# Painel único. Etapas à esquerda, trabalho (lanes) à direita.
#
#   fila          revisão          trabalho
#   prova         instalação       (lanes, altura inteira)
#
# Título = etapa, não papel nem nome de pessoa.
# Sessão antiga (título que não é "fila") é recriada se ninguém mudou o layout à mão
# e o primeiro painel ainda não é a etapa nova.
C=~/.transcentia/tools/cfg; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
TM=$(cfg painel.tmux /opt/homebrew/bin/tmux); T=~/.transcentia/tools; L=~/Library/Logs/TranscentIA
N=$(cfg painel.linhas_log 24)
W=$(cfg painel.largura_lanes 42%)

criar() {
  a=$($TM new-session -d -P -F '#{pane_id}' -s painel -x 220 -y 52 \
      "bash $T/seguir-dispatcher.sh $N")
  f=$($TM split-window -P -F '#{pane_id}' -h -f -l "$W" -t "$a" "bash $T/seguir-lanes.sh")
  c=$($TM split-window -P -F '#{pane_id}' -v -t "$a" "bash $T/acompanhar-testes.command")
  b=$($TM split-window -P -F '#{pane_id}' -h -t "$a" \
      "tail -n $N -F $L/bots-watch.log $L/bots-chave.log | bash $T/colorir.sh")
  e=$($TM split-window -P -F '#{pane_id}' -h -t "$c" "bash $T/seguir-build.sh")
  $TM source-file "$T/tema.tmux"
  $TM set -t painel allow-rename off
  $TM set -t painel mouse on
  $TM rename-window -t painel tuttidash
  $TM select-pane -t "$a" -T "fila"
  $TM select-pane -t "$b" -T "revisão"
  $TM select-pane -t "$c" -T "prova"
  $TM select-pane -t "$e" -T "instalação"
  $TM select-pane -t "$f" -T "trabalho"
  # A coluna da direita mostra o título de cada lane por dentro.
  $TM set -p -t "$f" pane-border-format ""
  $TM select-pane -t "$a"
}

if $TM has-session -t painel 2>/dev/null; then
  titulo=$($TM display -p -t painel:0.0 '#{pane_title}' 2>/dev/null || true)
  case "$titulo" in
    fila) ;;
    *) $TM kill-session -t painel ;;
  esac
fi
if ! $TM has-session -t painel 2>/dev/null; then
  criar
fi
exec $TM attach -t painel
