# Architecture and development dependencies

What Compositor is made of, what it needs to build, and where its edges are. The adaptation of
this checkout to the M1 Air it was cloned onto is recorded separately in
[local-development-m1-air.md](local-development-m1-air.md).

## What it is

A single-window macOS image editor for compositing and photo work: layers with masks, selections,
painting and retouching, adjustment layers, filters, and non-destructive transforms. No plugin
system, no scripting host, no server component. It ships as one `.app` plus its Sparkle update
feed (`appcast.xml` at the repository root).

## Repository layout

| Path | Contents |
| --- | --- |
| `Compositor.xcodeproj` | One project, three targets, one shared scheme (`Compositor`) |
| `Compositor/Document` | The model: documents, layers, masks, selections, tools, history |
| `Compositor/UI` | SwiftUI views and AppKit controls |
| `Compositor/Rendering` | The canvas: Metal, Core Image, and C pixel routines |
| `Compositor/IO` | Import, export, project store, file watching |
| `Compositor/IO/PSD` | Photoshop PSD/PSB reader and conversion |
| `CompositorTests` | Unit tests |
| `CompositorUITests` | UI tests |
| `Config` | `Info.plist`, `Compositor.entitlements` |
| `scripts` | `release.sh`, `publish.sh`, DMG tooling |
| `docs` | This document, the file format, and the agent-facing notes |

## Code by layer

Counted from this checkout:

| Layer | Swift files | Swift lines |
| --- | --- | --- |
| `Document` | 54 | 13,617 |
| `UI` | 46 | 8,144 |
| `Rendering` | 21 | 7,437 |
| `IO` (incl. `IO/PSD`) | 19 | 3,645 |
| App entry (`CompositorApp.swift`, `ContentView.swift`) | 2 | 815 |
| **Total** | **142** | **~33,700** |

Plus 9 C files (2,284 lines) and 9 headers (244 lines) in `Compositor/Rendering` for per-pixel
work — brush coverage, healing, levels, magic wand, noise, lens correction, content-aware fill,
adjustments and dithering — reached from Swift through
`Compositor/Compositor-Bridging-Header.h`.

Tests: 73 files, ~13,900 lines, in the `CompositorTests` target, plus the `CompositorUITests`
target.

## The three targets

- **Compositor** — the app. `MACOSX_DEPLOYMENT_TARGET = 15.0`, `ARCHS = arm64`, bundle id
  `com.wonderassembly.compositor`, sandboxed (`Config/Compositor.entitlements`), hardened runtime
  on for Release, `SWIFT_VERSION = 5.0`.
- **CompositorTests** — unit tests, bundle id `…compositor.tests`.
- **CompositorUITests** — UI tests, bundle id `…compositor.uitests`.

Two unit suites (`FloatingPanelTests`, `SliderSnapTests`) show real windows and are timed, so CI
runs them serially after the parallel run — see `.github/workflows/verify.yml`.

## Runtime architecture

The shapes that explain most of the code:

- **`EditorSession`** (`Document/EditorSession.swift`) is the hub: the open document, the active
  tool, the current edit (adjustment, filter, crop, transform, text draft), undo history, and
  every derived flag the UI binds to. It is `@Observable`, so views read it directly. Most other
  `Document/*.swift` files are `extension EditorSession` adding one tool's behavior.
- **`CanvasDocument`** holds layers, their masks, effects and adjustments. Layer pixel data lives
  in assets rather than in the model, so a layer can be moved and scaled without touching pixels.
- **Painting on the GPU.** `Rendering/GPUCanvas.swift` keeps layers as Metal textures and
  recomposites only what changed; Core Graphics is the fallback. `MetalWarp` and
  `MetalBrushCoverage` run brush and liquify strokes on the GPU. The C files handle the pixel
  operations that are cheaper on the CPU.
- **The document is a package, not a single file.** A `.comp` is a folder: a manifest plus one PNG
  per layer. That is what lets an external process edit a project while it is open and have the
  window update live (`IO/ProjectWatcher.swift`, `ProjectDigest.swift`). The format is specified in
  [project-format.md](project-format.md), and `ProjectManifest.current` in the sources is the
  version that a change to what is saved must bump.
