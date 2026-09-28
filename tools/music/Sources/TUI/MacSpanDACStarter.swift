// Starting SpanDAC on this Mac (score: data route and output, C-START).
//
// Step 0 seeded the protocol and a stub that never starts anything. This step
// fills in the live launcher, locator and poller, off the main loop, with
// three seams so nothing here ever touches a real process or socket under
// test: the launch itself goes through `ExternalCallTripwire` (the same
// tripwire that guards AppleScript and REST); the control-socket probe has no
// tripwire funnel of its own, so it is its own injected closure; and the
// clock (elapsed time and the pause between polls) is injected too.
import AppKit
import Foundation

/// The outcome of trying to bring SpanDAC on this Mac to a state that can
/// serve data.
enum MacSpanDACStartOutcome: Equatable {
    case ready
    case notInstalled
    case notAuthorized
    case timedOut
    case failed(String)
}

extension MacSpanDACStartOutcome {
    /// The sentence a person reads for this outcome (CHOSEN; C-START). Empty
    /// for `.ready`, which is never shown as a refusal.
    var sentence: String {
        switch self {
        case .ready:
            return ""
        case .notInstalled:
            return "SpanDAC isn't installed on this Mac."
        case .notAuthorized:
            return "SpanDAC needs Apple Music access. Open SpanDAC on this Mac and allow it."
        case .timedOut:
            return "SpanDAC on this Mac didn't start. Open it from your Applications folder."
        case .failed(let why):
            return why
        }
    }
}

/// Seam for starting, or reporting on, SpanDAC on this Mac. A later step's
/// live implementation launches at most once per attempt, off the main loop,
/// and never triggers the authorization prompt itself.
protocol MacSpanDACStarting: AnyObject {
    /// LaunchServices knows the app, or its socket already exists.
    var isInstalled: Bool { get }
    /// LaunchServices only (independent of the socket), for C-REPAIR's
    /// "paused" test.
    var isRunning: Bool { get }
    var isStarting: Bool { get }
    /// Blocking, bounded; never called on the main loop.
    func ensureStarted() -> MacSpanDACStartOutcome
    /// Brings the app forward without triggering authorization; only ever
    /// called from a person's Enter.
    func bringForward()
    /// Clears a sticky failed attempt so the next `ensureStarted()` tries
    /// again; only ever called from a person's Enter or a new process.
    func newAttempt()
}

/// The seed's only implementation: reports as never installed and never
/// starts anything. Safe as a default in every environment, including tests
/// that never construct a starter of their own.
final class NeverStartsMacSpanDAC: MacSpanDACStarting {
    var isInstalled: Bool { false }
    var isRunning: Bool { false }
    var isStarting: Bool { false }
    func ensureStarted() -> MacSpanDACStartOutcome { .notInstalled }
    func bringForward() {}
    func newAttempt() {}
}

/// SpanDAC on this Mac's bundle identifier, in this one constant.
///
/// **TEMPORARY and borrowed** (score's Open list): this is the App ID created
/// for MusicKit's automatic-token service, reused for this dogfood build by
/// standing decision; it is not yet a durable product identity, and nothing
/// in this file may assume it survives a future rename. Auto-launch and
/// bring-forward key on it, so a rename there is the one place this changes.
let macSpanDACBundleID = "com.anthonymaley.music-catalog"

/// One probe of SpanDAC's control socket while starting it: whether it
/// answered ready, said it needs Apple Music access, hasn't answered
/// something actionable yet (keep polling), or failed for a reason MusicTUI
/// can name (stop polling; sticky). The control socket has no
/// `ExternalCallTripwire` funnel of its own (only AppleScript and REST do), so
/// this closure IS the test seam: production reads it from a live
/// `SourceAppClient`, and every test supplies a fake.
enum MacSpanDACProbe: Equatable {
    case ready
    case notAuthorized
    case notYetReady
    case failed(String)
}

/// How `ensureStarted()` measures elapsed time and paces between polls.
/// Injectable (the "clock") so a test can prove the 15 s bound and the 250 ms
/// cadence without waiting for either; production ticks the wall clock and
/// really pauses.
struct MacSpanDACClock {
    var now: () -> Date
    var wait: (TimeInterval) -> Void

    static let live = MacSpanDACClock(now: Date.init, wait: { Thread.sleep(forTimeInterval: $0) })
}

