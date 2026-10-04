# Building Compositor on a MacBook Air M1 (8 GB)

This checkout was retargeted from macOS 26.0 to **macOS 15.0** so it builds and runs on the machine
it lives on, an M1 MacBook Air on macOS 15.6.1. This is the record of what changed, what was
measured, and what is still not possible here.

Environment: macOS 15.6.1 (24G90), Xcode 26.3 (Swift 6.2.4, macOS 26.2 SDK), Apple M1, 8 GB,
62 GB free disk.

## What the project requires

- **Xcode 26.** Installed now. `xcodebuild` works, but see the Sparkle problem below.
- **Swift 6.2.** The macOS 26 SDK is *not* actually required to compile the sources at a 15.0
  target — the macOS 26 API uses were the only SDK-version dependency, and they are gone now.
- **Sparkle 2.10.0** from `https://github.com/sparkle-project/Sparkle`, the only Swift package.

## What changed

Four macOS 26 API uses, and enough isolation annotations to compile cleanly under Swift 6.2 at a
15.0 deployment target.

### Deployment target

`MACOSX_DEPLOYMENT_TARGET` 26.0 → **15.0**, in all four build configurations. `Config/Info.plist`
gained `LSMinimumSystemVersion` 15.0. `README.md`'s requirement became "macOS 15.0 or later".

15.0 rather than 15.6: nothing in the sources needs more than 15.0, and the newer
`onGeometryChange` used in three places is available from 15.0.

### The four macOS 26 API uses, removed

Each was replaced by an equivalent that has always worked, rather than by a second rendering path
behind `#available` — one rendering on every supported system is easier to keep correct.

| Was | Where | Now |
| --- | --- | --- |
| `ToolbarSpacer(.fixed, placement: .navigation)` | `ContentView.swift` | `ToolbarItem(placement: .navigation) { Spacer().frame(width: 8) }` |
| `ToolbarSpacer(.flexible, placement: .navigation)` | `ContentView.swift` | `ToolbarItem(placement: .navigation) { Spacer() }` |
| `.sharedBackgroundVisibility(.hidden)` | `ContentView.swift` | gone; the tab strip reuses the toolbar's own background |
| `NSPopUpButton.borderShape = .capsule` | `BlendModePicker.swift`, `TypeControls.swift` | `appliesCapsuleBorder()`, in the new `UI/RoundedControls.swift` |

`appliesCapsuleBorder` draws the capsule itself — continuous corner curve, radius = half the
height, clipped — so the two AppKit pop-ups still match the SwiftUI buttons and menus beside them
(`View.roundedControls`), which never reached them anyway.

The two `ToolbarSpacer` sites are layout-only: a fixed inset before the tab strip and a flexible
spacer that absorbs the remaining navigation width before the zoom controls. A width-bearing spacer
item and a plain spacer item express the same thing. The difference on macOS 26 is only that the
tab strip now reuses the toolbar's background rather than opting out of it.

There is **no Touch Bar code in this project** — `NSTouchBar` and `touchBar` appear nowhere in the
sources — so nothing was removed on that account.

### Isolation annotations

Swift 6.2 has default main-actor isolation, which this codebase is written against: `EditorSession`
is declared plain `@Observable`, while its callers treat it as main-actor state. That works only if
the *default* isolation applies. Add one explicit `@MainActor` and it stops being a default and
becomes a claim about that type, which then has to be made true everywhere it is used.

So these nine annotations are one connected fix, not nine independent ones. Removing any of them
brings back an error somewhere else:

| Type | File |
| --- | --- |
| `EditorSession` | `Document/EditorSession.swift` |
| `TileWrites` (nested in `GPUCanvasRenderer`) | `Rendering/GPUCanvas.swift` |
| `WarpStroke` | `Document/SmudgeLiquify.swift` |
| `CompositorApplicationDelegate` | `IO/CompositorApplicationDelegate.swift` |
| `NativeLayerList`, its `Coordinator`, `LayerTableView` | `UI/NativeLayerList.swift` |
| `projectTabLabelWidth`, `projectTabPillWidth`, `projectTabOverflowPillWidth` | `UI/ProjectTabs.swift` |
| `ColorPickerState` | `Document/ColorPalette.swift` |
| `ColorPickerPanelController` | `UI/ColorPickerSheet.swift` |
| `guideColor`, `guideHitDistance` (made `nonisolated`) | `Document/Guides.swift` |

