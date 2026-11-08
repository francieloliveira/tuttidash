#!/usr/bin/env bash
# Renova o provisioning profile de macOS do TuttiDash (app.tuttidash.mac) com o login do Xcode.
# O profile libera keychain-access-groups (FRA-607). Conta Apple gratuita: vence em 7 dias, e
# com ele vencido o macOS não deixa o app abrir.
# Uso: tools/renovar-perfil.sh              gera e grava apps/notch-mac/.local/TuttiDash.provisionprofile
#      tools/renovar-perfil.sh --instalar   também roda o build.sh e troca /Applications/TuttiDash.app
# Precisa: Xcode com a conta da equipe logada (Settings › Accounts) e xcodegen (brew install xcodegen).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_DIR="$ROOT/apps/notch-mac"
DESTINO="$APP_DIR/.local/TuttiDash.provisionprofile"
EQUIPE="3QA76CY27W"
ID="app.tuttidash.mac"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

INSTALAR=0
case "${1:-}" in
  "") ;;
  --instalar) INSTALAR=1 ;;
  *) echo "uso: $0 [--instalar]" >&2; exit 64 ;;
esac
command -v xcodegen >/dev/null || { echo "ERRO: xcodegen ausente (brew install xcodegen)" >&2; exit 69; }

# Projeto descartável com o mesmo bundle id e entitlements: o Xcode só cria o profile
# quando compila um projeto dele com Keychain Sharing e assinatura automática.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/td-perfil.XXXXXX")"
APP_TMP="$TMP/dd/Build/Products/Debug/PerfilTuttiDash.app"
limpar() {
  # O app temporário tem o bundle id do TuttiDash: sai do LaunchServices para o `open` não achá-lo.
  [ -d "$APP_TMP" ] && "$LSREGISTER" -u "$APP_TMP" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap limpar EXIT

mkdir -p "$TMP/Fonte"
printf 'print("perfil")\n' > "$TMP/Fonte/main.swift"
cp "$APP_DIR/Resources/TuttiDash.entitlements" "$TMP/Fonte/TuttiDash.entitlements"
cat > "$TMP/project.yml" <<EOF
name: PerfilTuttiDash
options:
  deploymentTarget:
    macOS: "14.0"
targets:
  PerfilTuttiDash:
    type: application
    platform: macOS
    sources: [Fonte]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $ID
        PRODUCT_NAME: PerfilTuttiDash
        DEVELOPMENT_TEAM: $EQUIPE
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_IDENTITY: "Apple Development"
        CODE_SIGN_ENTITLEMENTS: Fonte/TuttiDash.entitlements
        GENERATE_INFOPLIST_FILE: YES
        ENABLE_HARDENED_RUNTIME: YES
        SWIFT_VERSION: "5.0"
EOF
(cd "$TMP" && xcodegen generate --quiet)

echo "==> xcodebuild com o login do Xcode (registra este Mac e gera o profile)"
# O destino macOS é o que faz o xcodebuild registrar este Mac na equipe.
if ! (cd "$TMP" && xcodebuild -project PerfilTuttiDash.xcodeproj -scheme PerfilTuttiDash \
        -destination "platform=macOS,arch=$(uname -m)" -configuration Debug \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        -derivedDataPath "$TMP/dd" build > "$TMP/xcodebuild.log" 2>&1); then
  grep -E "error:" "$TMP/xcodebuild.log" | head -5 >&2 || tail -15 "$TMP/xcodebuild.log" >&2
  echo "ERRO: o Xcode não gerou o profile. Confira a conta em Xcode › Settings › Accounts." >&2
  exit 1
fi

PERFIL="$APP_TMP/Contents/embedded.provisionprofile"
[ -f "$PERFIL" ] || { echo "ERRO: o build não embutiu o profile" >&2; exit 1; }
DADOS="$(security cms -D -i "$PERFIL")"
campo() { printf '%s' "$DADOS" | plutil -extract "$1" raw - 2>/dev/null || true; }
if [ "$(campo Platform.0)" != "OSX" ] || [ "$(campo 'Entitlements.com\.apple\.application-identifier')" != "$EQUIPE.$ID" ]; then
  echo "ERRO: o profile gerado não é de macOS para $EQUIPE.$ID" >&2
  exit 1
fi
install -m 600 "$PERFIL" "$DESTINO"
echo "==> profile gravado em $DESTINO"
echo "    $(campo Name) · vence em $(campo ExpirationDate)"

[ "$INSTALAR" = 1 ] || { echo "Para usar: cd apps/notch-mac && ./build.sh (ou rode de novo com --instalar)"; exit 0; }

(cd "$APP_DIR" && ./build.sh)
echo "==> trocando /Applications/TuttiDash.app (o antigo vai para a Lixeira)"
osascript -e 'tell application "TuttiDash" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -f "TuttiDash.app/Contents/MacOS/TuttiDash$" >/dev/null || break; sleep 1; done
if [ -d /Applications/TuttiDash.app ]; then
  mv /Applications/TuttiDash.app "$HOME/.Trash/TuttiDash-anterior-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$APP_DIR/build/TuttiDash.app" /Applications/TuttiDash.app
open /Applications/TuttiDash.app
echo "==> pronto: TuttiDash aberto com o profile novo"
