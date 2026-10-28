#!/bin/bash
# Prova do TuttiDash: desvia a suite para o runner certo.
# Uso: ./scripts/testar.sh {suite}
# - módulo Python (tests.*, tests/...) -> python3 -m unittest
# - resto (nome de alvo/classe Swift, com ou sem ponto) -> swift test --filter em apps/notch-mac
set -u
suite="${1:-}"
if [ -z "$suite" ]; then
  echo "uso: $0 <suite>" >&2
  exit 2
fi
case "$suite" in
  tests*|*/*)
    exec python3 -m unittest "$suite"
    ;;
  *)
    cd "$(dirname "$0")/../apps/notch-mac" || exit 1
    exec swift test --filter "$suite"
    ;;
esac
