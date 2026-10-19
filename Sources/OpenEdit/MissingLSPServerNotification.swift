import Foundation
import OpenEditConfig
import OpenEditLSP

/// App-wide seam over the missing-LSP notifier (ARCHITECTURE.md 5.6). Owns the
/// process's one `MissingLSPNotifier`, backed by `UserDefaults` and the real
/// `UNUserNotificationCenter`, and resolves a document's language server once
/// per open so #7 and #6 share a single availability result.
enum MissingLSPServerNotification {
    static let shared: MissingLSPNotifier = {
        let presenter = UserNotificationPresenter()
        let notifier = MissingLSPNotifier(
            suppressionStore: MissingLSPSuppressionStore(),
            presenter: presenter
        )
        presenter.onAction = { [weak notifier] identifier, languageID in
            notifier?.handleAction(identifier: identifier, languageID: languageID)
        }
        return notifier
    }()
}
