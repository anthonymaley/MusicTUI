// The one owner of a Discover container's lifecycle: create, readiness, play,
// confirmation, and both sweeps.
//
// Design: docs/plans/2026-09-03-discover-lifecycle-design.md (§3). Before
// this file, three actors touched a `__discover__` container on three threads
// with nothing coordinating them: the launch sweep (off-main, fire and
// forget), the play transaction (the shell's serial action queue), and the
// exit sweep (main thread, in `runShell`'s `defer`). The launch sweep read
// the current playlist's name once, before a container existed, so a play
// landing during a slow sweep could have its container captured and deleted
// as it started; an exit sweep landing between `play playlist` returning and
// Music reporting `playing` read a sweepable state and deleted the container
// whose first track was about to sound.
//
// Three rules, one `NSCondition`:
//
//   Rule 1  admission requires the launch sweep to have FINISHED. A play
//           request waits (timed, then untimed) before it mints a name, so
//           the set of registered transactions is empty for the whole
//           duration of the launch sweep. That is the lemma B1 pins.
//   Rule 2  exit closes admission FIRST (before `poller.stop()`), then, at
//           the old sweep line, waits briefly for a still-running launch
//           sweep, snapshots the protected names, and bakes them into the
//           exit sweep script. Exit never waits on a play transaction.
//   Rule 3  confirmation is positive ownership evidence: `player state` is
//           `nowPlayingReadyState` AND `name of current playlist` is this
//           transaction's name, compared inside AppleScript. Anything short
//           of that within the bound leaves the container PROTECTED for the
//           rest of the process. The fail direction is a leak a later sweep
//           collects, never a deletion.
//
// Every wait here uses the production condition variable; tests supply only
// the deadline instants through the scheduler seam, so B16 exercises the real
// wait-releases-lock behaviour rather than a fake that returns.
import Foundation

// MARK: - State

enum DiscoverAdmission: Equatable { case open, closed }

enum DiscoverSweepOutcome: Equatable { case swept, failed(String) }

enum DiscoverLaunchSweep: Equatable {
    case notStarted, running, finished(DiscoverSweepOutcome)
    var isFinished: Bool { if case .finished = self { return true } else { return false } }
    var isRunning: Bool { self == .running }
}

enum DiscoverFailureStage: Equatable { case create, readiness }

/// One transaction's position, with the protection each position carries
/// (design §3.1). `protected` is derived from this, never stored beside it.
enum DiscoverTransactionState: Equatable {
    case minted(String)
    case created(String)
    case ready(String)
    case playIssued(String)
    /// The confirmation bound elapsed without evidence. Protected for the
    /// rest of the process.
    case unconfirmed(String)
    /// `play playlist` threw. A thrown or timed-out Apple Event does not prove
    /// Music refused it, so this is protected for the rest of the process.
    case playAmbiguous(String)
    /// State AND current playlist matched. From here the sweep's ordinary
    /// state rule governs (I5).
    case confirmedPlaying(String)
    /// The create threw, or readiness timed out. Unprotected because no play
    /// command follows, so no deletion can interrupt playback; NOT because
    /// nothing exists. A create can throw after a 2xx (`createPlaylist`
    /// throws `noData` on an id-less body) and a transport failure is
    /// ambiguous about server acceptance, so a container may exist and a
    /// later sweep collects it.
    case failedBeforePlay(String, DiscoverFailureStage)

    var name: String {
        switch self {
        case .minted(let n), .created(let n), .ready(let n), .playIssued(let n),
             .unconfirmed(let n), .playAmbiguous(let n), .confirmedPlaying(let n),
             .failedBeforePlay(let n, _):
            return n
        }
    }

