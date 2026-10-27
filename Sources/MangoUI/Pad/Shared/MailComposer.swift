import Foundation
import BudgetCore
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif
#if canImport(MessageUI)
import MessageUI
#endif

/// Opens a prepared recharge email (step 10, Task 12) for the person to check and send: Mail's composer with the
/// recipients, subject, text and attachments filled in; the share sheet with the same text and files when Mail isn't set
/// up on this iPad (the share sheet can't fill the recipient). Nothing is sent from here, and nothing is marked: the
/// outcome goes back to `RechargeEmailFlow`, which only asks the person.
@MainActor
public enum MailComposer {
    public typealias Outcome = RechargeEmailFlow.Outcome

    public enum Route: Equatable, Sendable {
        case mail
        case shareSheet
    }

    /// Mail when it can send, else the share sheet.
    public static func route(canSendMail: Bool) -> Route { canSendMail ? .mail : .shareSheet }

    /// The share sheet's result as Mail's: Mail's own share completed is sent; another completed one (Files, another
    /// mail app) is saved, the person says whether it went; an error is failed; otherwise cancelled.
    public static func outcome(completed: Bool, isMail: Bool, failed: Bool) -> Outcome {
        if failed { return .failed }
        guard completed else { return .cancelled }
        return isMail ? .sent : .saved
    }

    /// Whether this device's Mail can compose a message.
    public static var canSendMail: Bool {
        #if canImport(MessageUI)
        MFMailComposeViewController.canSendMail()
        #else
        false
        #endif
    }

    #if canImport(UIKit)
    /// Presents `package` over the top-most screen, in Mail (or the share sheet when Mail can't send, or when `route`
    /// asks for it); `onFinished` gets how it ended.
    public static func present(package: RechargeEmailPackage, route: Route? = nil, onFinished: @escaping (Outcome) -> Void) {
        guard let top = topController() else { onFinished(.failed); return }
        switch route ?? self.route(canSendMail: canSendMail) {
        case .mail:
            #if canImport(MessageUI)
            if MFMailComposeViewController.canSendMail() {
                let composer = MFMailComposeViewController()
                composer.setToRecipients(package.to)
                composer.setSubject(package.subject)
                composer.setMessageBody(package.body, isHTML: false)
                for attachment in package.attachments {
                    guard let data = try? Data(contentsOf: attachment.url) else { continue }
                    composer.addAttachmentData(data, mimeType: mimeType(attachment.fileName), fileName: attachment.fileName)
                }
                let delegate = MailDelegate { outcome in
                    mailDelegate = nil
                    onFinished(outcome)
                }
                mailDelegate = delegate
                composer.mailComposeDelegate = delegate
                top.present(composer, animated: true)
                return
            }
            #endif
            presentShareSheet(package, over: top, onFinished: onFinished)
        case .shareSheet:
            presentShareSheet(package, over: top, onFinished: onFinished)
        }
    }

    private static var mailDelegate: MailDelegate?

    private static func presentShareSheet(_ package: RechargeEmailPackage, over top: UIViewController, onFinished: @escaping (Outcome) -> Void) {
        let items: [Any] = [EmailTextItem(subject: package.subject, body: package.body)] + package.attachments.map(\.url)
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { type, completed, _, error in
            onFinished(outcome(completed: completed, isMail: type == .mail, failed: error != nil))
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private static func mimeType(_ fileName: String) -> String {
        UTType(filenameExtension: (fileName as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
    #endif
}

#if canImport(UIKit)
/// The email's text for the share sheet, with its subject for apps that take one (Mail, other mail apps).
private final class EmailTextItem: NSObject, UIActivityItemSource {
    let subject: String
    let body: String

    init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { body }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        body
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        subject
    }
}
#endif

#if canImport(MessageUI)
/// Mail's result, mapped once, then the composer is closed.
private final class MailDelegate: NSObject, MFMailComposeViewControllerDelegate {
    let done: @MainActor (MailComposer.Outcome) -> Void

    init(done: @escaping @MainActor (MailComposer.Outcome) -> Void) {
        self.done = done
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        let outcome: MailComposer.Outcome = switch result {
        case .sent: .sent
        case .saved: .saved
        case .cancelled: .cancelled
        case .failed: .failed
        @unknown default: .failed
        }
        MainActor.assumeIsolated {
            controller.dismiss(animated: true)
            done(outcome)
        }
    }
}
#endif
