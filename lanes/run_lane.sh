#!/usr/bin/env bash
# Runner de uma lane (roda dentro da sessão tmux criada pelo dispatcher).
#   run_lane.sh <lane> <worktree> <card> <log.jsonl>
# Executa o agente headless com o prompt em .lane/prompt.md, mostra a saída
# formatada, grava .lane/exit_code e espera o dispatcher fechar o card.
set -uo pipefail
LANE="$1"; WT="$2"; CARD="$3"; LOG="$4"
HERE="$HOME/.transcentia/lanes"
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
CLEAN_ZDOTDIR="$HERE/zdotdir-limpo"
mkdir -p "$CLEAN_ZDOTDIR"
AGENT_CMD="$(cat .lane/agent_cmd)"
env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" \
  TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-pt_BR.UTF-8}" TERM="${TERM:-xterm-256color}" \
  PATH="$PATH" SHELL=/bin/bash ZDOTDIR="$CLEAN_ZDOTDIR" LANE="$LANE" \
  DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}" \
  /bin/bash --noprofile --norc -c "$AGENT_CMD" < .lane/prompt.md 2>&1 | tee "$LOG" | /usr/bin/python3 "$HERE/lane_view.py"
rc=${PIPESTATUS[0]}
# Não sobrescreve: se o dispatcher parou a lane, o motivo dele já está lá.
[ -f .lane/exit_code ] || echo "$rc" > .lane/exit_code

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

echo
echo "━━ agente terminou (código $(cat .lane/exit_code)) · o dispatcher assume: prova e fechamento ━━"
# Acompanha a prova do dispatcher (segundo plano, pode levar dezenas de minutos) até o card
# fechar, sem limite de tempo. Cada etapa aparece aqui e vai para o log do painel.
PAINEL="$HOME/Library/Logs/TranscentIA/lanes-dispatcher.log"
INICIO=$(date +%s)
LIDAS=0
mostrar_prova() {
  [ -f .lane/proof.log ] || return 0
  TOTAL=$(wc -l < .lane/proof.log | tr -d ' ')
  [ "$TOTAL" -gt "$LIDAS" ] || return 0
  tail -n +"$((LIDAS + 1))" .lane/proof.log | head -n "$((TOTAL - LIDAS))" \
    | grep -E '^\[prova\]|Executed [0-9]+ tests?|\*\* TEST (SUCCEEDED|FAILED) \*\*|abortado pelo preflight|lock de build|error:' \
    | while IFS= read -r L; do
        printf '\r\033[K  %s\n' "$L"
        printf '%s lane:%s %s prova: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LANE" "$CARD" "$L" >> "$PAINEL"
      done
  LIDAS=$TOTAL
}
while [ ! -f .lane/finalized ]; do
  mostrar_prova
  printf '\r\033[K  … %d min desde o fim do agente' "$(( ($(date +%s) - INICIO) / 60 ))"
  sleep 10
done
mostrar_prova
printf '\r\033[K'
echo "━━ resultado: $(cat .lane/finalized) ━━"
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
if [ "$LANE" = "grok" ]; then CLI=grok; elif [ "$LANE" = "opencode" ]; then CLI=opencode; elif [ "$LANE" = "codex" ]; then CLI=codex; elif [ "$LANE" = "deepseek" ]; then CLI=dsh; else CLI=claude; fi
if [ "$LANE" = "deepseek" ]; then
  # O dsh headless não tem --resume: a sessão fica no histórico (~/.dsh/sessions).
  # O retomar possível é abrir outra sessão no worktree, que já tem o trabalho.
  RESUME="cd \"$WT\" && dsh --profile headless --patch .lane/deepseek.yml \"continue o card $CARD a partir do worktree\""
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
RESULTADO=$(cat .lane/finalized 2>/dev/null || echo "o dispatcher ainda não fechou o card")

# Painel: a linha de retomar fica no log do dispatcher (que o painel de logs acompanha),
# para não se perder quando a tela da lane for reaproveitada.
printf '%s lane:%s %s → %s · retomar: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LANE" "$CARD" \
  "$RESULTADO" "$RESUME" >> "$HOME/Library/Logs/TranscentIA/lanes-dispatcher.log"

# Tela final: limpa, mostra o resumo da task e, na última linha, como retomar a sessão.
# Fica assim até o próximo card desta lane (o dispatcher recria a sessão tmux no claim).
RESUMO=$(/usr/bin/python3 -c '
import json, sys, textwrap
try:
    r = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    r = {}
partes = [r.get("summary") or r.get("reason") or "(sem resumo no result.json)"]
if r.get("residual_risk"):
    partes.append("Risco: " + str(r["residual_risk"]))
cols = int(sys.argv[2]) if sys.argv[2].isdigit() else 100
print("\n\n".join(textwrap.fill(str(p), width=max(40, cols - 2)) for p in partes))
' .lane/result.json "$(tput cols 2>/dev/null)" 2>/dev/null)
clear
echo "━━ lane:$LANE · $CARD · terminou $(date '+%H:%M') ━━"
echo
echo "Resultado: $RESULTADO"
echo
echo "$RESUMO"
echo
echo "Retomar: $RESUME"
while :; do sleep 86400; done
