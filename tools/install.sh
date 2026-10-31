#!/usr/bin/env bash
# Instala TODAS as ferramentas locais a partir deste checkout (E13: nada vive só na cópia local).
#   tools/install.sh            instala cfg, painel (com a coluna das lanes), janela das lanes, tema,
#                               seguidores de log com hora (carimbo, seguir-com-hora) e rodapé
#                               com barra de progresso (rodape.py),
#                               medir-estresse, lanepct-auto (+ build do lanepct),
#                               o catálogo de agentes (agents.d/ + catalogo.py),
#                               prompts do vigia e instalar.sh, e os launchd
#                               com.transcentia.bots.watch / .chave pelos lançadores com nome.
#                               FRA-613: dispatcher, vigia, chave, run_lane, lane_view,
#                               lanes_window e lanes_ctl NÃO são copiados para ~/.transcentia.
#                               O launchd executa a cópia do TuttiDash.app assinado.
#                               FRA-615: catalogo, projetos, privacidade, linear_ids, fila
#                               e config também não. O bundle traz controle/gasto_lanes.
#                               gasto_privado.py continua opcional (build pessoal).
#   tools/install.sh --sem-launchd   só copia arquivos
# Espelho: não mexe no PAUSE (quem decide é a chave bots-chave); nunca inicia o vigia em paralelo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$HOME/.transcentia/tools"; B="$HOME/.transcentia/bots"
LAUNCHERS="$HOME/Library/Application Support/AgentesLocais"
DOMAIN="gui/$(id -u)"
mkdir -p "$T" "$B/prompts" "$LAUNCHERS" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/TranscentIA"

aviso_legado() {
  if [ -e "$1" ]; then
    echo "AVISO: $1 ficou como legado inerte. O launchd executa a cópia do TuttiDash.app, não esta."
  fi
}

# Lançador com nome. O exec é o tuttidash-agente do bundle, nunca o script em ~/.transcentia.
lancador() { # nome label papel
  cat > "$LAUNCHERS/$1" <<EOF
#!/bin/zsh
# Lançador de $2 (gerado por tuttidash/tools/install.sh)
# Executa o tuttidash-agente do bundle assinado. Não usa ~/.transcentia.
papel=$3
candidatos=()
if [[ -n \${TUTTIDASH_AGENTE:-} && \${TUTTIDASH_AGENTE} != *".transcentia"* ]]; then
  candidatos+=("\$TUTTIDASH_AGENTE")
fi
candidatos+=(
  "/Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente"
  "\$HOME/Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente"
)
for agente in "\${candidatos[@]}"; do
  [[ "\$agente" == *".transcentia"* ]] && continue
  if [[ -x "\$agente" ]]; then
    exec "\$agente" "\$papel"
  fi
done
echo "tuttidash: tuttidash-agente não está no bundle assinado" >&2
exit 70
EOF
  chmod 755 "$LAUNCHERS/$1"
}

# O cfg acha o arquivo por gasto_lanes/config.py. A cópia fica ao lado do cfg
# instalado (no checkout ele usa ../gasto_lanes/config.py).
install -m 644 "$ROOT/gasto_lanes/config.py" "$T/config.py"
install -m 755 "$HERE/cfg" "$T/cfg"
"$T/cfg" migrate
for f in painel.command lanes.command colorir.sh carimbo.sh seguir-com-hora.sh seguir-lanes.sh \
         seguir-build.sh seguir-gestor.sh seguir-dispatcher.sh rodape.py status-lanes.sh acompanhar-testes.command medir-estresse.sh \
         lanepct-auto privacidade-modelos; do
  install -m 755 "$HERE/$f" "$T/$f"
done
install -m 644 "$HERE/script-controle.sh" "$T/script-controle.sh"
install -m 644 "$HERE/tema.tmux" "$T/tema.tmux"
aviso_legado "$T/bots-chave"

# lanepct: fonte versionada, binário compilado aqui (Swift do Xcode).
mkdir -p "$T/lane-pct"
rsync -a --delete --exclude .build "$HERE/lane-pct/" "$T/lane-pct/"
if command -v swift >/dev/null; then
  (cd "$T/lane-pct" && TUTTIDASH_APP="$ROOT/apps/notch-mac" swift build -c release --manifest-cache none -q) \
    || echo "AVISO: build do lanepct falhou; binário anterior mantido"
fi

aviso_legado "$B/watch.py"
install -m 755 "$ROOT/bots/instalar.sh" "$B/instalar.sh"
install -m 644 "$ROOT/bots/prompts/"*.md "$B/prompts/"

# Catálogo e projetos: o dispatcher, o vigia e a ListaModelos leem a cópia em
# TuttiDash.app/Contents/Resources/controle/gasto_lanes (FRA-615). A pasta
# gravável não recebe esses módulos. config.py ao lado do cfg continua: o
# binário `cfg` não é o import do plano de controle.
for mod in catalogo fila projetos privacidade linear_ids config gasto_privado; do
  aviso_legado "$B/$mod.py"
