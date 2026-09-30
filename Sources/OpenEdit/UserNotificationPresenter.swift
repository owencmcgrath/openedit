import Foundation
import UserNotifications
import OpenEditLSP

/// The app's `UserNotifications` edge for ARCHITECTURE.md 5.6. Owns the
/// `UNUserNotificationCenter` delegate, registers the "Don't show again" action,
/// and posts the missing-LSP notice. All policy lives in `MissingLSPNotifier`;
/// this type only moves bytes.
///
/// Bare `swift run` executables have no bundle identifier, and
/// `UNUserNotificationCenter` is unusable there; when unbundled the presenter
/// degrades to a no-op so the file still opens and highlights. The bundled
/// `.app` (the normal distribution) has the identifier and posts normally.
final class UserNotificationPresenter: NSObject, NotificationPresenting, UNUserNotificationCenterDelegate {
    /// Called with the action identifier and the language ID from a delivered
    /// notification response. Wired to `MissingLSPNotifier.handleAction`.
    var onAction: ((_ identifier: String, _ languageID: String?) -> Void)?

    private lazy var center = UNUserNotificationCenter.current()
    private let isBundled: Bool

    override init() {
        isBundled = Bundle.main.bundleIdentifier != nil
        super.init()
    }

    func configure() {
        guard isBundled else { return }
        let dontShowAgain = UNNotificationAction(
            identifier: MissingLSPNotifier.dontShowAgainActionIdentifier,
            title: "Don't show again",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: MissingLSPNotifier.categoryIdentifier,
            actions: [dontShowAgain],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        center.delegate = self
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard isBundled else {
            completion(false)
            return
        }
        // The OS only ever prompts once per install; a later call after a denial
        // returns `granted == false` without prompting again.
        center.requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func present(notice: MissingLSPNotice, languageID: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = MissingLSPNotifier.categoryIdentifier
        content.userInfo = [MissingLSPNotifier.languageIDUserInfoKey: languageID]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// The app is active when a file is opened, and would otherwise swallow the
    /// notice; present it as a banner anyway.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let languageID = response.notification.request.content
            .userInfo[MissingLSPNotifier.languageIDUserInfoKey] as? String
        onAction?(response.actionIdentifier, languageID)
        completionHandler()
    }
}
