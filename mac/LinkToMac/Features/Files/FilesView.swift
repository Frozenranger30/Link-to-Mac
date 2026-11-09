import SwiftUI
import UniformTypeIdentifiers

/// Drop zone + list of transfers.
struct FilesView: View {
    @EnvironmentObject var files: FileTransferService
    @EnvironmentObject var connection: ConnectionManager
    @State private var targeted = false
    @State private var picking = false

    var body: some View {
        VStack(spacing: 0) {
            DropZone(targeted: targeted, enabled: connection.isConnected) { picking = true }
                .padding(16)
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    FileDrop.load(providers) { files.send(urls: $0) }
                    return true
                }
            Divider()
            if files.transfers.isEmpty {
                EmptyState(symbol: "arrow.up.arrow.down.circle", text: String(localized: "Noch keine Übertragungen.\nDateien vom Handy landen im Ordner „Downloads“."))
            } else {
                List {
                    ForEach(files.transfers) { t in TransferRow(transfer: t) }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { picking = true } label: { Label("Dateien senden", systemImage: "paperplane") }
                    .disabled(!connection.isConnected)
                Button { files.clearFinished() } label: { Label("Liste leeren", systemImage: "trash") }
                Button { NSWorkspace.shared.open(FileTransferService.downloadsFolder) } label: { Label("Downloads öffnen", systemImage: "folder") }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { files.send(urls: urls) }
        }
    }
}

enum FileDrop {
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

private struct DropZone: View {
    let targeted: Bool
    let enabled: Bool
    let pick: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 34))
            Text(enabled ? String(localized: "Dateien hierher ziehen, um sie ans Handy zu senden") : String(localized: "Handy nicht verbunden"))
                .font(.headline)
            Button("Dateien auswählen …", action: pick).disabled(!enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
    }
}

private struct TransferRow: View {
    let transfer: FileTransferService.Transfer
    @EnvironmentObject var files: FileTransferService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(transfer.direction == .incoming ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                switch transfer.state {
                case .running, .waiting:
                    ProgressView(value: transfer.fraction)
                    Text("\(ByteFormat.string(transfer.bytes)) von \(ByteFormat.string(transfer.size))").font(.caption).foregroundStyle(.secondary)
                case .offered:
                    Text("\(ByteFormat.string(transfer.size)) – möchtest du die Datei annehmen?").font(.caption)
                case .done:
                    Text(transfer.direction == .incoming ? String(localized: "Empfangen") : String(localized: "Gesendet"))
                        .font(.caption).foregroundStyle(.secondary)
                case let .failed(msg):
                    Text(msg).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if transfer.state == .offered {
                Button("Ablehnen") { files.reject(transfer.id) }
                Button("Annehmen") { files.accept(transfer.id) }.buttonStyle(.borderedProminent)
            }
            if transfer.state == .done, transfer.direction == .incoming, let url = transfer.url {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .help(String(localized: "Im Finder zeigen"))
            }
        }
        .padding(.vertical, 4)
    }
}
