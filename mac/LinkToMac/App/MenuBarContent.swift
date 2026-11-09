import SwiftUI
import UniformTypeIdentifiers

struct MenuBarLabel: View {
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var phone: PhoneStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: connection.isConnected ? "laptopcomputer.and.iphone" : "laptopcomputer.slash")
            if connection.isConnected, let b = phone.status?.battery, b >= 0 {
                Text("\(b)%")
            }
        }
    }
}

/// Window-style menu bar panel with status, quick actions and a drop zone.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var phone: PhoneStore
    @EnvironmentObject var files: FileTransferService
    @EnvironmentObject var mirror: MirrorController
    @Environment(\.openWindow) private var openWindow
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeader()
            Divider()
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.up")
                Text("Dateien hierher ziehen").font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5)))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                FileDrop.load(providers) { files.send(urls: $0) }
                return true
            }
            .opacity(connection.isConnected ? 1 : 0.4)

            if let active = files.transfers.first(where: { $0.state == .running }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.name).font(.caption).lineLimit(1)
                    ProgressView(value: active.fraction)
                }
            }

            Group {
                MenuButton(title: String(localized: "Handy klingeln lassen"), symbol: "speaker.wave.3") { phone.ring() }
                MenuButton(title: String(localized: "Bildschirm spiegeln"), symbol: "iphone.gen3") {
                    openWindow(id: "mirror")
                    NSApp.activate(ignoringOtherApps: true)
                    if mirror.state == .idle { mirror.start() }
                }
            }
            .disabled(!connection.isConnected)
            MenuButton(title: String(localized: "Link to Mac öffnen"), symbol: "macwindow") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            MenuButton(title: String(localized: "Beenden"), symbol: "power") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct MenuButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }
}
