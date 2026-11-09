import AppKit
import Foundation
import UserNotifications

/// Detects one-time codes (2FA) in notification/SMS text.
enum OneTimeCode {
    private static let keywords = ["code", "pin", "otp", "tan", "passcode", "passwort", "password", "bestätigung", "verification",
                                   "verifizierung", "sicherheits", "security", "login", "anmelde", "kennwort", "einmal"]

    static func find(in text: String) -> String? {
        let lower = text.lowercased()
        guard keywords.contains(where: { lower.contains($0) }) else { return nil }
        let pattern = "(?<![0-9])([0-9]{3}[ -]?[0-9]{3}|[0-9]{4,8})(?![0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let code = text[r].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            // Skip things that look like years.
            if code.count == 4, let n = Int(code), (1900...2100).contains(n) { continue }
            return code
        }
        return nil
    }
}

/// Mirrors phone notifications into macOS Notification Center (F3).
final class NotificationsStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var items: [NotificationPostedBody] = []
    @Published private(set) var authorized = false

    private let connection: ConnectionManager
    private let settings: AppSettings
    private var icons: [String: NSImage] = [:]
    private var categories: [String: UNNotificationCategory] = [:]
    private let center = UNUserNotificationCenter.current()
    var onOpen: ((String) -> Void)?

    private static let callCategory = "call"

    init(connection: ConnectionManager, settings: AppSettings) {
        self.connection = connection
        self.settings = settings
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { self.authorized = granted }
        }
        loadIconCache()

        connection.on(MsgType.notificationPosted) { [weak self] msg in
            guard let self, let n = try? msg.body(NotificationPostedBody.self) else { return }
            self.posted(n)
        }
        connection.on(MsgType.notificationRemoved) { [weak self] msg in
            guard let self, let k = try? msg.body(NotificationKeyBody.self) else { return }
            self.removedOnPhone(k.key)
        }
        connection.onConnected { [weak self] in
            // The phone resends everything that is currently visible.
            self?.items.removeAll()
        }
    }

    func icon(for app: String) -> NSImage? { icons[app] }

    // MARK: Incoming

    private func posted(_ n: NotificationPostedBody) {
        if let png = n.appIconPng, let data = Data(base64Encoded: png), let image = NSImage(data: data) {
            icons[n.app] = image
            try? data.write(to: iconURL(n.app))
        }
        if settings.knownApps[n.app] != n.appName { settings.knownApps[n.app] = n.appName }
        var stored = n
        stored.appIconPng = nil
        items.removeAll { $0.key == n.key }
        items.insert(stored, at: 0)
        if items.count > 300 { items.removeLast(items.count - 300) }

        guard settings.showNotifications, !settings.mutedApps.contains(n.app) else { return }
        deliver(stored)
    }

    private func deliver(_ n: NotificationPostedBody) {
        let content = UNMutableNotificationContent()
        content.title = n.title.isEmpty ? n.appName : n.title
        content.subtitle = n.title.isEmpty ? "" : n.appName
        content.body = n.text
        content.threadIdentifier = n.app
        content.sound = .default
        var info: [String: Any] = ["key": n.key, "app": n.app]
        let code = OneTimeCode.find(in: n.title + " " + n.text)
        if let code { info["code"] = code }
        content.userInfo = info
        content.categoryIdentifier = category(for: n, code: code)
        if let url = iconFileURL(n.app), let attachment = try? UNNotificationAttachment(identifier: "icon", url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: Self.identifier(n.key), content: content, trigger: nil)
        center.add(request)
    }

    private func category(for n: NotificationPostedBody, code: String?) -> String {
        let id = "n-" + String((n.actions.map { "\($0.title)\($0.isReply)" }.joined(separator: "|") + (code ?? "")).hashValue, radix: 36)
        if categories[id] == nil {
            var actions: [UNNotificationAction] = []
            if let code {
                actions.append(UNNotificationAction(identifier: "copycode", title: String(localized: "Code \(code) kopieren"), options: []))
            }
            for (i, a) in n.actions.enumerated() {
                if a.isReply {
                    actions.append(UNTextInputNotificationAction(
                        identifier: "a\(i)", title: a.title, options: [],
                        textInputButtonTitle: String(localized: "Senden"),
                        textInputPlaceholder: String(localized: "Antwort …")))
                } else {
                    actions.append(UNNotificationAction(identifier: "a\(i)", title: a.title, options: []))
                }
            }
            categories[id] = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [.customDismissAction])
            center.setNotificationCategories(Set(categories.values))
        }
        return id
    }

    private func removedOnPhone(_ key: String) {
        items.removeAll { $0.key == key }
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(key)])
    }

    // MARK: Actions from the Mac

    func dismiss(_ key: String) {
        items.removeAll { $0.key == key }
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(key)])
        connection.send(MsgType.notificationRemoved, NotificationKeyBody(key: key))
    }

    func clearAll() {
        items.removeAll()
        center.removeAllDeliveredNotifications()
        connection.send(MsgType.notificationClearAll)
    }

    func perform(_ key: String, actionIndex: Int, reply: String?) {
        connection.send(MsgType.notificationAction, NotificationActionBody(key: key, actionIndex: actionIndex, replyText: reply))
    }

    /// Generic local notification (file received, errors, …).
    func local(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let key = info["key"] as? String
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case UNNotificationDismissActionIdentifier:
                if let key { self.dismiss(key) }
            case UNNotificationDefaultActionIdentifier:
                self.onOpen?(key ?? "")
            case "copycode":
                if let code = info["code"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            default:
                if let key, response.actionIdentifier.hasPrefix("a"), let idx = Int(response.actionIdentifier.dropFirst()) {
                    let text = (response as? UNTextInputNotificationResponse)?.userText
                    self.perform(key, actionIndex: idx, reply: text)
                }
            }
            completionHandler()
        }
    }

    // MARK: Icon cache

    static func identifier(_ key: String) -> String {
        "n:" + key
    }

    private var iconDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LinkToMac/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func iconURL(_ app: String) -> URL {
        iconDir.appendingPathComponent(app.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// Attachments are moved by the system, so we hand out a temporary copy.
    private func iconFileURL(_ app: String) -> URL? {
        let src = iconURL(app)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        return (try? FileManager.default.copyItem(at: src, to: tmp)) != nil ? tmp : nil
    }

    private func loadIconCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: iconDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "png" {
            if let img = NSImage(contentsOf: f) { icons[f.deletingPathExtension().lastPathComponent] = img }
        }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: iconDir)
        icons.removeAll()
    }
}
