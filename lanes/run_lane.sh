#!/usr/bin/env bash
# Runner de uma lane (roda dentro da sessão tmux criada pelo dispatcher).
#   run_lane.sh <lane> <worktree> <card> <log.jsonl> <agent_cmd> <run_dir>
# O comando e a prova vêm do RUN_DIR (FRA-595), nunca de .lane/agent_cmd.
# Executa o agente headless com o prompt do RUN_DIR, mostra a saída formatada,
# grava o exit_code no RUN_DIR e espera o dispatcher fechar o card.
set -uo pipefail
LANE="${1:-}"; WT="${2:-}"; CARD="${3:-}"; LOG="${4:-}"
AGENT_CMD_FILE="${5:-}"; RUN_DIR="${6:-}"
if [ -z "$LANE" ] || [ -z "$WT" ] || [ -z "$CARD" ] || [ -z "$LOG" ] || [ -z "$AGENT_CMD_FILE" ] || [ -z "$RUN_DIR" ]; then
  echo "run_lane.sh: faltou lane, worktree, card, log, agent_cmd ou RUN_DIR" >&2
  exit 1
fi
if [ -L "$AGENT_CMD_FILE" ] || [ -L "$RUN_DIR" ]; then
  echo "run_lane.sh: symlink recusado" >&2
  exit 1
fi
# Este script e o lane_view.py vêm do mesmo diretório (repo ou bundle assinado).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# zdotdir é estado. Escrever dentro do .app quebraria o codesign.
STATE_DIR="$HOME/.transcentia/lanes"
# O CLI dsh vem dentro do app DeepSeek Harness; instalação global (npm) também vale.
DSH_BIN="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin"
export LANE PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$DSH_BIN:$PATH"
cd "$WT" || exit 1
printf '\033]0;lane:%s · %s\007' "$LANE" "$CARD"   # título da janela
echo "━━ lane:$LANE · $CARD · $(date '+%H:%M:%S') ━━"
echo "worktree: $WT"
echo "log bruto: $LOG"
echo

# FRA-269: shell limpo. O agente e os comandos que ele abre não leem o .zshrc/.bashrc
# do usuário (um alias `cat`→`bat` quebrado derrubou o FRA-13). ZDOTDIR vazio impede
# o zsh de ler ~/.zshrc; env -i deixa só o necessário; PATH explícito.
# FRA-595: o comando é o arquivo que o dispatcher passou por argv, aberto sem
# seguir symlink. `.lane/agent_cmd` não entra.
CLEAN_ZDOTDIR="$STATE_DIR/zdotdir-limpo"
mkdir -p "$CLEAN_ZDOTDIR"
if ! AGENT_CMD="$(/usr/bin/python3 - "$AGENT_CMD_FILE" <<'PY'
import os, sys
path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags)
except OSError as exc:
    sys.stderr.write(f"agent_cmd recusado: {exc}\n")
    sys.exit(1)
try:
    dados = b""
    while len(dados) < 1_000_000:
        pedaco = os.read(fd, 1 << 16)
        if not pedaco:
            break
        dados += pedaco
finally:
    os.close(fd)
sys.stdout.buffer.write(dados)
PY
)"; then
  exit 1
fi
PROMPT="$RUN_DIR/prompt.md"
# Abre o prompt com O_NOFOLLOW e entrega no stdin do bash. Symlink não entra.
env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" \
  TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-pt_BR.UTF-8}" TERM="${TERM:-xterm-256color}" \
  PATH="$PATH" SHELL=/bin/bash ZDOTDIR="$CLEAN_ZDOTDIR" LANE="$LANE" \
  DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}" \
  /usr/bin/python3 -c '
import os, sys
path, cmd = sys.argv[1], sys.argv[2]
try:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
except OSError as exc:
    sys.stderr.write("prompt recusado: %s\n" % exc)
    sys.exit(1)
os.dup2(fd, 0)
if fd > 0:
    os.close(fd)
