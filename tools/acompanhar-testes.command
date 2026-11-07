#!/bin/bash
# Etapa prova: o log de teste mais recente, da lane ou local (/tmp).
# Troca sozinho quando outro arquivo passa a ser o mais novo.
C=~/.transcentia/tools/cfg; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
G=$(cfg painel.proof_log_glob "~/Developer/*-worktrees/*/.lane/proof.log"); G=${G/#\~/$HOME}
GL=$(cfg painel.gestor_log_glob "/tmp/fra*-*.log")
I=$(cfg painel.intervalo_s 10); N=$(cfg painel.linhas_lane 40)
R=$(cfg painel.filtro "Test Case|error:|Executed|BLOCK|TEST (SUCCEEDED|FAILED)|abortado")
exec > >(/usr/bin/python3 ~/.transcentia/tools/rodape.py testes --glob "$G" --glob "$GL") 2>&1
cur=""; P=""
mais_novo() {
  local melhor="" m=0 t
  for f in "$@"; do
    [ -f "$f" ] || continue
    t=$(stat -f %m "$f" 2>/dev/null || echo 0)
    if [ "$t" -gt "$m" ]; then m=$t; melhor=$f; fi
  done
  printf '%s' "$melhor"
}
while true; do
  # shellcheck disable=SC2086
  new=$(mais_novo $(ls -t $G $GL 2>/dev/null | head -8))
  if [ -n "$new" ] && [ "$new" != "$cur" ]; then
    [ -n "$P" ] && kill $P 2>/dev/null
    cur=$new
    case "$cur" in
      */.lane/proof.log) rotulo=$(basename "$(dirname "$(dirname "$cur")")"); origem=lane ;;
      *) rotulo=$(basename "$cur" .log); origem=local ;;
    esac
    printf '\n━━ prova · %s · %s ━━\n' "$origem" "$rotulo"
    bash ~/.transcentia/tools/seguir-com-hora.sh "$cur" "$N" "$R" &
    P=$!
  fi
  sleep "$I"
done
