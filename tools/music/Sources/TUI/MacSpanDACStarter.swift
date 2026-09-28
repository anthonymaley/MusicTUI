// Starting SpanDAC on this Mac (score: data route and output, C-START).
//
// This step seeds the protocol and a stub that never starts anything;
// nothing calls it yet, and no caller launches a real process from here. A
// later step wires the live launcher, locator and poller (through
// `ExternalCallTripwire` for its one process launch), all off the main loop.
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

/// The live starter. Seeded as the never-starting stub; a later step replaces
/// its body with the real launcher, locator and poller.
func liveMacSpanDACStarter() -> MacSpanDACStarting {
    NeverStartsMacSpanDAC()
}

extension SourceAppClient {
    /// The data client for an accepted SpanDAC-on-this-Mac selection. Seeded
    /// as the plain Unix-socket client; a later step adds the retry-once
    /// behaviour described in the score (C-START).
    static func macData(starter: MacSpanDACStarting) -> SourceAppClient {
        SourceAppClient()
    }
}

/// Shown while `ensureStarted()` is in flight (C-START).
let startingSpanDAC = "Starting SpanDAC…"
