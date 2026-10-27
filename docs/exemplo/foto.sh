#!/usr/bin/env bash
# Abre o TuttiDash com os dados de exemplo e grava a foto do painel (sem captura de tela).
# Uso: docs/exemplo/foto.sh [saida.png] [dashboard|lanes|builds|entregas|testes|custos]
set -euo pipefail
raiz="$(cd "$(dirname "$0")/../.." && pwd)"
pasta="${TMPDIR:-/tmp}/tuttidash-exemplo"
png="${1:-$pasta/painel.png}"
extra=""; [[ "${2:-}" == "testes" ]] && extra="--prova"
python3 "$raiz/docs/exemplo/gerar.py" "$pasta" $extra >/dev/null
bin="$raiz/apps/notch-mac/.build/release/TuttiDash"
TRANSCENTIA_GASTO_CONFIG="$pasta/config.json" "$bin" --foto-painel "$png" ${2:+--foto-pagina "$2"} &
pid=$!
sleep 10
kill "$pid" 2>/dev/null || true
echo "$png"
