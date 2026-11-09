import SwiftUI
import UniformTypeIdentifiers

struct PhotoGridView: View {
    @EnvironmentObject var store: PhotosStore
    @EnvironmentObject var connection: ConnectionManager
    @State private var viewing: PhotoInfo?
    @AppStorage("photoTileSize") private var tileSize: Double = 140

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.6), spacing: 4)], spacing: 4) {
                ForEach(store.photos) { photo in
                    PhotoTile(photo: photo, downloading: store.downloading.contains(photo.id))
                        .aspectRatio(1, contentMode: .fit)
                        .onTapGesture(count: 2) { viewing = photo.info }
                        .onDrag { dragProvider(photo.info) }
                        .contextMenu {
                            Button("Öffnen") { viewing = photo.info }
                            Button("In „Downloads“ sichern") { Task { await store.saveToDownloads(photo.info) } }
                        }
                        .onAppear {
                            if photo.id == store.photos.last?.id { Task { await store.loadMore() } }
                        }
                }
            }
            .padding(8)
            if store.loading {
                ProgressView().padding()
            }
        }
        .overlay {
            if store.photos.isEmpty && !store.loading {
                EmptyState(symbol: "photo.on.rectangle", text: connection.isConnected
                    ? String(localized: "Keine Fotos gefunden – ist die Berechtigung „Fotos“ auf dem Handy erteilt?")
                    : String(localized: "Verbinde dein Handy, um Fotos zu sehen"))
            }
        }
        .task(id: connection.isConnected) {
            if connection.isConnected && store.photos.isEmpty { await store.loadMore() }
        }
        .toolbar {
            ToolbarItemGroup {
                Slider(value: $tileSize, in: 90...260) { Text("Größe") }.frame(width: 120)
                Button { Task { await store.reload() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                    .disabled(!connection.isConnected)
            }
        }
        .sheet(item: $viewing) { info in PhotoViewer(info: info) }
        .alert(String(localized: "Fehler"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    /// Lazily downloads the full photo when it is dropped somewhere (Finder, Mail, Pages …).
    private func dragProvider(_ info: PhotoInfo) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = info.name
        let type = UTType(mimeType: info.mime) ?? .jpeg
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    let url = try await store.fullImage(info)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

private struct PhotoTile: View {
    let photo: PhotosStore.Photo
    let downloading: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.15))
                if let img = photo.thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                if downloading {
                    ProgressView().controlSize(.small).padding(6).background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .help(Date(milliseconds: photo.info.date).formatted(date: .long, time: .shortened))
    }
}

struct PhotoViewer: View {
    let info: PhotoInfo
    @EnvironmentObject var store: PhotosStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var url: URL?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(info.name).font(.headline)
                    Text(Date(milliseconds: info.date).formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    Button("Sichern") { Task { await store.saveToDownloads(info) } }
                }
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                } else if let error {
                    Text(error).foregroundStyle(.white)
                } else {
                    ProgressView("Lade Foto …").tint(.white).foregroundStyle(.white)
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 520, idealHeight: 700)
        .task {
            do {
                let u = try await store.fullImage(info)
                url = u
                image = NSImage(contentsOf: u)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