os.execv("/bin/bash", ["/bin/bash", "--noprofile", "--norc", "-c", cmd])
' "$PROMPT" "$AGENT_CMD" 2>&1 | tee "$LOG" | /usr/bin/python3 "$SCRIPT_DIR/lane_view.py"
rc=${PIPESTATUS[0]}
# Não sobrescreve: se o dispatcher parou a lane, o motivo dele já está lá.
# O_EXCL recusa arquivo plantado e não segue symlink. O código fica no RUN_DIR.
/usr/bin/python3 - "$RUN_DIR/exit_code" "$rc" <<'PY'
import os, sys
path, rc = sys.argv[1], sys.argv[2]
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags, 0o600)
except FileExistsError:
    sys.exit(0)
os.write(fd, (rc + "\n").encode())
os.close(fd)
PY

# dsh escreve texto puro, sem o stream JSON das outras lanes. Uma linha `result`
# sintética no fim dá ao parser do app o desfecho (ok/erro) e mantém o custo
# desconhecido — não inventa US$ zero.
if [ "$LANE" = "deepseek" ]; then
  /usr/bin/python3 - "$LOG" "$rc" <<'PY'
import json, sys
log, rc = sys.argv[1], int(sys.argv[2])
evento = {"type": "result", "subtype": "success" if rc == 0 else "error",
          "is_error": rc != 0, "num_turns": 1}
with open(log, "a", encoding="utf-8") as f:
    f.write(json.dumps(evento, ensure_ascii=False) + "\n")
PY
fi

CODIGO="$(/usr/bin/python3 - "$RUN_DIR/exit_code" "$rc" <<'PY'
import os, sys
path, rc = sys.argv[1], sys.argv[2]
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags)
except OSError:
    sys.stdout.write(rc)
    sys.exit(0)
try:
    sys.stdout.write(os.read(fd, 64).decode("utf-8", "replace").strip() or rc)
finally:
    os.close(fd)
PY
)"
echo
echo "━━ agente terminou (código ${CODIGO}) · o dispatcher assume: prova e fechamento ━━"
# Acompanha a prova do dispatcher (segundo plano, pode levar dezenas de minutos) até o card
# fechar, sem limite de tempo. Cada etapa aparece aqui e vai para o log do painel.
PAINEL="$HOME/Library/Logs/TranscentIA/lanes-dispatcher.log"
INICIO=$(date +%s)
LIDAS=0
PROOF="$RUN_DIR/proof.log"
mostrar_prova() {
  [ -f "$PROOF" ] && [ ! -L "$PROOF" ] || return 0
  TOTAL=$(wc -l < "$PROOF" | tr -d ' ')
  [ "$TOTAL" -gt "$LIDAS" ] || return 0
  tail -n +"$((LIDAS + 1))" "$PROOF" | head -n "$((TOTAL - LIDAS))" \
    | grep -E '^\[prova\]|Executed [0-9]+ tests?|\*\* TEST (SUCCEEDED|FAILED) \*\*|abortado pelo preflight|lock de build|error:' \
    | while IFS= read -r L; do
        printf '\r\033[K  %s\n' "$L"
        printf '%s lane:%s %s prova: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LANE" "$CARD" "$L" >> "$PAINEL"
      done
  LIDAS=$TOTAL
}
FINAL="$RUN_DIR/finalized"
while [ ! -f "$FINAL" ] || [ -L "$FINAL" ]; do
  [ -L "$FINAL" ] && echo "finalized symlink recusado" >&2 && exit 1
  mostrar_prova
  printf '\r\033[K  … %d min desde o fim do agente' "$(( ($(date +%s) - INICIO) / 60 ))"
  sleep 10
