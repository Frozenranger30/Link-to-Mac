import SwiftUI

/// Status sidebar header: phone name, battery, network.
struct StatusHeader: View {
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var phone: PhoneStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3").font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.phoneName ?? TrustStore.shared.pairedDevice?.name ?? String(localized: "Kein Handy"))
                        .font(.headline).lineLimit(1)
                    ConnectionBadge()
                }
            }
            if connection.isConnected, let s = phone.status {
                HStack(spacing: 10) {
                    Label("\(max(s.battery, 0)) %", systemImage: phone.batterySymbol)
                    Image(systemName: phone.wifiSymbol)
                    if let cell = s.cellSignal, cell >= 0 {
                        Image(systemName: "cellularbars", variableValue: Double(cell) / 4)
                    }
                    if s.dnd { Image(systemName: "moon.fill") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            MiniPlayer()
        }
        .padding(.vertical, 6)
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var color: Color {
        switch connection.state {
        case .connected: return .green
        case .connecting, .searching: return .orange
        case .notPaired: return .gray
        case .failed: return .red
        }
    }

    private var text: String {
        switch connection.state {
        case .connected: return String(localized: "Verbunden")
        case .connecting: return String(localized: "Verbinde …")
        case .searching: return String(localized: "Suche Handy …")
        case .notPaired: return String(localized: "Nicht gekoppelt")
        case let .failed(msg): return msg
        }
    }
}

/// "Übersicht": generic phone drawing plus the latest notifications.
struct OverviewView: View {
    @EnvironmentObject var connection: ConnectionManager
    @EnvironmentObject var phone: PhoneStore
    @EnvironmentObject var notifications: NotificationsStore
    @EnvironmentObject var messages: MessagesStore
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 32) {
                PhoneIllustration()
                    .frame(width: 180, height: 360)
                VStack(alignment: .leading, spacing: 16) {
                    Text(connection.phoneName ?? TrustStore.shared.pairedDevice?.name ?? String(localized: "Link to Mac"))
                        .font(.largeTitle.bold())
                    ConnectionBadge()
                    if connection.state == .notPaired {
                        Text("Koppele dein Android-Handy, um loszulegen.")
                        Button("Handy koppeln …") { selection = .settings }.buttonStyle(.borderedProminent)
                    }
                    if let s = phone.status, connection.isConnected {
                        HStack(spacing: 24) {
                            Stat(symbol: phone.batterySymbol, value: "\(max(s.battery, 0)) %", label: s.charging ? String(localized: "Lädt") : String(localized: "Akku"))
                            Stat(symbol: phone.wifiSymbol, value: s.network == "wifi" ? "\(s.wifiSignal)/4" : "–", label: String(localized: "WLAN"))
                            if let c = s.cellSignal, c >= 0 {
                                Stat(symbol: "cellularbars", value: "\(c)/4", label: s.carrier ?? String(localized: "Mobilfunk"))
                            }
                        }
                        HStack {
                            Button { phone.ring() } label: { Label("Handy klingeln lassen", systemImage: "speaker.wave.3") }
                            if phone.ringing {
                                Button("Stopp") { phone.stopRing() }
                            }
                        }
                        MiniPlayer().frame(maxWidth: 360)
                    }
                    if messages.unreadCount > 0 {
                        Button { selection = .messages } label: {
                            Label("\(messages.unreadCount) ungelesene Nachrichten", systemImage: "message.badge")
                        }
                        .buttonStyle(.link)
                    }
                    Divider()
                    Text("Letzte Benachrichtigungen").font(.headline)
                    if notifications.items.isEmpty {
                        Text("Keine Benachrichtigungen").foregroundStyle(.secondary)
                    }
                    ForEach(notifications.items.prefix(5)) { n in
                        NotificationRow(item: n)
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct Stat: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title2)
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 70)
    }
}

/// Generic phone outline (no real device artwork).
struct PhoneIllustration: View {
    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(Color.primary.opacity(0.85))
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.44, blue: 0.91), Color(red: 0.08, green: 0.72, blue: 0.65)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(8)
            Capsule().fill(Color.primary.opacity(0.85)).frame(width: 50, height: 10).offset(y: -160)
            VStack(spacing: 8) {
                Image(systemName: connection.isConnected ? "link" : "link.badge.plus")
                    .font(.system(size: 40, weight: .semibold))
                Text(Date(), style: .time).font(.title.bold())
            }
            .foregroundStyle(.white)
        }
    }
}
