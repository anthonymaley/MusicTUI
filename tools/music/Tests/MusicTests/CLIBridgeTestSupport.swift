// tools/music/Tests/MusicTests/CLIBridgeTestSupport.swift
//
// A `CLIBridgeEnv` for tests (slice 3 score, S5). Every path it touches is
// under NSTemporaryDirectory(), in a directory of its own: `mode.json`, the
// `output.lock` beside it, and the result cache. A lock built from a store in
// the bare temp root would share `$TMPDIR/output.lock` with every other test
// doing the same, so each env gets its own directory, asserted, not assumed.
//
// The wire is the library scene tests' scripted `BridgeLibraryReadsWire`: per-op replies, an
// unscripted request answers a loud `bad_request`, and every request is
// recorded so a count of zero is a count.
import XCTest
@testable import music

/// What a test env printed and slept, recorded in order.
final class CLIBridgeTestIO {
    private let lock = NSLock()
    private var outLines: [String] = []
    private var errLines: [String] = []
    private var slept: [TimeInterval] = []
    /// Called on the sleeping thread with each requested wait, before it is
    /// recorded. A test uses it to act "between attempts" without sleeping.
    var onSleep: ((TimeInterval) -> Void)?

    var out: [String] { lock.lock(); defer { lock.unlock() }; return outLines }
    var err: [String] { lock.lock(); defer { lock.unlock() }; return errLines }
    var sleeps: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return slept }

    /// `out` as bytes on stdout: each line as `print` would write it.
    var stdoutBytes: String { out.map { $0 + "\n" }.joined() }

    func writeOut(_ s: String) { lock.lock(); outLines.append(s); lock.unlock() }
    func writeErr(_ s: String) { lock.lock(); errLines.append(s); lock.unlock() }
    func sleep(_ t: TimeInterval) {
        onSleep?(t)
        lock.lock(); slept.append(t); lock.unlock()
    }
}

/// Status replies a scripted Bridge sends.
enum CLIBridgeReplies {
    static func status(playback: String = "idle", authorization: String = "authorized",
                       contract: Int = sourceContractVersion) -> String {
        """
        {"ok":true,"status":{"playback":"\(playback)","authorization":"\(authorization)","contract":\(contract)}}
        """
    }
    static let ok = #"{"ok":true}"#
    static func warming(retryAfter: Double) -> String {
        #"{"ok":false,"error":{"kind":"warming","detail":"Bridge is reading your library","retry_after":"# + "\(retryAfter)}}"
    }
    static func refused(_ detail: String) -> String {
        #"{"ok":false,"error":{"kind":"bad_request","detail":""# + detail + #""}}"#
    }
}

extension CLIBridgeEnv {

    /// A test env: temp store set to `mode`, its own temp lock, a temp cache,
    /// a Bridge client on `wire`'s transport, and `io` recording output and
    /// sleeps.
    ///
    /// `surface` is `.cli` unless a test says otherwise, and every Bridge-branch
    /// test drives the real CLI column: S6 and S7 dispatch `now`, transport,
    /// the `music play` forms and `search --library` from `.cli`. A test passes
    /// `.tui` only to model the TUI process itself. Production composes `.cli`
    /// only (`live()`).
    ///
    /// `outputLock` builds the CLI's lock from its path, so a test can hand in
    /// S1's latched lock (a waiter that pauses on a barrier, never a sleep).
    static func test(mode: PlaybackMode,
                     wire: BridgeLibraryReadsWire = BridgeLibraryReadsWire(),
                     cache: ResultCache? = nil,
                     io: CLIBridgeTestIO = CLIBridgeTestIO(),
                     surface: InvocationSurface = .cli,
                     outputLock: ((String) -> OutputLock)? = nil) -> CLIBridgeEnv {
        let dir = NSTemporaryDirectory() + "music-test-clibridge-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = PlaybackModeStore(path: dir + "/mode.json")
        precondition(store.set(mode), "could not write the temp mode store")
        let resultCache = cache ?? ResultCache(directory: dir + "/cache")

        for path in [dir + "/mode.json", store.lockPath, resultCache.directory] {
            precondition(isUnderTemporaryDirectory(path),
                         "CLIBridgeEnv.test path \(path) is not under NSTemporaryDirectory()")
        }

        let lock = outputLock?(store.lockPath) ?? OutputLock(path: store.lockPath)
        precondition(lock.path == store.lockPath, "the test lock must sit beside the temp mode.json")
        let routing = RoutingCoordinator(
            store: store, surface: surface,
            makeSource: { SourceAppClient(path: "/nonexistent/clibridge-test.sock", transport: wire.transport) },
            outputLock: lock)
        return CLIBridgeEnv(routing: routing, modeStore: store, cache: resultCache,
                            out: io.writeOut, err: io.writeErr, sleep: io.sleep)
    }

    /// The directory holding this env's mode.json and output.lock.
    var testDirectory: String {
        (routing.outputLock!.path as NSString).deletingLastPathComponent
    }
}

func isUnderTemporaryDirectory(_ path: String) -> Bool {
    let tmp = NSTemporaryDirectory()
    return path.hasPrefix(tmp) || path.hasPrefix("/private" + tmp)
}