/// The live way to bring SpanDAC on this Mac forward: `/usr/bin/open`,
/// hidden (`-g -j`) for a start, or plain for a person's Enter. Gated by
/// `ExternalCallTripwire` exactly as an AppleScript run or a REST request is:
/// a test that arms the tripwire records the call and never spawns the real
/// process.
func liveLaunchMacSpanDAC(bundleID: String, hidden: Bool) throws {
    try ExternalCallTripwire.shared.check(.launchApp(bundleID: bundleID))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = hidden ? ["-g", "-j", "-b", bundleID] : ["-b", bundleID]
    try process.run()
    process.waitUntilExit()
}

/// Installed = LaunchServices knows the app OR its control socket already
/// exists (a build that predates LaunchServices registration, or one whose
/// registration lagged, still counts once it has ever answered).
func liveMacSpanDACIsInstalled(bundleID: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        || FileManager.default.fileExists(atPath: SourceAppStationSearch.socketPath)
}

/// LaunchServices only, independent of the socket, for C-REPAIR's "paused"
/// test (a Mac SpanDAC whose process has quit but whose stale socket path
/// still exists on disk must not read as running).
func liveMacSpanDACIsRunning(bundleID: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
}

/// Sentences the app's own `slice.status` reply says are an authorization
/// problem (`StationSearchSource.swift`'s `readiness(from:)`), so this probe
/// can tell "needs Apple Music access" apart from "hasn't answered yet".
/// **Coupled, named rather than hidden:** these are copies of that function's sentences,
/// in a different file for the same reason `socketPath` is — a wording change
/// there silently stops this probe reporting `.notAuthorized` and it reads as
/// `.notYetReady` (retried until the 15 s bound, then `.timedOut`) instead.
private let macSpanDACNotAuthorizedSentences: Set<String> = [
    "SpanDAC has not been granted Apple Music access yet",
    "SpanDAC was denied Apple Music access",
    "Apple Music access is restricted on this Mac",
    "SpanDAC could not read its Apple Music access",
]

/// The live probe: one `slice.status` over the Mac's own Unix socket.
/// Starting SpanDAC on this Mac is for music DATA, so this reads
/// `dataReadiness`: SpanDAC answering with Apple Music access is ready, with
/// or without a DAC (a DAC is the output's concern, never the data's).
/// Access problems stop polling; anything else keeps polling, as before.
func liveMacSpanDACProbe(client: SourceAppClient = SourceAppClient()) -> MacSpanDACProbe {
    do {
        switch try client.control.status().dataReadiness {
        case .ready:
            return .ready
        case .unavailable(let reason) where macSpanDACNotAuthorizedSentences.contains(reason):
            return .notAuthorized
        case .unavailable, .checking:
            return .notYetReady
        }
    } catch SourceAppError.notAuthorized {
        return .notAuthorized
    } catch {
        return .notYetReady
    }
}

/// The live implementation of `MacSpanDACStarting`. Launches SpanDAC on this
/// Mac at most once per attempt, hidden, then polls its control socket every
/// `pollInterval` for up to `bound` before giving up. A non-ready outcome is
/// sticky until `newAttempt()` — the next `ensureStarted()` returns it again
/// without launching or polling a second time.
final class LiveMacSpanDACStarter: MacSpanDACStarting {
    private let bundleID: String
    private let checkInstalled: () -> Bool
    private let checkRunning: () -> Bool
    private let launch: (String) throws -> Void
    private let activate: (String) throws -> Void
    private let probe: () -> MacSpanDACProbe
    private let clock: MacSpanDACClock
    private let pollInterval: TimeInterval
    private let bound: TimeInterval

    private let lock = NSLock()
    private var launchedThisAttempt = false
    private var startingCount = 0
    private var stickyFailure: MacSpanDACStartOutcome?

    init(bundleID: String,
         checkInstalled: @escaping () -> Bool,
         checkRunning: @escaping () -> Bool,
         launch: @escaping (String) throws -> Void,
         activate: @escaping (String) throws -> Void,
         probe: @escaping () -> MacSpanDACProbe,
         clock: MacSpanDACClock = .live,
         pollInterval: TimeInterval = 0.25,
         bound: TimeInterval = 15) {
        self.bundleID = bundleID
        self.checkInstalled = checkInstalled
        self.checkRunning = checkRunning
        self.launch = launch
        self.activate = activate
        self.probe = probe
        self.clock = clock
        self.pollInterval = pollInterval
        self.bound = bound
    }

