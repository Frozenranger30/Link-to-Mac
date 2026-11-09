import SwiftUI

struct MessagesView: View {
    @EnvironmentObject var store: MessagesStore
    @EnvironmentObject var connection: ConnectionManager
    @State private var selected: Int64?
    @State private var search = ""
    @State private var showNew = false

    private var filtered: [SmsThread] {
        guard !search.isEmpty else { return store.threads }
        return store.threads.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.snippet.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(filtered) { t in
                        ThreadRow(thread: t).tag(t.threadId)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if store.threads.isEmpty {
                        EmptyState(symbol: "message", text: connection.isConnected ? String(localized: "Keine Unterhaltungen") : String(localized: "Verbinde dein Handy, um Nachrichten zu sehen"))
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            .searchable(text: $search, placement: .sidebar, prompt: Text("Suchen"))

            Group {
                if let id = selected, let thread = store.threads.first(where: { $0.threadId == id }) {
                    ChatView(thread: thread)
                } else {
                    EmptyState(symbol: "bubble.left.and.bubble.right", text: String(localized: "Wähle eine Unterhaltung"))
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showNew = true } label: { Label("Neue Nachricht", systemImage: "square.and.pencil") }
                    .disabled(!connection.isConnected)
                Button { Task { await store.refreshThreads() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                    .disabled(!connection.isConnected)
            }
        }
        .sheet(isPresented: $showNew) { NewMessageSheet() }
        .alert(String(localized: "Fehler"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }
}

private struct ThreadRow: View {
    let thread: SmsThread

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: thread.displayName)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.displayName).font(.headline).lineLimit(1)
                    Spacer()
                    Text(Date(milliseconds: thread.date).shortRelative).font(.caption).foregroundStyle(.secondary)
                }
                Text(thread.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if thread.unread > 0 {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ChatView: View {
    let thread: SmsThread
    @EnvironmentObject var store: MessagesStore
    @EnvironmentObject var connection: ConnectionManager
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Avatar(name: thread.displayName)
                VStack(alignment: .leading) {
                    Text(thread.displayName).font(.headline)
                    if thread.contactName != nil { Text(thread.address).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if store.hasMore[thread.threadId] == true {
                            Button("Ältere Nachrichten laden") {
                                Task { await store.loadMessages(thread: thread.threadId, older: true) }
                            }
                            .buttonStyle(.link)
                            .padding(.vertical, 6)
                        }
                        ForEach(store.messages[thread.threadId] ?? []) { m in
                            Bubble(message: m).id(m.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: store.messages[thread.threadId]?.last?.id) { last in
                    if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
                .onAppear {
                    if let last = store.messages[thread.threadId]?.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("SMS schreiben …", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending || !connection.isConnected)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(10)
        }
        .task(id: thread.threadId) {
            await store.loadMessages(thread: thread.threadId)
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        Task {
            if await store.send(text, to: thread.address) { draft = "" }
            sending = false
        }
    }
}

private struct Bubble: View {
    let message: SmsMessage

    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 60) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(message.outgoing ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    )
                    .foregroundStyle(message.outgoing ? Color.white : Color.primary)
                    .contextMenu {
                        Button("Text kopieren") { copy(message.body) }
                        if let code = OneTimeCode.find(in: message.body) {
                            Button("Code \(code) kopieren") { copy(code) }
                        }
                    }
                Text(Date(milliseconds: message.date).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !message.outgoing { Spacer(minLength: 60) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct NewMessageSheet: View {
    @EnvironmentObject var store: MessagesStore
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var text = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neue Nachricht").font(.title2.bold())
            TextField("Telefonnummer", text: $number)
            TextField("Nachricht", text: $text, axis: .vertical).lineLimit(3...8)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Senden") {
                    sending = true
                    Task {
                        if await store.send(text, to: number) {
                            dismiss()
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await store.refreshThreads()
                        }
                        sending = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(number.isEmpty || text.isEmpty || sending)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 380)
    }
}
