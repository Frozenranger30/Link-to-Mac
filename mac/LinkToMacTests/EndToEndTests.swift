import Network
import XCTest
@testable import LinkToMac

/// Pairs the real app with tools/fake_phone.py, connects over pinned TLS, authenticates and
/// exercises a few features. Skipped when the fake phone is not running (CI starts it).
final class EndToEndTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Sends `data` to the fake phone's helper port; returns false if nobody listens.
    private func sendToHelper(_ data: Data) -> Bool {
        let conn = NWConnection(host: "127.0.0.1", port: 47899, using: .tcp)
        var ready = false
        var failed = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: ready = true
            case .failed, .waiting: failed = true
            default: break
            }
        }
        conn.start(queue: .main)
        _ = waitUntil(3) { ready || failed }
        guard ready else {
            conn.cancel()
            return false
        }
        var sent = false
        conn.send(content: data, completion: .contentProcessed { _ in sent = true })
        _ = waitUntil(3) { sent }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        conn.cancel()
        return true
    }

    func testPairConnectAndExchangeData() throws {
        let model = AppModel.shared
        TrustStore.shared.pairedDevice = nil
        model.connection.pairedDeviceChanged()

        model.pairing.start()
        defer {
            model.pairing.stop()
            TrustStore.shared.pairedDevice = nil
            model.connection.pairedDeviceChanged()
        }
        let qr = try XCTUnwrap(model.pairing.qrJSON)
        guard sendToHelper(Data((qr + "\n").utf8)) else {
            throw XCTSkip("tools/fake_phone.py is not running")
        }

        // 1. Pairing request arrives and is accepted (the user would click "Erlauben").
        XCTAssertTrue(waitUntil(20) { model.pairing.pending != nil }, "no pair.request received")
        let pending = try XCTUnwrap(model.pairing.pending)
        XCTAssertEqual(pending.request.deviceName, "Fake Phone")
        model.pairing.reply(pending, accept: true)
        XCTAssertNotNil(TrustStore.shared.pairedDevice)

        // 2. Pinned TLS + challenge/response authentication.
        XCTAssertTrue(waitUntil(40) { model.connection.isConnected }, "not connected: \(model.connection.state) \(model.connection.lastError ?? "")")
        XCTAssertEqual(model.connection.phoneName, "Fake Phone")
        XCTAssertNotNil(model.connection.sessionToken)

        // 3. Pushed data.
        XCTAssertTrue(waitUntil(10) { model.phone.status?.battery == 77 }, "no status.update")
        XCTAssertTrue(waitUntil(10) { !model.notifications.items.isEmpty }, "no notification")
        XCTAssertTrue(waitUntil(15) { !model.messages.threads.isEmpty }, "no SMS threads")
        XCTAssertEqual(model.messages.threads.first?.contactName, "Anna")

        // 4. Request/response.
        var sentOK: Bool?
        Task { @MainActor in sentOK = await model.messages.send("Hallo aus dem Test", to: "+491701234567") }
        XCTAssertTrue(waitUntil(15) { sentOK != nil })
        XCTAssertEqual(sentOK, true)

        // 5. Data channel: photo download with SHA-256 verification.
        let info = PhotoInfo(id: 424242, date: 0, width: 1, height: 1, name: "IMG_TEST.jpg", mime: "image/jpeg", thumbJpeg: "")
        try? FileManager.default.removeItem(at: model.photos.cachedURL(for: info))
        var result: Result<URL, Error>?
        Task { @MainActor in
            do { result = .success(try await model.photos.fullImage(info)) } catch { result = .failure(error) }
        }
        XCTAssertTrue(waitUntil(30) { result != nil }, "photo download timed out")
        let url = try XCTUnwrap(result).get()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 300_000)
        XCTAssertEqual(data[7], 49)

        // 6. Heartbeat keeps the connection alive.
        RunLoop.main.run(until: Date().addingTimeInterval(12))
        XCTAssertTrue(model.connection.isConnected)
    }
}
