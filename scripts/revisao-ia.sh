#!/bin/bash
# FRA-612. Revisão de IA no runner limpo.
# Este arquivo vale como blob do commit da base (SHA completo em REVISAO_BASE_SHA).
# Uso: revisao-ia.sh <checkout-da-base> <checkout-do-head>
# O head só entra como árvore do diff. Nenhum script de lá é executado.
# O revisor não recebe o home, nem token, nem gh de escrita.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "uso: $0 <checkout-da-base> <checkout-do-head>" >&2
  exit 2
fi

base=$(cd "$1" && pwd -P)
head=$(cd "$2" && pwd -P)

if [ "$head" = "$base" ] || [ "${head#"$base"/}" != "$head" ]; then
  echo "revisao-ia: head dentro da base" >&2
  exit 2
fi
if [ "${base#"$head"/}" != "$base" ]; then
  echo "revisao-ia: base dentro do head" >&2
  exit 2
fi

[[ "${REVISAO_BASE_SHA-}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "revisao-ia: SHA da base incompleto" >&2
  exit 2
}
[[ "${REVISAO_HEAD_SHA-}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "revisao-ia: SHA do head incompleto" >&2
  exit 2
}

if [ "$(git -C "$base" rev-parse HEAD)" != "$REVISAO_BASE_SHA" ]; then
  echo "revisao-ia: checkout da base não é o SHA anunciado" >&2
  exit 2
fi
if [ "$(git -C "$head" rev-parse HEAD)" != "$REVISAO_HEAD_SHA" ]; then
  echo "revisao-ia: checkout do head não é o SHA anunciado" >&2
  exit 2
fi

modulo="$base/gasto_lanes/revisao_ia.py"
script="$base/scripts/revisao-ia.sh"
if [ -L "$modulo" ] || [ -L "$script" ]; then
  echo "revisao-ia: symlink na base" >&2
  exit 2
fi
if [ ! -f "$modulo" ]; then
  echo "revisao-ia: módulo da base ausente" >&2
  exit 2
fi
if ! git -C "$base" diff --quiet HEAD -- gasto_lanes/revisao_ia.py; then
  echo "revisao-ia: módulo diverge do commit da base" >&2
  exit 2
fi
if ! git -C "$base" diff --quiet HEAD -- scripts/revisao-ia.sh; then
  echo "revisao-ia: script diverge do commit da base" >&2
  exit 2
fi

contexto=$(mktemp -d)
home_revisor=$(mktemp -d)
trap 'rm -rf "$contexto" "$home_revisor"' EXIT

args=(--base "$base" --head "$head")
if [ -n "${REVISAO_EVENTO-}" ]; then
  args+=(--evento "$REVISAO_EVENTO")
fi

export HOME="$home_revisor"
export PATH="/usr/bin:/bin"
export PYTHONDONTWRITEBYTECODE=1
unset GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN ACTIONS_RUNTIME_TOKEN \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL SSH_AUTH_SOCK
cd "$contexto"
python3 "$modulo" "${args[@]}"
