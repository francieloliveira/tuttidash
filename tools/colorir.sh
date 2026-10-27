#!/bin/bash
# Colorizador de logs (bash 3.2 + awk do macOS). Uso: ... | colorir.sh [regex-filtro]
# Sem filtro, passa tudo. Linha a linha (fflush), sem buffer.
# O filtro vale para o texto depois da data/hora (uma regex com ^ continua funcionando).
COLORIR_FILTRO="${1:-}" exec /usr/bin/awk '
BEGIN { filtro = ENVIRON["COLORIR_FILTRO"]; E="\033["; R=E "0m" }
{
  l = $0; pre = ""
  if (match(l, /^(\[?[0-9-]+ )?[0-9][0-9]:[0-9][0-9](:[0-9][0-9])?\]? ?/)) {
    pre = E "2m" substr(l, 1, RLENGTH) R; l = substr(l, RLENGTH + 1)
  }
  if (filtro != "" && l !~ filtro) next
  if (l ~ /=== *FRA-[0-9]+.*===/)                                  l = E "1;36m" l R
  else if (l ~ /[Ff]ailed|FAILED|[Ee]rror|FALHOU|lane:falhou/)        l = E "1;31m" l R
  else if (l ~ /[Ww]arning|BLOCK|parada/)                           l = E "33m" l R
  else if (l ~ /[Pp]assed|SUCCEEDED|(^|[^A-Za-z])OK([^A-Za-z]|$)/)  l = E "32m" l R
  print pre l; fflush()
}'
