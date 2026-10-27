#!/bin/bash
# Segue o log de build mais recente (instalação no aparelho e builds das lanes).
# Onde procurar: painel.build_log_globs na config (padrões separados por vírgula).
C=~/.transcentia/tools/cfg; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
BRUTO=$(cfg painel.build_log_globs "/tmp/*-device.log, ~/Developer/*-worktrees/*/.lane/build*.log")
GLOBS=(); ARGS=()
IFS=',' read -ra PARTES <<<"$BRUTO"
for g in "${PARTES[@]}"; do
  g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"; g=${g/#\~/$HOME}
  [ -n "$g" ] && GLOBS+=("$g") && ARGS+=(--glob "$g")
done
exec > >(/usr/bin/python3 ~/.transcentia/tools/rodape.py build "${ARGS[@]}") 2>&1
cur=""; P=""
while true; do
  new=$(ls -t ${GLOBS[@]} 2>/dev/null | head -1)
  if [ -n "$new" ] && [ "$new" != "$cur" ]; then
    [ -n "$P" ] && kill $P 2>/dev/null
    cur=$new; echo; echo "=== $(basename "$cur" .log) ==="
    bash ~/.transcentia/tools/seguir-com-hora.sh "$cur" 15 "^\[safe\]|error:|warning: .*deprecated|BUILD (SUCCEEDED|FAILED)|INSTALL|Compiling|Linking|Signing|abortado" &
    P=$!
  fi
  sleep 10
done
