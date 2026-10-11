// axpress.swift — dismiss first-run modal dialogs in a GUI app (issue #38).
//
// Some editors under test show blocking first-launch dialogs (BBEdit's
// license agreement, welcome screens). This polls the app's windows via the
// Accessibility API for a bounded time and presses the default/confirm button
// of each window it finds, so automated runs proceed unattended. Only ever
// presses buttons — never types text.
//
// Usage: axpress --bundle-id com.example.App [--seconds 20]

import Foundation
import ApplicationServices
import AppKit

var bundleID = ""
var seconds = 20.0
var it = CommandLine.arguments.dropFirst().makeIterator()
while let arg = it.next() {
    switch arg {
    case "--bundle-id": bundleID = it.next() ?? ""
    case "--seconds": seconds = Double(it.next() ?? "20") ?? 20
    default: break
    }
}
guard !bundleID.isEmpty, AXIsProcessTrusted() else { exit(2) }

func appElement() -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func press(_ element: AXUIElement) {
    AXUIElementPerformAction(element, kAXPressAction as CFString)
}

/// Press a window's default button, or any button whose role/title suggests
/// agreement. Returns whether something was pressed.
func tryDismiss(_ window: AXUIElement) -> Bool {
    if let defaultButton = attribute(window, kAXDefaultButtonAttribute as CFString) {
        press(defaultButton as! AXUIElement)
        return true
    }
    guard let buttons = attribute(window, kAXButtonAttribute as CFString) as? [AXUIElement] else {
        return false
    }
    let agreeing = ["agree", "accept", "continue", "ok", "get started", "start", "later", "not now"]
    for button in buttons {
        let title = (attribute(button, kAXTitleAttribute as CFString) as? String)?.lowercased() ?? ""
        if agreeing.contains(where: { title.contains($0) }) {
            press(button)
            return true
        }
    }
    return false
}

let deadline = Date().addingTimeInterval(seconds)
var pressed = 0
while Date() < deadline {
    guard let app = appElement(),
          let windowsRaw = attribute(app, kAXWindowsAttribute as CFString),
          let windows = windowsRaw as? [AXUIElement]
    else { usleep(500_000); continue }
    for window in windows where tryDismiss(window) {
        pressed += 1
        usleep(400_000)
    }
    usleep(500_000)
}
print("pressed \(pressed)")