    /// Design §3.1's protected column. Six states protect, two do not.
    var isProtected: Bool {
        switch self {
        case .minted, .created, .ready, .playIssued, .unconfirmed, .playAmbiguous: return true
        case .confirmedPlaying, .failedBeforePlay: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .unconfirmed, .playAmbiguous, .confirmedPlaying, .failedBeforePlay: return true
        case .minted, .created, .ready, .playIssued: return false
        }
    }
}

/// The transition graph, pure. A terminal state has no successor; every
/// other state has exactly the successors the stage after it can produce.
func discoverTransitionIsLegal(from: DiscoverTransactionState, to: DiscoverTransactionState) -> Bool {
    guard from.name == to.name else { return false }
    switch (from, to) {
    case (.minted, .created), (.minted, .failedBeforePlay(_, .create)):
        return true
    case (.created, .ready), (.created, .failedBeforePlay(_, .readiness)):
        return true
    case (.ready, .playIssued), (.ready, .playAmbiguous):
        return true
    case (.playIssued, .confirmedPlaying), (.playIssued, .unconfirmed):
        return true
    default:
        return false
    }
}

// MARK: - Seams

/// Which wait a deadline is for. The production scheduler adds the matching
/// constant to the clock; a test hands back whatever instant makes the
/// branch under test deterministic.
enum DiscoverWait: Equatable {
    /// Rule 1's timed first wait, after which the startup toast is posted.
    case admissionToast
    /// Rule 2's wait for a still-running launch sweep.
    case exitLaunchSweep
    /// Readiness polling after the create.
    case readiness
    /// Confirmation polling after the play.
    case confirmation
}

/// Three different waits, kept distinct on purpose (design §3.6): `now()` for
/// elapsed time, `delay(until:)` for the sleeps between polls (a sleep, never
/// a condition wait), and `deadline(for:)` supplying the instants handed to
/// the coordinator's own `NSCondition.wait(until:)`.
struct DiscoverScheduler {
    var now: () -> Date
    var deadline: (DiscoverWait) -> Date
    var delay: (Date) -> Void

    static let admissionToastDelay: TimeInterval = 1
    static let exitLaunchSweepWait: TimeInterval = 2
    static let readinessTimeout: TimeInterval = 20
    static let readinessCadence: TimeInterval = 0.5
    static let confirmationBound: TimeInterval = 3
    static let confirmationCadence: TimeInterval = 0.3

    static func interval(for wait: DiscoverWait) -> TimeInterval {
        switch wait {
        case .admissionToast: return admissionToastDelay
        case .exitLaunchSweep: return exitLaunchSweepWait
        case .readiness: return readinessTimeout
        case .confirmation: return confirmationBound
        }
    }

    static let live = DiscoverScheduler(
        now: Date.init,
        deadline: { Date().addingTimeInterval(interval(for: $0)) },
        delay: { until in
            let seconds = until.timeIntervalSinceNow
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        })
}

/// What the coordinator asks the shell to show. Posting is a seam so tests
/// can assert exactly which toasts a path earns, and when.
enum DiscoverToast: Equatable {
    case outcome(DiscoverPlayOutcome, title: String)
    /// Rule 1's explanation for a key that has not acted yet.
    case startupCleanup
}

let discoverStartupCleanupToastText = "Finishing startup cleanup…"

/// The token a confirmation read returns when, inside AppleScript, the player
/// state is `nowPlayingReadyState` AND the current playlist is the named
/// container. Anything else is `notyet`. Fixed tokens rather than a delimited
/// payload, because the container name carries a user-controlled title.
let discoverConfirmedToken = "confirmed"
let discoverNotYetToken = "notyet"

/// Per-read backend timeout for a confirmation read. Short, so one
/// in-progress read can overrun the nominal bound by at most this much
/// (design §3.4: worst case about eight seconds, ordinarily one or two reads).
let discoverConfirmationReadTimeout: TimeInterval = 5

