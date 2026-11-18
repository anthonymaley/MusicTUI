// tools/music/Sources/TUI/RateAwareTransition.swift
import Foundation

// The per-track transition of the Mac route (mac-route-plan.md, section 3.3 and
// the "Appendix: rate transaction protocol", rules M1 to M5; score step P3).
// One `RateAwareTransition.run` is one sound start: first track, advance,
// next/previous, jump, shuffle, or a start with no rate work (a station, a
// resume). It puts `RateFence` (the fence, the lease, revalidate-and-play under
// the output lock) and `SourceRateFollow` (the four client ops, M2's bounded
// wait, M4's start line) together, and decides only what neither does:
//
//   1. fence + lease (M1)                       RateFence.begin
//   2. prepare, bounded wait (M2)                SourceRateFollow.prepare
//   3. revalidate the whole token, play (M3)     RateFence.playIfCurrent
//   4. wait (bounded) for THIS stream, then confirm   SourceRateFollow.confirm
//   5. correct at the start if SpanDAC says so    pause, correct, 0, resume (M5)
//   6. a stream that was not up in time is re-checked later, once (`recheck`)
//
// **The confirm read is for this stream (live check 2026-11-16).** Music keeps
// reporting the PREVIOUS stream's sample rate until the new stream is up (and
// refused `player position` for about 15 s after a jump to a hi-res song), so a
// single read half a second after the start confirmed 44100 for a 96000 song and
// SpanDAC rightly said `own_rate`. The read now waits, bounded, until Music is
// playing this persistent ID with the position advancing; only then is the rate
// read and sent. If the stream is not up in time nothing is confirmed (no rate is
// claimed that was not measured for this song) and `recheck` tries again later.
//
// **What it never does.** It never refuses a song for a rate reason: every
// outcome of the rate ops except the token going stale ends in a play (M4), and
// the start line says why. It never skips one: `RateTransitionResult.playOutcome`
// is the ONLY thing the caller may feed `AdvanceRetryGate`, and it is Music's
// own `play` result alone. An invalidated transition plays nothing and says so
// by `nil`, which touches no gate. One honest exception to "never refuses": a
// command that cannot take the output lock or write the fence plays NOTHING
// (`notStarted`), as `RateFence` and the lock's fail-closed rule already say,
// because that is a route switch in progress or a broken state directory, not a
// rate failure.
//
// **Known limit (the 22:52 ruling).** A write the DAC confirms only after the
// song started is never corrected mid-song; the next transition's prepare is
// the correction, and `RateTransitionPlayed.baseline` is what the poller
// compares `status.rate.rate_seq` with (`SourceRateFollow.warnsOfRateChange`).
//
// **The pause guarantee (section 3.3, D7).** The correction pauses the song
// itself, so the follower may resume only its OWN pause, and only when all of
// these hold at the moment of resuming, inside the output lock:
//   - the correction ended within `correctionWindow` (3 s) of the pause;
//   - Music still shows paused, on the same track, at the same position
//     (within `positionTolerance`, 0.5 s) as when the follower paused it;
//   - the fence did not move and the lease is ours (every MusicTUI command
//     moves the fence) and the caller's own checks still hold.
// A seek, a skip or a play seen in Music.app breaks the second condition; a TUI
// or CLI command breaks the third. Not detectable (D7, default: resume anyway):
// a pause pressed in Music.app's own window while ours is held changes nothing
// observable.
//
// Music.app is reached only through `RateMusicControlling`, so tests run with
// no AppleScript. `MacRoutePlayer` (P4) wires every TUI play on the Mac DAC route
// to this, with `AppleScriptRateMusic` as the real adapter.

// MARK: - the Music.app seam

/// What one AppleScript read of the current track gives (the one script of
/// section 3.3 step 4: `persistent ID`, `database ID`, `sample rate`).
struct RateTrackRead: Equatable {
    let persistentID: String
    let databaseID: Int?
    /// The delivered sample rate, in Hz; nil when Music reports none.
    let sampleRateHz: Int?
}

/// Music's player as the pause guarantee reads it.
struct RatePlayerState: Equatable {
    enum State: Equatable { case playing, paused, stopped }
    let state: State
    let persistentID: String?
    let position: TimeInterval
}

