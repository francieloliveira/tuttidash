#!/usr/bin/env bash
# Atualiza Resources/Localizable.xcstrings com os textos do código (mantém as traduções existentes).
# Depois, traduza as chaves novas (en) no Xcode ou editando o JSON.
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swift build --scratch-path "$T/b" -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$T/sd" >/dev/null
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$T"/sd/*.stringsdata
