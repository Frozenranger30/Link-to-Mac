import SwiftUI

/// Small now-playing card for the sidebar and menu bar.
struct MiniPlayer: View {
    @EnvironmentObject var phone: PhoneStore

    var body: some View {
        if let m = phone.media, m.active {
            HStack(spacing: 10) {
                Group {
                    if let art = phone.artwork {
                        Image(nsImage: art).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.title ?? m.appName ?? "–").font(.caption.bold()).lineLimit(1)
                    Text(m.artist ?? m.appName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button { phone.mediaAction("previous") } label: { Image(systemName: "backward.fill") }
                    Button { phone.mediaAction("toggle") } label: {
                        Image(systemName: m.playing == true ? "pause.fill" : "play.fill")
                    }
                    Button { phone.mediaAction("next") } label: { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
        }
    }
}
