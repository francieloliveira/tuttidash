#!/bin/bash
# Prova local (/tmp/fra*-*.log). O painel já junta isto na etapa prova.
# Este script fica para quem quiser seguir só este glob.
C=~/.transcentia/tools/cfg; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
G=$(cfg painel.gestor_log_glob "/tmp/fra*-*.log"); I=$(cfg painel.intervalo_s 10); N=$(cfg painel.linhas_gestor 20)
exec > >(/usr/bin/python3 ~/.transcentia/tools/rodape.py testes --glob "$G") 2>&1
cur=""; P=""
while true; do
  # shellcheck disable=SC2086
  new=$(ls -t $G 2>/dev/null | head -1)
  if [ -n "$new" ] && [ "$new" != "$cur" ]; then
    [ -n "$P" ] && kill $P 2>/dev/null
    cur=$new
    printf '\n━━ prova · local · %s ━━\n' "$(basename "$cur" .log)"
    bash ~/.transcentia/tools/seguir-com-hora.sh "$cur" "$N" "Test Case|error:|Executed|BLOCK|TEST (SUCCEEDED|FAILED)|abortado|INSTALL" &
    P=$!
  fi
  sleep "$I"
done
