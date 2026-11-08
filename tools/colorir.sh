#!/bin/bash
# Colorizador de logs do painel (bash 3.2 + awk do macOS).
# Uso: ... | colorir.sh [regex-filtro]
# Sem filtro, passa tudo. Linha a linha (fflush), sem buffer.
# O filtro vale para o texto depois da data/hora.
# Na tela: encurta o home
# e corta linha longa. O arquivo de log não é reescrito.
COLORIR_FILTRO="${1:-}" COLORIR_HOME="${HOME:-}" exec /usr/bin/awk '
BEGIN { filtro = ENVIRON["COLORIR_FILTRO"]; home = ENVIRON["COLORIR_HOME"]; E="\033["; R=E "0m" }
function limpar(s) {
  if (home != "") gsub(home, "~", s)
  if (length(s) > 220) s = substr(s, 1, 219) "…"
  return s
}
{
  l = $0; pre = ""
  if (match(l, /^(\[?[0-9-]+ )?[0-9][0-9]:[0-9][0-9](:[0-9][0-9])?\]? ?/)) {
    pre = E "2m" substr(l, 1, RLENGTH) R; l = substr(l, RLENGTH + 1)
  }
  if (filtro != "" && l !~ filtro) next
  l = limpar(l)
  if (l ~ /^━━/ || l ~ /^=== /)                                  l = E "1;36m" l R
  else if (l ~ /[Ff]ailed|FAILED|[Ee]rror|FALHOU|lane:falhou/)  l = E "1;31m" l R
  else if (l ~ /[Ww]arning|BLOCK|parada/)                       l = E "33m" l R
  else if (l ~ /[Pp]assed|SUCCEEDED|(^|[^A-Za-z])OK([^A-Za-z]|$)/) l = E "32m" l R
  print pre l; fflush()
}'
