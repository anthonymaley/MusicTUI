// tools/music/Sources/Commands/RunQueueControl.swift
import ArgumentParser
import Foundation

// Skip and back for a queue the Mac DAC route's detached runner owns (finding 7,
// live check 2026-11-18: `music skip` restarted the playing song).
//
// The runner hands Music ONE song at a time (`setQueueWithItem` per song), so
// Music has no next item: its "next track" restarts the current song, and the
// runner's own queue never hears of it. The runner is another process, so the
// skip reaches it through three small files beside the fence and the lock:
//
//   run-queue.runner        `pid`, `owner`, `phase` (one per line): written by a runner
//                           the moment it starts (`starting`) and again once it holds
//                           the play lease (`ready`), removed (its own record only)
//                           when it ends. A client asks a runner only while the pid is
//                           alive, the phase is `ready` and the lease is that owner's;
//                           a `starting` runner is waited for, never replaced by
//                           Music's own next track (which restarts the song).
//   run-queue.skip.<owner>  `step` space `nonce`: written by the client (atomically),
//                           addressed to that runner by its name: no other runner
//                           ever reads it. Two clients at once overwrite one another
//                           (last writer wins); each then learns the truth from the
//                           ack's nonce.
//   run-queue.ack.<owner>   `nonce` space `outcome`: written by the runner when the
//                           song that skip led to was started, or why it was not.
//                           A client reports success only for its own nonce.
//
// The runner then steps ITS queue and plays through the same
// `MacRoutePlayer.play` a natural end uses (`.next` / `.previous` fence command,
// prepare, confirm), so the skip is fenced and follows the rate like any advance.

/// One skip: the step in the queue, and the number its acknowledgement carries.
struct RunQueueSkipRequest: Equatable {
    let step: Int
    let nonce: String
}

//// What the runner says it did with a skip.
enum RunQueueSkipOutcome: String {
    /// The song the skip led to was started.
    case played
    /// Music refused it (after the runner's own retries).
    case failed
    /// The route could not start it (the output lock stayed busy).
    case notStarted
    /// A newer command owns the player: nothing was played.
    case superseded
    /// A skip past the last song: nothing to play.
    case end
    /// SpanDAC could not make the DAC the Mac's output: the song was not played.
    /// The ack carries SpanDAC's sentence after the outcome.
    case refused
}

/// What the runner's FIRST song came to, told to the command that spawned it
/// (the one place a runner's start can be reported to a person: `music play`
/// returns before the runner has played anything).
enum RunQueueFirstStart: Equatable {
    /// The first song played.
    case played
    /// SpanDAC would not make the DAC the Mac's output, so nothing played. Carries
    /// SpanDAC's own sentence.
    case refused(String)
    /// The runner ended without playing it, for any other reason (a newer command
    /// took over, the lock stayed busy, the route was left): not a refusal.
    case ended
}

/// The nonce of the first-start line in the ack file. A skip's nonce is a UUID,
/// so the two never meet.
let runQueueFirstStartNonce = "first"

/// The runner's end of the channel.
protocol RunQueueControlling {
    /// The runner is up (it may not hold the lease yet): a client waits for it.
    func register()
    /// The runner holds the play lease: clients may ask it.
    func markReady()
    /// The runner is ending. Removes only this runner's own record.
    func unregister()
    /// The pending skip addressed to this runner, taken: it is not returned twice.
    func takeSkip() -> RunQueueSkipRequest?
    /// What became of the skip `nonce`.
    func acknowledge(nonce: String, outcome: RunQueueSkipOutcome)
    /// The skip `nonce` led to a song SpanDAC would not let play (`route_output_refused`),
    /// with SpanDAC's own sentence. A control that cannot carry it answers `notStarted`.
    func acknowledgeRefused(nonce: String, detail: String)
    /// What the first song came to, once: the spawning command waits for it
    /// (`RunQueueFirstStartWait`). A control that cannot carry it says nothing.
    func reportFirstStart(_ result: RunQueueFirstStart)
}

