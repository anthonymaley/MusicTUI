// tools/music/Tests/MusicTests/ArtworkStoreLibraryCoverReadTests.swift
import XCTest
@testable import music

/// A SpanDAC library cover is read in place: its render key is the file key plus a
/// digest of the bytes the fetcher installed, and the file itself can be replaced or
/// evicted under a worker. The store must only ever publish a render of exactly the
/// bytes the key names, and must decide a failure on the file it actually read:
/// missing at read is an eviction (never negative), present but undecodable is a bad
/// cover (negative, once). Temp directory, injected render and clock; no network.
final class ArtworkStoreLibraryCoverReadTests: XCTestCase {

    private let base = "sd_0123456789abcdef0123456789abcdef"

    private final class Clock { var t: TimeInterval = 0 }

    private struct Rig {
        let dir: String
        let store: ArtworkStore
        let clock: Clock
        let base: String
        var url: String { URL(fileURLWithPath: "\(dir)/\(base)").absoluteString }

        func key(_ bytes: Data) -> String { base + "_" + LibraryCoverFetcher.renderDigest(bytes) }

        func install(_ bytes: Data) {
            try? bytes.write(to: URL(fileURLWithPath: "\(dir)/\(base)"), options: .atomic)
        }

        func remove() { try? FileManager.default.removeItem(atPath: "\(dir)/\(base)") }
    }

    private var dirs: [String] = []

    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(atPath: $0) }
        super.tearDown()
    }

    /// `render` names the bytes it was handed by their digest, or fails on anything
    /// that is not a decodable image.
    private func rig() -> Rig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-library-read-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let clock = Clock()
        let store = ArtworkStore(cacheDir: dir, fetch: { _ in nil },
                                 render: { path, _, _ in
                                     guard let data = FileManager.default.contents(atPath: path),
                                           imageDataToPNG(data) != nil else { return [] }
                                     return [LibraryCoverFetcher.renderDigest(data)]
                                 },
                                 now: { clock.t })
        return Rig(dir: dir, store: store, clock: clock, base: base)
    }

    private func lines(_ r: Rig, _ key: String) -> [String]? {
        if let hit = r.store.lines(key: key, url: r.url, width: 8, height: 4, onReady: {}) { return hit }
        r.store.waitUntilIdleForTesting()
        return r.store.lines(key: key, url: r.url, width: 8, height: 4) { }
    }

    private func kitty(_ r: Rig, _ key: String) -> String? {
        func escape(_ b: ArtBlock?) -> String? { if case .kitty(_, let t)? = b { return t }; return nil }
        if let hit = escape(r.store.block(key: key, url: r.url, width: 8, height: 4, kitty: true, onReady: {})) {
            return hit
        }
        r.store.waitUntilIdleForTesting()
        return escape(r.store.block(key: key, url: r.url, width: 8, height: 4, kitty: true) { })
    }

    private func expectedEscape(_ key: String, _ bytes: Data) -> String {
        kittyTransmitEscape(id: kittyImageID(forKey: key), png: imageDataToPNG(bytes)!)
    }

    // MARK: the key names the bytes

    func testAReplacementBeforeTheReadNeverPublishesOtherBytesUnderTheKey() {
        let a = LibraryCoverFetcherTests.jpeg(red: 200), b = LibraryCoverFetcherTests.jpeg(red: 20)
        for path in ["lines", "kitty"] {
            let r = rig()
            r.install(a)
            let keyA = r.key(a)
            let entered = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
            var held = false
            r.store.beforeLibraryCoverReadForTesting = {
                guard !held else { return }
                held = true
                entered.signal()
                go.wait()
            }
            if path == "lines" {
                XCTAssertNil(r.store.lines(key: keyA, url: r.url, width: 8, height: 4) { })
            } else {
                XCTAssertNil(r.store.block(key: keyA, url: r.url, width: 8, height: 4, kitty: true) { })
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "\(path): the worker never reached the read")
            r.install(b)   // a recheck renames B over the file while A's read is held
            go.signal()
            r.store.waitUntilIdleForTesting()

            r.install(a)   // A comes back under the same file
            r.clock.t += 3_600   // past any cooldown the mismatch set
            if path == "lines" {
                XCTAssertEqual(lines(r, keyA), [LibraryCoverFetcher.renderDigest(a)], "lines: B was drawn as A")
            } else {
                XCTAssertEqual(kitty(r, keyA), expectedEscape(keyA, a), "kitty: B was transmitted as A")
            }
        }
    }

    func testTheBytesTheKeyNamesRenderOnBothPaths() {
        let a = LibraryCoverFetcherTests.jpeg(red: 200)
        let r = rig()
        r.install(a)
        XCTAssertEqual(lines(r, r.key(a)), [LibraryCoverFetcher.renderDigest(a)])
        XCTAssertEqual(kitty(r, r.key(a)), expectedEscape(r.key(a), a))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.dir), [base], "read in place, no copy")
    }

    // MARK: failures decided on the file actually read

    func testAPresentButUndecodableCoverIsNegativeCachedOnceOnBothPaths() {
        let garbage = Data("not a jpeg".utf8)
        for path in ["lines", "kitty"] {
            let r = rig()
            r.install(garbage)
            var reads = 0
            r.store.beforeLibraryCoverReadForTesting = { reads += 1 }
            let key = r.key(garbage)
            for step in 0..<5 {
                r.clock.t += 60
                if path == "lines" { XCTAssertNil(lines(r, key), "\(path) \(step)") }
                else { XCTAssertNil(kitty(r, key), "\(path) \(step)") }
                r.store.pump()
                r.store.waitUntilIdleForTesting()
            }
            XCTAssertEqual(reads, 1, "\(path): an undecodable cover is read once, then negative-cached")
        }
    }

    func testACoverDeletedBetweenSelectionAndReadIsNotNegativeCached() {
        let a = LibraryCoverFetcherTests.jpeg(red: 200)
        for path in ["lines", "kitty"] {
            let r = rig()
            r.install(a)
            var first = true
            r.store.beforeLibraryCoverReadForTesting = {
                if first { first = false; r.remove() }   // evicted under the worker
            }
            let key = r.key(a)
            if path == "lines" { XCTAssertNil(lines(r, key), path) } else { XCTAssertNil(kitty(r, key), path) }
            r.install(a)   // reinstalled: the same bytes, the same key
            r.clock.t += 3_600
            if path == "lines" {
                XCTAssertEqual(lines(r, key), [LibraryCoverFetcher.renderDigest(a)], "lines: eviction was negative-cached")
            } else {
                XCTAssertEqual(kitty(r, key), expectedEscape(key, a), "kitty: eviction was negative-cached")
            }
        }
    }

    func testACoverMissingBeforeTheAskIsNotNegativeCached() {
        let a = LibraryCoverFetcherTests.jpeg(red: 200)
        for path in ["lines", "kitty"] {
            let r = rig()
            let key = r.key(a)
            if path == "lines" { XCTAssertNil(lines(r, key), path) } else { XCTAssertNil(kitty(r, key), path) }
            r.install(a)
            r.clock.t += 3_600
            if path == "lines" {
                XCTAssertEqual(lines(r, key), [LibraryCoverFetcher.renderDigest(a)], path)
            } else {
                XCTAssertEqual(kitty(r, key), expectedEscape(key, a), path)
            }
        }
    }
}
