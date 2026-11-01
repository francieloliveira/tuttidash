#!/bin/bash
# Anota a cada 15 s a carga do Mac (load, memória, térmico) enquanto o trabalho roda.
C=~/.transcentia/tools/cfg; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
# Provas em andamento: o mesmo lugar do painel.proof_log_glob, com proof_started no lugar do log.
G=$(cfg painel.proof_log_glob "~/Developer/*-worktrees/*/.lane/proof.log"); G=${G/#\~/$HOME}
PROVAS=("${G%/*}/proof_started")
# Padrão novo. Se o log antigo já existe e a config ainda aponta para o padrão,
# a série continua nele. estresse.saida explícito (outro caminho) vale como está.
NOVO="$HOME/Library/Logs/TuttiDash/carga-mac.tsv"
VELHO="$HOME/Library/Logs/TranscentIA/estresse.tsv"
OUT=$(cfg estresse.saida "~/Library/Logs/TuttiDash/carga-mac.tsv"); OUT=${OUT/#\~/$HOME}
if [ -f "$VELHO" ] && [ "$OUT" = "$NOVO" ]; then OUT=$VELHO; fi
I=$(cfg estresse.intervalo_s 15)
if [ "${1:-}" = "--saida" ]; then printf '%s\n' "$OUT"; exit 0; fi
mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || printf "hora\tload1\tload5\tlivre_mb\tswap_usado_mb\tpressao_pct_livre\ttermico\txcodebuild\tsimuladores\tlanes_ativas\n" > "$OUT"
while true; do
  read l1 l5 <<<"$(sysctl -n vm.loadavg | awk '{print $2, $3}')"
  ps=$(vm_stat | awk '/page size/{print $8}'); fp=$(vm_stat | awk '/Pages free/{gsub("\\.","",$3);print $3}')
  livre=$(( fp * ps / 1048576 ))
  swap=$(sysctl -n vm.swapusage | awk '{gsub("M","",$6);print int($6)}')
  pr=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{print $2}')
  term=$(pmset -g therm 2>/dev/null | awk -F'= ' '/CPU_Speed_Limit/{print $2}'); term=${term:-100}
  xc=$(pgrep -x xcodebuild | wc -l | tr -d ' ')
  sim=$(pgrep -f "Simulator|launchd_sim" | wc -l | tr -d ' ')
  lanes=$(ls ${PROVAS[@]} 2>/dev/null | wc -l | tr -d ' ')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$(date '+%F %T')" $l1 $l5 $livre $swap "$pr" $term $xc $sim $lanes >> "$OUT"
  sleep $I
done
