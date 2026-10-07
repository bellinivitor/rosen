#!/usr/bin/env bash
# Release do Rosen.
#   Scripts/release.sh 0.2.0     → grava a versão, gera dist/Rosen-0.2.0.zip (arm64 + x86_64)
#                                  e atualiza versão + sha256 em Casks/rosen.rb
#   Scripts/release.sh --tap     → copia Casks/rosen.rb para o tap (../homebrew-rosen),
#                                  faz commit e push. Não recompila nada.
#
# Ordem: release.sh X.Y.Z → commit/push → gh release create (com o zip) → release.sh --tap.
# O --tap vem por último porque o Cask aponta para o zip da release; antes disso o checksum falha.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK="$ROOT/Casks/rosen.rb"
TAP_DIR="${TAP_DIR:-$ROOT/../homebrew-rosen}"

publish_tap() {
  if [[ ! -d "$TAP_DIR/.git" ]]; then
    echo "Tap não encontrado em $TAP_DIR. Clone com:"
    echo "  gh repo clone bellinivitor/homebrew-rosen \"$TAP_DIR\""
    exit 1
  fi
  local version
  version="$(grep -E '^  version ' "$CASK" | sed -E 's/.*"(.*)".*/\1/')"
  {
    echo "# Cask do Rosen: brew install --cask bellinivitor/rosen/rosen"
    echo "# Gerado pelo Scripts/release.sh do repositório bellinivitor/rosen; não edite à mão."
    grep -v '^#' "$CASK"
  } > "$TAP_DIR/Casks/rosen.rb"
  git -C "$TAP_DIR" pull -q --rebase
  if git -C "$TAP_DIR" diff --quiet; then
    echo "Tap já está em $version."
  else
    git -C "$TAP_DIR" commit -qam "chore: rosen $version"
    git -C "$TAP_DIR" push -q
    echo "✓ Tap publicado: rosen $version"
  fi
}

if [[ "${1:-}" == "--tap" ]]; then
  publish_tap
  exit 0
fi

[[ $# -ge 1 ]] && echo "$1" > "$ROOT/VERSION"
VERSION="$(cat "$ROOT/VERSION")"

ARCHS="arm64 x86_64" "$ROOT/Scripts/build.sh" release

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/Rosen-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/Rosen.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' -E "s/^  sha256 .*/  sha256 \"$SHA\"/" "$CASK"

echo
echo "✓ $ZIP"
echo "  sha256 $SHA"
echo "  Casks/rosen.rb atualizado. Próximos passos:"
echo "    git commit -am \"chore: release $VERSION\" && git push"
echo "    gh release create v$VERSION \"$ZIP\""
echo "    Scripts/release.sh --tap"
