import Foundation

/// Cmd-Shift-T-style last-closed stack for `--reopen` (ARCHITECTURE.md 5.1).
///
/// Only file-backed, non-scratch documents are recorded; untitled windows have
/// no path to restore. The stack is capped and de-duplicated so re-closing a
/// file moves it to the top rather than growing the list forever.
final class ReopenStore {
    static let shared = ReopenStore()

    static let defaultsKey = "reopen.lastClosed"
    static let limit = 20

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastClosedPaths: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func record(fileURL: URL) {
        let path = fileURL.standardizedFileURL.path
        var paths = lastClosedPaths.filter { $0 != path }
        paths.append(path)
        if paths.count > Self.limit {
            paths.removeFirst(paths.count - Self.limit)
        }
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    /// Pop and return the newest path that still exists as a regular file.
    func popLastClosed() -> URL? {
        var paths = lastClosedPaths
        while let path = paths.popLast() {
            defaults.set(paths, forKey: Self.defaultsKey)
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue
            {
                return url
            }
        }
        return nil
    }
}