/// Music.app control for a rate transition. The real one is AppleScript (P4
/// wires it); tests fake it. Every method is one short call.
protocol RateMusicControlling {
    /// Starts the track by persistent ID. Its throw is the ONLY failure that
    /// feeds `AdvanceRetryGate`.
    func playTrack(persistentID: String) throws
    func pause() throws
    func resume() throws
    func seekToStart() throws
    /// nil when Music cannot be read (Automation off, nothing current).
    func readCurrentTrack() -> RateTrackRead?
    func readPlayerState() -> RatePlayerState?
}

/// How long and how often the transition waits for a stream to be up. The
/// windows are CHOSEN, NOT MEASURED, except that the live check saw Music refuse
/// `player position` for about 15 s after a jump (so the re-check window is twice
/// that). Tests pass an instant `sleep`.
struct RateStreamWait {
    /// The first confirm's bound: it holds up the caller, so it is short.
    var window: TimeInterval = 4
    var interval: TimeInterval = 0.25
    /// The later re-check's bound: it runs off the caller's thread.
    var recheckWindow: TimeInterval = 30
    var recheckInterval: TimeInterval = 1
    /// How many times, `pauseInterval` apart, the player is read to see the pause
    /// the follower just gave it. Music's player state lags a pause by a moment
    /// (live, 2026-11-17: its own log has the pause at 47.659 and the rate change at
    /// 47.899, and a read-back in between still said playing), so one read dropped
    /// the correction with Music left paused. 1 (a bare value, so every test that
    /// predates this) is the single read; `live` waits up to five reads, a second
    /// or so. CHOSEN, NOT MEASURED: the one measured lag was about a quarter second.
    var pauseReads = 1
    var pauseInterval: TimeInterval = 0.25
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    static let live = RateStreamWait(pauseReads: 5)
}

// MARK: - plan and result

/// What starts the sound.
enum RateSound {
    /// A song by persistent ID: prepare, play, confirm, maybe correct.
    case track(persistentID: String, catalogID: String?)
    /// A start with no rate work (a station, a resume): announce, wait for the
    /// DAC to be quiet, then `start`. Nothing is confirmed or corrected.
    case other(start: () throws -> Void)
}

struct RateTransitionPlan {
    let command: RateCommand
    let sound: RateSound
    let dacUID: String?
    /// The rest of the plan's token (queue generation, index, current track,
    /// routing stamp, state): true while it still holds. Runs under the output
    /// lock, as `RateFence.playIfCurrent`'s `alsoCurrent`.
    let isCurrent: () -> Bool

    init(command: RateCommand, sound: RateSound, dacUID: String? = nil, isCurrent: @escaping () -> Bool = { true }) {
        self.command = command
        self.sound = sound
        self.dacUID = dacUID
        self.isCurrent = isCurrent
    }
}

/// Why a correction left the song where it is.
enum RateCorrectionStop: Equatable {
    /// A command moved the fence, took the lease, or the caller's own checks
    /// failed: it owns the player now.
    case newerCommand
    /// Music.app showed a seek, a skip or a play during the correction.
    case musicSeeked, musicSkipped, musicPlayed
    /// The correction took more than the window.
    case tooSlow
    /// The follower could not read Music to prove its pause still stood.
    case stateUnreadable
    /// Music refused the resume.
    case resumeFailed(String)
    /// The output lock could not be taken to resume.
    case lockUnavailable(String)

    /// Whether the follower's own pause is still the thing holding the song,
    /// so the line must say "paused to switch the DAC rate; press play".
    var leavesOurPause: Bool {
        switch self {
        case .tooSlow, .stateUnreadable, .resumeFailed, .lockUnavailable: return true
        case .newerCommand, .musicSeeked, .musicSkipped, .musicPlayed: return false
        }
    }
}

enum RateCorrection: Equatable {
    /// SpanDAC did not ask for one.
    case notNeeded
    /// Nothing was paused: the pause failed or Music was not on the track.
    case notAttempted(String)
    /// Corrected, restarted from 0 and resumed. `restarted` is false if Music
    /// refused the seek (it then resumed where it was).
    case resumed(restartedFromStart: Bool, rateOutcome: SourceRateOutcome)
    /// Our pause stands, or a newer owner took over.
    case stopped(RateCorrectionStop, rateOutcome: SourceRateOutcome?)
}

