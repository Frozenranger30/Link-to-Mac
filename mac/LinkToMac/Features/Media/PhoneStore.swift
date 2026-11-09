import AppKit
import Foundation

/// Battery/network status (F2), now-playing info (F11) and "find my phone" (F10).
final class PhoneStore: ObservableObject {
    @Published private(set) var status: StatusBody?
    @Published private(set) var media: MediaStateBody?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var ringing = false

    private let connection: ConnectionManager

    init(connection: ConnectionManager) {
        self.connection = connection
        connection.on(MsgType.statusUpdate) { [weak self] msg in
            guard let self, let s = try? msg.body(StatusBody.self) else { return }
            self.status = s
        }
        connection.on(MsgType.mediaState) { [weak self] msg in
            guard let self, let m = try? msg.body(MediaStateBody.self) else { return }
            if let art = m.artPng, let img = NSImage(base64: art) {
                self.artwork = img
            } else if m.title != self.media?.title {
                self.artwork = nil
            }
            self.media = m
        }
        connection.onDisconnected { [weak self] in
            self?.media = nil
            self?.ringing = false
        }
    }

    func mediaAction(_ action: String) {
        connection.send(MsgType.mediaAction, MediaActionBody(action: action))
    }

    func ring() {
        connection.send(MsgType.findRing)
        ringing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.ringing = false }
    }

    func stopRing() {
        connection.send(MsgType.findStop)
        ringing = false
    }

    var batterySymbol: String {
        guard let s = status, s.battery >= 0 else { return "battery.0" }
        if s.charging { return "battery.100.bolt" }
        switch s.battery {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    var wifiSymbol: String {
        guard let s = status else { return "wifi.slash" }
        return s.network == "wifi" ? "wifi" : "wifi.slash"
    }
}
