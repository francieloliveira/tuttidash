#!/usr/bin/env bash
# Canal e versão do build do app (29/10). Imprime "<canal> <versão>":
#   main main-<sha>                  commit = origin/main e sem mudança pendente
#   alpha branch-<nome>-<sha>[-sujo]  qualquer outra coisa (outra branch, à frente da main, mudança local)
#   alpha dev                        sem git
# Não vai à rede: compara com a origin/main que o repositório já tem.
# Uso: tools/versao-build.sh [pasta do repositório]
set -u
d="${1:-.}"
sha=$(git -C "$d" rev-parse --short=7 HEAD 2>/dev/null) || { echo "alpha dev"; exit 0; }
main=$(git -C "$d" rev-parse --short=7 origin/main 2>/dev/null || true)
sujo=$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null | grep -v '\.lane/' | head -1 || true)
if [ -n "$main" ] && [ "$sha" = "$main" ] && [ -z "$sujo" ]; then
  echo "main main-$sha"
  exit 0
fi
branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
if [ "$sha" = "$main" ]; then
  nome=main
elif [ "$branch" = "HEAD" ]; then
  nome=detached
else
  nome="${branch##*/}"
fi
nome=$(printf '%s' "$nome" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)
echo "alpha branch-$nome-$sha${sujo:+-sujo}"
