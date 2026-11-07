#!/bin/bash
# Etapa fila: log do dispatcher e, no rodapé, o estado atual de cada lane.
L=~/Library/Logs/TranscentIA; N=${1:-24}
exec > >(/usr/bin/python3 ~/.transcentia/tools/rodape.py lanes --log "$L/lanes-dispatcher.log") 2>&1
printf '━━ fila ━━\n'
tail -n "$N" -F "$L/lanes-dispatcher.log" | bash ~/.transcentia/tools/colorir.sh