struct RateTransitionPlayed: Equatable {
    let token: RateToken
    /// M4's case, from the terminal answer of the prepare (or the quiet wait).
    let startLine: SourceRateStartLine
    /// The prepare's (or quiet wait's) outcome.
    let rateOutcome: SourceRateOutcome
    /// The identity-checked read; nil when Music could not be read or showed
    /// another track (the read is then discarded, M5).
    let delivered: RateTrackRead?
    /// `slice.confirmRate`'s outcome; nil when nothing was confirmed.
    let confirm: SourceRateOutcome?
    let correction: RateCorrection
    /// The `rate_seq` of the last rate answer before sound (for a correction,
    /// the correction's). nil: SpanDAC never answered, "DAC rate unconfirmed"
    /// stands for the whole song.
    let baseline: Int?
    /// The answer to the second `slice.confirmRate`, sent after a correction
    /// resumed the song: the delivered rate AFTER the correction. nil when no
    /// correction resumed (or Music could not be read). It, not `confirm`, is
    /// the evidence for a corrected song (fix round 1, finding 6).
    var confirmAfterCorrection: SourceRateOutcome? = nil
}

enum RateTransitionResult: Equatable {
    /// A newer command owns the player. NOTHING was played.
    case invalidated
    /// The output lock stayed busy past its bound (a route switch is in
    /// progress), or a nested lock use. Nothing was played.
    case notStarted(String)
    /// The fence or lock files could not be used (a broken state directory).
    /// The song PLAYED, at the DAC's current rate, with no rate follow and no
    /// confirm or correction (2026-11-15 ruling): the caller says why.
    case playedUnfollowed(reason: String)
    /// Music's own `play` failed. The one result that is a play failure.
    case playFailed(String)
    case played(RateTransitionPlayed)

    /// The only value a caller may hand `AdvanceRetryGate`: true is
    /// `playSucceeded()`, false is `playFailed()`, nil touches the gate not at
    /// all. A rate failure is a `played` result and so is true: it never skips
    /// a song.
    var playOutcome: Bool? {
        switch self {
        case .played, .playedUnfollowed: return true
        case .playFailed: return false
        case .invalidated, .notStarted: return nil
        }
    }
}

// MARK: - the transition

final class RateAwareTransition {

    /// Section 3.3: a correction that ended later than this after the pause is
    /// not resumed.
    static let correctionWindow: TimeInterval = 3
    /// Section 3.3: "at the same position (+-0.5 s)".
    static let positionTolerance: TimeInterval = 0.5

    private let fence: RateFence
    private let owner: String
    private let music: RateMusicControlling
    private let makeFollow: (RateToken) -> SourceRateFollow
    private let now: () -> TimeInterval
    /// False once the process is closing: a correction would pause the song, and
    /// a closing TUI must not start a pause it may not live to release.
    private let allowCorrection: () -> Bool
    private let streamWait: RateStreamWait

    /// What `recheck` needs from the `run` that started the song. One transition
    /// object is one run (`MacRoutePlayer` makes one per play); set before `run`
    /// returns, read by the one follow-up it schedules.
    private var followUp: (plan: RateTransitionPlan, follow: SourceRateFollow, persistentID: String)?

    /// `makeFollow` builds the client for a token (its control, its clock): the
    /// production one is `SourceRateFollow(token:control:status:)` on
    /// `SourceAppControl.macRate()`.
    init(fence: RateFence, owner: String, music: RateMusicControlling,
         makeFollow: @escaping (RateToken) -> SourceRateFollow,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         allowCorrection: @escaping () -> Bool = { true },
         streamWait: RateStreamWait = .live) {
        self.streamWait = streamWait
        self.fence = fence
        self.owner = owner
        self.music = music
        self.makeFollow = makeFollow
        self.now = now
        self.allowCorrection = allowCorrection
    }

