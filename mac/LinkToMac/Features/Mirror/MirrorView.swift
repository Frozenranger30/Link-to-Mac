import AVFoundation
import SwiftUI

/// Window content for the mirrored phone screen.
struct MirrorWindowView: View {
    @EnvironmentObject var mirror: MirrorController
    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                MirrorRepresentable(mirror: mirror)
                switch mirror.state {
                case .idle:
                    VStack(spacing: 12) {
                        Image(systemName: "iphone.gen3").font(.system(size: 44)).foregroundStyle(.white.opacity(0.6))
                        Button("Spiegelung starten") { mirror.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!connection.isConnected)
                    }
                case .requesting:
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Bitte auf dem Handy „Jetzt starten“ tippen.")
                            .foregroundStyle(.white).multilineTextAlignment(.center)
                        Text("Wenn nichts erscheint: Mitteilung „Bildschirm auf den Mac spiegeln?“ auf dem Handy antippen.")
                            .font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    }
                    .padding()
                case .running:
                    EmptyView()
                case let .failed(msg):
                    VStack(spacing: 10) {
                        Text(msg).foregroundStyle(.white).multilineTextAlignment(.center)
                        Button("Erneut versuchen") { mirror.start() }
                    }
                    .padding()
                }
            }
            .aspectRatio(mirror.videoSize, contentMode: .fit)
            if let err = mirror.lastError {
                Text(err).font(.caption).foregroundStyle(.orange).padding(6)
            }
        }
        .background(Color.black)
        .toolbar {
            ToolbarItemGroup {
                Button { mirror.key("back") } label: { Label("Zurück", systemImage: "chevron.backward") }
                Button { mirror.key("home") } label: { Label("Home", systemImage: "circle") }
                Button { mirror.key("recents") } label: { Label("Übersicht", systemImage: "square.on.square") }
                Button { mirror.key("notifications") } label: { Label("Benachrichtigungen", systemImage: "bell") }
                if mirror.state == .running {
                    Button { mirror.stop() } label: { Label("Beenden", systemImage: "stop.fill") }
                }
            }
        }
        .navigationTitle(connection.phoneName ?? String(localized: "Handy-Bildschirm"))
        .onDisappear { if mirror.state != .idle { mirror.stop() } }
    }
}

struct MirrorRepresentable: NSViewRepresentable {
    let mirror: MirrorController

    func makeNSView(context: Context) -> MirrorNSView {
        MirrorNSView(mirror: mirror)
    }

    func updateNSView(_ nsView: MirrorNSView, context: Context) {
        nsView.needsLayout = true
    }
}

/// Hosts the display layer and turns mouse/keyboard events into input messages.
final class MirrorNSView: NSView {
    private let mirror: MirrorController
    private var downPoint: CGPoint?
    private var downTime = Date()
    private var scrollAccum = CGSize.zero
    private var lastScroll = Date.distantPast
    private var scrollPoint = CGPoint.zero

    init(mirror: MirrorController) {
        self.mirror = mirror
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(mirror.decoder.layer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirror.decoder.layer.frame = bounds
        CATransaction.commit()
    }

    private var videoRect: CGRect {
        AVMakeRect(aspectRatio: mirror.videoSize, insideRect: bounds)
    }

    private func normalized(_ event: NSEvent) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let r = videoRect
        guard r.width > 0, r.height > 0, r.contains(p) else { return nil }
        return CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = normalized(event)
        downTime = Date()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = downPoint, mirror.state == .running else { return }
        downPoint = nil
        let end = normalized(event) ?? start
        let ms = Int(Date().timeIntervalSince(downTime) * 1000)
        let r = videoRect
        let dist = hypot((end.x - start.x) * r.width, (end.y - start.y) * r.height)
        if dist < 6 {
            if ms >= 500 { mirror.longPress(start, ms: ms) } else { mirror.tap(start) }
        } else {
            mirror.swipe(from: start, to: end, ms: max(80, min(ms, 2000)))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        mirror.key("back")
    }

    override func otherMouseDown(with event: NSEvent) {
        mirror.key("home")
    }

    override func scrollWheel(with event: NSEvent) {
        guard mirror.state == .running, let p = normalized(event) else { return }
        scrollPoint = p
        let r = videoRect
        // Content moves with the fingers: natural scrolling deltas map directly.
        scrollAccum.width += event.scrollingDeltaX / max(r.width, 1)
        scrollAccum.height += event.scrollingDeltaY / max(r.height, 1)
        if Date().timeIntervalSince(lastScroll) > 0.12 {
            lastScroll = Date()
            let dx = -Double(scrollAccum.width) * (event.hasPreciseScrollingDeltas ? 1 : 8)
            let dy = -Double(scrollAccum.height) * (event.hasPreciseScrollingDeltas ? 1 : 8)
            scrollAccum = .zero
            if abs(dx) > 0.002 || abs(dy) > 0.002 {
                mirror.scroll(at: scrollPoint, dx: max(-0.6, min(0.6, dx)), dy: max(-0.6, min(0.6, dy)))
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard mirror.state == .running else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51: mirror.key("backspace")
        case 36, 76: mirror.key("enter")
        case 53: mirror.key("back")
        default:
            if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
            if let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                mirror.key("text", text: chars)
            }
        }
    }
}
