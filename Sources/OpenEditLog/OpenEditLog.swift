import Foundation
import os

/// Severity for the app's small logging layer (ARCHITECTURE.md 5.1, #46).
public enum OpenEditLogLevel: Int, Comparable, CaseIterable, Sendable {
    case error = 0
    case warning = 1
    case info = 2
    case debug = 3

    public init?(name: String) {
        switch name.lowercased() {
        case "error", "err": self = .error
        case "warning", "warn": self = .warning
        case "info": self = .info
        case "debug": self = .debug
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .error: return "error"
        case .warning: return "warning"
        case .info: return "info"
        case .debug: return "debug"
        }
    }

    public static func < (lhs: OpenEditLogLevel, rhs: OpenEditLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Process-wide logger behind `--log-level`, `--log-file`, and `--debug`
/// (ARCHITECTURE.md 5.1). Always writes to OSLog under subsystem
/// `com.openedit.app`; an optional append-only file sink is added when the CLI
/// requests one. Runtime reconfiguration is deliberate so the flags can also
/// affect an already-running instance.
public final class OpenEditLog: @unchecked Sendable {
    public static let shared = OpenEditLog()

    public static let subsystem = "com.openedit.app"

    private let lock = NSLock()
    private var level: OpenEditLogLevel = .info
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var loggers: [String: Logger] = [:]

    private init() {}

    /// Apply the latest CLI logging request. Passing `nil` for `fileURL` leaves
    /// the existing sink alone; passing a different path switches to it. A
    /// level of `nil` leaves the current level alone.
    public func configure(level newLevel: OpenEditLogLevel?, fileURL newFileURL: URL?) {
        lock.lock()
        defer { lock.unlock() }

        if let newLevel {
            level = newLevel
        }

        if let newFileURL, newFileURL != fileURL {
            fileHandle?.closeFile()
            fileHandle = nil
            fileURL = nil

            let manager = FileManager.default
            if !manager.fileExists(atPath: newFileURL.path) {
                manager.createFile(atPath: newFileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: newFileURL) {
                handle.seekToEndOfFile()
                fileHandle = handle
                fileURL = newFileURL
            }
        }
    }

    public var currentLevel: OpenEditLogLevel {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    /// Strip an existing file sink (used by tests and by a `--no-*` reset).
    public func removeFileSink() {
        lock.lock()
        defer { lock.unlock() }
        fileHandle?.closeFile()
        fileHandle = nil
        fileURL = nil
    }

    public func log(
        _ messageLevel: OpenEditLogLevel,
        category: String,
        _ message: @autoclosure () -> String
    ) {
        let text = message()

        lock.lock()
        guard messageLevel <= level else {
            lock.unlock()
            return
        }
        let logger = loggers[category] ?? Logger(subsystem: Self.subsystem, category: category)
        loggers[category] = logger
        lock.unlock()

        switch messageLevel {
        case .error:
            logger.error("\(text, privacy: .public)")
        case .warning:
            logger.warning("\(text, privacy: .public)")
        case .info:
            logger.info("\(text, privacy: .public)")
        case .debug:
            logger.debug("\(text, privacy: .public)")
        }

        let line = "\(Self.timestamp()) [\(messageLevel.name.uppercased())] [\(category)] \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = fileHandle else { return }
        try? handle.write(contentsOf: data)
    }

    public func error(category: String, _ message: @autoclosure () -> String) {
        log(.error, category: category, message())
    }

    public func warning(category: String, _ message: @autoclosure () -> String) {
        log(.warning, category: category, message())
    }

    public func info(category: String, _ message: @autoclosure () -> String) {
        log(.info, category: category, message())
    }

    public func debug(category: String, _ message: @autoclosure () -> String) {
        log(.debug, category: category, message())
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
