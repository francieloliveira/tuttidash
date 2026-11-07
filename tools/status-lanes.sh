#!/bin/bash
# Barra de status: carga do Mac e lanes com sessão aberta.
carga=$(sysctl -n vm.loadavg | awk '{print $2}')
TM=$(command -v tmux || echo /opt/homebrew/bin/tmux)
lanes=$($TM ls -F '#{session_name}' 2>/dev/null | sed -n 's/^lane-//p' | tr '\n' ' ')
echo "carga $carga · ${lanes:-ociosas}"
