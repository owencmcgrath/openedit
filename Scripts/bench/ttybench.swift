// ttybench.swift — time-to-rendered benchmark for terminal editors (issue #38).
//
// Spawns a TUI editor on a fresh pseudo-terminal, watches the master side of
// the pty, and stamps the moment the editor has actually painted the
// benchmark file's content (matched by a known byte prefix of the file, so
// "opened" means "content visible", not "process started"). A configurable
// quit keystroke sequence then closes the editor; a run that does not exit
// gets SIGTERM and is flagged as assisted.
//
// This is the terminal-editor counterpart of the GUI harness's
// time-to-interactive window check: both measure first content paint, which
// makes the CLI and GUI tables comparable in a way a bare open-and-quit
// timing is not.
//
// Usage:
//   ttybench --file <path> --runs N [--timeout-sec S] [--term TERM] \
//            --quit "key-seq" -- <command> [args...]
//
// Key sequence escapes: \e = ESC, \r = CR, \n = LF, \xHH = hex byte.
// A "\;" inside the sequence inserts a 60 ms pause between key groups.

import Foundation
import Darwin

// MARK: - Argument parsing

var file = ""
var runs = 10
var timeoutSec = 30.0
var term = "xterm-256color"
var quitSeq = ""
var initSeq = ""
var dumpPath = ""
var cmd: [String] = []

var it = CommandLine.arguments.dropFirst().makeIterator()
while let arg = it.next() {
    switch arg {
    case "--file": file = it.next() ?? ""
    case "--runs": runs = Int(it.next() ?? "10") ?? 10
    case "--timeout-sec": timeoutSec = Double(it.next() ?? "30") ?? 30
    case "--term": term = it.next() ?? term
    case "--quit": quitSeq = it.next() ?? ""
    case "--init": initSeq = it.next() ?? ""
    case "--dump": dumpPath = it.next() ?? ""
    case "--": cmd = Array(it); break
    default: break
    }
}
guard !file.isEmpty, !cmd.isEmpty, FileManager.default.fileExists(atPath: file) else {
    FileHandle.standardError.write("ttybench: --file and -- <command> required\n".data(using: .utf8)!)
    exit(2)
}

// The needle the editor must paint: the first 24 bytes of the file's first
// line. Random alphanumeric corpus bytes never collide with escape sequences.
let fileData = FileManager.default.contents(atPath: file)!
let head = fileData.prefix(24)
let needle = Array(head)

func decodeKeys(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    let chars = Array(s.utf8)
    var i = 0
    while i < chars.count {
        if chars[i] == 0x5C, i + 1 < chars.count { // backslash
            switch chars[i + 1] {
            case UInt8(ascii: "e"): out.append(0x1B); i += 2
            case UInt8(ascii: "r"): out.append(0x0D); i += 2
            case UInt8(ascii: "n"): out.append(0x0A); i += 2
            case UInt8(ascii: "t"): out.append(0x09); i += 2
            case UInt8(ascii: "x"):
                if i + 3 < chars.count,
                   let hi = UInt8(String(UnicodeScalar(chars[i + 2])), radix: 16),
                   let lo = UInt8(String(UnicodeScalar(chars[i + 3])), radix: 16) {
                    out.append(hi << 4 | lo); i += 4
                } else { out.append(chars[i]); i += 1 }
            case UInt8(ascii: ";"): // "\;" = 60ms pause
                out.append(0xFE); i += 2 // placeholder for pause
            default: out.append(chars[i]); i += 1
            }
        } else {
            out.append(chars[i]); i += 1
        }
    }
    return out
}
let quitBytes = decodeKeys(quitSeq)

// MARK: - pty plumbing

func openptyPair(rows: UInt16 = 40, cols: UInt16 = 132) -> (Int32, Int32)? {
    var master: Int32 = 0
    var slave: Int32 = 0
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &ws) == 0 else { return nil }
    return (master, slave)
}

func nonblocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

