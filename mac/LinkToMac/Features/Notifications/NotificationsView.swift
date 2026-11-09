import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject var store: NotificationsStore
    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        List {
            ForEach(store.items) { n in
                NotificationRow(item: n)
            }
        }
        .listStyle(.inset)
        .overlay {
            if store.items.isEmpty {
                EmptyState(symbol: "bell.slash", text: connection.isConnected
                    ? String(localized: "Keine Benachrichtigungen")
                    : String(localized: "Verbinde dein Handy, um Benachrichtigungen zu sehen"))
            }
        }
        .toolbar {
            Button { store.clearAll() } label: { Label("Alle löschen", systemImage: "trash") }
                .disabled(store.items.isEmpty)
        }
    }
}

struct NotificationRow: View {
    let item: NotificationPostedBody
    @EnvironmentObject var store: NotificationsStore
    @State private var reply = ""
    @State private var replying = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = store.icon(for: item.app) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.badge").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.appName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.date.shortRelative).font(.caption).foregroundStyle(.secondary)
                }
                if !item.title.isEmpty { Text(item.title).font(.headline) }
                if !item.text.isEmpty { Text(item.text).textSelection(.enabled).lineLimit(6) }
                HStack(spacing: 8) {
                    if let code = OneTimeCode.find(in: item.title + " " + item.text) {
                        Button("Code \(code) kopieren") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                    }
                    ForEach(Array(item.actions.enumerated()), id: \.offset) { idx, action in
                        if action.isReply {
                            Button(action.title) { replying.toggle() }
                        } else {
                            Button(action.title) { store.perform(item.key, actionIndex: idx, reply: nil) }
                        }
                    }
                }
                .controlSize(.small)
                if replying, let idx = item.actions.firstIndex(where: { $0.isReply }) {
                    HStack {
                        TextField("Antwort …", text: $reply)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { sendReply(idx) }
                        Button("Senden") { sendReply(idx) }.disabled(reply.isEmpty)
                    }
                }
            }
            Button { store.dismiss(item.key) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help(String(localized: "Auch auf dem Handy entfernen"))
        }
        .padding(.vertical, 4)
    }

    private func sendReply(_ idx: Int) {
        guard !reply.isEmpty else { return }
        store.perform(item.key, actionIndex: idx, reply: reply)
        reply = ""
        replying = false
    }
}
