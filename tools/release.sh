#!/usr/bin/env bash
# Empacota o TuttiDash para distribuição. Não publica nada.
#
#   tools/release.sh [--sem-testes] [--local] [--notarizar PERFIL]
#
# - exige árvore git limpa (senão o .zip não corresponde ao commit);
# - roda as suítes Python/Swift (salvo --sem-testes);
# - chama apps/notch-mac/build.sh, que assina com Developer ID/Apple Development;
# - cria dist/TuttiDash-<versão>.zip e o SHA-256;
# - com --notarizar, usa `xcrun notarytool submit --keychain-profile PERFIL`.
#
# Sem certificado/notarização, o script para antes do upload e diz o que falta.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$ROOT/dist"
TESTES=1
PERFIL=""
MODO_LOCAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sem-testes) TESTES=0; shift ;;
    --local) MODO_LOCAL=1; shift ;;
    --notarizar) PERFIL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "release: argumento desconhecido: $1" >&2; exit 2 ;;
  esac
done
cd "$ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "release: árvore git suja; commit ou stash antes de empacotar" >&2
  git status --short | head -30 >&2
  exit 1
fi
if [[ "$TESTES" == "1" ]]; then
  echo "==> testes Python"
  python3 -m unittest discover -s tests -t .
  echo "==> testes Swift"
  (cd apps/notch-mac && swift test --disable-sandbox)
fi
echo "==> build do app"
(cd apps/notch-mac && ./build.sh)
APP="$ROOT/apps/notch-mac/build/TuttiDash.app"
[[ -d "$APP" ]] || { echo "release: app não gerado em $APP" >&2; exit 1; }
VERSAO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
mkdir -p "$DIST"
ZIP="$DIST/TuttiDash-$VERSAO-$BUILD.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"
echo "==> $ZIP"
cat "$ZIP.sha256"
if [[ -n "$PERFIL" ]]; then
  if [[ "$MODO_LOCAL" == "1" ]]; then
    echo "release: --local e --notarizar são exclusivos" >&2
    exit 2
  fi
  command -v xcrun >/dev/null || { echo "release: xcrun não encontrado" >&2; exit 1; }
  echo "==> notarização ($PERFIL)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PERFIL" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  echo "==> notarizado e grampeado"
else
  echo "release: modo local; o .zip está assinado, mas não notarizado." >&2
  echo "release: para distribuir a outros Macs, veja docs/produto/notarizacao.md." >&2
fi
