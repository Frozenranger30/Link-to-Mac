import AppKit
import Foundation
import SwiftUI

/// Call state, call log and dialing (F8).
final class CallsStore: ObservableObject {
    @Published private(set) var current = CallStateBody(state: "idle", number: nil, contactName: nil)
    @Published private(set) var log: [CallEntry] = []
    @Published private(set) var contacts: [Contact] = []
    @Published var error: String?

    private let connection: ConnectionManager
    private let settings: AppSettings
    private var panel: IncomingCallPanel?

    init(connection: ConnectionManager, settings: AppSettings) {
        self.connection = connection
        self.settings = settings
        connection.on(MsgType.callState) { [weak self] msg in
            guard let self, let s = try? msg.body(CallStateBody.self) else { return }
            self.stateChanged(s)
        }
        connection.onConnected { [weak self] in
            Task { await self?.refresh() }
        }
        connection.onDisconnected { [weak self] in
            self?.stateChanged(CallStateBody(state: "idle", number: nil, contactName: nil))
        }
    }

    var displayName: String {
        current.contactName ?? current.number ?? String(localized: "Unbekannt")
    }

    private func stateChanged(_ s: CallStateBody) {
        let previous = current.state
        current = s
        switch s.state {
        case "ringing", "offhook":
            if settings.callPopup || s.state == "offhook" && panel != nil { showPanel() }
        default:
            panel?.close()
            panel = nil
            if previous != "idle" {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await self.refresh()
                }
            }
        }
    }

    private func showPanel() {
        if panel == nil {
            panel = IncomingCallPanel(rootView: AnyView(IncomingCallView().environmentObject(self)))
        }
        panel?.show()
    }

    func action(_ action: String, number: String? = nil) {
        connection.send(MsgType.callAction, CallActionBody(action: action, number: number))
    }

    func dial(_ number: String) {
        let cleaned = number.filter { "+0123456789*#".contains($0) }
        guard !cleaned.isEmpty else { return }
        action("dial", number: cleaned)
    }

    @MainActor
    func refresh() async {
        do {
            let reply = try await connection.request(MsgType.calllogGet, CallLogGetBody(limit: 300))
            log = try reply.body(CallLogBody.self).calls
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if contacts.isEmpty, let reply = try? await connection.request(MsgType.contactsGet, Empty()) {
            contacts = (try? reply.body(ContactsBody.self).contacts) ?? []
        }
    }
}

/// Floating, non-activating panel for incoming calls.
final class IncomingCallPanel: NSPanel {
    convenience init(rootView: AnyView) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .hudWindow, .utilityWindow],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: rootView)
    }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.maxX - frame.width - 16, y: f.maxY - frame.height - 16))
        }
        orderFrontRegardless()
    }
}

struct IncomingCallView: View {
    @EnvironmentObject var calls: CallsStore

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Avatar(name: calls.displayName, size: 44)
                VStack(alignment: .leading) {
                    Text(calls.current.state == "ringing" ? String(localized: "Eingehender Anruf") : String(localized: "Im Gespräch"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(calls.displayName).font(.title3.bold()).lineLimit(1)
                    if calls.current.contactName != nil, let n = calls.current.number {
                        Text(n).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack {
                if calls.current.state == "ringing" {
                    Button { calls.action("reject") } label: {
                        Label("Ablehnen", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                    Button { calls.action("answer") } label: {
                        Label("Annehmen", systemImage: "phone.fill").frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                } else {
                    Button { calls.action("hangup") } label: {
                        Label("Auflegen", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if calls.current.state == "offhook" {
                Text("Gesprochen wird am Handy.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
