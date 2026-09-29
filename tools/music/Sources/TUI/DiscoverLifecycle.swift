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

/// `identity` is SpanDAC data only: the container was made, but no persistent
/// ID to play it by arrived in time, or its tracks were not exactly the
/// expected ones in the expected order, so nothing plays and the container is
/// left for the sweep. `selectionChanged`, SpanDAC data only too: the output
/// or the data source moved before the play, so nothing plays.
enum DiscoverFailureStage: Equatable { case create, readiness, identity, selectionChanged }

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
    /// SpanDAC data only (score C-ADD): the request that makes the container
    /// was sent and no classifiable answer came back (a timeout, a closed
    /// socket, a lost reply, or SpanDAC's own `outcome: unknown`). The
    /// container may exist, so it is PROTECTED while the attempt lives. Not
    /// terminal: the attempt pauses here, and the person's next Enter resumes
    /// it with the SAME name, never by itself.
    case unknownOutcome(String)

    var name: String {
        switch self {
        case .minted(let n), .created(let n), .ready(let n), .playIssued(let n),
             .unconfirmed(let n), .playAmbiguous(let n), .confirmedPlaying(let n),
             .failedBeforePlay(let n, _), .unknownOutcome(let n):
            return n
        }
    }

    /// Design §3.1's protected column. Six states protect, two do not; with
    /// SpanDAC data a seventh, `unknownOutcome`, protects too.
    var isProtected: Bool {
        switch self {
        case .minted, .created, .ready, .playIssued, .unconfirmed, .playAmbiguous, .unknownOutcome: return true
        case .confirmedPlaying, .failedBeforePlay: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .unconfirmed, .playAmbiguous, .confirmedPlaying, .failedBeforePlay: return true
        case .minted, .created, .ready, .playIssued, .unknownOutcome: return false
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
    // SpanDAC data only. The container request's answer was lost: the attempt
    // pauses, and resuming it re-sends the same name, whose answer is then
    // classified like a first one.
    case (.minted, .unknownOutcome),
         (.unknownOutcome, .created), (.unknownOutcome, .failedBeforePlay(_, .create)),
         (.unknownOutcome, .unknownOutcome):
        return true
    // SpanDAC data only: made, but with no persistent ID to play it by, or
    // not exactly the expected tracks; or the selection moved before the play.
    case (.created, .failedBeforePlay(_, .identity)), (.created, .failedBeforePlay(_, .selectionChanged)):
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
    /// SpanDAC data only. A playlist SpanDAC has just made answers with no
    /// persistent ID for a few seconds (observed live: a few seconds after the
    /// create, the same ensure returned it). The same ensure, same name, is
    /// re-sent at this cadence until the ID arrives or the window closes.
    /// CHOSEN values: about once a second, for at most ten seconds.
    static let aliasCadence: TimeInterval = 1
    static let aliasWindow: TimeInterval = 10

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

/// Maps a thrown create to the outcome the user sees. A missing or expired
/// user token is the sign-in toast, exactly as before; anything else is the
/// create failure with its message.
func discoverCreateFailureOutcome(_ error: Error) -> DiscoverPlayOutcome {
    if isExpiredToken(error) { return .needsSignIn }
    if let auth = error as? AuthError, case .userTokenRequired = auth { return .needsSignIn }
    return .createFailed(error.localizedDescription)
}

/// The one honest toast each outcome earns. Never a success message for
/// anything but `.playing`: the point of resolving the outcome first is to
/// not claim playback started when it did not.
func discoverToastMessage(for outcome: DiscoverPlayOutcome, title: String) -> (text: String, isError: Bool) {
    switch outcome {
    case .playing(let playedTitle):
        return ("Playing \(playedTitle)", false)
    case .needsSignIn:
        return ("Sign in to play Discover music (music auth setup).", true)
    case .notReady:
        return ("'\(title)' is still loading — try again in a moment.", true)
    case .createFailed(let message):
        return ("Couldn't start '\(title)': \(message)", true)
    case .playFailed(let message):
        return ("Couldn't play '\(title)': \(message)", true)
    case .outcomeUnknown:
        return (discoverOutcomeUnknownText, true)
    case .refused(let message):
        return (message, true)
    }
}

// MARK: - Outcomes

/// `libraryOpsNotOffered`: SpanDAC data only, the connected SpanDAC does not
/// advertise the library ops, so nothing was minted or sent.
/// `selectionChanged`: SpanDAC data only, MusicTUI did not have SpanDAC data
/// on its own output when the play began, so nothing was minted or sent.
enum DiscoverRefusal: Equatable { case exiting, libraryOpsNotOffered, selectionChanged }

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
        /// The same ordering hook for Rule 2: called under the lock immediately
        /// before `finishExit()` waits on a running launch sweep. Production
        /// leaves it nil.
        var onExitWait: (() -> Void)? = nil
        /// Where the launch sweep body runs. Production: a global queue.
        var launchExecutor: (@escaping () -> Void) -> Void = { DispatchQueue.global().async(execute: $0) }
        /// SpanDAC data only: the track count of the container with this
        /// persistent ID (hex), read through AppleScript; 0 when unreadable.
        var readCountByPersistentID: (_ hex: String) -> Int = { _ in 0 }
        /// SpanDAC data only: `discoverConfirmationScript(persistentID:)`'s
        /// answer for this persistent ID (hex).
        var confirmReadByPersistentID: (_ hex: String) -> String = { _ in discoverNotYetToken }
        /// SpanDAC data only: the persistent IDs of the container's tracks, in
        /// the container's own order (the order it plays), for the container
        /// with this persistent ID (hex); nil when the read failed.
        var readContainerTrackIDsByPersistentID: (_ hex: String) -> [String]? = { _ in nil }
        /// SpanDAC data only: the identity read behind `verifyExactTracks`,
        /// for these persistent IDs (hex). Throws when the read failed.
        var readTracksByPersistentID: (_ hexes: [String]) throws -> [String: [HandoffTrackHit]] = { _ in
            throw ActionError(message: pickASpanDACOutput)
        }
    }

    /// SpanDAC data only: the play attempt whose container name is in use. The
    /// name is the token (`__discover__ <uuid> — <title>`): minted ONCE per
    /// attempt and recorded here and in the transaction table BEFORE the first
    /// request carries it. It is kept until the attempt ends in a confirmed
    /// failure or a completed play; while it is `unknownOutcome`, every SpanDAC
    /// play request resumes it with the same name rather than minting another.
    private struct SpanDACAttempt {
        let id: UUID
        let name: String
        let title: String
        let catalogIDs: [String]
        let disableShuffle: Bool
    }

    private let condition = NSCondition()
    private let seams: Seams
    // All three guarded by `condition`.
    private var admissionState: DiscoverAdmission = .open
    private var launchSweepState: DiscoverLaunchSweep = .notStarted
    private var transactionTable: [UUID: DiscoverTransactionState] = [:]
    private var spandacAttempt: SpanDACAttempt?

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

    /// The token of the SpanDAC attempt still in use, if any. For tests.
    var spandacAttemptName: String? { condition.lock(); defer { condition.unlock() }; return spandacAttempt?.name }

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
        guard awaitAdmissionLocked() else { condition.unlock(); return nil }
        let (id, name) = mintLocked(title: title)
        condition.unlock()
        seams.onTransition?(id, .minted(name))
        return (id, name)
    }

    /// Rule 1's wait. The caller holds the lock and still holds it on return.
    /// False when admission is closed.
    private func awaitAdmissionLocked() -> Bool {
        var toasted = false
        while true {
            if admissionState == .closed { return false }
            if launchSweepState.isFinished { return true }
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
    }

    /// Mints a name and records it as `minted`. Caller holds the lock.
    private func mintLocked(title: String) -> (UUID, String) {
        let id = UUID()
        let name = discoverPlaylistPrefix + id.uuidString + discoverPlaylistNameSeparator + title
        transactionTable[id] = .minted(name)
        return (id, name)
    }

    // MARK: SpanDAC data: the container made by SpanDAC on this Mac

    /// A Discover play on the MusicTUI output with SpanDAC as MusicTUI's data
    /// source (score C-ADD). Admission, the readiness and confirmation cadence
    /// and the sweeps are the shipped ones; three things differ:
    ///
    /// 1. The container is ensured by SpanDAC (`library.ensurePlaylist`) under
    ///    a client-generated name, minted once per attempt and recorded before
    ///    the first request.
    /// 2. It is read, played and confirmed by the persistent ID SpanDAC
    ///    returned, never by a name search. A playlist just made may answer
    ///    without that ID: the same ensure, same name, is re-sent about once a
    ///    second for up to ten seconds until it arrives. No ID in time, or a
    ///    container that does not hold exactly the expected tracks in the
    ///    expected order, plays nothing; neither does a routing stamp that
    ///    moved since the request began, read again just before the play.
    /// 3. A request whose outcome is unknown leaves the attempt in
    ///    `unknownOutcome`, protected, and nothing retries by itself. The next
    ///    request, which only a person's Enter makes, resumes that attempt and
    ///    re-sends the SAME name: SpanDAC then finds the one playlist instead
    ///    of making a second. A new name is minted only after a confirmed
    ///    failure or a completed play.
    ///
    /// The web service is never used here, and no developer key is read.
    func requestSpanDACPlay(title: String, catalogIDs: [String], disableShuffle: Bool,
                            library: SpanDACLibraryAdding,
                            currentStamp: @escaping () -> MusicTUIHandoffStamp?) -> DiscoverPlayRequestOutcome {
        guard library.canAdd else {
            seams.post(.outcome(.refused(updateSpanDACToPlayOnMusicTUI), title: title))
            return .refused(.libraryOpsNotOffered)
        }
        // The stamp at entry, read again just before the one sound mutation.
        guard let entryStamp = currentStamp() else {
            seams.post(.outcome(.refused(sourceChangedNothingPlayed), title: title))
            return .refused(.selectionChanged)
        }
        condition.lock()
        guard awaitAdmissionLocked() else { condition.unlock(); return .refused(.exiting) }
        let attempt: SpanDACAttempt
        let minted: Bool
        if let pending = spandacAttempt {
            // Resume: the same token, never a second one.
            attempt = pending
            minted = false
        } else {
            let (id, name) = mintLocked(title: title)
            attempt = SpanDACAttempt(id: id, name: name, title: title, catalogIDs: catalogIDs,
                                     disableShuffle: disableShuffle)
            spandacAttempt = attempt
            minted = true
        }
        condition.unlock()
        if minted { seams.onTransition?(attempt.id, .minted(attempt.name)) }
        return .completed(runSpanDAC(attempt, library: library,
                                     stampUnchanged: { currentStamp() == entryStamp }))
    }

    /// Ends the attempt in `state`: its token is spent, so the next request
    /// mints anew.
    private func finish(_ id: UUID, _ state: DiscoverTransactionState) -> DiscoverTransactionState {
        transition(id, to: state)
        return spent(id, state)
    }

    /// The attempt already reached `state`; spend its token.
    private func spent(_ id: UUID, _ state: DiscoverTransactionState) -> DiscoverTransactionState {
        condition.lock()
        if spandacAttempt?.id == id { spandacAttempt = nil }
        condition.unlock()
        return state
    }

    private func runSpanDAC(_ attempt: SpanDACAttempt, library: SpanDACLibraryAdding,
                            stampUnchanged: @escaping () -> Bool) -> DiscoverTransactionState {
        let id = attempt.id, name = attempt.name, title = attempt.title

        let ensured: (created: Bool, id: String, alias: String?)
        do {
            ensured = try library.ensurePlaylist(name: name, catalogueIDs: attempt.catalogIDs)
        } catch SpanDACLibraryOpError.outcomeUnknown {
            // The attempt and its token stay; nothing is re-sent by itself.
            transition(id, to: .unknownOutcome(name))
            seams.post(.outcome(.outcomeUnknown, title: title))
            return .unknownOutcome(name)
        } catch {
            // Confirmed: SpanDAC or Apple refused, or nothing was sent.
            let state = finish(id, .failedBeforePlay(name, .create))
            seams.post(.outcome(spandacCreateFailureOutcome(error), title: title))
            return state
        }
        transition(id, to: .created(name))

        // Play by identity only. A playlist just made may answer without its
        // persistent ID for a few seconds: the same ensure, same name, is
        // re-sent until it arrives. None in time: nothing plays, and the
        // container, now unprotected, is left for the sweep.
        let alias = ensured.alias ?? awaitAlias(name: name, catalogIDs: attempt.catalogIDs,
                                                playlistID: ensured.id, library: library)
        guard let alias, let hex = persistentIDHex(fromAlias: alias) else {
            let state = finish(id, .failedBeforePlay(name, .identity))
            seams.post(.outcome(.refused(pickASpanDACOutput), title: title))
            return state
        }
        let seams = self.seams
        let state = readyPlayConfirm(
            id: id, name: name, title: title, expected: attempt.catalogIDs.count,
            readCount: { seams.readCountByPersistentID(hex) },
            beforePlay: {
                // Exactly the expected tracks, in the order they will play,
                // then the stamp, last, just before the sound mutation.
                guard discoverContainerHoldsExactly(
                    catalogIDs: attempt.catalogIDs, containerHex: hex, library: library,
                    tracks: ClosurePersistentIDReader(read: seams.readTracksByPersistentID),
                    containerTrackIDs: seams.readContainerTrackIDsByPersistentID) else {
                    return (.identity, .refused(pickASpanDACOutput))
                }
                guard stampUnchanged() else { return (.selectionChanged, .refused(sourceChangedNothingPlayed)) }
                return nil
            },
            scripts: discoverPlayScripts(persistentID: hex, disableShuffle: attempt.disableShuffle),
            confirmRead: { seams.confirmReadByPersistentID(hex) })
        return spent(id, state)
    }

    /// Re-sends the SAME ensure (same name, same tracks; never a new name)
    /// every `aliasCadence` until the reply carries the persistent ID, for at
    /// most `aliasWindow`. The playlist exists, so each re-send finds it. A
    /// reply that says it made a playlist, or names a different one, ends the
    /// wait at once: that is not the playlist this attempt made. Anything
    /// else that is not the ID (a lost or refused re-send) waits for the next.
    private func awaitAlias(name: String, catalogIDs: [String], playlistID: String,
                            library: SpanDACLibraryAdding) -> String? {
        let scheduler = seams.scheduler
        let deadline = scheduler.now().addingTimeInterval(DiscoverScheduler.aliasWindow)
        while true {
            let next = scheduler.now().addingTimeInterval(DiscoverScheduler.aliasCadence)
            if next > deadline { return nil }
            scheduler.delay(next)
            guard let again = try? library.ensurePlaylist(name: name, catalogueIDs: catalogIDs) else { continue }
            guard !again.created, again.id == playlistID else { return nil }
            if let alias = again.alias { return alias }
        }
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
        return readyPlayConfirm(id: id, name: name, title: title, expected: catalogIDs.count,
                                readCount: { self.seams.readCount(name) },
                                scripts: discoverPlayScripts(playlistName: name, disableShuffle: disableShuffle),
                                confirmRead: { self.seams.confirmRead(name) })
    }

    /// Readiness, play and confirmation, from `created` to a terminal state.
    /// The container is addressed only through the three closures: by name on
    /// the shipped path, by persistent ID with SpanDAC data.
    ///
    /// `beforePlay` runs once readiness is reached and before the play: nil
    /// lets it play; a stage and outcome end it there, before anything plays.
    private func readyPlayConfirm(id: UUID, name: String, title: String, expected: Int,
                                  readCount: () -> Int,
                                  beforePlay: () -> (DiscoverFailureStage, DiscoverPlayOutcome)? = { nil },
                                  scripts: [String],
                                  confirmRead: () -> String) -> DiscoverTransactionState {
        let scheduler = seams.scheduler

        // Readiness: library adds return 202 and materialise asynchronously.
        let start = scheduler.now()
        pollLoop: while true {
            let observed = readCount()
            let elapsed = scheduler.now().timeIntervalSince(start)
            switch discoverReadiness(observed: observed, expected: expected,
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
        if let (stage, outcome) = beforePlay() {
            let state = DiscoverTransactionState.failedBeforePlay(name, stage)
            transition(id, to: state)
            seams.post(.outcome(outcome, title: title))
            return state
        }
        transition(id, to: .ready(name))

        // Play the playlist itself, never a track position within it (see
        // `discoverPlayScripts`). A thrown play is AMBIGUOUS: Music may have
        // accepted the command, so the container stays protected.
        do {
            try seams.play(scripts)
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
            if confirmRead() == discoverConfirmedToken {
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
        // Defensive: phase 1 should already have run. Idempotent, and it
        // broadcasts too, so a request waiting in Rule 1 is released even if
        // a caller skipped `closeAdmission()` (Codex M1).
        admissionState = .closed
        condition.broadcast()
        let deadline = seams.scheduler.deadline(.exitLaunchSweep)
        while launchSweepState.isRunning {
            seams.onExitWait?()
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

/// The outcome a CONFIRMED SpanDAC container failure shows. A SpanDAC that
/// does not offer the op says to update it; anything else is the create
/// failure with SpanDAC's own sentence.
func spandacCreateFailureOutcome(_ error: Error) -> DiscoverPlayOutcome {
    switch error {
    case SpanDACLibraryOpError.notOffered: return .refused(updateSpanDACToPlayOnMusicTUI)
    case SpanDACLibraryOpError.failed(let detail): return .createFailed(detail)
    default: return .createFailed(error.localizedDescription)
    }
}

// MARK: - Production wiring

/// Track count of a (possibly not-yet-visible) playlist, read through
/// AppleScript. A failed script or a playlist AppleScript can't see yet both
/// read as 0, which is safe: `discoverReadiness` treats 0 as "not ready" and
/// keeps polling until the timeout, never falsely claiming readiness.
func discoverReadPlaylistTrackCount(name: String, backend: AppleScriptBackend) -> Int {
    let esc = escapeAppleScriptString(name)
    guard let raw = try? syncRun({ try await backend.runMusic("return (count of tracks of playlist \"\(esc)\") as text") })
    else { return 0 }
    return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

/// The coordinator with its live seams. Every seam runs on whichever thread
/// calls it (the action queue for a play, a global queue for the launch
/// sweep, the main thread for the exit sweep) and blocks it with `syncRun`,
/// exactly as the code it replaces did. The REST backend is resolved per
/// create rather than held, because it is per-token and the tokens can
/// change under a running TUI; without both tokens the create refuses with
/// the sign-in outcome, the same gate `DiscoverScene` applies before asking.
func makeDiscoverLifecycleCoordinator(backend: AppleScriptBackend, status: StatusStore) -> DiscoverLifecycleCoordinator {
    let seams = DiscoverLifecycleCoordinator.Seams(
        runSweep: { script in
            _ = try syncRun { try await backend.runMusic(script) }
        },
        create: { name, ids in
            guard let api = makeArtworkAPI(), api.userToken != nil else { throw AuthError.userTokenRequired }
            _ = try syncRun { try await api.createPlaylist(name: name, songIDs: ids) }
        },
        readCount: { name in discoverReadPlaylistTrackCount(name: name, backend: backend) },
        play: { scripts in
            for script in scripts {
                _ = try syncRun { try await backend.runMusic(script) }
            }
        },
        confirmRead: { name in
            let script = discoverConfirmationScript(playlistName: name)
            let raw = try? syncRun { try await backend.runMusic(script, timeout: discoverConfirmationReadTimeout) }
            return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? discoverNotYetToken
        },
        post: { toast in
            switch toast {
            case .startupCleanup:
                status.post(discoverStartupCleanupToastText)
            case .outcome(let outcome, let title):
                let m = discoverToastMessage(for: outcome, title: title)
                // Every error outcome means the play did not start: it stays.
                status.post(m.text, error: m.isError, untilStateChange: m.isError)
            }
        },
        scheduler: .live,
        readCountByPersistentID: { hex in
            guard let raw = try? syncRun({ try await backend.runMusic(discoverTrackCountScript(persistentID: hex)) })
            else { return 0 }
            return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        },
        confirmReadByPersistentID: { hex in
            let script = discoverConfirmationScript(persistentID: hex)
            let raw = try? syncRun { try await backend.runMusic(script, timeout: discoverConfirmationReadTimeout) }
            return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? discoverNotYetToken
        },
        readContainerTrackIDsByPersistentID: { hex in
            guard let raw = try? syncRun({ try await backend.runMusic(discoverContainerTrackIDsScript(persistentID: hex)) })
            else { return nil }
            return parseContainerTrackIDsInOrder(raw)
        },
        readTracksByPersistentID: { hexes in
            // CHOSEN: 60 s for one read of every track, as the hand-off's.
            try AppleScriptPersistentIDReader(run: { script in
                try syncRun { try await backend.runMusic(script, timeout: 60) }
            }).tracks(persistentIDs: hexes)
        })
    return DiscoverLifecycleCoordinator(seams: seams)
}
