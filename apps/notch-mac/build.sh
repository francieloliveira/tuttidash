#!/usr/bin/env bash
# Gera build/TuttiDash.app (release). Assina com SIGN_IDENTITY (variável de ambiente, ou a linha
# SIGN_IDENTITY=... em Privado/assinatura.env, fora do repositório). A identidade que o lançador
# aceita é Apple Development da equipe 3QA76CY27W (designated requirement, não o hash do CodeDirectory).
# Sem identidade, o build fica ad-hoc e o tuttidash-agente aborta na hora de executar.
# Uso: ./build.sh            compila e empacota
#      ./build.sh --testes   roda os testes antes de empacotar
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
APP_NAME="TuttiDash"
EXEC="TuttiDash"
OUT="build"
APP="$OUT/$APP_NAME.app"

if [[ "${1:-}" == "--testes" ]]; then
  echo "==> swift test"
  swift test
fi

echo "==> swift build -c release"
# Sem cache de manifesto: o Package.swift decide se Privado/GastoPrivado entra,
# e o cache antigo continuaria dizendo "sem privado" depois de restaurar a pasta.
swift build -c release --manifest-cache none --product "$EXEC"
BIN_DIR="$(swift build -c release --manifest-cache none --show-bin-path)"

echo "==> empacotando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Versão no topo do app (29/10): main-<sha> só para a main do GitHub sem mudança; o resto é alpha.
read -r CANAL VERSAO <<< "$("$HERE/../../tools/versao-build.sh" "$HERE")"
/usr/libexec/PlistBuddy -c "Add :TDCanal string ${CANAL:-alpha}" -c "Add :TDVersao string ${VERSAO:-dev}" "$APP/Contents/Info.plist"
echo "==> versão: $VERSAO ($CANAL)"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarTemplate.png Resources/MenuBarTemplate@2x.png "$APP/Contents/Resources/"
echo "==> agentes (SMAppService): Contents/Library/LaunchAgents + lançadores"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/LaunchAgents/*.plist "$APP/Contents/Library/LaunchAgents/"
xcrun clang -O2 -Wall -mmacosx-version-min=14.0 -o "$APP/Contents/MacOS/tuttidash-agente" Agente/agente.c
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> manifests de agente (agents.d/, 0600 no bundle)"
AGENTS_D="$(cd "$HERE/../.." && pwd)/agents.d"
if [[ ! -d "$AGENTS_D" ]]; then
  echo "ERRO: agents.d/ não encontrado em $AGENTS_D" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Resources/agents.d"
install -m 600 "$AGENTS_D"/*.json "$APP/Contents/Resources/agents.d/"

echo "==> settings e MCP (bundle, 0600; sem fixture de teste)"
if [[ ! -f "$HERE/Resources/claude-settings.json" || ! -f "$HERE/Resources/lane-mcp.json" ]]; then
  echo "ERRO: falta o template de produção Resources/claude-settings.json ou lane-mcp.json" >&2
  exit 1
fi
install -m 600 "$HERE/Resources/claude-settings.json" "$APP/Contents/Resources/claude-settings.json"
# O lane-mcp.json versionado não leva caminho de máquina e é o único que entra
# no bundle. Um override local apontaria para um script fora do bundle, gravável
# pelo usuário (FRA-614). O comando, quando existir, fica em Contents/Resources.
install -m 600 "$HERE/Resources/lane-mcp.json" "$APP/Contents/Resources/lane-mcp.json"

echo "==> proxy do Linear (o app sobe o processo; a chave entra pelo stdin)"
# O processo só enxerga o bundle: estes módulos ficam ao lado do script.
cp "$HERE/../../gasto_lanes/proxy_linear.py" "$APP/Contents/Resources/proxy_linear.py"
cp "$HERE/../../gasto_lanes/linear_ids.py" "$APP/Contents/Resources/linear_ids.py"
cp "$HERE/../../gasto_lanes/config.py" "$APP/Contents/Resources/config.py"

echo "==> plano de controle (scripts no bundle assinado, FRA-613)"
REPO="$(cd "$HERE/../.." && pwd)"
CTRL="$APP/Contents/Resources/controle"
mkdir -p "$CTRL/lanes" "$CTRL/bots" "$CTRL/tools"
install -m 755 "$REPO/lanes/dispatcher.py" "$CTRL/lanes/dispatcher.py"
install -m 644 "$REPO/lanes/permissao.py" "$CTRL/lanes/permissao.py"
install -m 755 "$REPO/lanes/acp_runner.py" "$CTRL/lanes/acp_runner.py"
install -m 755 "$REPO/lanes/bancada.py" "$CTRL/lanes/bancada.py"
install -m 755 "$REPO/lanes/lane_view.py" "$CTRL/lanes/lane_view.py"
install -m 755 "$REPO/lanes/lanes_window.py" "$CTRL/lanes/lanes_window.py"
install -m 755 "$REPO/lanes/lanes_ctl.py" "$CTRL/lanes/lanes_ctl.py"
install -m 755 "$REPO/lanes/run_lane.sh" "$CTRL/lanes/run_lane.sh"
install -m 755 "$REPO/bots/watch.py" "$CTRL/bots/watch.py"
install -m 644 "$REPO/bots/caixa_leitura.py" "$CTRL/bots/caixa_leitura.py"
install -m 755 "$REPO/bots/git-leitura" "$CTRL/bots/git-leitura"
install -m 755 "$REPO/tools/bots-chave" "$CTRL/tools/bots-chave"
install -m 755 "$REPO/tools/instalar-prova-remota" "$CTRL/tools/instalar-prova-remota"
mkdir -p "$CTRL/tools/prova-remota-linux"
install -m 644 "$REPO/tools/prova-remota-linux/prova-remota.yml" "$CTRL/tools/prova-remota-linux/prova-remota.yml"
install -m 755 "$REPO/tools/prova-remota-linux/prova-remota.sh" "$CTRL/tools/prova-remota-linux/prova-remota.sh"
install -m 644 "$REPO/tools/prova-remota-linux/prova_remota.py" "$CTRL/tools/prova-remota-linux/prova_remota.py"
install -m 755 "$REPO/tools/lanes.command" "$CTRL/tools/lanes.command"
install -m 644 "$REPO/tools/script-controle.sh" "$CTRL/tools/script-controle.sh"

echo "==> módulos Python (controle/gasto_lanes, FRA-615)"
# Uma cópia só: dispatcher, vigia, janela e ListaModelos leem esta pasta.
# gasto_privado.py é do build pessoal; sem o arquivo a instalação pública segue.
mkdir -p "$CTRL/gasto_lanes"
for mod in catalogo.py projetos.py privacidade.py linear_ids.py fila.py config.py proxy_linear.py revisao_ia.py acp.py politica_acp.py; do
  install -m 644 "$REPO/gasto_lanes/$mod" "$CTRL/gasto_lanes/$mod"
done
PRIVADO_PY="$REPO/apps/notch-mac/Privado/python/gasto_privado.py"
if [[ -f "$PRIVADO_PY" ]]; then
  install -m 644 "$PRIVADO_PY" "$CTRL/gasto_lanes/gasto_privado.py"
fi

echo "==> âncora de integridade fora do bundle (FRA-616)"
# O manifesto não entra no .app. No Mac o arquivo é /private/var/db/tuttidash/controle.sha256
# (/var é symlink). Dono root. O bundle sozinho não é a fonte.
python3 "$REPO/tools/integridade-controle.py" gerar "$CTRL" "$OUT/controle.sha256"
python3 "$REPO/tools/integridade-controle.py" instalar "$OUT/controle.sha256"

echo "==> textos (Localizable.xcstrings -> en/pt-BR)"
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
# FRA-524: o app é só em pt-BR. Com o en.lproj no bundle, um Mac em inglês misturava os dois idiomas.
rm -rf "$APP/Contents/Resources/en.lproj"

if [[ -z "${SIGN_IDENTITY:-}" && -f "$HERE/Privado/assinatura.env" ]]; then
  SIGN_IDENTITY="$(sed -n 's/^SIGN_IDENTITY=//p' "$HERE/Privado/assinatura.env" | head -1)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" != "-" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> codesign com $SIGN_IDENTITY (hardened runtime)"
else
  echo "==> codesign ad-hoc (identidade $SIGN_IDENTITY não encontrada)"
  SIGN_IDENTITY="-"
fi
REQ='anchor apple generic and certificate leaf[subject.OU] = "3QA76CY27W" and certificate leaf[field.1.2.840.113635.100.6.1.12]'
# O designated requirement padrão cita o certificado pelo nome (subject.CN). O agente e o app
# (FRA-616) exigem o da equipe: assina com ele explícito. Ad-hoc não tem como atender.
DR_ARGS=()
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  DR_ARGS=(--requirements "=designated => $REQ")
fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
  ${DR_ARGS[@]+"${DR_ARGS[@]}"} --identifier app.tuttidash.agente "$APP/Contents/MacOS/tuttidash-agente"
# keychain-access-groups (FRA-607) é restrito: sem provisioning profile embutido o macOS
# mata o app no lançamento (spawn failed, POSIX 162). O profile fica fora do repositório,
# em Privado/TuttiDash.provisionprofile. Sem ele, assina sem entitlements: o Cofre já
# grava sem o access group quando o entitlement falta (errSecMissingEntitlement).
PERFIL="$HERE/Privado/TuttiDash.provisionprofile"
ENT_ARGS=()
if [[ "$SIGN_IDENTITY" != "-" && -f "$PERFIL" ]]; then
  PREFIXO="$(security cms -D -i "$PERFIL" | plutil -extract ApplicationIdentifierPrefix.0 raw -)"
  cp "$PERFIL" "$APP/Contents/embedded.provisionprofile"
  sed "s/\$(AppIdentifierPrefix)/$PREFIXO./" Resources/TuttiDash.entitlements > "$OUT/TuttiDash.entitlements"
  ENT_ARGS=(--entitlements "$OUT/TuttiDash.entitlements")
  echo "==> entitlements com o profile de $PREFIXO (keychain-access-groups)"
else
  echo "AVISO: sem Privado/TuttiDash.provisionprofile; assina sem keychain-access-groups (o Cofre grava sem o access group)"
fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
  ${DR_ARGS[@]+"${DR_ARGS[@]}"} ${ENT_ARGS[@]+"${ENT_ARGS[@]}"} "$APP"
codesign --verify --verbose=1 "$APP"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "AVISO: ad-hoc não atende o designated requirement da equipe 3QA76CY27W; o lançador aborta até assinar com Apple Development"
else
  # `-R=texto`: sem o `=` o codesign lê o argumento como caminho de arquivo.
  codesign --verify --strict -R "=$REQ" "$APP"
fi

echo "Pronto: $(pwd)/$APP"
echo "Abrir:  open \"$(pwd)/$APP\""
