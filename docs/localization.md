# Localization

Compositor ships English and Simplified Chinese, and switches between them from the app menu without a
relaunch. This is how that works, and the two traps in it — one of which is the reason the view code is
written the way it is.

## The mechanism

macOS decides a process's localization once, at launch. `Bundle.main` resolves which `.lproj` it reads at
that moment and nothing afterwards changes it.

This was measured rather than assumed, because it decides the whole design. Setting `AppleLanguages` at
runtime and then asking the same `Bundle.main` for a string returns the **launch** language, not the new
one; a bundle built explicitly for a language returns that language. So:

- **`Localization.bundle(for:)`** returns the `.lproj` bundle for a language. Foundation reads a bundle's
  table without consulting the process language, so choosing a bundle is the whole switch.
- **`Localization.v(_:)`** (`v` for view) resolves a string through the chosen bundle. It is what all view
  code uses.
- **`Localization.string(_:)` / `text(_:)`** do the same for AppKit, models and errors, where there is no
  view to read an environment from. Both are deliberately **not** `@MainActor`: menu titles, alerts and the
  adjustments and blend modes that name themselves are built where no actor is in reach, and an isolated
  lookup there does not type-check inside a `ForEach` or a `ResultBuilder`. A lock guards the current
  bundle, which is resolved once per language change rather than once per string.
- **`LocalizationRoot`** re-identifies the view tree when the language changes (`.id(store.language)`) and
  puts the bundle in the environment. Without it, a sheet already built would keep the labels it was
  built with until something else replaced it.

The chosen language is stored under `compositor.language`, a key of the app's own. It is deliberately not
`AppleLanguages`, which macOS reads once at launch and which would only take effect after a relaunch — the
opposite of what the switcher is for.

## Why every view string says `Localization.v`

`Text("Save")` cannot follow the switcher, for the reason above: SwiftUI resolves that literal against
`Bundle.main`, and no environment value redirects it. Re-identifying the tree does not help either — the
rebuilt `Text` still asks `Bundle.main`.

That has a consequence worth stating plainly: on a Mac whose language is Chinese, a bare `Text("Save")`
renders in Chinese *whatever the reader picks*, so the English option would not work at all. This is why
every literal a reader sees goes through `Localization.v`:

```swift
Text(Localization.v("Save"))
Text(Localization.v("Delete %@", layer.name))       // was Text("Delete \(layer.name)")
.help(Localization.v("Zoom in (⌘+)"))
.accessibilityLabel(Localization.v("Canvas"))
```

That is 392 view literals plus 138 tooltips and screen-reader labels, converted mechanically and then
type-checked to zero errors. Four interpolations containing nested `Int(...)` calls were split by hand,
and `scripts/l10n/extract-keys.py` is what proves the coverage is complete rather than merely plausible.

`Localization.v` uses `String(format:)` rather than `String(localized:)`'s own interpolation so the table
can stay a plain `.strings` file: `String(localized:)` reads `%@` only from a `.xcstrings` or `.plist`
catalog, where the key must also match the interpolated source text exactly. A `.strings` file takes the
format specifier directly. The one caveat is that `.strings` needs `%%` for a literal percent sign, which
is why a couple of keys read `%lld%%`.

## Display text is not the stored value

Five enums used `rawValue` for both the persisted value and the label on screen. `LayerBlendMode` is
`Codable` and `docs/project-format.md` records that a `.comp` manifest stores `blendMode: "Normal"`
verbatim — so localizing the raw value would have made a project written in one language unreadable in
another. Each now carries:

- **`rawValue`** — exactly what it always was. What a `.comp` stores, what a test names its reference
  image after. Never localized.
- **`displayName`** — the English wording, which is the key into `Localizable.strings`.
- **`localizedName`** — `displayName` in the reader's language.

`ShapeKind` keeps its raw value unlocalized for a second reason: it also names the layer a shape creates
(`nextShapeName`), and switching language must not rename anyone's layers.

The property exists so a call site stays a plain member access (`.localizedName`). Writing the lookup out
longhand inside a `Text(` in a deep view builder was enough to send type checking past its limit — twice,
in `LevelsSheet` and `TypeControls` — which is worth knowing before "simplifying" one of these back.

## Adding a language

1. Add the case to `Localization.Language`, with its endonym and English name.
2. Add a `translation` map to `scripts/l10n/translations.py` in the same shape as the Chinese one.
3. `python3 scripts/l10n/build-strings.py` writes the tables; `extract-keys.py` reports what is missing.
4. Add the folder name to the `CFBundleLocalizations` array in `scripts/dev-build.sh`, so `Bundle.main`
   will hand out the `.lproj` however macOS has the process language set.

A string with no translation falls back to English, never to an identifier, so a partial translation is
safe to ship.

## What does not switch, and why

The app's own strings switch immediately. **The menus macOS itself supplies do not** — "About
Compositor", "Services", "Hide", "Quit", and the standard items in Edit and Window. The system localizes
those per app, from what the bundle declares, when the app launches; a running app cannot renegotiate it.
Switching the language changes what Compositor draws, and a relaunch is what changes what macOS draws
around it.

This is a system constraint, not an omission. It is also why the switcher lives in the app menu: the
items beside it are the ones that will be right after the next launch.

## Checking it

```sh
scripts/dev-build.sh typecheck          # must be clean; the call sites are sensitive to inference
python3 scripts/l10n/extract-keys.py    # 450 of 451 keys translated; the one miss is a comment
python3 scripts/l10n/build-strings.py   # rewrites both tables from translations.py
```

`extract-keys.py` counts the one `'literal'` in a code comment as a key. That is the whole of the
reported gap.
