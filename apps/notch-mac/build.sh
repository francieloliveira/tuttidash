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
swift build -c release --product "$EXEC"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> empacotando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarTemplate.png Resources/MenuBarTemplate@2x.png "$APP/Contents/Resources/"
echo "==> agentes (SMAppService): Contents/Library/LaunchAgents + lançadores"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/LaunchAgents/*.plist "$APP/Contents/Library/LaunchAgents/"
xcrun clang -O2 -Wall -mmacosx-version-min=14.0 -o "$APP/Contents/MacOS/tuttidash-agente" Agente/agente.c
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> manifests de agente (agents.d/)"
AGENTS_D="$(cd "$HERE/../.." && pwd)/agents.d"
if [[ -d "$AGENTS_D" ]]; then
  mkdir -p "$APP/Contents/Resources/agents.d"
  cp "$AGENTS_D"/*.json "$APP/Contents/Resources/agents.d/"
else
  echo "AVISO: agents.d/ não encontrado em $AGENTS_D (o app cai no registry embutido)"
fi

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
