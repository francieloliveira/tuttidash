#!/usr/bin/env bash
# Gera build/TuttiDash.app (release). Assina com SIGN_IDENTITY (variável de ambiente, ou a linha
# SIGN_IDENTITY=... em Privado/assinatura.env, fora do repositório); sem identidade, ad-hoc.
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
# O lane-mcp.json versionado é neutro: o caminho do servidor de docs é desta máquina e
# não vai para o git (FRA-614). Quem tem MCP põe lane-mcp.local.json, fora do git.
MCP="$HERE/Resources/lane-mcp.json"
if [[ -f "$HERE/Resources/lane-mcp.local.json" ]]; then
  MCP="$HERE/Resources/lane-mcp.local.json"
  echo "    MCP: Resources/lane-mcp.local.json"
else
  echo "    MCP: template neutro (o bundle fica sem servidor MCP)"
fi
install -m 600 "$MCP" "$APP/Contents/Resources/lane-mcp.json"

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
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
  --identifier app.tuttidash.agente "$APP/Contents/MacOS/tuttidash-agente"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
  --entitlements Resources/TuttiDash.entitlements "$APP"
codesign --verify --verbose=1 "$APP"

echo "Pronto: $(pwd)/$APP"
echo "Abrir:  open \"$(pwd)/$APP\""
