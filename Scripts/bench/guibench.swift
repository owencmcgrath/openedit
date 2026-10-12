// guibench.swift — time-to-interactive benchmark for GUI editors (issue #38).
//
// Measures the wall-clock delta from invoking an editor's open command to the
// moment the benchmark file is visibly open, detected via the macOS
// Accessibility API: poll the app process's window list until a window whose
// AX title contains the file's basename appears (cold) or replaces a decoy
// title (warm). This is the same readiness notion the TTY harness implements
// for terminal editors — "content painted" — so both tables share a metric.
//
// Cold mode: the target app is quit first; every run then launches it fresh.
// Warm mode: the app stays running; each run opens a distinct copy of the
// corpus file (never opened before in that session), so a stale matching
// title cannot produce a false positive.
//
// Usage:
//   guibench --file <path> --mode cold|warm --runs N [--timeout-sec S]
//            --bundle-id com.example.App --decoy <path>
//            -- <open-command> [args...]
//
// The open command may use %FILE% and is run through /bin/sh. The decoy file
// (required in warm mode) is opened between runs to move the title off the
// target file's name.

import Foundation
import ApplicationServices
import AppKit

var file = ""
var mode = "cold"
var runs = 5
var timeoutSec = 180.0
var bundleID = ""
var decoy = ""
var openCommand = ""

var it = CommandLine.arguments.dropFirst().makeIterator()
while let arg = it.next() {
    switch arg {
    case "--file": file = it.next() ?? ""
    case "--mode": mode = it.next() ?? "cold"
    case "--runs": runs = Int(it.next() ?? "5") ?? 5
    case "--timeout-sec": timeoutSec = Double(it.next() ?? "180") ?? 180
    case "--bundle-id": bundleID = it.next() ?? ""
    case "--decoy": decoy = it.next() ?? ""
    case "--":
        // Everything after -- is the command string, joined verbatim and run
        // through /bin/sh. (Callers may pass one pre-quoted shell template or
        // several tokens; either way it must NOT be re-quoted — wrapping a
        // whole shell line in quotes makes sh treat it as one command name.)
        var tokens: [String] = []
        while let t = it.next() { tokens.append(t) }
        openCommand = tokens.joined(separator: " ")
        break
    default: break
    }
}
guard !file.isEmpty, !openCommand.isEmpty else {
    FileHandle.standardError.write("guibench: --file and -- <command> required\n".data(using: .utf8)!)
    exit(2)
}
let basename = (file as NSString).lastPathComponent

/// Window titles hide well-known extensions (NSDocument displayName, like
/// TextEdit showing "file" for "file.txt"), so the match needle drops the
/// extension. Corpus names carry a `-runN` suffix (driver-generated), which
/// keeps sizes from prefix-colliding (needle "fixed-100lines-run1" is not a
/// substring of "fixed-1000lines-run1").
func titleNeedle(forPath path: String) -> String {
    let base = (path as NSString).lastPathComponent
    if let range = base.range(of: ".", options: .backwards), range.lowerBound > base.startIndex {
        return String(base[..<range.lowerBound])
    }
    return base
}

// MARK: - App process helpers

func pidForBundleID(_ id: String) -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier
}

func terminateApp(bundleID: String) {
    guard let pid = pidForBundleID(bundleID) else { return }
    // Ask politely first (saves state, deletes autosave windows), then force.
    if let app = NSRunningApplication(processIdentifier: pid) {
        app.terminate()
        let deadline = Date().addingTimeInterval(10)
        while app.isTerminated == false && Date() < deadline { usleep(100_000) }
    }
    if pidForBundleID(bundleID) != nil, let pidKill = pidForBundleID(bundleID) {
        kill(pidKill, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while pidForBundleID(bundleID) != nil && Date() < deadline { usleep(100_000) }
        if let still = pidForBundleID(bundleID) { kill(still, SIGKILL) }
    }
    // Give LaunchServices a moment to forget the process, bounded so a
    // refuse-to-die app cannot hang the whole benchmark.
    let goneDeadline = Date().addingTimeInterval(5)
    while pidForBundleID(bundleID) != nil && Date() < goneDeadline { usleep(50_000) }
}

func runShell(_ command: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", command]
    let errPipe = Pipe()
    proc.standardError = errPipe
    proc.standardOutput = FileHandle.nullDevice
    do { try proc.run() } catch {
        FileHandle.standardError.write("guibench: open failed: \(error)\n".data(using: .utf8)!)
        return
    }
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        FileHandle.standardError.write("guibench: open exited \(proc.terminationStatus): \(err)\n".data(using: .utf8)!)
    }
}