    /// One sound start. `token` is the one the command already took (M1) when
    /// the caller moved the fence at command time; nil takes it here. Blocks for
    /// at most M2's 4.5 s, plus a correction's window.
    func run(_ plan: RateTransitionPlan, token given: RateToken? = nil) -> RateTransitionResult {
        // 1. M1: the fence moves first.
        let token: RateToken
        do {
            token = try given ?? fence.begin(plan.command, owner: owner)
        } catch {
            if Self.isBrokenStateDirectory(error) { return playUnfenced(plan, reason: Self.describe(error)) }
            return .notStarted(Self.describe(error))
        }
        let follow = makeFollow(token)

        // 2. M2: prepare (or announce and wait for quiet), bounded, never refusing.
        let rateOutcome: SourceRateOutcome
        switch plan.sound {
        case .track(let persistentID, let catalogID):
            rateOutcome = follow.prepare(dacUID: plan.dacUID, persistentID: persistentID, catalogID: catalogID)
        case .other:
            _ = follow.announce()
            rateOutcome = follow.awaitQuiet()
        }

        // 3. M3: revalidate the whole token and play, under the lock.
        var playError: Error?
        let revalidation: RateRevalidation<Void>
        do {
            revalidation = try fence.playIfCurrent(token, alsoCurrent: plan.isCurrent) {
                do { try self.startSound(plan.sound) } catch { playError = error }
            }
        } catch {
            if Self.isBrokenStateDirectory(error) { return playUnfenced(plan, reason: Self.describe(error)) }
            return .notStarted(Self.describe(error))
        }
        guard case .played = revalidation else { return .invalidated }
        if let playError { return .playFailed(Self.describe(playError)) }

        // M4, after the revalidation that makes a `superseded` answer a regression.
        let startLine = SourceRateStartLine.line(for: rateOutcome)

        // 4. Confirm, from one read that must be this track.
        guard case .track(let persistentID, _) = plan.sound else {
            return .played(RateTransitionPlayed(token: token, startLine: startLine, rateOutcome: rateOutcome,
                                                delivered: nil, confirm: nil, correction: .notNeeded,
                                                baseline: follow.baseline))
        }
        followUp = (plan, follow, persistentID)
        let delivered = streamRead(persistentID, window: streamWait.window, interval: streamWait.interval)
        let finish = confirmAndCorrect(plan, token: token, follow: follow, persistentID: persistentID,
                                       delivered: delivered)

        return .played(RateTransitionPlayed(token: token, startLine: startLine, rateOutcome: rateOutcome,
                                            delivered: delivered, confirm: finish.confirm,
                                            correction: finish.correction, baseline: follow.baseline,
                                            confirmAfterCorrection: finish.confirmAfter))
    }

    /// Whether `recheck` has anything to do for `played`: a track start whose
    /// first read could not be proven to be this stream (nothing was confirmed,
    /// so nothing was corrected either).
    func needsRecheck(_ played: RateTransitionPlayed) -> Bool {
        followUp != nil && played.delivered == nil && played.confirm == nil && played.correction == .notNeeded
    }

    /// The follow-up for a start whose stream was not up when the confirm gave
    /// up (the live check's jump to a hi-res song, 2026-11-16): waits, off the
    /// caller's thread and bounded by `recheckWindow`, until Music is playing
    /// this ID with the position advancing, reads the rate of THIS stream,
    /// confirms it, and, if SpanDAC says the DAC is not at it, runs the same
    /// correction a start runs (every guarantee of `correct`: the pause is
    /// revalidated under the output lock, resumed only if still ours), once.
    ///
    /// Returns the played record with the new evidence, or nil when there is
    /// nothing new to say: `cancelled` (the caller is closing), a newer command
    /// (the fence moved, or the plan's own token no longer holds), or no stream
    /// within the window. It never plays, pauses or seeks except through the one
    /// correction, and a failure of any kind leaves the song playing.
    func recheck(_ played: RateTransitionPlayed, cancelled: () -> Bool = { false }) -> RateTransitionPlayed? {
        guard needsRecheck(played), let ctx = followUp else { return nil }
        let token = played.token
        func stillOurs() -> Bool {
            if cancelled() || !ctx.plan.isCurrent() { return false }
            // A busy lock is a route switch in progress: not a newer command, and
            // not known either way, so keep waiting.
            return (try? fence.fenceFileHolds(token.fence, timeout: 0.5)) ?? true
        }
        guard stillOurs() else { return nil }
        let delivered = streamRead(ctx.persistentID, window: streamWait.recheckWindow,
                                   interval: streamWait.recheckInterval, keepGoing: stillOurs)
        guard let delivered, stillOurs() else { return nil }
        let finish = confirmAndCorrect(ctx.plan, token: token, follow: ctx.follow, persistentID: ctx.persistentID,
                                       delivered: delivered)
        followUp = nil      // once
        return RateTransitionPlayed(token: token, startLine: played.startLine, rateOutcome: played.rateOutcome,
                                    delivered: delivered, confirm: finish.confirm, correction: finish.correction,
                                    baseline: ctx.follow.baseline, confirmAfterCorrection: finish.confirmAfter)
    }

    // MARK: private

