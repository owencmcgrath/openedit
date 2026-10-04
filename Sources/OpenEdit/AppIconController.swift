import AppKit

/// Swaps the app's icon between the light and dark artwork so the Dock and app
/// switcher follow the user's system appearance (light/dark), including live
/// switches while the app is running.
///
/// The bundle ships two `icns` files (`Resources/AppIcon-Light.icns` and
/// `AppIcon-Dark.icns`, built by `Scripts/generate-app-icons.sh` from the source
/// PNGs in `icons/`). `Info.plist`'s `CFBundleIconFile` names the light artwork
/// as the on-disk default — the icon Finder shows before the app runs — and this
/// controller overrides `NSApp.applicationIconImage` at runtime to track the
/// current appearance.
///
/// This is a runtime substitute for an appearance-aware asset catalog: the app
/// is packaged by `Scripts/build-app.sh` with the Command Line Tools toolchain,
/// which cannot compile an `Assets.car` (`actool` needs a full Xcode install).
/// A side effect is that Finder's at-rest preview always shows the light
/// artwork; only a running app (Dock, app switcher, About panel) can follow the
/// preference.
final class AppIconController {
    /// Pure mapping from an appearance to the bundled resource name. Kept
    /// independent of `NSApp` so it can be reasoned about (and tested) without a
    /// running application.
    static func resourceName(for appearance: NSAppearance) -> String {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? "AppIcon-Dark"
            : "AppIcon-Light"
    }

    private var observation: NSKeyValueObservation?

    /// Begin following `NSApp.effectiveAppearance`. Idempotent: a second call is
    /// a no-op. Call once after launch.
    func start() {
        guard observation == nil else { return }
        apply(NSApp.effectiveAppearance)
        // AppKit documents the app's `effectiveAppearance` as KVO-observable
        // (there is no appearance-change notification); this fires on both live
        // system switches and per-app appearance overrides.
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
            self?.apply(application.effectiveAppearance)
        }
    }

    deinit {
        observation?.invalidate()
    }

    private func apply(_ appearance: NSAppearance) {
        // Bare `swift run` executables have no bundled resources, so this is a
        // no-op there and the app keeps AppKit's default icon.
        guard let url = Bundle.main.url(
            forResource: Self.resourceName(for: appearance),
            withExtension: "icns"
        ), let image = NSImage(contentsOf: url) else { return }

        NSApp.applicationIconImage = image
    }
}