/// One confirmation read, as text. Both reads are inside `try`, so a failed
/// read is `notyet` and polling continues; an unreadable context is never
/// confirmation. The comparison happens inside AppleScript.
func discoverConfirmationScript(playlistName: String) -> String {
    let esc = escapeAppleScriptString(playlistName)
    return """
        set stateText to ""
        set ctxName to ""
        try
            set stateText to player state as text
        end try
        try
            set ctxName to name of current playlist
        end try
        if stateText is "\(nowPlayingReadyState)" and ctxName is "\(esc)" then return "\(discoverConfirmedToken)"
        return "\(discoverNotYetToken)"
        """
}

/// Maps a thrown create to the outcome the user sees. An expired user token
/// is the sign-in toast, exactly as before; anything else is the create
/// failure with its message.
func discoverCreateFailureOutcome(_ error: Error) -> DiscoverPlayOutcome {
    isExpiredToken(error) ? .needsSignIn : .createFailed(error.localizedDescription)
}

// MARK: - Outcomes

enum DiscoverRefusal: Equatable { case exiting }

enum DiscoverPlayRequestOutcome: Equatable {
    /// Refused before minting: no name, no create, no footprint in Music.
    case refused(DiscoverRefusal)
    /// The transaction reached a terminal state.
    case completed(DiscoverTransactionState)
}

enum DiscoverExitOutcome: Equatable {
    /// The exit sweep ran with these names protected (sorted).
    case swept(protected: [String])
    /// The launch sweep was still running at the deadline. By the lemma there
    /// were no transactions of ours to protect, so nothing is lost; the
    /// prior-session residue the launch sweep was collecting stays eligible
    /// for a later sweep.
    case skippedLaunchSweepStillRunning
}

// MARK: - Coordinator

final class DiscoverLifecycleCoordinator {
    struct Seams {
        var runSweep: (String) throws -> Void
        var create: (_ name: String, _ catalogIDs: [String]) throws -> Void
        var readCount: (_ name: String) -> Int
        var play: (_ scripts: [String]) throws -> Void
        /// Returns `discoverConfirmedToken` or anything else.
        var confirmRead: (_ name: String) -> String
        var post: (DiscoverToast) -> Void
        var scheduler: DiscoverScheduler
        /// Observation hook for tests: every transition, in order, outside
        /// the lock. Production leaves it nil.
        var onTransition: ((UUID, DiscoverTransactionState) -> Void)? = nil
        /// Ordering hook for tests, called UNDER the lock immediately before a
        /// request enters a condition wait in Rule 1. Because the caller holds
        /// the lock, anything the test does after this hook that needs the lock
        /// (such as `closeAdmission()`) cannot run until the request is inside
        /// the wait, which is what makes "woken by the broadcast" provable
        /// rather than assumed. Production leaves it nil.
        var onAdmissionWait: (() -> Void)? = nil
        /// Where the launch sweep body runs. Production: a global queue.
        var launchExecutor: (@escaping () -> Void) -> Void = { DispatchQueue.global().async(execute: $0) }
    }

    private let condition = NSCondition()
    private let seams: Seams
    // All three guarded by `condition`.
    private var admissionState: DiscoverAdmission = .open
    private var launchSweepState: DiscoverLaunchSweep = .notStarted
    private var transactionTable: [UUID: DiscoverTransactionState] = [:]

    init(seams: Seams) { self.seams = seams }

    // Read-only views for tests and diagnostics, taken under the lock.
    var admission: DiscoverAdmission { condition.lock(); defer { condition.unlock() }; return admissionState }
    var launchSweep: DiscoverLaunchSweep { condition.lock(); defer { condition.unlock() }; return launchSweepState }
    var transactions: [UUID: DiscoverTransactionState] { condition.lock(); defer { condition.unlock() }; return transactionTable }

    /// Design §3.1: derived, never stored. Caller holds the lock.
    private func protectedNamesLocked() -> [String] {
        transactionTable.values.filter { $0.isProtected }.map { $0.name }.sorted()
    }

