#!/bin/bash
# Segue um log mostrando a hora de cada linha nova, como no log do dispatcher.
# Uso: seguir-com-hora.sh ARQUIVO LINHAS [regex-filtro]
# As LINHAS anteriores aparecem sem hora (não dá para saber quando foram escritas);
# uma linha avisa quando o arquivo começou e a última escrita. Sem buraco nem repetição
# entre o que já estava no arquivo e o que chega depois.
# Ao receber TERM (troca de arquivo pelo seguidor), encerra também o tail e os filtros.
F=$1; N=${2:-20}; R=${3:-}
D="$(cd "$(dirname "$0")" && pwd)"
trap 'pkill -P $$ 2>/dev/null; exit 0' TERM INT HUP
desde=$(stat -f %SB -t '%Y-%m-%d %H:%M:%S' "$F" 2>/dev/null)
ultima=$(stat -f %Sm -t '%H:%M:%S' "$F" 2>/dev/null)
printf '\033[2m(linhas anteriores sem hora · arquivo de %s · última escrita %s)\033[0m\n' "$desde" "$ultima"
L=$(wc -l < "$F" 2>/dev/null | tr -d ' '); L=${L:-0}
head -n "$L" "$F" 2>/dev/null | tail -n "$N" | bash "$D/colorir.sh" "$R"
tail -n +$((L + 1)) -F "$F" 2>/dev/null | bash "$D/carimbo.sh" | bash "$D/colorir.sh" "$R" &
wait
