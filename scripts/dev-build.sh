#!/bin/bash
# Local typecheck/build loop driving the Xcode toolchain directly, without xcodebuild.
#
# Why not xcodebuild: it insists on resolving the Sparkle package first, and github.com is
# unreachable from this machine, so the supported build always stops there. This script
# substitutes a stand-in module for Sparkle and otherwise compiles the real sources with the
# real SDK, which is enough to type-check the whole app and to link one that runs.
#
#   scripts/dev-build.sh typecheck   # parse and type-check only
#   scripts/dev-build.sh app         # link a runnable Compositor.app in .devbuild/
#
# Sparkle cannot be fetched on this machine (github.com is unreachable), so a stand-in module
# declaring the single Sparkle type the app names is compiled into .devbuild/stub.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-typecheck}"
BUILD="$ROOT/.devbuild"
STUB="$BUILD/stub"
CACHE="$BUILD/modulecache"

DEVELOPER="$(xcode-select -p 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer)"
SWIFTC="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
TARGET="arm64-apple-macos15.0"

if [ ! -x "$SWIFTC" ]; then
    echo "dev-build: no Xcode toolchain at $SWIFTC" >&2
    exit 1
fi

mkdir -p "$STUB" "$CACHE"

# A stand-in for the Sparkle package: SPUStandardUpdaterController, the only type the app uses.
cat > "$STUB/Sparkle.swift" <<'SWIFT'
import Foundation
public final class SPUStandardUpdaterController: NSObject {
    public init(startingUpdater: Bool, updaterDelegate: AnyObject?, userDriverDelegate: AnyObject?) {}
    public func startUpdater() {}
    public func checkForUpdates(_ sender: Any?) {}
}
SWIFT
"$SWIFTC" -emit-module -module-name Sparkle -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$CACHE" -emit-module-path "$STUB/Sparkle.swiftmodule" \
    "$STUB/Sparkle.swift"
"$SWIFTC" -c -parse-as-library -module-name Sparkle -sdk "$SDK" -target "$TARGET" \
    -module-cache-path "$CACHE" -o "$STUB/Sparkle.o" "$STUB/Sparkle.swift"

COMMON=(-sdk "$SDK" -target "$TARGET" -module-cache-path "$CACHE"
        -I "$STUB" -I "$ROOT/Compositor/Rendering"
        -import-objc-header "$ROOT/Compositor/Compositor-Bridging-Header.h")

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Compositor" -name '*.swift' | sort)

case "$MODE" in
    typecheck)
        "$SWIFTC" -typecheck "${COMMON[@]}" "${SOURCES[@]}"
        echo "typecheck: clean ($TARGET, SDK $(/usr/bin/plutil -extract Version raw "$SDK/SDKSettings.plist"))"
        ;;
    app)
        APP="$BUILD/Compositor.app"
        rm -rf "$APP"
        mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
        # The C pixel routines are compiled first: swiftc will not compile them itself.
        CLANG="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        OBJECTS=()
        for source in "$ROOT"/Compositor/Rendering/*.c; do
            object="$BUILD/objects/$(basename "${source%.c}").o"
            mkdir -p "$BUILD/objects"
            "$CLANG" -c "$source" -o "$object" -isysroot "$SDK" -target "$TARGET" \
                -I "$ROOT/Compositor/Rendering" -O2
            OBJECTS+=("$object")
        done
        "$SWIFTC" -o "$APP/Contents/MacOS/Compositor" "${COMMON[@]}" \
            "${SOURCES[@]}" "${OBJECTS[@]}" "$STUB/Sparkle.o" \
            -framework SwiftUI -framework AppKit -framework Metal -framework MetalKit \
            -framework Accelerate -framework CoreImage -framework Vision -framework CoreML \
            -framework UniformTypeIdentifiers -framework ImageIO -framework CoreGraphics \
            -framework QuartzCore -framework Security
        cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"
        # Xcode fills these in from the target's build settings (GENERATE_INFOPLIST_FILE = YES), so the
        # checked-in Info.plist has no identity of its own. Without them the bundle has no name, which
        # Apple events need, so "quit app \"Compositor\"" hangs.
        PLIST="$APP/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.wonderassembly.compositor" "$PLIST"
        /usr/libexec/PlistBuddy -c "Add :CFBundleName string Compositor" "$PLIST"
        /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Compositor" "$PLIST"
        /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
        /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.4.5" "$PLIST"
        /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$PLIST"
        codesign --force --sign - "$APP" 2>/dev/null || true
        echo "app: $APP"
        ;;
    *)
        echo "usage: $0 [typecheck|app]" >&2
        exit 2
        ;;
esac
