#!/bin/bash
# FRA-610. Prova remota.
# Este arquivo vale como blob do commit da base (SHA completo em PROVA_BASE_SHA).
# Uso: prova-remota.sh <checkout-da-base> <checkout-do-head>
# O head só é o diretório do código sob prova. Nenhum script de lá é executado.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "uso: $0 <checkout-da-base> <checkout-do-head>" >&2
  exit 2
fi

base=$(cd "$1" && pwd -P)
head=$(cd "$2" && pwd -P)

if [ "$head" = "$base" ] || [ "${head#"$base"/}" != "$head" ]; then
  echo "prova-remota: head dentro da base" >&2
  exit 2
fi
if [ "${base#"$head"/}" != "$base" ]; then
  echo "prova-remota: base dentro do head" >&2
  exit 2
fi

[[ "${PROVA_BASE_SHA-}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "prova-remota: SHA da base incompleto" >&2
  exit 2
}
[[ "${PROVA_HEAD_SHA-}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "prova-remota: SHA do head incompleto" >&2
  exit 2
}

if [ "$(git -C "$base" rev-parse HEAD)" != "$PROVA_BASE_SHA" ]; then
  echo "prova-remota: checkout da base não é o SHA anunciado" >&2
  exit 2
fi
if [ "$(git -C "$head" rev-parse HEAD)" != "$PROVA_HEAD_SHA" ]; then
  echo "prova-remota: checkout do head não é o SHA anunciado" >&2
  exit 2
fi

modulo="$base/gasto_lanes/prova_remota.py"
script="$base/scripts/prova-remota.sh"
if [ -L "$modulo" ] || [ -L "$script" ]; then
  echo "prova-remota: symlink na base" >&2
  exit 2
fi
if [ ! -f "$modulo" ]; then
  echo "prova-remota: módulo da base ausente" >&2
  exit 2
fi
if ! git -C "$base" diff --quiet HEAD -- gasto_lanes/prova_remota.py; then
  echo "prova-remota: módulo diverge do commit da base" >&2
  exit 2
fi
if ! git -C "$base" diff --quiet HEAD -- scripts/prova-remota.sh; then
  echo "prova-remota: script diverge do commit da base" >&2
  exit 2
fi

unset GITHUB_TOKEN GH_TOKEN ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
exec python3 "$modulo" --base "$base" --head "$head"