/// One timed run. Returns seconds from spawn until `needle` was painted, or nil on timeout/failure.
func timedRun() -> Double? {
    guard let (master, slave) = openptyPair() else { return nil }
    defer { close(master) }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: cmd[0])
    proc.arguments = Array(cmd.dropFirst())
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = term
    env["LC_ALL"] = "en_US.UTF-8"
    env.removeValue(forKey: "VIM") // keep --clean runs clean
    proc.environment = env
    let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    proc.standardInput = slaveHandle
    proc.standardOutput = slaveHandle
    proc.standardError = slaveHandle

    do { try proc.run() } catch { close(slave); return nil }
    let pid = proc.processIdentifier
    close(slave) // the child holds its own descriptors now

    nonblocking(master)
    let t0 = DispatchTime.now()
    var matched = false
    var raw: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    let deadline = Date().addingTimeInterval(timeoutSec)
    var responder = TerminalQueryResponder()
    // One-shot pre-open keystrokes (e.g. answering a first-run prompt); sent
    // shortly after spawn so they land before the editor reads input.
    let initBytes: [UInt8] = decodeKeys(initSeq)
    var initSent = false
    defer {
        if !dumpPath.isEmpty { try? Data(raw).write(to: URL(fileURLWithPath: dumpPath)) }
    }

    while !matched && Date() < deadline {
        if !initSent, !initBytes.isEmpty,
           Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) > 0.4 {
            _ = write(master, initBytes, initBytes.count)
            initSent = true
        }
        let n = read(master, &buf, buf.count)
        if n > 0 {
            raw.append(contentsOf: buf[0..<n])
            if raw.count > 16384 { raw.removeFirst(raw.count - 16384) }
            // Editors (vim, emacs, ...) query the terminal at startup (DSR,
            // DA) and block until an answer arrives; a pty with no responder
            // would leave them hanging and poison the measurement. Answer
            // like a minimal terminal would.
            let responses = responder.consume(Array(buf[0..<n]))
            for response in responses {
                _ = write(master, response, response.count)
            }
            // The editor paints through ANSI escape sequences; strip them and
            // match on the visible text so interleaved color/cursor codes do
            // not break a contiguous-content check.
            if containsVisible(ANSIStripper.strip(raw), needle: needle) { matched = true; break }
        } else {
            usleep(2000)
        }
    }
    guard matched else {
        kill(pid, SIGKILL)
        var st: Int32 = 0
        waitpid(pid, &st, 0)
        return nil
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9

    // Quit the editor.
    var chunk: [UInt8] = []
    for b in quitBytes {
        if b == 0xFE {
            _ = write(master, chunk, chunk.count); chunk.removeAll(); usleep(60_000)
        } else {
            chunk.append(b)
        }
    }
    if !chunk.isEmpty { _ = write(master, chunk, chunk.count) }

    // Wait for exit; escalate if the quit keys did not land.
    let softDeadline = Date().addingTimeInterval(3)
    while proc.isRunning {
        if Date() > softDeadline { kill(pid, SIGTERM); break }
        usleep(10_000)
    }
    let hardDeadline = Date().addingTimeInterval(2)
    while proc.isRunning {
        if Date() > hardDeadline { kill(pid, SIGKILL); break }
        usleep(10_000)
    }
    proc.waitUntilExit()
    return elapsed
}

/// True if `haystack` contains `needle` as a contiguous run of printable text.
func containsVisible(_ haystack: [UInt8], needle: [UInt8]) -> Bool {
    guard !needle.isEmpty else { return false }
    var hi = 0
    for b in haystack {
        if b == needle[hi] {
            hi += 1
            if hi == needle.count { return true }
        } else {
            hi = (b == needle[0]) ? 1 : 0
        }
    }
    return false
}

/// Strip ANSI escape sequences (CSI/OSC/2-byte) and control bytes, keeping
/// printable ASCII + newlines, so TUI output can be matched as visible text.
enum ANSIStripper {
    enum State { case normal, escape, csi, osc, oscEscape }

    static func strip(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var state = State.normal
        for b in bytes {
            switch state {
            case .normal:
                if b == 0x1B { state = .escape }
                else if b == 0x0A || (b >= 0x20 && b != 0x7F) { out.append(b) }
            case .escape:
                if b == 0x5B { state = .csi }        // '['
                else if b == 0x5D { state = .osc }   // ']'
                else if b >= 0x20 && b <= 0x2F { state = .escape } // intermediate
                else { state = .normal }
            case .csi:
                if b >= 0x40 && b <= 0x7E { state = .normal }      // final byte
            case .osc:
                if b == 0x07 { state = .normal }
                else if b == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = (b == 0x5C) ? .normal : .osc                // ST = ESC '\'
            }
        }
        return out
    }
}

