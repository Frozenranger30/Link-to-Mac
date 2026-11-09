import AppKit
import Foundation

/// Recent photos from the phone (F5).
final class PhotosStore: ObservableObject {
    struct Photo: Identifiable, Equatable {
        let info: PhotoInfo
        let thumbnail: NSImage?
        var id: Int64 { info.id }
        static func == (a: Photo, b: Photo) -> Bool { a.info == b.info }
    }

    @Published private(set) var photos: [Photo] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var downloading: Set<Int64> = []

    private let connection: ConnectionManager
    private let files: FileTransferService
    private let pageSize = 60

    init(connection: ConnectionManager, files: FileTransferService) {
        self.connection = connection
        self.files = files
        connection.onConnected { [weak self] in
            guard let self else { return }
            self.photos = []
            self.total = 0
        }
    }

    var canLoadMore: Bool { photos.count < total || (total == 0 && photos.isEmpty) }

    @MainActor
    func loadMore() async {
        guard !loading, connection.isConnected, photos.isEmpty || photos.count < total else { return }
        loading = true
        defer { loading = false }
        do {
            let reply = try await connection.request(MsgType.photosList, PhotosListBody(offset: photos.count, limit: pageSize), timeout: 60)
            let page = try reply.body(PhotosBody.self)
            total = page.total
            let existing = Set(photos.map(\.id))
            let decoded = await Task.detached(priority: .userInitiated) {
                page.photos.map { Photo(info: $0, thumbnail: NSImage(base64: $0.thumbJpeg)) }
            }.value
            photos.append(contentsOf: decoded.filter { !existing.contains($0.id) })
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    func reload() async {
        photos = []
        total = 0
        await loadMore()
    }

    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LinkToMac/photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cachedURL(for info: PhotoInfo) -> URL {
        cacheDir.appendingPathComponent("\(info.id)-" + info.name.replacingOccurrences(of: "/", with: "_"))
    }

    /// Downloads the full-size photo (or returns the cached copy).
    @MainActor
    func fullImage(_ info: PhotoInfo) async throws -> URL {
        let url = cachedURL(for: info)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        downloading.insert(info.id)
        defer { downloading.remove(info.id) }
        let transferId = UUID().uuidString.lowercased()
        let result: URL = try await withCheckedThrowingContinuation { cont in
            files.expectPhoto(transferId: transferId, destination: url) { cont.resume(with: $0) }
            if connection.send(MsgType.photoGet, PhotoGetBody(id: info.id, transferId: transferId)) == nil {
                files.cancelExpectation(transferId)
                cont.resume(throwing: LinkError.notConnected)
            }
        }
        return result
    }

    /// Copies a photo to the Downloads folder.
    @MainActor
    func saveToDownloads(_ info: PhotoInfo) async {
        do {
            let src = try await fullImage(info)
            let dst = FileTransferService.uniqueDownloadURL(name: info.name)
            try FileManager.default.copyItem(at: src, to: dst)
            NSWorkspace.shared.activateFileViewerSelecting([dst])
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        photos = []
        total = 0
    }
}
