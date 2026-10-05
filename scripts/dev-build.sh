#!/bin/bash
# Local typecheck, build and package loop driving the Xcode toolchain directly, without xcodebuild.
#
# Why not xcodebuild: it insists on resolving the Sparkle package before it compiles anything, and
# github.com is unreachable from the machine this was written on, so the supported build always
# stops there. This substitutes a stand-in module for Sparkle and otherwise compiles the real
# sources with the real SDK.
#
#   scripts/dev-build.sh typecheck   # parse and type-check only
#   scripts/dev-build.sh app         # link .devbuild/Compositor.app
#   scripts/dev-build.sh package     # …and wrap it in .devbuild/Compositor-<version>-dev.dmg
#
# The `package` DMG is for installing on this or another Mac you control. It is **ad-hoc signed**,
# not signed with a Developer ID and not notarized, so Gatekeeper on a different Mac will refuse it
# on first open; right-click > Open, or `xattr -dr com.apple.quarantine`, gets past that. For a
# distribution build use scripts/release.sh, which needs a Developer ID certificate and
# create-dmg. See docs/local-development-m1-air.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-typecheck}"
BUILD="$ROOT/.devbuild"
STUB="$BUILD/stub"
CACHE="$BUILD/modulecache"
DIST="$BUILD/dist"

DEVELOPER="$(xcode-select -p 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer)"
SWIFTC="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
CLANG="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
SDK="$DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
TARGET="arm64-apple-macos15.0"

if [ ! -x "$SWIFTC" ]; then
    echo "dev-build: no Xcode toolchain at $SWIFTC" >&2
    exit 1
fi

# Version and build number, as Xcode would read them from the target's build settings.
PROJECT="$ROOT/Compositor.xcodeproj/project.pbxproj"
VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PROJECT" | sed 's/.*= \(.*\);/\1/')"
BUILD_NUMBER="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT" | sed 's/.*= \(.*\);/\1/')"

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

# The app's icon, from the asset catalog. Xcode compiles the catalog; iconutil does it here.
build_icon() {
    local iconset="$BUILD/AppIcon.iconset"
    local source="$ROOT/Compositor/Assets.xcassets/AppIcon.appiconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    cp "$source/app-icon-16.png"   "$iconset/icon_16x16.png"
    cp "$source/app-icon-32.png"   "$iconset/icon_16x16@2x.png"
    cp "$source/app-icon-32.png"   "$iconset/icon_32x32.png"
    cp "$source/app-icon-64.png"   "$iconset/icon_32x32@2x.png"
    cp "$source/app-icon-128.png"  "$iconset/icon_128x128.png"
    cp "$source/app-icon-256.png"  "$iconset/icon_128x128@2x.png"
    cp "$source/app-icon-256.png"  "$iconset/icon_256x256.png"
    cp "$source/app-icon-512.png"  "$iconset/icon_256x256@2x.png"
    cp "$source/app-icon-512.png"  "$iconset/icon_512x512.png"
    cp "$source/app-icon-1024.png" "$iconset/icon_512x512@2x.png"
    iconutil -c icns "$iconset" -o "$BUILD/AppIcon.icns"
}

# Links the app bundle at the path given. Everything the Xcode project would do to the bundle
# except compiling the asset catalog and writing the Info.plist keys, both done by hand.
build_app() {
    local APP="$1"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    # The C pixel routines are compiled first: swiftc will not compile them itself.
    local OBJECTS=()
    local source object
    mkdir -p "$BUILD/objects"
    for source in "$ROOT"/Compositor/Rendering/*.c; do
        object="$BUILD/objects/$(basename "${source%.c}").o"
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

    build_icon
    cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"

    # Xcode fills these in from the target's build settings (GENERATE_INFOPLIST_FILE = YES), so the
    # checked-in Info.plist has no identity of its own. Without them the bundle has no name, which
    # Apple events need, so "quit app \"Compositor\"" hangs.
    local PLIST="$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.wonderassembly.compositor" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string Compositor" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Compositor" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PLIST"

    # The checked-in Info.plist points at the real appcast and turns automatic checks on, because the
    # release build ships the real Sparkle. This build links a stand-in that does nothing, so turn
    # the checks off: otherwise the app would claim a feature it does not have, and "Check for
    # Updates…" would silently do nothing instead of failing.
    /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$PLIST" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$PLIST"
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PLIST" 2>/dev/null || true

    # Ad-hoc, which is the minimum a bundle needs to launch on Apple silicon. Deep, so the nested
    # frameworks and helpers are sealed too.
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1
    codesign --verify --strict "$APP" >/dev/null 2>&1 || {
        echo "dev-build: ad-hoc signature did not verify" >&2
        exit 1
    }
}

# The DMG, laid out like scripts/release.sh's: the app on the left, Applications on the right, over
# the same background. create-dmg is not used, so the Finder furniture (icon positions and the
# background picture) is not set — hdiutil alone cannot write a .DS_Store. Drag-to-install still
# works; only the window's appearance differs from a release build.
build_dmg() {
    local APP="$1" DMG="$2"
    local STAGE="$BUILD/dmg"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp "$ROOT/scripts/dmg/dmg-bg.jpg" "$STAGE/.background.jpg" 2>/dev/null || true

    # Checked here rather than by mounting the finished image: mounting would need a detach on every
    # exit path, and `set -e` would skip it precisely when something had already gone wrong.
    local count
    count="$(ls "$STAGE" | wc -l | tr -d ' ')"
    if [ "$count" != "2" ]; then
        echo "dev-build: expected the app and the Applications link, found: $(ls "$STAGE" | tr '\n' ' ')" >&2
        exit 1
    fi

    rm -f "$DMG"
    hdiutil create -quiet -volname "Compositor" -srcfolder "$STAGE" \
        -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
    hdiutil verify -quiet "$DMG"
}

case "$MODE" in
    typecheck)
        "$SWIFTC" -typecheck "${COMMON[@]}" "${SOURCES[@]}"
        echo "typecheck: clean ($TARGET, SDK $(/usr/bin/plutil -extract Version raw "$SDK/SDKSettings.plist"))"
        ;;
    app)
        build_app "$BUILD/Compositor.app"
        echo "app: $BUILD/Compositor.app"
        ;;
    package)
        mkdir -p "$DIST"
        build_app "$BUILD/Compositor.app"
        DMG="$DIST/Compositor-$VERSION-dev.dmg"
        build_dmg "$BUILD/Compositor.app" "$DMG"
        echo "package: $DMG"
        echo "size: $(du -h "$DMG" | cut -f1), version $VERSION ($BUILD_NUMBER), ad-hoc signed"
        ;;
    *)
        echo "usage: $0 [typecheck|app|package]" >&2
        exit 2
        ;;
esac
