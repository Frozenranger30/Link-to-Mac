import Foundation

/// SMS conversations (F4).
final class MessagesStore: ObservableObject {
    @Published private(set) var threads: [SmsThread] = []
    @Published private(set) var messages: [Int64: [SmsMessage]] = [:]
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var sending: Set<String> = []
    @Published private(set) var hasMore: [Int64: Bool] = [:]

    private let connection: ConnectionManager
    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LinkToMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("threads.json")
    }()

    init(connection: ConnectionManager) {
        self.connection = connection
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([SmsThread].self, from: data) {
            threads = cached
        }
        connection.on(MsgType.smsReceived) { [weak self] msg in
            guard let self, let r = try? msg.body(SmsReceivedBody.self) else { return }
            self.received(r)
        }
        connection.onConnected { [weak self] in
            Task { await self?.refreshThreads() }
        }
    }

    var unreadCount: Int { threads.reduce(0) { $0 + $1.unread } }

    @MainActor
    func refreshThreads() async {
        loading = true
        defer { loading = false }
        do {
            let reply = try await connection.request(MsgType.smsThreadsGet, SmsThreadsGetBody(limit: 300))
            threads = try reply.body(SmsThreadsBody.self).threads
            error = nil
            if let data = try? JSONEncoder().encode(threads) { try? data.write(to: cacheURL) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    func loadMessages(thread: Int64, older: Bool = false) async {
        let existing = messages[thread] ?? []
        let before = older ? existing.first?.date : nil
        do {
            let reply = try await connection.request(MsgType.smsMessagesGet, SmsMessagesGetBody(threadId: thread, before: before, limit: 100))
            let list = try reply.body(SmsMessagesBody.self).messages
            if older {
                messages[thread] = list + existing
            } else {
                messages[thread] = list
            }
            hasMore[thread] = list.count >= 100
            if let i = threads.firstIndex(where: { $0.threadId == thread }), threads[i].unread > 0 {
                threads[i].unread = 0
                connection.send(MsgType.smsMarkRead, SmsMarkReadBody(threadId: thread))
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    func send(_ text: String, to address: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = UUID().uuidString
        sending.insert(key)
        defer { sending.remove(key) }
        do {
            let reply = try await connection.request(MsgType.smsSend, SmsSendBody(address: address, text: trimmed), timeout: 60)
            let result = try reply.body(SmsSentBody.self)
            if !result.ok {
                error = result.error ?? String(localized: "SMS konnte nicht gesendet werden")
                return false
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func received(_ r: SmsReceivedBody) {
        let m = r.message
        if var list = messages[m.threadId], !list.contains(where: { $0.id == m.id }) {
            list.append(m)
            messages[m.threadId] = list
        }
        if let i = threads.firstIndex(where: { $0.threadId == m.threadId }) {
            var t = threads.remove(at: i)
            t.snippet = m.body
            t.date = m.date
            if !m.outgoing { t.unread += 1 }
            if t.contactName == nil { t.contactName = r.contactName }
            threads.insert(t, at: 0)
        } else {
            threads.insert(SmsThread(threadId: m.threadId, address: m.address, contactName: r.contactName,
                                     snippet: m.body, date: m.date, unread: m.outgoing ? 0 : 1), at: 0)
        }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
        threads = []
        messages = [:]
    }
}