extension RunQueueControlling {
    func acknowledgeRefused(nonce: String, detail: String) { acknowledge(nonce: nonce, outcome: .notStarted) }
    func reportFirstStart(_ result: RunQueueFirstStart) {}
}

/// The channel's files, in the directory of `mode.json`.
struct RunQueueControlFiles {
    let directory: String
    var runnerPath: String { (directory as NSString).appendingPathComponent("run-queue.runner") }
    /// Addressed by the runner's lease owner, which is `pid-random` and safe in a name.
    func skipPath(owner: String) -> String { (directory as NSString).appendingPathComponent("run-queue.skip.\(owner)") }
    func ackPath(owner: String) -> String { (directory as NSString).appendingPathComponent("run-queue.ack.\(owner)") }

    static func beside(_ modes: PlaybackModeStore) -> RunQueueControlFiles {
        RunQueueControlFiles(directory: (modes.lockPath as NSString).deletingLastPathComponent)
    }

    /// Write-then-rename, so a reader never sees half a file.
    func write(_ text: String, to path: String) -> Bool {
        let temp = path + ".tmp-\(getpid())-\(UUID().uuidString.prefix(6))"
        guard (try? text.write(toFile: temp, atomically: false, encoding: .utf8)) != nil else { return false }
        if rename(temp, path) == 0 { return true }
        unlink(temp)
        return false
    }

    func read(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))
    }
}

struct FileRunQueueControl: RunQueueControlling {
    let files: RunQueueControlFiles
    let owner: String
    var pid: Int32 = getpid()

    private func record(_ phase: String) -> String { "\(pid)\n\(owner)\n\(phase)\n" }

    func register() { _ = files.write(record("starting"), to: files.runnerPath) }
    func markReady() { _ = files.write(record("ready"), to: files.runnerPath) }

    func unregister() {
        // Only this runner's own record (its pid AND owner, either phase): a newer
        // runner's must survive.
        if let text = files.read(files.runnerPath), text.hasPrefix("\(pid)\n\(owner)\n") { unlink(files.runnerPath) }
        unlink(files.skipPath(owner: owner))
    }

    func takeSkip() -> RunQueueSkipRequest? {
        let path = files.skipPath(owner: owner)
        let taken = path + ".taken"
        guard rename(path, taken) == 0 else { return nil }
        defer { unlink(taken) }
        guard let text = files.read(taken) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2, let step = Int(parts[0]), step == 1 || step == -1, !parts[1].isEmpty else { return nil }
        return RunQueueSkipRequest(step: step, nonce: parts[1])
    }

    func acknowledge(nonce: String, outcome: RunQueueSkipOutcome) {
        _ = files.write("\(nonce) \(outcome.rawValue)", to: files.ackPath(owner: owner))
    }

    /// `nonce refused <detail>`, the detail on one line.
    func acknowledgeRefused(nonce: String, detail: String) {
        let line = detail.split(whereSeparator: \.isNewline).joined(separator: " ")
        _ = files.write("\(nonce) \(RunQueueSkipOutcome.refused.rawValue) \(line)", to: files.ackPath(owner: owner))
    }
}

extension FileRunQueueControl {
    /// `first played`, `first ended` or `first refused <detail>` in the runner's ack
    /// file, one line, for the parent that spawned it.
    func reportFirstStart(_ result: RunQueueFirstStart) {
        let words: String
        switch result {
        case .played: words = "played"
        case .ended: words = "ended"
        case .refused(let detail):
            words = "refused " + detail.split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        _ = files.write("\(runQueueFirstStartNonce) \(words)", to: files.ackPath(owner: owner))
    }
}

/// The spawning command's wait for its runner's first song (`music play` on the
/// Mac route). The runner starts after the command releases the output lock, so
/// the wait must run AFTER the release, never inside it.
///
/// **The bound is 3.0 s**, polled every 50 ms, and only ever spent in full when
/// the runner says nothing: a refusal is read as soon as it is written, and so is
/// a played first song. The refusal comes from one SpanDAC exchange (its guard
/// answers inside 2.5 s, `RouteOutput`), so 3.0 s sees it; a success is usually
/// reported within a second. Past the bound the command says what it always said
/// ("Playing ...") and the runner carries on.
struct RunQueueFirstStartWait {
    static let bound: TimeInterval = 3.0
    static let poll: TimeInterval = 0.05