    /// The fence or lock files are unusable (not busy): the file system, not
    /// another command, is what failed.
    private static func isBrokenStateDirectory(_ error: Error) -> Bool {
        if case RateFenceError.unavailable = error { return true }
        if case OutputLockError.unavailable = error { return true }
        return false
    }

    /// 2026-11-15 ruling: with no usable fence there is no ordering to keep and
    /// nothing to follow, but the song still plays, at the DAC's current rate.
    /// The rest of the plan's token is still honoured.
    private func playUnfenced(_ plan: RateTransitionPlan, reason: String) -> RateTransitionResult {
        guard plan.isCurrent() else { return .invalidated }
        do { try startSound(plan.sound) } catch { return .playFailed(Self.describe(error)) }
        return .playedUnfollowed(reason: reason)
    }

    private func startSound(_ sound: RateSound) throws {
        switch sound {
        case .track(let persistentID, _): try music.playTrack(persistentID: persistentID)
        case .other(let start): try start()
        }
    }

    /// A read of the rate that is THIS stream's: Music is playing `persistentID`
    /// and its position is advancing (two reads of it, the later one greater). The
    /// rate is read only then, because Music reports the previous stream's rate
    /// until the new one is up. Polls every `interval` for at most `window`
    /// seconds (also capped by iteration count, so a frozen test clock ends); nil
    /// when the stream was not proven in time, when Music cannot be read, or when
    /// `keepGoing` says stop. A pause, a stop or another track restarts the proof.
    private func streamRead(_ persistentID: String, window: TimeInterval, interval: TimeInterval,
                            keepGoing: () -> Bool = { true }) -> RateTrackRead? {
        let started = now()
        var attemptsLeft = Int(window / max(interval, 0.001)) + 1
        var lastPosition: TimeInterval?
        while true {
            if let state = music.readPlayerState(), state.state == .playing, state.persistentID == persistentID {
                if let previous = lastPosition, state.position > previous {
                    guard let read = music.readCurrentTrack(), read.persistentID == persistentID else { return nil }
                    return read
                }
                lastPosition = state.position
            } else {
                lastPosition = nil
            }
            attemptsLeft -= 1
            if attemptsLeft <= 0 || now() - started >= window || !keepGoing() { return nil }
            streamWait.sleep(interval)
        }
    }

    /// Steps 4 and 5 for one proven read: confirm it to SpanDAC and, if SpanDAC
    /// says the DAC is not at the song's rate, correct (once). `delivered` nil
    /// (no proven read) confirms and corrects nothing.
    private func confirmAndCorrect(_ plan: RateTransitionPlan, token: RateToken, follow: SourceRateFollow,
                                   persistentID: String, delivered: RateTrackRead?)
        -> (confirm: SourceRateOutcome?, correction: RateCorrection, confirmAfter: SourceRateOutcome?) {
        var confirm: SourceRateOutcome?
        if let delivered {
            confirm = follow.confirm(persistentID: delivered.persistentID, deliveredHz: delivered.sampleRateHz)
        }
        var correction = RateCorrection.notNeeded
        var confirmAfter: SourceRateOutcome?
        if case .answered(let answer)? = confirm, answer.outcome == .correct,
           allowCorrection(), follow.mayWriteRate,
           let rateHz = answer.targetHz ?? delivered?.sampleRateHz {
            correction = correct(plan, token: token, follow: follow, persistentID: persistentID, toHz: rateHz,
                                 confirmAfter: &confirmAfter)
        }
        return (confirm, correction, confirmAfter)
    }

