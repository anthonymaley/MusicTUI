// tools/music/Tests/MusicTests/ArtworkStoreLocalFileTests.swift
import XCTest
import CoreGraphics
import ImageIO
@testable import music

/// An `sd_` key is a local file `LibraryCoverFetcher` installed and may evict on
/// its own. A read that fails because the file is MISSING is the eviction racing
/// the store, not a bad cover: it must not be negative-cached, so a reinstall of
/// the same key still renders. A file that is present but undecodable, and every
/// non-`sd_` key, keep the negative cache. Injected fetch/render, temp dir only.
final class ArtworkStoreLocalFileTests: XCTestCase {

    private let key = "sd_0123456789abcdef0123456789abcdef"

    private func tmpDir() -> String {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-local-test-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        let e = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    private func install(_ data: Data, in dir: String, as name: String) {
        try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }

    private func makeSolidColorJPEG() -> Data? {
        let width = 4, height = 4, bytesPerRow = 16
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 30; pixels[i + 1] = 60; pixels[i + 2] = 90; pixels[i + 3] = 255
        }
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: lines (chafa) path

    func testEvictedSdFileIsNotNegativeCachedAndAReinstallRenders() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ArtworkStore(cacheDir: dir, fetch: { _ in nil }, render: { _, _, _ in ["ART"] })
        // Evicted before the store consumed it: the file URL fetch fails.
        XCTAssertNil(store.lines(key: key, url: "file:///gone", width: 8, height: 4) { XCTFail("nothing to render") })
        settle()
        install(Data([1, 2, 3]), in: dir, as: key)        // the same key comes back
        let ready = expectation(description: "onReady")
        XCTAssertNil(store.lines(key: key, url: "file:///gone", width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(store.lines(key: key, url: "file:///gone", width: 8, height: 4) { }, ["ART"])
    }

    func testSdFileEvictedBetweenFetchAndRenderIsNotNegativeCached() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        install(Data([1, 2, 3]), in: dir, as: key)
        var renders = 0
        let store = ArtworkStore(cacheDir: dir, fetch: { _ in XCTFail("on disk: no fetch"); return nil }, render: { path, _, _ in
            renders += 1
            if renders == 1 { try? FileManager.default.removeItem(atPath: path); return [] }   // eviction lands mid-render
            return ["ART"]
        })
        XCTAssertNil(store.lines(key: key, url: "u", width: 8, height: 4) { XCTFail("first render fails") })
        settle()
        install(Data([1, 2, 3]), in: dir, as: key)
        let ready = expectation(description: "onReady")
        XCTAssertNil(store.lines(key: key, url: "u", width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(store.lines(key: key, url: "u", width: 8, height: 4) { }, ["ART"])
    }

    func testPresentButUnrenderableSdFileIsStillNegativeCached() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        install(Data([0, 1, 2]), in: dir, as: key)
        var renders = 0
        let store = ArtworkStore(cacheDir: dir, fetch: { _ in XCTFail("on disk: no fetch"); return nil },
                                 render: { _, _, _ in renders += 1; return [] })
        XCTAssertNil(store.lines(key: key, url: "u", width: 8, height: 4) { XCTFail("onReady must not fire") })
        settle()
        XCTAssertNil(store.lines(key: key, url: "u", width: 8, height: 4) { XCTFail("onReady must not fire") })
        settle()
        XCTAssertEqual(renders, 1, "an undecodable file that still exists must not loop")
    }

    func testRemoteFetchFailureOnANonSdKeyIsStillNegativeCached() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var fetches = 0
        let store = ArtworkStore(cacheDir: dir, fetch: { _ in fetches += 1; return nil }, render: { _, _, _ in ["ART"] })
        XCTAssertNil(store.lines(key: "a.9", url: "u", width: 8, height: 4) { })
        settle()
        XCTAssertNil(store.lines(key: "a.9", url: "u", width: 8, height: 4) { })
        settle()
        XCTAssertNil(store.block(key: "a.9", url: "u", width: 8, height: 4, kitty: true) { })
        settle()
        XCTAssertEqual(fetches, 1)
    }

    // MARK: kitty path

    func testKittyEvictedSdFileIsNotNegativeCachedAndAReinstallTransmits() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let jpeg = makeSolidColorJPEG() else { XCTFail("fixture"); return }
        let store = ArtworkStore(cacheDir: dir, fetch: { _ in nil }, render: { _, _, _ in [] })
        XCTAssertNil(store.block(key: key, url: "file:///gone", width: 8, height: 4, kitty: true) { XCTFail("nothing to transmit") })
        settle()
        install(jpeg, in: dir, as: key)
        let ready = expectation(description: "onReady")
        XCTAssertNil(store.block(key: key, url: "file:///gone", width: 8, height: 4, kitty: true) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        guard case .kitty(_, let transmit)? = store.block(key: key, url: "file:///gone", width: 8, height: 4, kitty: true, onReady: {}) else {
            XCTFail("expected .kitty"); return
        }
        XCTAssertNotNil(transmit)
    }

    func testKittyPresentButUndecodableSdFileIsStillNegativeCached() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let jpeg = makeSolidColorJPEG() else { XCTFail("fixture"); return }
        install(Data([0, 1, 2, 0xFF]), in: dir, as: key)
        let store = ArtworkStore(cacheDir: dir, fetch: { _ in XCTFail("on disk: no fetch"); return nil }, render: { _, _, _ in [] })
        XCTAssertNil(store.block(key: key, url: "u", width: 8, height: 4, kitty: true) { XCTFail("must not transmit") })
        settle()
        install(jpeg, in: dir, as: key)       // even a good file under that key is not retried this session
        XCTAssertNil(store.block(key: key, url: "u", width: 8, height: 4, kitty: true) { XCTFail("must not retry a negative-cached key") })
        settle()
        XCTAssertNil(store.block(key: key, url: "u", width: 8, height: 4, kitty: true) { })
    }
}