    let files: RunQueueControlFiles
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    /// What the runner named `owner` said its first song came to, or nil when it
    /// said nothing within the bound.
    func wait(owner: String) -> RunQueueFirstStart? {
        let started = now()
        while true {
            if let line = files.read(files.ackPath(owner: owner)), let result = Self.parse(line) { return result }
            if now() - started >= Self.bound { return nil }
            sleep(Self.poll)
        }
    }

    static func parse(_ line: String) -> RunQueueFirstStart? {
        let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2, parts[0] == runQueueFirstStartNonce else { return nil }
        switch parts[1] {
        case "played": return .played
        case "ended": return .ended
        case "refused":
            let detail = parts.count == 3 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return .refused(detail.isEmpty ? SourceAppError.routeOutputRefusedSentence : detail)
        default: return nil
        }
    }
}

/// The client's end: `music skip`, `music back`, and the TUI's next and previous
/// when the queue is a runner's.
struct RunQueueSkipClient {
    enum Outcome: Equatable {
        /// No live runner owns the lease: the caller does what it always did.
        case noRunner
        /// The runner started the song the skip led to (or there was none to go to).
        case done
        /// The runner never took the request (busy, or gone): withdrawn.
        case notPickedUp
        /// The runner did not say, for THIS request, that it started in time (it may
        /// have heard another client's instead).
        case notAcknowledged
        /// The request could not be written.
        case notSent
        /// The runner heard it and the song did not start.
        case notStarted
        /// The runner heard it and SpanDAC would not make the DAC the Mac's output:
        /// the song was not played. Carries SpanDAC's own sentence.
        case refused(String)
        /// The runner heard it and a newer command had taken over.
        case superseded
        /// A runner exists for the route but is not ready to be asked: its start has
        /// not finished. Music's own next track is NOT a substitute (it restarts the song).
        case stillStarting
    }

    let files: RunQueueControlFiles
    /// Whether a process is alive. The default is `kill(pid, 0)`.
    var isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    /// Who holds the play lease relative to `owner`. Read WITHOUT the output lock held
    /// by this process: under it the answer would be `.busy` (the lock is ours).
    var leaseStatus: (String) -> RateFence.LeaseStatus
    var newNonce: () -> String = { UUID().uuidString }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The runner polls once a second, so a pick-up within a few seconds is a live runner.
    var pickUpWithin: TimeInterval = 4
    /// A start can take a prepare, a confirm and a correction.
    var ackWithin: TimeInterval = 20
    /// How long a runner that has not finished starting is waited for.
    var startWithin: TimeInterval = 8
    var pollEvery: TimeInterval = 0.1

    static func live(modes: PlaybackModeStore = PlaybackModeStore()) -> RunQueueSkipClient {
        let fence = RateFence(store: modes)
        return RunQueueSkipClient(files: .beside(modes), leaseStatus: { fence.leaseStatus(owner: $0) })
    }

    enum RunnerState: Equatable {
        /// No record, or its process is gone: nothing owns the queue.
        case none
        /// A live runner that has not said it holds the lease.
        case starting
        case ready(owner: String)
    }

    func runnerState() -> RunnerState {
        guard let text = files.read(files.runnerPath) else { return .none }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 2, let pid = Int32(lines[0]), isAlive(pid) else { return .none }
        return lines.count >= 3 && lines[2] == "ready" ? .ready(owner: lines[1]) : .starting
    }

