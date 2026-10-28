#!/bin/bash
# Prova do TuttiDash: desvia a suite para o runner certo.
# Uso: ./scripts/testar.sh {suite}
# - Gasto* -> Swift (apps/notch-mac): swift test --filter {suite}
# - resto -> Python: python3 -m unittest {suite}
set -u
suite="${1:-}"
if [ -z "$suite" ]; then
  echo "uso: $0 <suite>" >&2
  exit 2
fi
case "$suite" in
  Gasto*)
    cd "$(dirname "$0")/../apps/notch-mac" || exit 1
    exec swift test --filter "$suite"
    ;;
  *)
    exec python3 -m unittest "$suite"
    ;;
esac
