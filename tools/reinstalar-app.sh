#!/usr/bin/env bash
# Reinstala o TuttiDash sem matar lane em andamento (lições das instalações de 02/11, FRA-630).
#
#   tools/reinstalar-app.sh [--espera MINUTOS] [--sem-build]
#
# 1. Build (apps/notch-mac/build.sh) com o app atual ainda rodando. Falhou: nada muda.
# 2. Âncora nova gerada do `controle` do app novo (integridade-controle.py gerar).
# 3. PAUSE: o dispatcher não assume card novo.
# 4. Espera não haver sessão tmux `lane-*` (até --espera minutos, padrão 120).
#    Trocar o bundle com lane rodando mata a sessão dela.
# 5. Um único comando de administrador: grava a âncora e troca o app. O anterior vai para
#    a Lixeira como `TuttiDash-anterior-<data>.app`. Âncora e app nunca ficam divergentes
#    por mais que esse comando (a 1ª instalação de 02/11 parou o dispatcher 1 h 29 min).
# 6. Reabre o app e tira o PAUSE (só o PAUSE que este script criou).
#
# Voltar atrás: tirar o app novo, devolver o anterior da Lixeira para /Applications e
# gravar a âncora dele (`integridade-controle.py gerar <app>/Contents/Resources/controle M`
# e `sudo python3 integridade-controle.py gravar M`).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_DEST="/Applications/TuttiDash.app"
NOVO="$REPO/apps/notch-mac/build/TuttiDash.app"
STATE="$HOME/.transcentia/lanes"
PAUSE="$STATE/PAUSE"
TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"
ESPERA_MIN=120
BUILD=1

while [ $# -gt 0 ]; do
  case "$1" in
    --espera) ESPERA_MIN="${2:?}"; shift 2;;
    --sem-build) BUILD=0; shift;;
    *) echo "uso: $0 [--espera MINUTOS] [--sem-build]" >&2; exit 2;;
  esac
done
case "$ESPERA_MIN" in ''|*[!0-9]*) echo "--espera precisa ser número de minutos" >&2; exit 2;; esac

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

lanes_rodando() {
  "$TMUX_BIN" ls -F '#{session_name}' 2>/dev/null | grep -c '^lane-' || true
}

# 1. build
if [ "$BUILD" = 1 ]; then
  log "build do app novo"
  "$REPO/apps/notch-mac/build.sh"
fi
[ -d "$NOVO" ] || { echo "app novo não existe: $NOVO" >&2; exit 1; }
codesign --verify --strict "$NOVO"
VERSAO="$(/usr/libexec/PlistBuddy -c 'Print :TDVersao' "$NOVO/Contents/Info.plist" 2>/dev/null || echo '?')"

# 2. âncora do app novo
TMPD="$(mktemp -d -t td-reinstalar)"
MANIF="$TMPD/controle.sha256"
/usr/bin/python3 "$REPO/tools/integridade-controle.py" gerar "$NOVO/Contents/Resources/controle" "$MANIF"
head -2 "$MANIF" | grep -q '^team ' || { echo "manifesto sem a equipe; abortei" >&2; exit 1; }

# 3. PAUSE (só tira no fim se fui eu que criei)
CRIEI_PAUSE=0
if [ ! -e "$PAUSE" ]; then
  mkdir -p "$STATE"
  : > "$PAUSE"
  CRIEI_PAUSE=1
  log "PAUSE criado: nenhum card novo será assumido"
else
  log "PAUSE já existia; fica como está no fim"
fi
tirar_pause() { if [ "$CRIEI_PAUSE" = 1 ]; then rm -f "$PAUSE"; log "PAUSE retirado"; fi; }
trap 'tirar_pause; rm -rf "$TMPD"' EXIT

# 4. espera as lanes ficarem livres
limite=$(( $(date +%s) + ESPERA_MIN * 60 ))
while :; do
  n="$(lanes_rodando)"
  [ "$n" = 0 ] && break
  if [ "$(date +%s)" -ge "$limite" ]; then
    echo "ainda há $n lane(s) rodando depois de $ESPERA_MIN min; não troquei o app" >&2
    exit 1
  fi
  log "esperando $n lane(s) terminar ($("$TMUX_BIN" ls -F '#{session_name}' 2>/dev/null | grep '^lane-' | tr '\n' ' '))"
  sleep 30
done
log "nenhuma lane rodando"

# 5. âncora + troca num único comando de administrador
TS="$(date +%Y%m%d-%H%M%S)"
LIXO="$HOME/.Trash/TuttiDash-anterior-$TS.app"
DONO="$(id -un):$(id -gn)"
CMD="/usr/bin/python3 '$REPO/tools/integridade-controle.py' gravar '$MANIF' && mv '$APP_DEST' '$LIXO' && /usr/bin/ditto '$NOVO' '$APP_DEST' && chown -R '$DONO' '$APP_DEST'"
log "pedindo a senha de administrador (âncora + troca do app)"
osascript -e 'tell application "TuttiDash" to quit' >/dev/null 2>&1 || true
/usr/bin/osascript -e "do shell script \"$CMD\" with administrator privileges"
log "app trocado: $VERSAO (anterior na Lixeira: $(basename "$LIXO"))"

# 6. reabre
open "$APP_DEST"
log "app aberto"