    var isInstalled: Bool { checkInstalled() }
    var isRunning: Bool { checkRunning() }
    var isStarting: Bool {
        lock.lock(); defer { lock.unlock() }
        return startingCount > 0
    }

    func ensureStarted() -> MacSpanDACStartOutcome {
        lock.lock()
        if let sticky = stickyFailure {
            lock.unlock()
            return sticky
        }
        guard checkInstalled() else {
            lock.unlock()
            return .notInstalled
        }
        let shouldLaunch = !launchedThisAttempt
        launchedThisAttempt = true
        startingCount += 1
        lock.unlock()
        defer {
            lock.lock()
            startingCount -= 1
            lock.unlock()
        }

        if shouldLaunch {
            do {
                try launch(bundleID)
            } catch {
                return sticking(.failed("\(error)"))
            }
        }

        let deadline = clock.now().addingTimeInterval(bound)
        while true {
            switch probe() {
            case .ready:
                return .ready
            case .notAuthorized:
                return sticking(.notAuthorized)
            case .failed(let why):
                return sticking(.failed(why))
            case .notYetReady:
                break
            }
            if clock.now() >= deadline {
                return sticking(.timedOut)
            }
            clock.wait(pollInterval)
        }
    }

    /// Records a non-ready outcome as this attempt's sticky failure, then
    /// returns it.
    private func sticking(_ outcome: MacSpanDACStartOutcome) -> MacSpanDACStartOutcome {
        lock.lock()
        stickyFailure = outcome
        lock.unlock()
        return outcome
    }

    /// Never triggers the authorization prompt itself: it only activates the
    /// app, exactly as a person double-clicking it would.
    func bringForward() {
        try? activate(bundleID)
    }

    func newAttempt() {
        lock.lock()
        launchedThisAttempt = false
        stickyFailure = nil
        lock.unlock()
    }
}

/// The live starter: SpanDAC on this Mac, launched hidden through
/// `ExternalCallTripwire`, polled over its own control socket.
func liveMacSpanDACStarter() -> MacSpanDACStarting {
    LiveMacSpanDACStarter(
        bundleID: macSpanDACBundleID,
        checkInstalled: { liveMacSpanDACIsInstalled(bundleID: macSpanDACBundleID) },
        checkRunning: { liveMacSpanDACIsRunning(bundleID: macSpanDACBundleID) },
        launch: { try liveLaunchMacSpanDAC(bundleID: $0, hidden: true) },
        activate: { try liveLaunchMacSpanDAC(bundleID: $0, hidden: false) },
        probe: { liveMacSpanDACProbe() })
}

/// The retry-once-after-a-start rule for one transport function (C-START).
///
/// A request that fails because SpanDAC on this Mac is not running asks
/// `starter` to bring it up, and only on `.ready` does it try the SAME
/// request again, once. Every other transport error (a malformed reply, a
/// permission problem on the socket itself, a timeout on a request that DID
/// reach a running SpanDAC) is not "not running" and never launches anything.
///
/// A free function, not a closure built inline in `macData(starter:)`, so a
/// test can drive it with a fake `send` and never reach a real socket.
func retryingOnceAfterAStart(
    _ send: @escaping (String, String) throws -> String,
    starter: MacSpanDACStarting
) -> (String, String) throws -> String {
    { path, line in
        do {
            return try send(path, line)
        } catch SourceAppError.notRunning {
            guard starter.ensureStarted() == .ready else { throw SourceAppError.notRunning }
            return try send(path, line)
        }
    }
}

extension SourceAppClient {
    /// The data client for an accepted SpanDAC-on-this-Mac selection: the
    /// plain Unix-socket client, with `retryingOnceAfterAStart` wrapped
    /// around both its transports.
    static func macData(starter: MacSpanDACStarting) -> SourceAppClient {
        let path = SourceAppStationSearch.socketPath
        let baseTransport = SourceAppStationSearch.sendOverUnixSocket
        let baseLibraryTransport = SourceAppStationSearch.sender(
            timeoutSeconds: SourceAppControl.libraryReadTimeoutSeconds)
        return SourceAppClient(
            path: path,
            transport: retryingOnceAfterAStart(baseTransport, starter: starter),
            libraryTransport: retryingOnceAfterAStart(baseLibraryTransport, starter: starter))
    }
}

/// Shown while `ensureStarted()` is in flight (C-START).
let startingSpanDAC = "Starting SpanDAC…"