- **Rendering is versioned by cache, not by invalidation.** `DownsampleCache`, `EffectsPreviewCache`
  and `TiledLayerRenderer` keep zoomed-out and preview results keyed by what produced them.

## Development dependencies

**Swift packages — one.**

| Package | Version | Used for |
| --- | --- | --- |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0, pinned in `Package.resolved` | Automatic updates |

It is referenced once in the UI (`SPUStandardUpdaterController` in
`IO/CompositorApplicationDelegate.swift`, started one second after launch so its first-run prompt
cannot block the editor window) and linked into the app target. It is the only network client in
the sandboxed app, and the reason `Config/Compositor.entitlements` carries a
`temporary-exception.mach-lookup.global-name` pair for `-spks`/`-spki`.

**Apple frameworks.** SwiftUI, AppKit, Metal, MetalKit, Core Image, Vision (Select Subject,
Remove Background), Core ML, Core Graphics, ImageIO, UniformTypeIdentifiers, Accelerate (via the
C routines), AVFoundation.

**Build-time tooling.**

- **Xcode 26** — CI pins `Xcode_26.6` on a `macos-26` runner, and the project file is
  `objectVersion = 77` with `LastUpgradeCheck = 2700`. Swift 6.2 is what the sources are written
  for; the macOS 26 SDK is not itself required, since the retarget below.
- **A Mac with Apple silicon** — `ARCHS = arm64`. The deployment target is **macOS 15.0**
  (`LSMinimumSystemVersion` in `Config/Info.plist` matches), lowered from 26.0 so the app builds and
  runs on the machine this checkout lives on.
- [`create-dmg`](https://github.com/create-dmg/create-dmg) — only for `scripts/release.sh`.
- For releasing: a Developer ID Application certificate, and notarization credentials stored as
  `compositor-notary`. Neither belongs in the repository.

**No other package managers.** No CocoaPods, Carthage, npm or Makefile step exists in the checkout;
the Xcode project and `scripts/` are the whole build.

## Deployment target and the macOS 26 API that used to be here

The app targets **macOS 15.0**. Four macOS 26 conveniences were removed to get there; each was
replaced by an equivalent that works everywhere, rather than kept behind `#available`:

- `ToolbarSpacer(_:placement:)` in `ContentView.swift` (twice) became width-bearing and plain
  `Spacer` toolbar items. Layout only: a fixed inset before the tab strip, and the spacer that
  absorbs the remaining navigation width before the zoom controls.
- `.sharedBackgroundVisibility(.hidden)` on the tab strip's `ToolbarItem` is gone, so the strip
  reuses the toolbar's own background instead of opting out of it.
- `NSPopUpButton.borderShape = .capsule` (the Blend mode and font pop-ups) became
  `NSControl.appliesCapsuleBorder()` in `UI/RoundedControls.swift`, which draws the same capsule
  itself so those AppKit controls match the SwiftUI buttons beside them.

Two Swift 6.2 notes worth keeping in mind when editing. The sources rely on Swift 6.2's **default
main-actor isolation** — `EditorSession` and friends are declared without `@MainActor` — but a
handful of types do carry it explicitly, because a default stops applying once anything is
explicit, and a nested type never inherits its enclosing type's isolation. `TileWrites` in
`Rendering/GPUCanvas.swift` is the clearest case. Adding or removing one of these annotations moves
errors rather than fixing them, so they are a set. The details, and the reasoning, are in
[local-development-m1-air.md](local-development-m1-air.md).

## Build and test

```sh
# Build
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' build

# Unit tests
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' \
  test -only-testing:CompositorTests
```

CI additionally resolves packages before building, builds for testing once with
`CODE_SIGN_IDENTITY=-`, then runs the two suites that open real windows serially.

Both commands resolve the Sparkle package first, which needs github.com. On a machine that cannot
reach it, `scripts/dev-build.sh` compiles and links the app with the Xcode toolchain directly,
substituting a stand-in for Sparkle, and can also package the result as an ad-hoc signed development
DMG (`scripts/dev-build.sh package`). Neither substitutes for `release.sh`: that one signs with a
Developer ID and notarizes. See [local-development-m1-air.md](local-development-m1-air.md).
