import Foundation
import SwiftUI

/// The app's languages, and the machinery for choosing one at runtime.
///
/// macOS normally picks a process's localization once, at launch, and an app that wants to change it has to be
/// relaunched. Compositor instead resolves every string through a bundle for the chosen language, so the switcher in
/// the app menu takes effect immediately.
///
/// The load-bearing fact, measured rather than assumed: `Bundle.main` resolves which `.lproj` it reads *once*, and
/// nothing at runtime redirects it — not `AppleLanguages`, not the `locale` environment. A bundle built explicitly
/// for a language does return that language, and that is the whole mechanism. Two call-site rules follow:
///
/// - View code uses `v(_:)`. A bare `Text("Save")` asks `Bundle.main` and is therefore stuck in the launch language,
///   so on a Mac set to Chinese the English option would not work at all. `LocalizationRoot` re-identifies the tree
///   when the language changes, which is what re-resolves those strings with the chosen bundle in the environment.
/// - Everything else uses `string(_:)` or `text(_:)`. AppKit menu titles, alerts, and the enums that name themselves
///   are built where no view can be read and no actor is in reach, so those look the bundle up directly.
///
/// `docs/localization.md` has the measurements, the reason `displayName` is kept separate from `rawValue`, and what
/// macOS does not let a running app change.
enum Localization {
    /// The languages the app ships. `code` is what `.lproj` folders are named after; `endonym` is the language's own
    /// name, which is what a language picker should show — a reader who cannot read the current language can still
    /// find their own.
    enum Language: String, CaseIterable, Identifiable, Sendable {
        case english = "en"
        case simplifiedChinese = "zh-Hans"

        var id: String { rawValue }

        var code: String { rawValue }

        var endonym: String {
            switch self {
            case .english: return "English"
            case .simplifiedChinese: return "简体中文"
            }
        }

        /// The language's name in English, for the language picker's secondary line and for diagnostics.
        var englishName: String {
            switch self {
            case .english: return "English"
            case .simplifiedChinese: return "Simplified Chinese"
            }
        }

        /// Non-nil when `identifier` (a BCP 47 tag such as `zh-Hans-CN` or `en-US`) names this language. Compared on
        /// the language and script subtags only, since a region does not change which table applies.
        init?(matching identifier: String) {
            let lowered = identifier.lowercased()
            let parts = lowered.split(separator: "-").map(String.init)
            guard let language = parts.first else { return nil }
            switch language {
            case "en":
                self = .english
            case "zh":
                // Traditional Chinese is a different translation, not a variant of this one, so it does not match:
                // falling back to English is more honest than showing simplified text.
                if parts.contains("hant") { return nil }
                self = .simplifiedChinese
            default:
                return nil
            }
        }
    }

    /// The chosen language, observable so the switcher and the views it re-identifies can react to it.
    @MainActor
    @Observable
    final class Store {
        /// Where the choice is remembered. A separate key from `AppleLanguages`, which macOS reads once at launch and
        /// which changing would only take effect after a relaunch.
        private static let defaultsKey = "compositor.language"

        var language: Language {
            didSet {
                guard language != oldValue else { return }
                UserDefaults.standard.set(language.code, forKey: Self.defaultsKey)
                // Keep the context-free lookup in step. Must happen before any view observes the new value.
                Current.language = language
            }
        }

        init() {
            let defaults = UserDefaults.standard
            let stored = defaults.string(forKey: Self.defaultsKey).flatMap(Language.init(rawValue:))
            let initial = stored ?? Self.systemLanguage()
            self.language = initial
            Current.language = initial
        }

        /// The best match for what the system is set to, falling back to English. `Locale.preferredLanguages` is in the
        /// user's order of preference, so the first one the app has a translation for wins.
        private static func systemLanguage() -> Language {
            for identifier in Locale.preferredLanguages {
                if let language = Language(matching: identifier) { return language }
            }
            return .english
        }
    }

    /// The chosen language and its bundle, readable from any context.
    ///
    /// `string(_:)` has to work outside the main actor: AppKit menu titles, error messages and the adjustments and
    /// blend modes that name themselves are built where no view and no actor is in reach, and `@MainActor` on the
    /// lookup makes those call sites fail to type-check inside a `ForEach` or a `ResultBuilder`. A lock is affordable
    /// here because the bundle is resolved once per language change, not once per string.
    private enum Current {
        private static let lock = NSLock()
        private static var storage: (language: Language, bundle: Bundle) = (.english, .main)

        static var language: Language {
            get { lock.withLock { storage.language } }
            set {
                let resolved = (newValue, Localization.bundle(for: newValue))
                lock.withLock { storage = resolved }
            }
        }

