import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case overview, messages, photos, calls, notifications, files, mirror, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return String(localized: "Übersicht")
        case .messages: return String(localized: "Nachrichten")
        case .photos: return String(localized: "Fotos")
        case .calls: return String(localized: "Anrufe")
        case .notifications: return String(localized: "Benachrichtigungen")
        case .files: return String(localized: "Dateien")
        case .mirror: return String(localized: "Handy-Bildschirm")
        case .settings: return String(localized: "Einstellungen")
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "house"
        case .messages: return "message"
        case .photos: return "photo.on.rectangle"
        case .calls: return "phone"
        case .notifications: return "bell"
        case .files: return "folder"
        case .mirror: return "iphone.gen3"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var messages: MessagesStore
    @EnvironmentObject var notifications: NotificationsStore
    @EnvironmentObject var files: FileTransferService

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section { StatusHeader() }
                Section {
                    ForEach(SidebarItem.allCases) { item in
                        NavigationLink(value: item) {
                            Label(item.title, systemImage: item.symbol)
                                .badge(badge(for: item))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                FileDrop.load(providers) { files.send(urls: $0) }
                model.selection = .files
                return true
            }
        } detail: {
            detail
                .navigationTitle(model.selection?.title ?? "Link to Mac")
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .messages: return messages.unreadCount
        case .notifications: return notifications.items.count
        default: return 0
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .overview {
        case .overview: OverviewView(selection: $model.selection)
        case .messages: MessagesView()
        case .photos: PhotoGridView()
        case .calls: CallsView()
        case .notifications: NotificationsView()
        case .files: FilesView()
        case .mirror: MirrorLauncherView()
        case .settings: SettingsView()
        }
    }
}

/// Main-window section that opens the separate mirror window.
struct MirrorLauncherView: View {
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var mirror: MirrorController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Handy-Bildschirm auf dem Mac").font(.title2.bold())
            Text("Der Bildschirm deines Handys erscheint in einem eigenen Fenster. Mit der Maus tippst und wischst du, mit der Tastatur schreibst du. Rechtsklick = Zurück.")
                .multilineTextAlignment(.center).frame(maxWidth: 460).foregroundStyle(.secondary)
            Button {
                openWindow(id: "mirror")
                if mirror.state == .idle { mirror.start() }
            } label: {
                Label("Spiegelung starten", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!connection.isConnected)
            Text("Zur Steuerung muss auf dem Handy die Bedienungshilfe „Link to Mac Steuerung“ aktiviert sein.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
