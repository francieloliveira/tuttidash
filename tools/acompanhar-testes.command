#!/bin/bash
# Acompanha ao vivo a prova da lane mais recente; troca sozinho quando outra começa.
C=~/.transcentia/tools/cfg; cfg(){ [ -x "$C" ] && "$C" get "$1" "$2" 2>/dev/null || echo "$2"; }
G=$(cfg painel.proof_log_glob "~/Developer/*-worktrees/*/.lane/proof.log"); G=${G/#\~/$HOME}
I=$(cfg painel.intervalo_s 10); N=$(cfg painel.linhas_lane 40); R=$(cfg painel.filtro "Test Case|error:|Executed|BLOCK|TEST (SUCCEEDED|FAILED)|abortado")
# Rodapé com barra de progresso (rodape.py lê a prova mais recente por conta própria).
exec > >(/usr/bin/python3 ~/.transcentia/tools/rodape.py testes --glob "$G") 2>&1
cur=""; P=""
while true; do
  new=$(ls -t $G 2>/dev/null | head -1)
  if [ -n "$new" ] && [ "$new" != "$cur" ]; then
    [ -n "$P" ] && kill $P 2>/dev/null
    cur=$new; card=$(basename "$(dirname "$(dirname "$cur")")")
    echo; echo "=== $(echo $card | tr a-z A-Z) ==="
    bash ~/.transcentia/tools/seguir-com-hora.sh "$cur" "$N" "$R" &
    P=$!
  fi
  sleep $I
done