done
mostrar_prova
printf '\r\033[K'
echo "━━ resultado: $(/usr/bin/python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)); print(os.read(fd,400).decode("utf-8","replace").strip()); os.close(fd)' "$FINAL") ━━"
# Id da sessão do agente: o init e o result do stream trazem session_id.
SID=$(/usr/bin/python3 -c '
import json, sys
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        sid = json.loads(raw).get("session_id")
    except (ValueError, AttributeError):
        continue
    if isinstance(sid, str) and sid:
        print(sid)
        break
' "$LOG" 2>/dev/null)
# Lane ACP (PRD lanes-acp): o agente vem do evento inicial do acp_runner, não do nome da lane.
ACP_AGENTE=$(/usr/bin/python3 -c '
import json, re, sys
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        ev = json.loads(raw)
    except ValueError:
        continue
    if isinstance(ev, dict) and ev.get("transporte") == "acp":
        a = str(ev.get("agente") or "")
        print(a if re.fullmatch(r"[a-z][a-z0-9-]{0,39}", a) else "")
        break
' "$LOG" 2>/dev/null)
if [ -n "$ACP_AGENTE" ]; then case "$SID" in *[!A-Za-z0-9_.:-]*) SID="";; esac; fi
if [ "$LANE" = "grok" ]; then CLI=grok; elif [ "$LANE" = "opencode" ]; then CLI=opencode; elif [ "$LANE" = "codex" ]; then CLI=codex; elif [ "$LANE" = "deepseek" ]; then CLI=dsh; else CLI=claude; fi
if [ -n "$ACP_AGENTE" ]; then
  if [ "$ACP_AGENTE" = "opencode" ] && [ -n "$SID" ]; then RESUME="cd \"$WT\" && opencode run --session $SID";
  else RESUME="cd \"$WT\" && sessão ACP ${SID:-desconhecida} do agente $ACP_AGENTE"; fi
elif [ "$LANE" = "deepseek" ]; then
  # O dsh headless não tem --resume: a sessão fica no histórico (~/.dsh/sessions).
  # O retomar possível é abrir outra sessão no worktree, que já tem o trabalho.
  RESUME="cd \"$WT\" && dsh --profile headless --patch \"$RUN_DIR/deepseek.yml\" \"continue o card $CARD a partir do worktree\""
elif [ -n "$SID" ]; then
  # opencode/codex: --session continua a sessão (não validado ponta a ponta, FRA-374/376)
  if [ "$LANE" = "opencode" ]; then RESUME="cd \"$WT\" && opencode run --session $SID";
  elif [ "$LANE" = "codex" ]; then RESUME="cd \"$WT\" && codex run --session $SID";
  else RESUME="cd \"$WT\" && $CLI --resume $SID"; fi
elif [ "$LANE" = "grok" ]; then
  RESUME="cd \"$WT\" && grok sessions (restaure a sessão desta lane)"
elif [ "$LANE" = "opencode" ]; then
  RESUME="cd \"$WT\" && opencode run --continue"
elif [ "$LANE" = "codex" ]; then
  RESUME="cd \"$WT\" && codex run --continue"
else
  RESUME="cd \"$WT\" && claude --continue"
fi
RESULTADO=$(/usr/bin/python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY|getattr(os,"O_NOFOLLOW",0)); print(os.read(fd,400).decode("utf-8","replace").strip()); os.close(fd)' "$FINAL" 2>/dev/null || echo "o dispatcher ainda não fechou o card")

# Painel: a linha de retomar fica no log do dispatcher (que o painel de logs acompanha),
# para não se perder quando a tela da lane for reaproveitada.
mkdir -p "$(dirname "$PAINEL")"
printf '%s lane:%s %s → %s · retomar: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LANE" "$CARD" \
  "$RESULTADO" "$RESUME" >> "$PAINEL"

# Tela final: limpa, mostra o resumo da task e, na última linha, como retomar a sessão.
# Fica assim até o próximo card desta lane (o dispatcher recria a sessão tmux no claim).
# result.json continua sendo o arquivo do agente. Symlink é recusado.
RESUMO=$(/usr/bin/python3 -c '
import json, os, sys, textwrap
caminho = sys.argv[1]
if os.path.islink(caminho) or os.path.islink(os.path.dirname(caminho)):
    raise SystemExit(0)
try:
    fd = os.open(caminho, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    raw = os.read(fd, 1_000_000)
    os.close(fd)
    r = json.loads(raw.decode("utf-8"))
except Exception:
    r = {}
partes = [r.get("summary") or r.get("reason") or "(sem resumo no result.json)"]
if r.get("residual_risk"):
    partes.append("Risco: " + str(r["residual_risk"]))
cols = int(sys.argv[2]) if sys.argv[2].isdigit() else 100
print("\n\n".join(textwrap.fill(str(p), width=max(40, cols - 2)) for p in partes))
' "$WT/.lane/result.json" "$(tput cols 2>/dev/null || echo 100)" 2>/dev/null)
clear || true
echo "━━ lane:$LANE · $CARD · terminou $(date '+%H:%M') ━━"
echo
echo "Resultado: $RESULTADO"
echo
echo "$RESUMO"
echo
echo "Retomar: $RESUME"
while :; do sleep 86400; done
