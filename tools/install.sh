#!/usr/bin/env bash
# Instala TODAS as ferramentas locais a partir deste checkout (E13: nada vive só na cópia local).
#   tools/install.sh            instala cfg, painel (com a coluna das lanes), janela das lanes, tema,
#                               seguidores de log com hora (carimbo, seguir-com-hora) e rodapé
#                               com barra de progresso (rodape.py),
#                               medir-estresse, lanepct-auto (+ build do lanepct),
#                               o catálogo de agentes (agents.d/ + catalogo.py),
#                               prompts do vigia e instalar.sh, e os launchd
#                               com.transcentia.bots.watch / .chave pelos lançadores com nome.
#                               FRA-613/617: dispatcher, vigia, chave, run_lane, lane_view,
#                               lanes_window e lanes_ctl NÃO são copiados para ~/.transcentia.
#                               Cópias antigas são aposentadas. O launchd executa o bundle.
#                               Se a âncora não conferir, a migração volta ao estado anterior
#                               e não religa chave que estava desligada.
#                               FRA-615: catalogo, projetos, privacidade, linear_ids, fila
#                               e config também não. O bundle traz controle/gasto_lanes.
#                               gasto_privado.py continua opcional (build pessoal).
#   tools/install.sh --sem-launchd   copia arquivos e aposenta o legado, sem launchctl
# Espelho: não mexe no PAUSE (quem decide é a chave bots-chave); nunca inicia o vigia em paralelo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$HOME/.transcentia/tools"; B="$HOME/.transcentia/bots"
mkdir -p "$T" "$B/prompts" "$HOME/Library/Application Support/AgentesLocais" \
  "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/TranscentIA" "$HOME/Library/Logs/TuttiDash"

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

# lanepct: fonte versionada, binário compilado aqui (Swift do Xcode).
mkdir -p "$T/lane-pct"
rsync -a --delete --exclude .build "$HERE/lane-pct/" "$T/lane-pct/"
if command -v swift >/dev/null; then
  (cd "$T/lane-pct" && TUTTIDASH_APP="$ROOT/apps/notch-mac" swift build -c release --manifest-cache none -q) \
    || echo "AVISO: build do lanepct falhou; binário anterior mantido"
fi

install -m 644 "$ROOT/bots/caixa_leitura.py" "$B/caixa_leitura.py"
install -m 755 "$ROOT/bots/git-leitura" "$B/git-leitura"
install -m 755 "$ROOT/bots/instalar.sh" "$B/instalar.sh"
install -m 644 "$ROOT/bots/prompts/"*.md "$B/prompts/"

# Catálogo e projetos: o dispatcher, o vigia e a ListaModelos leem a cópia em
# TuttiDash.app/Contents/Resources/controle/gasto_lanes (FRA-615). A pasta
# gravável não recebe esses módulos. config.py ao lado do cfg continua: o
# binário `cfg` não é o import do plano de controle.
LANES_DIR="$HOME/.transcentia/lanes"
if [ -d "$LANES_DIR" ]; then
  for f in "$ROOT"/lanes/lane-prompt.md "$ROOT"/lanes/lane-prompt-*.md; do
    [ -f "$f" ] || continue
    install -m 644 "$f" "$LANES_DIR/$(basename "$f")"
  done
fi
# Espelho antigo. A execução (app, dispatcher, vigia) não lê esta pasta (FRA-614):
# o manifesto que vale é o do bundle assinado. O rsync não é a fonte.
mkdir -p "$HOME/.transcentia/agents.d"
rsync -a --delete "$ROOT/agents.d/" "$HOME/.transcentia/agents.d/"

# FRA-616: hash fora do alcance do agente. Não copia o manifesto para ~/.transcentia.
if [[ "${TUTTIDASH_SEM_ANCORA:-}" == "1" ]]; then
  echo "AVISO: âncora de integridade não instalada (TUTTIDASH_SEM_ANCORA)."
else
  python3 "$ROOT/tools/integridade-controle.py" instalar-repo "$ROOT"
fi

# FRA-617: aposenta as cópias antigas e aponta o launchd para o bundle.
# --sem-launchd ainda aposenta e grava os plists; não chama launchctl.
# Âncora divergente restaura o estado anterior e sai com erro.
if [ "${1:-}" = "--sem-launchd" ]; then
  python3 "$ROOT/tools/migrar-controle.py" aplicar --sem-launchd
else
  python3 "$ROOT/tools/migrar-controle.py" aplicar
fi
echo "instalado: ferramentas em $T, vigia em $B (PAUSE $( [ -f "$B/PAUSE" ] && echo presente: vigia parado, Grok Bot ativo || echo ausente: vigia ativo))"
