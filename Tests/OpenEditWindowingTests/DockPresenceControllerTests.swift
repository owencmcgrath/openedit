import AppKit
import Testing

@testable import OpenEdit

/// Dock-presence policy coverage (ARCHITECTURE.md 5.13): the
/// document-window-count → activation-policy mapping, and #39's last-window
/// focus hand-off decision. Both are pure functions, so no app instance or
/// window server is involved.
@Suite struct DockPresencePolicyTests {

    @Test func documentWindowsKeepTheAppRegular() {
        #expect(DockPresenceController.activationPolicy(forDocumentWindowCount: 1) == .regular)
        #expect(DockPresenceController.activationPolicy(forDocumentWindowCount: 3) == .regular)
    }

    @Test func noDocumentWindowsDropTheAppToAccessory() {
        #expect(DockPresenceController.activationPolicy(forDocumentWindowCount: 0) == .accessory)
    }
}

@Suite struct DockPresenceYieldTests {

    @Test func closingTheLastWindowWhileFrontmostYields() {
        // The #39 scenario: Cmd-W on the last document window of a frontmost
        // app must hand focus back to whatever the user came from.
        #expect(DockPresenceController.shouldYieldActivation(
            from: .regular,
            to: .accessory,
            isActive: true,
            hasWindows: false
        ))
    }

    @Test func inactiveAppHasNoFocusToYield() {
        // The user is already elsewhere; hiding would only disturb state for
        // no visible effect.
        #expect(!DockPresenceController.shouldYieldActivation(
            from: .regular,
            to: .accessory,
            isActive: false,
            hasWindows: false
        ))
    }

    @Test func remainingWindowsBlockTheHandoff() {
        // e.g. the Settings window is open: it does not count as a document
        // window (5.13), but hiding the app would pull it out from under the
        // user mid-use.
        #expect(!DockPresenceController.shouldYieldActivation(
            from: .regular,
            to: .accessory,
            isActive: true,
            hasWindows: true
        ))
    }

    @Test func restoreToRegularNeverYields() {
        // The restore path must keep its no-focus-stealing guarantee: bringing
        // the Dock icon back while another app is frontmost stays quiet.
        #expect(!DockPresenceController.shouldYieldActivation(
            from: .accessory,
            to: .regular,
            isActive: true,
            hasWindows: false
        ))
    }

    @Test func unchangedPolicyNeverYields() {
        // Recomputes that do not change the policy (another window's
        // key/main notifications) are no-ops and must not hide the app.
        #expect(!DockPresenceController.shouldYieldActivation(
            from: .regular,
            to: .regular,
            isActive: true,
            hasWindows: false
        ))
        #expect(!DockPresenceController.shouldYieldActivation(
            from: .accessory,
            to: .accessory,
            isActive: true,
            hasWindows: false
        ))
    }
}
