import AppKit
import Foundation

/// Clipboard sync (F7): polls NSPasteboard.changeCount every 0.5 s and sends changes to the phone.
final class ClipboardSync: ObservableObject {
    @Published private(set) var lastSent: Date?
    @Published private(set) var lastReceived: Date?

    private let connection: ConnectionManager
    private let settings: AppSettings
    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private let maxImageBytes = 4 * 1024 * 1024

    init(connection: ConnectionManager, settings: AppSettings) {
        self.connection = connection
        self.settings = settings
        connection.on(MsgType.clipboardSet) { [weak self] msg in
            guard let self, let body = try? msg.body(ClipboardSetBody.self) else { return }
            self.apply(body)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        guard settings.clipboardSync, settings.feature("clipboard"), connection.isConnected else { return }
        // Respect password managers that mark their entries as concealed/transient.
        let types = pb.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) {
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            connection.send(MsgType.clipboardSet, ClipboardSetBody(mime: "text/plain", text: text))
            lastSent = Date()
        } else if let image = NSImage(pasteboard: pb), let png = image.pngData(), png.count <= maxImageBytes {
            connection.send(MsgType.clipboardSet, ClipboardSetBody(mime: "image/png", dataBase64: png.base64EncodedString()))
            lastSent = Date()
        }
    }

    private func apply(_ body: ClipboardSetBody) {
        guard settings.clipboardSync else { return }
        let pb = NSPasteboard.general
        if body.mime.hasPrefix("text"), let text = body.text {
            pb.clearContents()
            pb.setString(text, forType: .string)
        } else if body.mime.hasPrefix("image"), let b64 = body.dataBase64, let data = Data(base64Encoded: b64) {
            pb.clearContents()
            pb.setData(data, forType: .png)
        } else {
            return
        }
        changeCount = pb.changeCount // don't echo back
        lastReceived = Date()
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
