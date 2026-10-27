#!/bin/bash
# Dispatcher no painel: o log da fila rolando e, no rodapé, o estado atual de cada lane.
L=~/Library/Logs/TranscentIA; N=${1:-30}
exec > >(/usr/bin/python3 ~/.transcentia/tools/rodape.py lanes --log "$L/lanes-dispatcher.log") 2>&1
tail -n "$N" -F "$L/lanes-dispatcher.log" | bash ~/.transcentia/tools/colorir.sh
