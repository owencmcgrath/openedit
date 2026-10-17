import Foundation

/// Watches a single file path for external writes and fires a callback on the
/// main queue. Uses a DispatchSource on the file's inode, which catches both
/// in-place writes (.write/.extend) and atomic save-replaces, where a new file
/// is renamed over the old one and the watched inode is unlinked (.delete).
/// See ARCHITECTURE.md 5.3.
final class FileChangeWatcher {
    private let path: String
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var pendingDebounce: DispatchWorkItem?

    init(
        path: String,
        debounceInterval: TimeInterval = 0,
        onChange: @escaping () -> Void
    ) {
        self.path = path
        self.debounceInterval = max(0, debounceInterval)
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
        pendingDebounce?.cancel()
        pendingDebounce = nil
        source?.cancel()
        source = nil
    }

    private func deliverChange() {
        // Whether the path is occupied again (rename-over replace) or gone
        // for good (external delete), the document decides what to do; the
        // watcher's only job is to report that *something* happened at the
        // path and make sure the next event lands on a live inode.
        //
        // Re-arm immediately so a burst of writes (an atomic-replace save
        // plus a follow-up write) keeps landing on a live inode; the debounce
        // only coalesces the callbacks, it never drops the watch.
        start()
        pendingDebounce?.cancel()
        guard debounceInterval > 0 else {
            onChange()
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingDebounce = nil
            self?.onChange()
        }
        pendingDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
