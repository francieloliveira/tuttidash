#!/usr/bin/env bash
# Instala TODAS as ferramentas locais a partir deste checkout (E13: nada vive só na cópia local).
#   tools/install.sh            instala cfg, painel (com a coluna das lanes), janela das lanes, tema,
#                               seguidores de log com hora (carimbo, seguir-com-hora) e rodapé
#                               com barra de progresso (rodape.py),
#                               medir-estresse, bots-chave, lanepct-auto (+ build do lanepct),
#                               o catálogo de agentes (agents.d/ + catalogo.py),
#                               a pasta das lanes (~/.transcentia/lanes, criada mesmo
#                               numa instalação limpa: dispatcher, run_lane.sh, lane_view.py,
#                               prompts, claude-settings.json e lane-mcp.json),
#                               vigia dos bots (watch.py, prompts, instalar.sh) e os launchd
#                               com.transcentia.bots.watch / .chave pelos lançadores com nome.
#   tools/install.sh --sem-launchd   só copia arquivos
#   tools/install.sh --force         substitui claude-settings.json e lane-mcp.json
#                                    já customizados (sem --force eles ficam)
# Espelho: não mexe no PAUSE (quem decide é a chave bots-chave) nem no arquivo enabled
# das lanes; nunca inicia o vigia em paralelo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SEM_LAUNCHD=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --sem-launchd) SEM_LAUNCHD=1 ;;
    --force) FORCE=1 ;;
  esac
done
# FRA-591: sem runner, view ou template a instalação para aqui. A mensagem lista
# o que falta e nada é copiado para ~/.transcentia/lanes.
faltando=()
[ -f "$ROOT/lanes/dispatcher.py" ] || faltando+=("lanes/dispatcher.py")
[ -f "$ROOT/lanes/run_lane.sh" ] || faltando+=("lanes/run_lane.sh")
[ -f "$ROOT/lanes/lane_view.py" ] || faltando+=("lanes/lane_view.py")
[ -f "$ROOT/lanes/templates/claude-settings.json" ] || faltando+=("lanes/templates/claude-settings.json")
[ -f "$ROOT/lanes/templates/lane-mcp.json" ] || faltando+=("lanes/templates/lane-mcp.json")
if [ "${#faltando[@]}" -gt 0 ]; then
  echo "ERRO: instalação das lanes incompleta no repositório. Faltam:" >&2
  for f in "${faltando[@]}"; do echo "  - $f" >&2; done
  exit 1
fi
T="$HOME/.transcentia/tools"; B="$HOME/.transcentia/bots"
LAUNCHERS="$HOME/Library/Application Support/AgentesLocais"
DOMAIN="gui/$(id -u)"
mkdir -p "$T" "$B/prompts" "$LAUNCHERS" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/TranscentIA"

install -m 755 "$HERE/cfg" "$T/cfg"
"$T/cfg" migrate
for f in painel.command lanes.command colorir.sh carimbo.sh seguir-com-hora.sh seguir-lanes.sh \
         seguir-build.sh seguir-gestor.sh seguir-dispatcher.sh rodape.py status-lanes.sh acompanhar-testes.command medir-estresse.sh \
         bots-chave lanepct-auto privacidade-modelos; do
  install -m 755 "$HERE/$f" "$T/$f"
done
install -m 644 "$HERE/tema.tmux" "$T/tema.tmux"

# lanepct: fonte versionada, binário compilado aqui (Swift do Xcode).
mkdir -p "$T/lane-pct"
rsync -a --delete --exclude .build "$HERE/lane-pct/" "$T/lane-pct/"
if command -v swift >/dev/null; then
  (cd "$T/lane-pct" && TUTTIDASH_APP="$ROOT/apps/notch-mac" swift build -c release --manifest-cache none -q) \
    || echo "AVISO: build do lanepct falhou; binário anterior mantido"
fi

install -m 700 "$ROOT/bots/watch.py" "$B/watch.py"
install -m 755 "$ROOT/bots/instalar.sh" "$B/instalar.sh"
install -m 644 "$ROOT/bots/prompts/"*.md "$B/prompts/"

