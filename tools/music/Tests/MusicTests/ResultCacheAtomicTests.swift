import XCTest
@testable import music

/// The four cache writes used `data.write(to:)` with no options, which is a
/// truncate-then-write: the file is emptied, then refilled. Any reader landing
/// in that window sees a short file and fails to decode. A crash in that window
/// leaves the cache permanently truncated.
///
/// Truncation-by-crash cannot be induced in a unit test, but it is the same
/// flag that fixes both, and the concurrent-reader half IS observable: with an
/// atomic write the reader sees either the old file or the new one and never a
/// partial one, because Foundation writes a temp file and renames it.
final class ResultCacheAtomicTests: XCTestCase {

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "/musictui-cache-test-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func songs(_ n: Int, tag: String) -> [SongResult] {
        (0..<n).map {
            SongResult(index: $0,
                       title: "\(tag) title \($0) padded out so the payload is big enough to straddle a write",
                       artist: "\(tag) artist \($0)",
                       album: "\(tag) album \($0)",
                       catalogId: "\(tag)-\($0)")
        }
    }

    /// A reader interleaved with writers must never observe a half-written
    /// file. Without the atomic option this fails: the read lands mid-truncate
    /// and JSONDecoder throws on the short data.
    func testConcurrentReadsNeverSeeAPartiallyWrittenCache() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ResultCache(directory: dir)

        // Seed so the file always exists; a missing file is a legal read result
        // and is not what this test is about.
        try? cache.writeSongs(songs(200, tag: "seed"))

        let deadline = Date().addingTimeInterval(2.0)
        var decodeFailures = 0
        let lock = NSLock()

        let writers = DispatchQueue(label: "writers", attributes: .concurrent)
        let group = DispatchGroup()

        for w in 0..<2 {
            group.enter()
            writers.async {
                var i = 0
                while Date() < deadline {
                    // Alternating sizes so a truncate window is wide and the
                    // short read is unambiguous.
                    let n = (i % 2 == 0) ? 400 : 20
                    try? cache.writeSongs(self.songs(n, tag: "w\(w)"))
                    i += 1
                }
                group.leave()
            }
        }

        group.enter()
        writers.async {
            while Date() < deadline {
                do {
                    _ = try cache.readSongs()
                } catch is CacheError {
                    // "no cache" is legal; only a decode failure indicates a
                    // partially written file.
                } catch {
                    lock.lock(); decodeFailures += 1; lock.unlock()
                }
            }
            group.leave()
        }

        group.wait()
        XCTAssertEqual(decodeFailures, 0,
                       "a reader saw a partially written cache file \(decodeFailures) time(s)")
    }
}
