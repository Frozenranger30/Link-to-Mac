import AppKit
import Foundation

/// Creates and wires all services. Everything runs on the main thread.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings()
    let connection = ConnectionManager()
    let pairing = PairingService()
    let phone: PhoneStore
    let notifications: NotificationsStore
    let messages: MessagesStore
    let files: FileTransferService
    let photos: PhotosStore
    let calls: CallsStore
    let clipboard: ClipboardSync
    let mirror: MirrorController

    @Published var selection: SidebarItem? = .overview

    private init() {
        phone = PhoneStore(connection: connection)
        notifications = NotificationsStore(connection: connection, settings: settings)
        messages = MessagesStore(connection: connection)
        files = FileTransferService(connection: connection, settings: settings)
        photos = PhotosStore(connection: connection, files: files)
        calls = CallsStore(connection: connection, settings: settings)
        clipboard = ClipboardSync(connection: connection, settings: settings)
        mirror = MirrorController(connection: connection)

        pairing.onPaired = { [weak self] _ in
            self?.connection.pairedDeviceChanged()
        }
        connection.onConnected { [weak self] in
            self?.pushFeatures()
        }
        connection.on(MsgType.unpair) { [weak self] _ in
            self?.forgetDevice()
        }
        notifications.onOpen = { [weak self] _ in
            self?.selection = .notifications
            self?.showMainWindow()
        }
        files.onReceived = { [weak self] t in
            self?.notifications.local(title: String(localized: "Datei empfangen"), body: t.name)
        }
        connection.start()
    }

    func pushFeatures() {
        connection.send(MsgType.settingsUpdate, SettingsUpdateBody(features: settings.phoneFeatures))
    }

    func unpair() {
        connection.send(MsgType.unpair)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.forgetDevice() }
    }

    private func forgetDevice() {
        TrustStore.shared.pairedDevice = nil
        TrustStore.shared.resetIdentity()
        connection.pairedDeviceChanged()
        clearCaches()
    }

    func clearCaches() {
        messages.clearCache()
        photos.clearCache()
        notifications.clearCache()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