done
LANES_DIR="$HOME/.transcentia/lanes"
if [ -d "$LANES_DIR" ]; then
  for mod in catalogo fila projetos privacidade linear_ids config gasto_privado; do
    aviso_legado "$LANES_DIR/$mod.py"
  done
  for f in dispatcher.py lanes_window.py lanes_ctl.py run_lane.sh lane_view.py; do
    aviso_legado "$LANES_DIR/$f"
  done
  for f in "$ROOT"/lanes/lane-prompt.md "$ROOT"/lanes/lane-prompt-*.md; do
    [ -f "$f" ] || continue
    install -m 644 "$f" "$LANES_DIR/$(basename "$f")"
  done
fi
mkdir -p "$HOME/.transcentia/agents.d"
rsync -a --delete "$ROOT/agents.d/" "$HOME/.transcentia/agents.d/"

# FRA-523: lançadores com nome antigo saem. Os novos apontam para o bundle.
for velho in "TranscentIA Bots (vigia)" "TranscentIA Chave Bots"; do rm -f "$LAUNCHERS/$velho"; done
lancador "TuttiDash Vigia" com.transcentia.bots.watch vigia
lancador "TuttiDash Chave" com.transcentia.bots.chave chave
lancador "TuttiDash Dispatcher" com.transcentia.lanes.dispatcher dispatcher

# FRA-616: hash fora do alcance do agente. Não copia o manifesto para ~/.transcentia.
if [[ "${TUTTIDASH_SEM_ANCORA:-}" == "1" ]]; then
  echo "AVISO: âncora de integridade não instalada (TUTTIDASH_SEM_ANCORA)."
else
  python3 "$ROOT/tools/integridade-controle.py" instalar-repo "$ROOT"
fi

[ "${1:-}" = "--sem-launchd" ] && { echo "arquivos instalados (sem launchd)"; exit 0; }

# Quando o agente já roda de dentro do TuttiDash.app (SMAppService, Labels app.tuttidash.agente.*),
# não instala plist solto. Label antigo -> novo: bots.watch=vigia, bots.chave=chave, lanes.dispatcher=dispatcher.
novo_label(){ case "$1" in *bots.watch) echo app.tuttidash.agente.vigia;; *bots.chave) echo app.tuttidash.agente.chave;;
  *lanes.dispatcher) echo app.tuttidash.agente.dispatcher;; esac; }
no_app(){ launchctl print "$DOMAIN/$(novo_label "$1")" >/dev/null 2>&1; }
for k in watch chave; do
  L="com.transcentia.bots.$k"; P="$HOME/Library/LaunchAgents/$L.plist"
  if no_app "$L"; then echo "$L: agente do TuttiDash.app (sem plist solto)"; continue; fi
  sed "s#__HOME__#$HOME#g" "$ROOT/bots/launchd/$L.plist" > "$P"
  plutil -lint "$P" >/dev/null
  launchctl bootout "$DOMAIN/$L" 2>/dev/null || true
  for t in 1 2 3 4 5; do
    launchctl bootstrap "$DOMAIN" "$P" 2>/dev/null && break
    [ "$t" = 5 ] && { echo "ERRO: bootstrap de $L falhou 5 vezes"; exit 1; }
    sleep 3
  done
done
# FRA-523: o dispatcher é agendado pelo app; aqui só migra o lançador de nome antigo (mesmo Label).
LD="com.transcentia.lanes.dispatcher"; PD="$HOME/Library/LaunchAgents/$LD.plist"
VELHO="$LAUNCHERS/TranscentIA Lanes (dispatcher)"; NOVO_L="$LAUNCHERS/TuttiDash Dispatcher"
if ! no_app "$LD" && [ -f "$PD" ] && grep -q "TranscentIA Lanes (dispatcher)" "$PD"; then
  [ -f "$VELHO" ] && [ ! -f "$NOVO_L" ] && mv "$VELHO" "$NOVO_L"
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $NOVO_L" "$PD"
  /usr/libexec/PlistBuddy -c "Delete :AssociatedBundleIdentifiers" "$PD" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :AssociatedBundleIdentifiers array" -c "Add :AssociatedBundleIdentifiers:0 string app.tuttidash.mac" "$PD"
  plutil -lint "$PD" >/dev/null
  launchctl bootout "$DOMAIN/$LD" 2>/dev/null || true
  for t in 1 2 3 4 5; do
    launchctl bootstrap "$DOMAIN" "$PD" 2>/dev/null && break
    [ "$t" = 5 ] && { echo "ERRO: bootstrap de $LD falhou 5 vezes"; exit 1; }
    sleep 3
  done
  rm -f "$VELHO"
fi
echo "instalado: ferramentas em $T, vigia em $B (PAUSE $( [ -f "$B/PAUSE" ] && echo presente: vigia parado, Grok Bot ativo || echo ausente: vigia ativo))"