/// Answers the startup queries editors send a real terminal (a pty with no
/// responder can leave vim/emacs blocked mid-paint, which silently inflates
/// every sample or times runs out entirely).
struct TerminalQueryResponder {
    private var state = ANSIStripper.State.normal
    private var csiBody: [UInt8] = []
    private var oscBody: [UInt8] = []
    private var awaitingOSCTerminator = false

    /// Feed output bytes; returns canned responses to append to the pty master.
    mutating func consume(_ bytes: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for b in bytes {
            switch state {
            case .normal:
                if b == 0x1B { state = .escape; csiBody = []; oscBody = [] }
            case .escape:
                switch b {
                case 0x5B: state = .csi
                case 0x5D: state = .osc; awaitingOSCTerminator = false
                case 0x50: state = .osc // DCS (XTGETTCAP etc.)
                case 0x20...0x2F: break // intermediate byte, stay
                default: state = .normal
                }
            case .csi:
                if b >= 0x40 && b <= 0x7E {
                    // Final byte: classify the complete CSI sequence.
                    let response = Self.respondCSI(csiBody, final: b)
                    if let response { out.append(response) }
                    state = .normal
                } else {
                    csiBody.append(b)
                }
            case .osc:
                if b == 0x07 { state = .normal }
                else if b == 0x1B { state = .oscEscape }
                else { oscBody.append(b) }
            case .oscEscape:
                state = (b == 0x5C) ? .normal : .osc
            }
        }
        return out
    }

    private static func respondCSI(_ body: [UInt8], final: UInt8) -> [UInt8]? {
        let text = String(decoding: body, as: UTF8.self)
        switch (body.isEmpty ? "" : text, final) {
        case (_, 0x6E): // 'n' — device status report variants
            if body.isEmpty || text == "6" { return Array("[1;1R".utf8) }
            if text == "5" { return Array("[0n".utf8) }
            if text.hasPrefix("?6") { return Array("[99;1;1;0R".utf8) }
            return Array("[0n".utf8)
        case ("", 0x63): // CSI c — primary DA
            return Array("[?1;2c".utf8)
        case (_, 0x63): // CSI > c / = c — secondary/tertiary DA
            if text.hasPrefix(">") { return Array("[>0;277;0c".utf8) }
            if text.hasPrefix("=") { return Array("\u{1b}P!|00000000\u{1b}\\".utf8) }
            return Array("[?1;2c".utf8)
        case (_, 0x70): // 'p' — DECRQM (e.g. kakoune's CSI ? 2026 $ p)
            guard text.hasSuffix("$") else { return nil }
            let mode = String(text.dropLast(1))
            // "not recognized" for every mode: editors fall back to plain
            // painting, which is exactly what the harness wants to observe.
            return Array("[?\(mode);2$y".utf8)
        case (_, 0x75): // 'u' — kitty keyboard protocol query CSI ? u
            if text.hasPrefix("?") { return Array("[?0u".utf8) }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Run and report

var samples: [Double] = []
var failures = 0
for _ in 0..<runs {
    if let t = timedRun() { samples.append(t) } else { failures += 1 }
}
guard !samples.isEmpty else {
    FileHandle.standardError.write("ttybench: every run failed\n".data(using: .utf8)!)
    exit(1)
}
samples.sort()
func pct(_ p: Double) -> Double {
    let frac = (p / 100) * Double(samples.count - 1)
    let idx = min(samples.count - 1, max(0, Int(frac.rounded())))
    return samples[idx]
}
let median = samples.count % 2 == 1
    ? samples[samples.count / 2]
    : (samples[samples.count / 2 - 1] + samples[samples.count / 2]) / 2

var out = "runs=\(runs)\nok=\(samples.count)\nfailed=\(failures)\n"
out += String(format: "median=%.6f\np90=%.6f\nmin=%.6f\nmax=%.6f\n", median, pct(90), samples.first!, samples.last!)
out += samples.map { String(format: "sample=%.6f", $0) }.joined(separator: "\n") + "\n"
FileHandle.standardOutput.write(out.data(using: .utf8)!)
