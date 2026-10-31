#!/bin/bash
# Instala o app no aparelho a partir da main ou de uma branch atualizada com a main.
# Uso: instalar.sh <main|branch:nome> <arquivo-de-log> <repo> <worktree> <programa> [argumentos...]
#   O programa e os argumentos são argv (vêm de `watch.instalar_comando`).
#   O script não abre um shell em volta do comando. Texto antigo da config é partido no vigia (shlex).
#   REPO e WT são conferidos com o cadastro antes de qualquer git reset/clean.
#   A ref passa por `git check-ref-format --branch`. `$` e `;` são recusados:
#   o check-ref-format deixa esses caracteres passarem, e este fluxo não aceita.
# Roda dentro da sessão tmux "instalar-aparelho" (E14: nunca em /tmp com nohup).
# 1ª tentativa com SKIP_PREFLIGHT=1; só se falhar, repete com o preflight normal.
# Prova: TUTTIDASH_INSTALAR_CONFIG aponta um cadastro temporário; não afrouxa a raiz.
set -u
export PATH=/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

if [ "$#" -lt 5 ]; then
  echo "[instalar] uso: instalar.sh <main|branch:nome> <log> <repo> <worktree> <programa> [argumentos...]" >&2
  exit 2
fi
REF="$1"; LOG="$2"; REPO="$3"; WT="$4"
shift 4

fim(){ echo "$1" > "$LOG.exit"; echo "[instalar] fim código $1" >> "$LOG"; exit "$1"; }
recusar(){ mkdir -p "$(dirname "$LOG")"; echo "[instalar] $1" >> "$LOG"; fim 2; }

mkdir -p "$(dirname "$LOG")"
if [ -z "${1:-}" ]; then
  recusar "comando ausente: passe o programa e os argumentos em argv, sem shell"
fi

BR=""
msg=""
validar_ref() {
  local nome=""
  msg=""
  if [ "$REF" = "main" ]; then
    nome="main"
  elif [ "${REF#branch:}" != "$REF" ]; then
    nome="${REF#branch:}"
  else
    msg="ref recusada: use main ou branch:<nome>"
    return 1
  fi
  if [ -z "$nome" ]; then
    msg="ref recusada: branch sem nome"
    return 1
  fi
  # `--branch --help` seria lido como opção do git, não como nome.
  case "$nome" in
    -*)
      msg="ref recusada: «${nome}» não pode começar com -"
      return 1
      ;;
  esac
  if ! git check-ref-format --branch "$nome" >/dev/null 2>&1; then
    msg="ref recusada: «${nome}» não passa em git check-ref-format --branch"
    return 1
  fi
  # `$` e `;` não são proibidos pelo check-ref-format. Recusa aqui, sem executar.
  case "$nome" in
    *'$'*|*';'*)
      msg="ref recusada: «${nome}» contém \$ ou ; e não entra neste fluxo (git check-ref-format não barra esses caracteres)"
      return 1
      ;;
  esac
  BR="$nome"
  return 0
}
validar_ref || recusar "$msg"

AQUI="$(cd "$(dirname "$0")" && pwd)"
if ! alvos="$(python3 - "$AQUI" "$REPO" "$WT" 2>>"$LOG" <<'PY'
import sys
from pathlib import Path
aqui = Path(sys.argv[1])
for cand in (aqui, aqui.parent / "gasto_lanes"):
    if (cand / "projetos.py").is_file():
        sys.path.insert(0, str(cand))
        break
else:
    print("projetos.py não encontrado ao lado de instalar.sh")
    sys.exit(2)
import projetos
codigo, texto = projetos.checar_alvo_instalar(sys.argv[2], sys.argv[3])
print(texto)
sys.exit(codigo)
PY
)"; then
  recusar "${alvos:-repo ou worktree recusados}"
fi
REPO="${alvos%%$'\n'*}"
_resto="${alvos#*$'\n'}"
WT="${_resto%%$'\n'*}"
if [ -z "$REPO" ] || [ -z "$WT" ] || [ "$REPO" = "$WT" ]; then
  recusar "repo ou worktree recusados"
fi

{
  echo "[instalar] $(date '+%F %T') ref=$REF"
  git -C "$REPO" fetch -q origin || fim 2
  [ -d "$WT" ] || git -C "$REPO" worktree add -q --detach "$WT" origin/main || fim 2
  git -C "$WT" merge --abort 2>/dev/null || true
  git -C "$WT" reset -q --hard && git -C "$WT" clean -qfd -e .lane || fim 2
  if [ "$REF" = "main" ]; then
    git -C "$WT" checkout -q --detach origin/main || fim 2
  else
    git -C "$WT" checkout -q --detach "origin/$BR" || fim 2
    git -C "$WT" -c user.name="TuttiDash Gestor" -c user.email=gestor@local merge -q --no-edit origin/main \
      || { echo "[instalar] conflito ao atualizar $BR com a main"; git -C "$WT" merge --abort 2>/dev/null || true; fim 3; }
  fi
  echo "[instalar] head $(git -C "$WT" rev-parse --short HEAD)"
} >> "$LOG" 2>&1
cd "$WT" || fim 2
SKIP_PREFLIGHT=1 "$@" >> "$LOG" 2>&1 && fim 0
echo "[instalar] falhou com SKIP_PREFLIGHT=1; repetindo com o preflight normal" >> "$LOG"
env -u SKIP_PREFLIGHT "$@" >> "$LOG" 2>&1 && fim 0
fim 1