    var protectedNames: [String] { condition.lock(); defer { condition.unlock() }; return protectedNamesLocked() }

    // MARK: Launch sweep

    /// Marks the launch sweep running BEFORE returning, then hands the body to
    /// the executor. The mark is synchronous so a request arriving on the next
    /// line already waits on it; the body is off the caller so a slow Music
    /// does not delay first paint.
    func startLaunchSweep() {
        condition.lock()
        guard launchSweepState == .notStarted else { condition.unlock(); return }
        launchSweepState = .running
        condition.unlock()
        seams.launchExecutor { [self] in
            let outcome: DiscoverSweepOutcome
            do {
                try seams.runSweep(discoverSweepScript())
                outcome = .swept
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            completeLaunchSweep(outcome)
        }
    }

    /// `finished` is entered exactly once, whatever the outcome, and the
    /// condition is broadcast so both a waiting request (Rule 1) and a
    /// waiting exit (Rule 2) wake.
    func completeLaunchSweep(_ outcome: DiscoverSweepOutcome) {
        condition.lock()
        defer { condition.unlock() }
        guard !launchSweepState.isFinished else { return }
        launchSweepState = .finished(outcome)
        condition.broadcast()
    }

    // MARK: Rule 1: admission

    /// The single entry point for a Discover play. Runs the whole transaction
    /// on the calling thread (the shell's serial action queue) and returns its
    /// terminal state, or a refusal that left no footprint.
    func requestPlay(title: String, catalogIDs: [String], disableShuffle: Bool) -> DiscoverPlayRequestOutcome {
        guard let (id, name) = admit(title: title) else { return .refused(.exiting) }
        return .completed(run(id: id, name: name, title: title,
                              catalogIDs: catalogIDs, disableShuffle: disableShuffle))
    }

    /// Waits for admission and mints under the lock. Returns nil when refused.
    private func admit(title: String) -> (UUID, String)? {
        condition.lock()
        var toasted = false
        while true {
            if admissionState == .closed { condition.unlock(); return nil }
            if launchSweepState.isFinished { break }
            seams.onAdmissionWait?()
            if toasted {
                // Untimed: only the broadcast (completion or closure) ends it.
                condition.wait()
                continue
            }
            let woke = condition.wait(until: seams.scheduler.deadline(.admissionToast))
            if !woke && !launchSweepState.isFinished && admissionState == .open {
                // Timed out with the sweep still running: explain the delay
                // once, then wait untimed for the broadcast.
                condition.unlock()
                seams.post(.startupCleanup)
                condition.lock()
                toasted = true
            }
        }
        let id = UUID()
        let name = discoverPlaylistPrefix + id.uuidString + discoverPlaylistNameSeparator + title
        transactionTable[id] = .minted(name)
        condition.unlock()
        seams.onTransition?(id, .minted(name))
        return (id, name)
    }

    private func transition(_ id: UUID, to state: DiscoverTransactionState) {
        condition.lock()
        if let current = transactionTable[id] {
            assert(discoverTransitionIsLegal(from: current, to: state),
                   "illegal Discover transition \(current) -> \(state)")
        }
        transactionTable[id] = state
        condition.unlock()
        seams.onTransition?(id, state)
    }

    // MARK: Stages (design §3.6)

    private func run(id: UUID, name: String, title: String,
                     catalogIDs: [String], disableShuffle: Bool) -> DiscoverTransactionState {
        let scheduler = seams.scheduler

        // Create and seed in one request. The id it returns is not needed:
        // readiness polls by NAME through AppleScript, and playback plays the
        // playlist by name too.
        do {
            try seams.create(name, catalogIDs)
        } catch {
            let state = DiscoverTransactionState.failedBeforePlay(name, .create)
            transition(id, to: state)
            seams.post(.outcome(discoverCreateFailureOutcome(error), title: title))
            return state
        }
        transition(id, to: .created(name))

        // Readiness: library adds return 202 and materialise asynchronously.
        let start = scheduler.now()
        pollLoop: while true {
            let observed = seams.readCount(name)
            let elapsed = scheduler.now().timeIntervalSince(start)
            switch discoverReadiness(observed: observed, expected: catalogIDs.count,
                                     elapsed: elapsed, timeout: DiscoverScheduler.readinessTimeout) {
            case .ready:
                break pollLoop
            case .timedOut:
                let state = DiscoverTransactionState.failedBeforePlay(name, .readiness)
                transition(id, to: state)
                seams.post(.outcome(.notReady, title: title))
                return state
            case .wait:
                scheduler.delay(scheduler.now().addingTimeInterval(DiscoverScheduler.readinessCadence))
            }
        }
        transition(id, to: .ready(name))

        // Play the playlist itself, never a track position within it (see
        // `discoverPlayScripts`). A thrown play is AMBIGUOUS: Music may have
        // accepted the command, so the container stays protected.
        do {
            try seams.play(discoverPlayScripts(playlistName: name, disableShuffle: disableShuffle))
        } catch {
            let state = DiscoverTransactionState.playAmbiguous(name)
            transition(id, to: state)
            seams.post(.outcome(.playFailed(error.localizedDescription), title: title))
            return state
        }
        transition(id, to: .playIssued(name))
        // The toast is unchanged from before: posted as soon as the play
        // returns, before confirmation (design §3.4, timing made explicit).
        seams.post(.outcome(.playing(title: title), title: title))

        // Rule 3: confirmation, against an absolute deadline, at the `now`
        // command's cadence. Each read compares inside AppleScript.
        // A read is never SCHEDULED past the deadline, so the count is bounded
        // by the cadence: at 0.3s over 3s that is eleven reads at most
        // (t = 0, 0.3, …, 3.0), ordinarily one or two.
        let deadline = scheduler.deadline(.confirmation)
        while true {
            if seams.confirmRead(name) == discoverConfirmedToken {
                let state = DiscoverTransactionState.confirmedPlaying(name)
                transition(id, to: state)
                return state
            }
            let next = scheduler.now().addingTimeInterval(DiscoverScheduler.confirmationCadence)
            if next > deadline {
                let state = DiscoverTransactionState.unconfirmed(name)
                transition(id, to: state)
                return state
            }
            scheduler.delay(next)
        }
    }

    // MARK: Rule 2: exit, two phases

    /// Phase 1, the FIRST statement of the exit `defer`, ahead of
    /// `poller.stop()`. Synchronous, no waiting. Any request waiting in Rule 1
    /// wakes and is refused without minting; any later request is refused at
    /// its first check.
    func closeAdmission() {
        condition.lock()
        admissionState = .closed
        condition.broadcast()
        condition.unlock()
    }

    /// Phase 2, at the old sweep line, after the poller is confirmed stopped.
    /// Waits briefly for a still-running launch sweep (releasing the lock so
    /// its completion can wake us), snapshots the protected names, and runs
    /// the exit sweep with them baked in. Never waits on a play transaction.
    @discardableResult
    func finishExit() -> DiscoverExitOutcome {
        condition.lock()
        // Defensive: phase 1 should already have run. Idempotent.
        admissionState = .closed
        let deadline = seams.scheduler.deadline(.exitLaunchSweep)
        while launchSweepState.isRunning {
            let woke = condition.wait(until: deadline)
            if !woke && launchSweepState.isRunning {
                condition.unlock()
                return .skippedLaunchSweepStillRunning
            }
        }
        let protected = protectedNamesLocked()
        condition.unlock()
        // Transactions still in flight are NOT marked here: the action thread
        // may be transitioning concurrently and a state written here would be
        // schedule-sensitive. The snapshot is exact; that is what tests assert.
        try? seams.runSweep(discoverSweepScript(protectedNames: protected))
        return .swept(protected: protected)
    }
}