        static var bundle: Bundle { lock.withLock { storage.bundle } }
    }

    /// The bundle holding the table for `language`, or the main bundle when that language has no `.lproj` — better a
    /// window full of English than one full of keys.
    static func bundle(for language: Language) -> Bundle {
        if let path = Bundle.main.path(forResource: language.code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        // `zh-Hans` is what the folder is called; `zh_CN` is what older tooling writes. Accept either.
        if language == .simplifiedChinese {
            for fallback in ["zh_CN", "zh-Hans-CN", "zh"] {
                if let path = Bundle.main.path(forResource: fallback, ofType: "lproj"),
                   let bundle = Bundle(path: path) {
                    return bundle
                }
            }
        }
        return .main
    }

    /// The one store the app uses. `CompositorApp` owns it for the view tree; this is how non-view code reaches the
    /// same choice without threading it through every call.
    @MainActor
    static let shared = Store()

    /// A localized string for AppKit, models and error messages. `key` is the English wording, which is the table's
    /// key. An unknown key comes back unchanged, so a missed string shows English rather than an identifier.
    ///
    /// Deliberately not `@MainActor`: the display names on `LayerBlendMode` and `AdjustmentKind` call this from
    /// inside a `ForEach` and from `nonisolated` enums, and an isolated lookup there does not type-check.
    static func string(_ key: String) -> String {
        Current.bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// A localized string with substitutions, as a format string. The localized text carries the argument order, so a
    /// translation may reorder them.
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }

    /// A localized string as a plain `String`, for the places that need one and cannot take a `LocalizedStringKey` —
    /// an `NSMenuItem` title, an `NSAlert` message, a `help(_:)` tooltip.
    static func text(_ key: String) -> String { string(key) }

    // MARK: - What view code must use instead of a bare literal

    /// A localized string resolved through the chosen bundle, for `Text`, `Button`, `Label` and `help`.
    ///
    /// A bare `Text("Save")` does **not** work with the switcher, and not for want of re-identifying the tree:
    /// `Bundle.main` resolves which `.lproj` it reads *once*, and nothing at runtime redirects it — not
    /// `AppleLanguages`, not the `locale` environment, not `Bundle.main.preferredLocalizations`. Measured on this
    /// machine: after setting `AppleLanguages` to another language, the same `Bundle.main` kept returning the
    /// launch language. So `Text("Save")` is stuck in whatever language the app launched in, which also means an
    /// English reader whose Mac is set to Chinese can never reach English.
    ///
    /// Passing a bundle explicitly is the one mechanism that does switch, and it is what Apple documents for
    /// runtime language changes. Use these two functions for anything a reader sees; keep the bare literal only
    /// where the string is not shown.
    static func v(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: Current.bundle)
    }

    /// A localized format string with substitutions, for view code. `key` carries the format specifiers the
    /// translation replaces, as in `v("Delete %@", layer.name)`.
    ///
    /// Uses `String(format:)` rather than `String(localized:)`'s own interpolation so that the table is a plain
    /// `.strings` file: `String(localized:)` reads `%@` only from a `.xcstrings` or `.plist` catalog, where the
    /// key also has to match the interpolated source exactly. A `.strings` file accepts it directly.
    static func v(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: String(localized: String.LocalizationValue(key), bundle: Current.bundle), arguments: arguments)
    }
}

/// Puts the chosen language's bundle in the environment. `Text("literal")` cannot be told which bundle to use, which
/// is why the tree is also re-identified when the language changes: that re-resolves each literal while this bundle is
/// the one in place.
extension EnvironmentValues {
    @Entry var localizationBundle: Bundle = .main
    /// Not used for lookup — it is the value `LocaleRoot` identifies the tree by, so that a change rebuilds it.
    @Entry var appLanguage: Localization.Language = .english
}

/// Re-identifies everything below it when the language changes.
///
/// A change has to reach `Text("literal")`, which SwiftUI resolves itself and no environment value can redirect. New
/// identity discards and rebuilds the subtree, so every literal is resolved again — now against the bundle in the
/// environment. Without this the menus and sheet labels keep the language they were built with.
struct LocalizationRoot<Content: View>: View {
    @Environment(Localization.Store.self) private var store
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.localizationBundle, Localization.bundle(for: store.language))
            .environment(\.appLanguage, store.language)
            .id(store.language)
    }
}

/// Reads a localized string from the environment, for view code that needs a `String` where a `Text` will not do —
/// building an `NSMenuItem`, or interpolating into a string that is not itself localized.
struct LocalizedString {
    @Environment(\.localizationBundle) private var bundle

    subscript(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// A localized format string with substitutions.
    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: bundle.localizedString(forKey: key, value: key, table: nil), arguments: arguments)
    }
}
