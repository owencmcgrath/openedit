import Foundation

/// Seam between the notification policy and `UserNotifications`, so the policy
/// (authorization denied vs. granted, exact text, suppression) is testable
/// without posting real notifications. The app target provides the concrete
/// `UNUserNotificationCenter` implementation; tests provide a spy.
public protocol NotificationPresenting: AnyObject {
    /// Register the "Don't show again" action/category and become the center's
    /// delegate. Safe to call more than once.
    func configure()

    /// Request authorization, reporting whether notifications may be shown.
    /// Must never block the caller: the completion may arrive later, off the
    /// main thread.
    func requestAuthorization(completion: @escaping (Bool) -> Void)

    /// Post `notice`, tagging it with `languageID` so the "Don't show again"
    /// action can be attributed back to the language.
    func present(notice: MissingLSPNotice, languageID: String)
}
