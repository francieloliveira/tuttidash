#!/usr/bin/env bash
# Testa a hora nos seguidores do painel: carimbo, filtro do colorir depois da hora e
# seguir-com-hora (anteriores sem hora, novas com hora, sem sobrar processo ao encerrar).
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
f=0; ok(){ [ "$1" == "$2" ] && echo "ok  $3" || { echo "FALHA $3: '$1' != '$2'"; f=1; }; }
semcor(){ sed $'s/\033\\[[0-9;]*m//g'; }

out=$(echo "Test Case abc" | bash "$D/carimbo.sh")
ok "$(echo "$out" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} Test Case abc$')" 1 "carimbo: data e hora no formato do dispatcher"
ok "$(echo "2026-10-13 13:22:46 lane:claude" | bash "$D/carimbo.sh")" "2026-10-13 13:22:46 lane:claude" "carimbo: linha já datada passa igual"

out=$(printf '2026-10-13 13:00:00 [safe] simulador\n2026-10-13 13:00:01 outra\n' | bash "$D/colorir.sh" '^\[safe\]' | semcor)
ok "$out" "2026-10-13 13:00:00 [safe] simulador" "colorir: filtro com ^ vale depois da hora"
ok "$(printf 'BUILD SUCCEEDED\nnada\n' | bash "$D/colorir.sh" 'SUCCEEDED' | semcor)" "BUILD SUCCEEDED" "colorir: linha sem hora continua filtrando"

L="$T/proof.log"; printf 'Test Case um\nTest Case dois\nTest Case tres\n' > "$L"
bash "$D/seguir-com-hora.sh" "$L" 2 "Test Case" > "$T/saida" 2>&1 &
P=$!; sleep 2
echo "Test Case quatro" >> "$L"; sleep 2
kill $P; sleep 1
s=$(semcor < "$T/saida")
ok "$(echo "$s" | grep -c 'Test Case um')" 0 "seguir: respeita o número de linhas anteriores"
ok "$(echo "$s" | grep -c '^Test Case dois$')" 1 "seguir: anteriores sem hora"
ok "$(echo "$s" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} Test Case quatro$')" 1 "seguir: nova linha com hora"
ok "$(echo "$s" | grep -c 'Test Case tres')" 1 "seguir: sem repetir linha anterior"
ok "$(pgrep -f "tail -n +4 -F $L" | wc -l | tr -d ' ')" 0 "seguir: TERM encerra o tail"
exit $f
