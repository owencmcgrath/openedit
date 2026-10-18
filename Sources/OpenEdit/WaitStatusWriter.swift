import Foundation

/// Writes the JSON status file the CLI's `--wait` mode polls (ARCHITECTURE.md
/// 5.1, #46). The shim owns creation and polling; the app only replaces the
/// file atomically as the document changes state.
enum WaitStatusWriter {
    static func write(state: String, path: String?, to url: URL) {
        var object: [String: String] = ["state": state]
        if let path {
            object["path"] = path
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
