import Foundation

/// Watches a single file path for external writes and fires a callback on the
/// main queue. Uses a DispatchSource on the file's inode, which catches both
/// in-place writes (.write/.extend) and atomic save-replaces, where a new file
/// is renamed over the old one and the watched inode is unlinked (.delete).
/// See ARCHITECTURE.md 5.3.
final class FileChangeWatcher {
    private let path: String
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// (Re)arm the watch. Must be called again after every change, because an
    /// atomic replace leaves the source pointed at the replaced (now unlinked)
    /// inode.
    func start() {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.deliverChange()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func deliverChange() {
        // Whether the path is occupied again (rename-over replace) or gone
        // for good (external delete), the document decides what to do; the
        // watcher's only job is to report that *something* happened at the
        // path and make sure the next event lands on a live inode.
        onChange()
        start()
    }
}
