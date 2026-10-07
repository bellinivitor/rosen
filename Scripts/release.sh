#!/usr/bin/env bash
# Gera o zip universal e atualiza o Cask com versão + sha256.
#   Scripts/release.sh            → usa a versão do arquivo VERSION
#   Scripts/release.sh 0.2.0      → grava a nova versão e gera
#
# Depois: commit + push e crie a release vX.Y.Z no GitHub anexando dist/Rosen-X.Y.Z.zip
# (este repositório também é o tap do Homebrew, então o Cask vai junto).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -ge 1 ]] && echo "$1" > "$ROOT/VERSION"
VERSION="$(cat "$ROOT/VERSION")"

ARCHS="arm64 x86_64" "$ROOT/Scripts/build.sh" release

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/Rosen-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/Rosen.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

CASK="$ROOT/Casks/rosen.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' -E "s/^  sha256 .*/  sha256 \"$SHA\"/" "$CASK"

echo
echo "✓ $ZIP"
echo "  sha256 $SHA"
echo "  Cask atualizado: Casks/rosen.rb"
