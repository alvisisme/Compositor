import AppKit

/// What this app no longer uses from macOS 26, and what stands in for it here.
///
/// The app deploys to macOS 15, so the four macOS 26 conveniences it used to rely on are gone:
/// `NSPopUpButton.borderShape`, `ToolbarSpacer`, `ToolbarContent.sharedBackgroundVisibility(_:)`
/// and the fixed-size `Spacer` that `ToolbarSpacer` provided. Each is replaced by the closest
/// equivalent that has always worked, rather than by a second code path behind `#available` — one
/// rendering on every supported system is easier to keep correct. See
/// [docs/local-development-m1-air.md](../../docs/local-development-m1-air.md).

extension NSControl {
    /// The capsule edge macOS 26's `borderShape = .capsule` gave a pop-up button, drawn here so the
    /// pop-up matches the SwiftUI buttons and menus beside it (`View.roundedControls`).
    func appliesCapsuleBorder() {
        wantsLayer = true
        guard let layer else { return }
        layer.cornerCurve = .continuous
        layer.cornerRadius = bounds.height / 2
        layer.masksToBounds = true
    }
}