// MARK: - Accessibility polling

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("guibench: no Accessibility permission for this process\n".data(using: .utf8)!)
    exit(3)
}

/// All window titles of the app with `pid`, via the Accessibility API.
func windowTitles(pid: pid_t) -> [String] {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement]
    else { return [] }
    var titles: [String] = []
    for window in windows {
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
           let t = title as? String {
            titles.append(t)
        }
    }
    return titles
}

/// Poll until any window title contains `needle`. Returns elapsed seconds.
func waitForTitle(pid: pid_t, needle: String, timeout: TimeInterval) -> Double? {
    let t0 = DispatchTime.now()
    let deadline = Date().addingTimeInterval(timeout)
    let lower = needle.lowercased()
    while Date() < deadline {
        guard let current = pidForBundleID(bundleID) else { usleep(10_000); continue }
        if windowTitles(pid: current).contains(where: { $0.lowercased().contains(lower) }) {
            return Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        }
        usleep(5_000)
    }
    return nil
}

// MARK: - Modes

var samples: [Double] = []
var failures = 0

func pathForRun(_ index: Int) -> String {
    file.replacingOccurrences(of: "%RUN%", with: String(index))
}

switch mode {
case "cold":
    for runIndex in 1...max(1, runs) {
        let target = pathForRun(runIndex)
        let needle = titleNeedle(forPath: target)
        terminateApp(bundleID: bundleID)
        usleep(300_000) // let WindowServer settle between launches
        let t0 = DispatchTime.now()
        runShell(openCommand.replacingOccurrences(of: "%FILE%", with: target))
        if waitForTitle(pid: pidForBundleID(bundleID) ?? 0, needle: needle, timeout: timeoutSec) != nil {
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9)
        } else {
            failures += 1
        }
        usleep(500_000)
    }
case "warm":
    guard !decoy.isEmpty else {
        FileHandle.standardError.write("guibench: warm mode needs --decoy\n".data(using: .utf8)!)
        exit(2)
    }
    // Ensure a running instance with some window, so the warm path is real.
    if pidForBundleID(bundleID) == nil {
        runShell(openCommand.replacingOccurrences(of: "%FILE%", with: decoy))
        _ = waitForTitle(pid: 0, needle: (decoy as NSString).lastPathComponent, timeout: timeoutSec)
        usleep(1_000_000)
    }
    for runIndex in 1...max(1, runs) {
        let target = pathForRun(runIndex)
        let needle = titleNeedle(forPath: target)
        // Move the title off the target basename with the decoy, then time
        // the real open.
        runShell(openCommand.replacingOccurrences(of: "%FILE%", with: decoy))
        _ = waitForTitle(pid: 0, needle: (decoy as NSString).lastPathComponent, timeout: timeoutSec)
        usleep(400_000)
        let command = openCommand.replacingOccurrences(of: "%FILE%", with: target)
        let t0 = DispatchTime.now()
        runShell(command)
        if waitForTitle(pid: 0, needle: needle, timeout: timeoutSec) != nil {
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9)
        } else {
            failures += 1
        }
    }
default:
    FileHandle.standardError.write("guibench: mode must be cold or warm\n".data(using: .utf8)!)
    exit(2)
}

guard !samples.isEmpty else {
    FileHandle.standardError.write("guibench: every run failed (timeout \(timeoutSec)s, needle \(basename))\n".data(using: .utf8)!)
    exit(1)
}
samples.sort()
let median = samples.count % 2 == 1
    ? samples[samples.count / 2]
    : (samples[samples.count / 2 - 1] + samples[samples.count / 2]) / 2
var out = "mode=\(mode)\nruns=\(runs)\nok=\(samples.count)\nfailed=\(failures)\n"
out += String(format: "median=%.6f\np90=%.6f\nmin=%.6f\nmax=%.6f\n",
              median,
              samples[min(samples.count - 1, Int((Double(samples.count - 1) * 0.9).rounded()))],
              samples.first!, samples.last!)
out += samples.map { String(format: "sample=%.6f", $0) }.joined(separator: "\n") + "\n"
FileHandle.standardOutput.write(out.data(using: .utf8)!)
