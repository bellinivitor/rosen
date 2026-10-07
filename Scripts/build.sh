#!/usr/bin/env bash
# Compila o Rosen com swiftc (sem depender do SwiftPM).
#   Scripts/build.sh            → build/Rosen.app (release)
#   Scripts/build.sh debug      → build/Rosen.app (debug)
#   Scripts/build.sh test       → roda os testes do RosenCore
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-release}"
BUILD="$ROOT/build"
OBJ="$BUILD/obj"
VERSION="$(cat "$ROOT/VERSION")"
MIN_MACOS="14.0"
# SDK: o do macOS 27 nas Command Line Tools não traz o plugin de macros do SwiftUI;
# por isso preferimos o 26.x quando ele existe. Sobrescreva com SDK=/caminho.
if [[ -z "${SDK:-}" ]]; then
  CLT_SDKS="$(xcode-select -p)/SDKs"
  if [[ -d "$CLT_SDKS/MacOSX26.sdk" && ! -d "$(xcode-select -p)/../SharedFrameworks" ]]; then
    SDK="$CLT_SDKS/MacOSX26.sdk"
  else
    SDK="$(xcrun --show-sdk-path --sdk macosx)"
  fi
fi
ARCHS="${ARCHS:-$(uname -m)}"

mkdir -p "$OBJ"

if [[ "$MODE" == "debug" || "$MODE" == "test" || "$MODE" == "snapshot" ]]; then
  OPT=(-Onone -g -DDEBUG)
else
  OPT=(-O -whole-module-optimization)
fi

build_arch() {
  local arch="$1"
  local target="$arch-apple-macosx$MIN_MACOS"
  local out="$OBJ/$arch"
  mkdir -p "$out"

  echo "› RosenCore ($arch)"
  xcrun swiftc "${OPT[@]}" -sdk "$SDK" -target "$target" -swift-version 5 \
    -parse-as-library -enable-testing \
    -module-name RosenCore -emit-module -emit-module-path "$out/RosenCore.swiftmodule" \
    -emit-library -static -o "$out/libRosenCore.a" \
    "$ROOT"/Sources/RosenCore/*.swift

  if [[ "$MODE" == "test" ]]; then
    local fw="$(xcode-select -p)/Library/Developer/Frameworks"
    local runner="$out/main.swift"
    echo 'import Testing
@main struct Runner { static func main() async { await Testing.__swiftPMEntryPoint() as Never } }' > "$runner"
    echo "› Testes ($arch)"
    xcrun swiftc "${OPT[@]}" -sdk "$SDK" -target "$target" -swift-version 5 \
      -parse-as-library -module-name RosenCoreTests \
      -I "$out" -L "$out" -lRosenCore -F "$fw" -I "$fw" -L "$fw" \
      -Xlinker -rpath -Xlinker "$fw" -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib" -framework Testing \
      -plugin-path "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" \
      "$ROOT"/Tests/RosenCoreTests/*.swift "$runner" -o "$out/RosenCoreTests"
    "$out/RosenCoreTests"
    return
  fi

  if [[ "$MODE" == "snapshot" ]]; then
    echo "› Snapshots ($arch)"
    xcrun swiftc "${OPT[@]}" -sdk "$SDK" -target "$target" -swift-version 5 \
      -parse-as-library -module-name RosenSnapshot -DSNAPSHOT \
      -I "$out" -L "$out" -lRosenCore \
      "$ROOT"/Sources/Rosen/*.swift "$ROOT"/Sources/Rosen/Views/*.swift "$ROOT"/Scripts/Snapshot/main.swift \
      -o "$out/RosenSnapshot"
    "$out/RosenSnapshot" "$BUILD/snapshots"
    return
  fi

  echo "› Rosen ($arch)"
  xcrun swiftc "${OPT[@]}" -sdk "$SDK" -target "$target" -swift-version 5 \
    -parse-as-library -module-name Rosen \
    -I "$out" -L "$out" -lRosenCore \
    "$ROOT"/Sources/Rosen/*.swift "$ROOT"/Sources/Rosen/Views/*.swift \
    -o "$out/Rosen"
}

BINARIES=()
for arch in $ARCHS; do
  build_arch "$arch"
  BINARIES+=("$OBJ/$arch/Rosen")
done
[[ "$MODE" == "test" || "$MODE" == "snapshot" ]] && exit 0

APP="$BUILD/Rosen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Rosen"

# Versão de exibição pode ter sufixo (0.1.0-beta); o número de build precisa ser só números (0.1.0).
BUILD_NUMBER="${VERSION%%-*}"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

if [[ ! -f "$BUILD/AppIcon.icns" || "$ROOT/Scripts/make-icon.swift" -nt "$BUILD/AppIcon.icns" ]]; then
  echo "› Ícone"
  xcrun swift "$ROOT/Scripts/make-icon.swift" "$BUILD/AppIcon.iconset" >/dev/null
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Assinatura: use SIGN_IDENTITY="Developer ID Application: ..." para distribuição; padrão é ad-hoc.
codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP" >/dev/null
echo "✓ $APP"