# Catálogo de agentes e de projetos: fonte única dos CLIs/lanes e da lista de
# projetos que o dispatcher enxerga (Swift, dispatcher e vigia leem o mesmo).
# Os dois módulos são stdlib puro e precisam estar ao lado de cada script que roda
# isolado (o dispatcher e o vigia não enxergam o pacote).
for mod in catalogo fila projetos privacidade linear_ids; do
  install -m 644 "$ROOT/gasto_lanes/$mod.py" "$B/$mod.py"
done
# Build pessoal (FRA-565): módulo opcional fora do repositório aberto, ao lado do catálogo.
PRIVADO_PY="$ROOT/apps/notch-mac/Privado/python/gasto_privado.py"
[ -f "$PRIVADO_PY" ] && install -m 644 "$PRIVADO_PY" "$B/gasto_privado.py"
# Backup e diff quando a cópia instalada existe e o conteúdo difere; depois instala.
copiar_com_backup() { # mode src dest
  local mode="$1" src="$2" dest="$3"
  if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
    cp -p "$dest" "$dest.bak"
    echo "backup: $dest → $dest.bak"
    diff -u "$dest" "$src" || true
  fi
  install -m "$mode" "$src" "$dest"
}
# 0600. Customização fica no lugar, a menos que --force.
copiar_template() { # src dest
  local src="$1" dest="$2"
  if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
    if [ "$FORCE" -ne 1 ]; then
      echo "mantido: $dest (customização; use --force para substituir pelo template)"
      return 0
    fi
    cp -p "$dest" "$dest.bak"
    echo "backup: $dest → $dest.bak"
    diff -u "$dest" "$src" || true
  fi
  install -m 600 "$src" "$dest"
}
# FRA-591: instalação limpa também cria a pasta. A fonte é o repositório.
LANES_DIR="$HOME/.transcentia/lanes"
mkdir -p "$LANES_DIR"
for mod in catalogo fila projetos privacidade linear_ids; do
  install -m 644 "$ROOT/gasto_lanes/$mod.py" "$LANES_DIR/$mod.py"
done
[ -f "$PRIVADO_PY" ] && install -m 644 "$PRIVADO_PY" "$LANES_DIR/gasto_privado.py"
for f in dispatcher.py lanes_window.py lanes_ctl.py; do
  install -m 755 "$ROOT/lanes/$f" "$LANES_DIR/$f"
done
copiar_com_backup 755 "$ROOT/lanes/run_lane.sh" "$LANES_DIR/run_lane.sh"
copiar_com_backup 644 "$ROOT/lanes/lane_view.py" "$LANES_DIR/lane_view.py"
for f in "$ROOT"/lanes/lane-prompt.md "$ROOT"/lanes/lane-prompt-*.md; do
  [ -f "$f" ] || continue
  install -m 644 "$f" "$LANES_DIR/$(basename "$f")"
done
copiar_template "$ROOT/lanes/templates/claude-settings.json" "$LANES_DIR/claude-settings.json"
copiar_template "$ROOT/lanes/templates/lane-mcp.json" "$LANES_DIR/lane-mcp.json"
mkdir -p "$HOME/.transcentia/agents.d"
rsync -a --delete "$ROOT/agents.d/" "$HOME/.transcentia/agents.d/"

[ "$SEM_LAUNCHD" -eq 1 ] && { echo "arquivos instalados (sem launchd)"; exit 0; }

# Nunca registrar o launchd direto no python3 (aparece como "python3" em Itens de Início):
# cada agente tem um lançador com nome em ~/Library/Application Support/AgentesLocais/<Nome>.
lancador(){ # nome label alvo
  printf '#!/bin/zsh\n# Lançador de %s (gerado por tuttidash/tools/install.sh)\nexec /usr/bin/python3 %q "$@"\n' \
    "$2" "$3" > "$LAUNCHERS/$1"; chmod 755 "$LAUNCHERS/$1"; }
# FRA-523: lançadores com nome antigo saem (o app e este script geram os novos).
for velho in "TranscentIA Bots (vigia)" "TranscentIA Chave Bots"; do rm -f "$LAUNCHERS/$velho"; done
lancador "TuttiDash Vigia" com.transcentia.bots.watch "$B/watch.py"
lancador "TuttiDash Chave" com.transcentia.bots.chave "$T/bots-chave"
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