    func send(step: Int) -> Outcome {
        let began = now()
        var owner: String
        waiting: while true {
            switch runnerState() {
            case .none:
                return .noRunner
            case .starting:
                break
            case .ready(let candidate):
                switch leaseStatus(candidate) {
                case .ours: owner = candidate; break waiting
                case .busy: break           // the lock is held by someone for a moment
                case .another, .none, .unreadable: return .noRunner     // the lease moved on
                }
            }
            if now() - began > startWithin { return .stillStarting }
            sleep(pollEvery)
        }
        let nonce = newNonce()
        let skipPath = files.skipPath(owner: owner)
        guard files.write("\(step) \(nonce)", to: skipPath) else { return .notSent }
        let sentAt = now()
        // Picked up: the file is gone (the runner took it, or another client's write
        // was taken instead, which the ack's nonce will tell).
        while FileManager.default.fileExists(atPath: skipPath) {
            if now() - sentAt > pickUpWithin {
                // Withdrawn, but only if it is still THIS client's request.
                if files.read(skipPath)?.split(separator: " ").last.map(String.init) == nonce { unlink(skipPath) }
                return .notPickedUp
            }
            sleep(pollEvery)
        }
        while now() - sentAt <= ackWithin {
            if let ack = files.read(files.ackPath(owner: owner)) {
                let parts = ack.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                    .map(String.init)
                if parts.count == 3, parts[0] == nonce, parts[1] == RunQueueSkipOutcome.refused.rawValue {
                    return .refused(parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if parts.count == 2, parts[0] == nonce {
                    switch RunQueueSkipOutcome(rawValue: parts[1]) {
                    case .played?, .end?: return .done
                    case .superseded?: return .superseded
                    case .failed?, .notStarted?: return .notStarted
                    case .refused?: return .notStarted      // a refusal with no sentence
                    case nil: return .notAcknowledged
                    }
                }
            }
            sleep(pollEvery)
        }
        return .notAcknowledged
    }
}

/// `music skip` / `music back` on the Mac DAC route: the runner that owns the queue
/// steps it. True when this handled the command (a line was shown or an error was
/// reported); false when the caller should do what it always did (route off, no
/// runner).
///
/// Everything it reads (the route flag, the runner's record, the lease) lives beside
/// `modes`, the coordinator's own store, so a test's temp store is a temp world and only
/// production's reaches `~/.config/music`.
func skipThroughRunner(step: Int, json: Bool,
                       modes: PlaybackModeStore = PlaybackModeStore(),
                       routeIsOn: (() -> Bool)? = nil,
                       client: RunQueueSkipClient? = nil,
                       show: (Bool) -> Void = { showNowPlaying(json: $0, waitForPlay: true) },
                       fail: (String) -> Void = { errorOut($0) },
                       refused: ((String) -> Void)? = nil) throws -> Bool {
    let routeIsOn = routeIsOn ?? { MacRouteStore(beside: modes).isOn }
    let client = client ?? RunQueueSkipClient.live(modes: modes)
    guard routeIsOn() else { return false }
    switch client.send(step: step) {
    case .noRunner:
        return false
    case .done:
        show(json)
        return true
    case .notStarted:
        fail(macRouteSkipNotStartedMessage)
        throw ExitCode.failure
    case .superseded:
        fail(macRouteSkipSupersededMessage)
        throw ExitCode.failure
    case .refused(let detail):
        // SpanDAC's own sentence, verbatim: the song was not played.
        if let refused { refused(detail) } else { fail(detail) }
        throw ExitCode.failure
    case .stillStarting:
        fail(macRouteSkipStartingMessage)
        throw ExitCode.failure
    case .notPickedUp, .notAcknowledged, .notSent:
        fail(macRouteSkipNotDoneMessage)
        throw ExitCode.failure
    }
}

let macRouteSkipNotDoneMessage = "Couldn't skip: the queue that follows the DAC's sample rate didn't answer."
let macRouteSkipNotStartedMessage = "Couldn't skip: the next song didn't start."
let macRouteSkipStartingMessage = "Couldn't skip: the queue is still starting."
let macRouteSkipSupersededMessage = "Couldn't skip: another command took over playback."
