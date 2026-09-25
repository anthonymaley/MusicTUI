import XCTest
@testable import music

/// Arm the external-call tripwire for `body`, then disarm it and return every
/// AppleScript or REST call that reached a funnel. While armed, each call is
/// recorded and throws `ExternalCallBlocked` before any `Process` or
/// `URLSession` runs, so a count of zero is a count, not an inference.
func withTripwire<T>(_ body: () throws -> T) rethrows -> (result: T, calls: [ExternalCall]) {
    ExternalCallTripwire.shared.arm()
    let result: T
    do {
        result = try body()
    } catch {
        ExternalCallTripwire.shared.disarm()
        throw error
    }
    return (result, ExternalCallTripwire.shared.disarm())
}

/// Run `body` with stdout redirected into a pipe; return what it printed and
/// the error it threw, if any. `print` is buffered by stdio, so stdout is
/// flushed on both sides of the swap.
func captureStdout(_ body: () throws -> Void) -> (output: String, error: Error?) {
    let pipe = Pipe()
    fflush(stdout)
    let saved = dup(STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    var thrown: Error?
    do { try body() } catch { thrown = error }
    fflush(stdout)
    dup2(saved, STDOUT_FILENO)
    close(saved)
    try? pipe.fileHandleForWriting.close()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (String(decoding: data, as: UTF8.self), thrown)
}

/// A temp-directory cache plus counting `readSongs`/`readAuth` inputs for the
/// command-boundary tests. Never touches `~/.config/music`.
final class BoundaryHarness {
    let dir: URL
    let cache: ResultCache
    private(set) var songReads = 0
    private(set) var authReads = 0
    var tokens: (dev: String?, user: String?) = (nil, nil)

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-boundary-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        precondition(dir.path.hasPrefix(NSTemporaryDirectory()) || dir.path.hasPrefix("/private" + NSTemporaryDirectory()),
                     "boundary cache must live under NSTemporaryDirectory()")
        cache = ResultCache(directory: dir.path)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var deps: CachedRowCommandDeps {
        CachedRowCommandDeps(
            readSongs: { [unowned self] in
                self.songReads += 1
                return try self.cache.readSongs()
            },
            readAuth: { [unowned self] in
                self.authReads += 1
                return (dev: self.tokens.dev, user: self.tokens.user, storefront: "us")
            })
    }
}

extension SongResult {
    static func row(_ i: Int, _ origin: SongOrigin, catalogId: String? = nil, bridgeID: String? = nil) -> SongResult {
        SongResult(index: i, title: "T\(i)", artist: "A\(i)", album: "AL\(i)",
                   catalogId: catalogId ?? (origin == .bridgeLibrary ? "" : "id\(i)"),
                   origin: origin, bridgeID: bridgeID)
    }
}