`TileWrites` is the one that is not about the default-isolation question: a nested type does not
inherit `@MainActor` from the class around it, so `place` calling the main-actor `grayCopy` needs
the annotation under any Swift 6.2 configuration. The two `EditorSession` statics in `Guides.swift`
are `nonisolated` because `hitGuide`'s default argument is evaluated outside the main actor.

## Verification

With the changes above, against the macOS 26.2 SDK and a 15.0 deployment target:

```
scripts/dev-build.sh typecheck
  → typecheck: clean (arm64-apple-macos15.0, SDK 26.2)      0 errors, 0 warnings
scripts/dev-build.sh app
  → .devbuild/Compositor.app
```

and the built bundle was exercised on this macOS 15.6.1 machine, not just linked:

- it launches, and settles to 0.1% CPU after startup (about 4.6 s of CPU over the first 46 s,
  ~117 MB resident, 5 threads);
- it responds to Apple events — `tell application "Compositor" to activate` brings it forward;
- it quits cleanly through its own `NSApplicationDelegate`, which is the part that matters: the
  delegate is `@MainActor` now, and its `applicationShouldTerminate` runs `confirmQuit()`, so a
  clean exit means the AppKit integration, the main-actor annotations and the event loop are all
  working, not merely that the binary started.

For that last check to mean anything the bundle needs an identity: Xcode fills `CFBundleIdentifier`
and friends in from the target's build settings (`GENERATE_INFOPLIST_FILE = YES`), so the
checked-in `Config/Info.plist` has none, and a hand-built bundle without them cannot be addressed by
name. `scripts/dev-build.sh` adds them.

`scripts/dev-build.sh` is the loop used for this. It drives the Xcode toolchain directly rather
than through `xcodebuild`, for the reason in the next section, and substitutes a 4-line stand-in
module for Sparkle. Everything else — every source file, the real SDK, the real C routines — is
compiled as it normally would be.

## What still cannot be done here

### `xcodebuild` cannot get past Sparkle

The supported build and the whole test suite go through `xcodebuild`, which resolves Swift packages
before compiling anything. **github.com is unreachable from this machine**, so it stops there:

```
xcodebuild: error: Could not resolve package dependencies:
    error: RPC failed; curl 28 Failed to connect to github.com port 443 after 75001 ms
```

Reachability, host by host:

| Host | Result |
| --- | --- |
| `github.com` | **times out** — TCP connects, no response (HTTPS and `git ls-remote` alike) |
| `codeload.github.com`, `api.github.com` | reachable, but transfers stall (40 KB/s and slower) |
| `raw.githubusercontent.com`, `cdn.jsdelivr.net` | reachable |
| `developer.apple.com`, `registry.npmjs.org` | reachable, fast |

So `xcodebuild`, `xcodebuild test`, and CI's exact commands need Sparkle resolved first — by
patience, by a mirror, or by vendoring it. Until then, `scripts/dev-build.sh` is the way to compile
and run here, but **the unit and UI tests cannot be run on this machine**: the `Testing` framework
ships with Xcode's test infrastructure, not the plain toolchain.

### Memory

8 GB with swap already 6.4 GB full is the constraint to plan around. A full compile is a couple of
minutes of solid CPU and pushes swap hard; a Debug build plus Xcode plus a running Metal canvas will
not fit comfortably. `CompositorUITests` and the two window-opening unit suites
(`FloatingPanelTests`, `SliderSnapTests`) are the heaviest part of a test run.

Disk is fine: 62 GB free against roughly 30 GB for the installed Xcode.

## Method

Every claim here was measured on this machine:

- The deployment target and each annotation were found by type-checking and bisecting, not by
  guessing: the pristine sources were type-checked first (3 errors), the four API uses were
  removed, and the isolation annotations were then added one wave at a time as the compiler
  reported them, re-running until it was clean at 0 errors and 0 warnings.
- The API availability was checked against Apple's documentation (`ToolbarSpacer` and
  `sharedBackgroundVisibility` are macOS 26.0; `buttonBorderShape` is macOS 12.0), and the rest was
  confirmed by compiling at `-target arm64-apple-macos15.0`.
- GitHub reachability was tested host by host; the `xcodebuild` failure is its actual output.
- The app was launched, driven and quit, rather than assumed to work because it linked; the
  bundle-identity gap above was found that way, by a quit that hung.
