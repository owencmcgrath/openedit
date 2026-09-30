import Foundation
import OpenEditConfig

/// Decides and posts #7's missing-LSP notice for one document open
/// (ARCHITECTURE.md 5.6).
///
/// One call per open event, with the availability result also handed to #6, so
/// the two consumers cannot disagree or double-act on the same open. The class
/// holds only policy: locating executables is `LanguageServerLocator`, the
/// `UserNotifications` edge is `NotificationPresenting`, and persistence is
/// `MissingLSPSuppressionStore`.
public final class MissingLSPNotifier {
    /// Identifier of the notification action that silences a language. An
    /// ordinary dismissal (clicking the body) does *not* use this, so it never
    /// suppresses future notices.
    public static let dontShowAgainActionIdentifier = "OPENEDIT_MISSING_LSP_DONT_SHOW_AGAIN"

    /// Identifier of the notification category carrying the action above.
    public static let categoryIdentifier = "OPENEDIT_MISSING_LANGUAGE_SERVER"

    /// `userInfo` key under which the language ID travels with the notification.
    public static let languageIDUserInfoKey = "languageID"

    private let suppressionStore: MissingLSPSuppressionStore
    private let presenter: NotificationPresenting

    public init(
        suppressionStore: MissingLSPSuppressionStore,
        presenter: NotificationPresenting
    ) {
        self.suppressionStore = suppressionStore
        self.presenter = presenter
    }

    /// Request authorization at first launch (ARCHITECTURE.md 5.6). Denial does
    /// not block anything; it only means notices never appear.
    public func start() {
        presenter.configure()
        presenter.requestAuthorization { _ in }
    }

    /// Handle one file-open event. `availability` is the result #6 also
    /// consumes; only `.missing` can produce a notice, and only once per open.
    ///
    /// Never blocks: authorization may resolve asynchronously, long after the
    /// document is already open and editable.
    public func handleDocumentOpen(
        language: ResolvedLanguage,
        availability: LanguageServerAvailability
    ) {
        guard case .missing = availability else { return }
        guard !suppressionStore.isSuppressed(languageID: language.languageID) else { return }

        let notice = MissingLSPNotice(language: language)
        presenter.requestAuthorization { [weak self] granted in
            guard let self, granted else { return }
            // Re-check suppression: the user may have chosen "Don't show again"
            // between the request and the grant. One open, at most one notice.
            guard !self.suppressionStore.isSuppressed(languageID: language.languageID) else { return }
            self.presenter.present(notice: notice, languageID: language.languageID)
        }
    }

    /// Route a delivered notification response. Only the explicit
    /// "Don't show again" action persists a suppression.
    public func handleAction(identifier: String, languageID: String?) {
        guard identifier == Self.dontShowAgainActionIdentifier, let languageID else { return }
        suppressionStore.suppress(languageID: languageID)
    }
}
