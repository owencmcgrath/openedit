import Foundation
import os

/// Open-path instrumentation for issue #38's benchmark harness.
///
/// Two mechanisms, both zero-cost when not benchmarking:
///
/// 1. `os_signpost` spans (subsystem com.openedit.app, category "open") so
///    Instruments can show the read → text-set → highlight → first-paint
///    pipeline inside the process.
/// 2. A marker file: when `OPENEDIT_BENCH_MARKER` names a writable path, each
///    document's first paint appends one line
///      `<paintWallMS>\t<readMS>\t<setTextMS>\t<highlightMS>\t<path>`
///    The external GUI harness stamps its own clock (same epoch) just before
///    `open`, so subtracting t0 from paintWallMS gives an OpenEdit-internal
///    readiness measurement independent of Accessibility polling — the
///    "editor-specific readiness signal" the issue's methodology allows.
enum OpenSignposts {
    static let signposter = OSSignposter(subsystem: "com.openedit.app", category: "open")

    /// Marker path from the environment; empty when not benchmarking.
    static let markerPath: String? = ProcessInfo.processInfo.environment["OPENEDIT_BENCH_MARKER"]

    /// Wall-clock milliseconds since the Unix epoch (same clock the harness stamps).
    static func wallNowMS() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    /// Append one marker line. Never throws; benchmarking only.
    static func writeMarker(paintWallMS: Double, readMS: Double, setTextMS: Double, highlightMS: Double, path: String) {
        guard let markerPath else { return }
        let line = String(
            format: "%.0f\t%.0f\t%.0f\t%.0f\t%@\n",
            paintWallMS, readMS, setTextMS, highlightMS, path
        )
        if let handle = FileHandle(forWritingAtPath: markerPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(line.data(using: .utf8)!)
        } else {
            try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: markerPath))
        }
    }
}
