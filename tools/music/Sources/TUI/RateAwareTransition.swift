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
//   4. confirm from one identity-checked read     SourceRateFollow.confirm
//   5. correct at the start if SpanDAC says so    pause, correct, 0, resume (M5)
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

    /// `makeFollow` builds the client for a token (its control, its clock): the
    /// production one is `SourceRateFollow(token:control:status:)` on
    /// `SourceAppControl.macRate()`.
    init(fence: RateFence, owner: String, music: RateMusicControlling,
         makeFollow: @escaping (RateToken) -> SourceRateFollow,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         allowCorrection: @escaping () -> Bool = { true }) {
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
        let delivered = identityCheckedRead(persistentID)
        var confirm: SourceRateOutcome?
        if let delivered {
            confirm = follow.confirm(persistentID: delivered.persistentID, deliveredHz: delivered.sampleRateHz)
        }

        // 5. Correct at the start.
        var correction = RateCorrection.notNeeded
        if case .answered(let answer)? = confirm, answer.outcome == .correct,
           allowCorrection(),
           let rateHz = answer.targetHz ?? delivered?.sampleRateHz {
            correction = correct(plan, token: token, follow: follow, persistentID: persistentID, toHz: rateHz)
        }

        return .played(RateTransitionPlayed(token: token, startLine: startLine, rateOutcome: rateOutcome,
                                            delivered: delivered, confirm: confirm, correction: correction,
                                            baseline: follow.baseline))
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

    /// One read; discarded unless it is the transition's own track (M5).
    private func identityCheckedRead(_ persistentID: String) -> RateTrackRead? {
        guard let read = music.readCurrentTrack(), read.persistentID == persistentID else { return nil }
        return read
    }

    /// Section 3.3 step 5: pause (ours), SpanDAC writes the rate, revalidate,
    /// position 0, play; resume only our own pause (the guarantee in the header).
    private func correct(_ plan: RateTransitionPlan, token: RateToken, follow: SourceRateFollow,
                         persistentID: String, toHz rateHz: Int) -> RateCorrection {
        let pausedAt = now()
        do { try music.pause() } catch {
            return .notAttempted("could not pause: \(Self.describe(error))")
        }
        // Our pause is held only if Music shows it, on this track.
        guard let paused = music.readPlayerState() else {
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
        if let again = identityCheckedRead(persistentID) {
            _ = follow.confirm(persistentID: again.persistentID, deliveredHz: again.sampleRateHz)
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