    /// Section 3.3 step 5: pause (ours), SpanDAC writes the rate, revalidate,
    /// position 0, play; resume only our own pause (the guarantee in the header).
    /// `confirmAfter` receives the second confirm's outcome when the song resumed.
    private func correct(_ plan: RateTransitionPlan, token: RateToken, follow: SourceRateFollow,
                         persistentID: String, toHz rateHz: Int,
                         confirmAfter: inout SourceRateOutcome?) -> RateCorrection {
        // The pause is the first act of a correction and the one that can hurt a
        // newer command, so it gets the same revalidation as a play (fix round 1,
        // finding 1): inside the output lock, the token AND the track Music is on
        // are checked together with the pause. If either has moved, nothing is
        // paused and nothing is left for the follower to resume.
        enum PauseRefusal { case unreadable, notOurTrack, notOurs }
        var refusal: PauseRefusal?
        var pauseError: Error?
        let pauseRevalidation: RateRevalidation<Void>
        do {
            pauseRevalidation = try fence.playIfCurrent(token, alsoCurrent: {
                guard plan.isCurrent() else { return false }      // a newer command (no refusal set)
                guard let state = self.music.readPlayerState() else { refusal = .unreadable; return false }
                guard state.persistentID == persistentID else { refusal = .notOurTrack; return false }
                // Already paused: that pause is not ours to hold or to resume.
                guard state.state != .paused else { refusal = .notOurs; return false }
                return true
            }, play: {
                do { try self.music.pause() } catch { pauseError = error }
            })
        } catch {
            return .notAttempted("could not pause: \(Self.describe(error))")
        }
        if case .invalidated = pauseRevalidation {
            switch refusal {
            case nil: return .stopped(.newerCommand, rateOutcome: nil)
            case .unreadable?: return .notAttempted("Music could not be read before pausing")
            case .notOurTrack?: return .notAttempted("Music was not on the track")
            case .notOurs?: return .notAttempted("Music was already paused")
            }
        }
        if let pauseError { return .notAttempted("could not pause: \(Self.describe(pauseError))") }
        // The window is how long OUR pause is held, so it counts from the pause, not
        // from the revalidation read before it (the read-back below can now wait).
        let pausedAt = now()
        // Our pause is held only if Music shows it, on this track. Music's player
        // state lags a pause by a moment, so a state that still says playing this
        // track (or cannot be read yet) is read again, a bounded few times, before
        // it is taken for "the pause did not take".
        var shown: RatePlayerState?
        for attempt in 0..<max(1, streamWait.pauseReads) {
            if attempt > 0 { streamWait.sleep(streamWait.pauseInterval) }
            shown = music.readPlayerState()
            if let state = shown, state.state == .paused, state.persistentID == persistentID { break }
            if let state = shown, !(state.state == .playing && state.persistentID == persistentID) { break }
        }
        guard let paused = shown else {
            return .stopped(.stateUnreadable, rateOutcome: nil)
        }
        guard paused.state == .paused, paused.persistentID == persistentID else {
            // Not ours to resume: the song ended, or someone moved Music first.
            return .notAttempted("Music was not paused on the track")
        }

        let rateOutcome = follow.correct(toHz: rateHz, dacUID: plan.dacUID, persistentID: persistentID)

        // Resume only inside the lock, only if every condition still holds.
        var stop: RateCorrectionStop?
        var restarted = true
        var resumeError: Error?
        let revalidation: RateRevalidation<Void>
        do {
            revalidation = try fence.playIfCurrent(token, alsoCurrent: {
                guard plan.isCurrent() else { stop = .newerCommand; return false }
                if self.now() - pausedAt > Self.correctionWindow { stop = .tooSlow; return false }
                guard let state = self.music.readPlayerState() else { stop = .stateUnreadable; return false }
                if state.state == .playing { stop = .musicPlayed; return false }
                if state.state != .paused || state.persistentID != persistentID { stop = .musicSkipped; return false }
                if abs(state.position - paused.position) > Self.positionTolerance { stop = .musicSeeked; return false }
                return true
            }, play: {
                do { try self.music.seekToStart() } catch { restarted = false }
                do { try self.music.resume() } catch { resumeError = error }
            })
        } catch {
            return .stopped(.lockUnavailable(Self.describe(error)), rateOutcome: rateOutcome)
        }
        if case .invalidated = revalidation {
            // `stop` is set when our own conditions failed; otherwise the fence
            // or the lease did: a newer command owns the player.
            return .stopped(stop ?? .newerCommand, rateOutcome: rateOutcome)
        }
        if let resumeError { return .stopped(.resumeFailed(Self.describe(resumeError)), rateOutcome: rateOutcome) }

        // SpanDAC records the delivered rate (section 3.3 step 5, last bullet).
        // Its answer is the evidence of the corrected song: kept, not discarded
        // (fix round 1, finding 6).
        if let again = streamRead(persistentID, window: streamWait.window, interval: streamWait.interval) {
            confirmAfter = follow.confirm(persistentID: again.persistentID, deliveredHz: again.sampleRateHz)
        }
        return .resumed(restartedFromStart: restarted, rateOutcome: rateOutcome)
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? OutputLockError { return "\(e)" }
        if let e = error as? RateFenceError { return "\(e)" }
        if let e = error as? ActionError { return e.message }
        return String(describing: error)
    }
}
