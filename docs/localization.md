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
python3 scripts/l10n/extract-keys.py    # every key a call site looks up has a translation
python3 scripts/l10n/build-strings.py   # rewrites both tables from translations.py
python3 scripts/l10n/build-strings.py --report   # untranslated candidates and stale entries
```

`extract-keys.py` looks for the keys passed to `Localization.v`, `text` and `string`, and reports
514 of the 515 it finds as translated. The one it counts as missing is the `'literal'` inside the
comment in `CompositorApp.swift` that explains why a bare `Text("literal")` cannot switch, so there is
no real gap by that measure.

**It cannot see the other way a string reaches a reader.** A phrase that arrives as an enum's
`rawValue`, as a ternary branch, or in an array of definitions is not an argument to a `Localization`
call at the point where it is written, so the extractor does not count it — and all three of those
shapes were where English survived the first sweeps. A quick way to find them again is to grep for
`Text(` whose argument ends in `.rawValue`, and for `? "…" : "…"` branches that no `Localization`
call encloses.

The remaining English is a known set rather than an unknown one: the help text on the Camera Raw
panels and the filter sheet, and the tool names in the shortcut editor's canvas section. They are
clusters of tooltips rather than anything on the main path.

## Adding a language

## Adding a language

1. Add the case to `Localization.Language`, with its endonym — the language's own name for itself,
   because that is what the picker must show a reader who cannot read the current one.
2. Add its map to `scripts/l10n/translations.py` beside the Chinese one.
3. Add the `.lproj` folder name to the `CFBundleLocalizations` array in `scripts/dev-build.sh`, so
   `Bundle.main` will hand that folder out when macOS has the process language set to it.
4. `python3 scripts/l10n/build-strings.py` writes the tables; `extract-keys.py` reports what is
   still missing.

A string with no translation falls back to English rather than to an identifier, so a partial
translation is safe to ship and coverage can grow a batch at a time.

## What the mechanical passes could not do

Worth knowing before trusting a sweep. Four shapes defeated a search for a literal at a display
call, and each of them left real English behind until it was hunted separately:

- **Ternary branches.** `Text(cond ? "A" : "B")` passes the literal to the ternary, not to `Text`.
- **`rawValue` on an enum.** The string is not written where it is shown at all. Every such picker
  needs `Text(Localization.v($0.rawValue))` — display only, never the enum, because three of those
  enums are `Codable` and their raw values are what a `.comp` stores.
- **Concatenation.** `"Add " + kind.rawValue` cannot be translated: "Add Drop Shadow" is a phrase,
  and gluing a translated noun onto an English verb is not. The whole phrase has to be the key.
- **Interpolation as a suffix.** `title + " by 10"` with the key `"%@ by 10"` looks up the frame and
  fills it with an English title, so Chinese read "Decrease tracking 10". The whole phrase is the key.

A related trap: `Localization.text(_:)` takes no arguments. A message with a value in it needs the
variadic `string(_:)`, and the compiler only catches the mistake when the argument is a String.

Finally, notation — `100%`, `#`, `%`, the `×` in a size, the letters `RGB` — should be `Text(verbatim:)`
or nothing at all. Translating it is wrong, and marking it explicitly is what stops the next sweep
from "fixing" it.
