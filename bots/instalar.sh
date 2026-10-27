#!/bin/bash
# Instala o app no aparelho a partir da main ou de uma branch atualizada com a main.
# Uso: instalar.sh main|branch:<nome> <arquivo-de-log> <repo> <worktree> <comando>
#   <comando> roda dentro do worktree (vem de `watch.instalar_comando` na config).
# Roda dentro da sessão tmux "instalar-aparelho" (E14: nunca em /tmp com nohup).
# 1ª tentativa com SKIP_PREFLIGHT=1; só se falhar, repete com o preflight normal.
set -u
REF="$1"; LOG="$2"; REPO="$3"; WT="$4"; CMD="$5"
export PATH=/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
mkdir -p "$(dirname "$LOG")"
fim(){ echo "$1" > "$LOG.exit"; echo "[instalar] fim código $1" >> "$LOG"; exit "$1"; }
{
  echo "[instalar] $(date '+%F %T') ref=$REF"
  git -C "$REPO" fetch -q origin || fim 2
  [ -d "$WT" ] || git -C "$REPO" worktree add -q --detach "$WT" origin/main || fim 2
  git -C "$WT" merge --abort 2>/dev/null
  git -C "$WT" reset -q --hard && git -C "$WT" clean -qfd -e .lane
  if [ "$REF" = main ]; then
    git -C "$WT" checkout -q --detach origin/main || fim 2
  else
    BR="${REF#branch:}"
    git -C "$WT" checkout -q --detach "origin/$BR" || fim 2
    git -C "$WT" -c user.name="TuttiDash Gestor" -c user.email=gestor@local merge -q --no-edit origin/main \
      || { echo "[instalar] conflito ao atualizar $BR com a main"; git -C "$WT" merge --abort; fim 3; }
  fi
  echo "[instalar] head $(git -C "$WT" rev-parse --short HEAD)"
} >> "$LOG" 2>&1
cd "$WT" || fim 2
SKIP_PREFLIGHT=1 bash -c "$CMD" >> "$LOG" 2>&1 && fim 0
echo "[instalar] falhou com SKIP_PREFLIGHT=1; repetindo com o preflight normal" >> "$LOG"
bash -c "$CMD" >> "$LOG" 2>&1 && fim 0
fim 1
