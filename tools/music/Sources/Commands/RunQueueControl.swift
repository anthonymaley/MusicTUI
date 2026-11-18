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
//   run-queue.runner   `pid`, newline, `owner`: written by the runner when it
//                      starts, removed when it ends. A client trusts it only while
//                      the pid is alive AND the play lease is still that owner's.
//   run-queue.skip     `step` space `nonce`: written by the client (atomically);
//                      the runner takes it on its next poll, so the skip is read
//                      once.
//   run-queue.ack      `nonce`: written by the runner when the song that skip led
//                      to has been started (whatever the outcome), which is when a
//                      client may show what is playing.
//
// The runner then steps ITS queue and plays through the same
// `MacRoutePlayer.play` a natural end uses (`.next` / `.previous` fence command,
// prepare, confirm), so the skip is fenced and follows the rate like any advance.

/// One skip: the step in the queue, and the number its acknowledgement carries.
struct RunQueueSkipRequest: Equatable {
    let step: Int
    let nonce: String
}

/// The runner's end of the channel.
protocol RunQueueControlling {
    /// The runner is up and owns the queue for `owner`'s lease.
    func register()
    /// The runner is ending.
    func unregister()
    /// The pending skip, taken: it is not returned twice.
    func takeSkip() -> RunQueueSkipRequest?
    /// The song the skip led to was started.
    func acknowledge(nonce: String)
}

/// The channel's files, in the directory of `mode.json`.
struct RunQueueControlFiles {
    let directory: String
    var runnerPath: String { (directory as NSString).appendingPathComponent("run-queue.runner") }
    var skipPath: String { (directory as NSString).appendingPathComponent("run-queue.skip") }
    var ackPath: String { (directory as NSString).appendingPathComponent("run-queue.ack") }

    static func beside(_ modes: PlaybackModeStore) -> RunQueueControlFiles {
        RunQueueControlFiles(directory: (modes.lockPath as NSString).deletingLastPathComponent)
    }

    /// Write-then-rename, so a reader never sees half a file.
    func write(_ text: String, to path: String) -> Bool {
        let temp = path + ".tmp-\(getpid())"
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

    func register() { _ = files.write("\(pid)\n\(owner)\n", to: files.runnerPath) }

    func unregister() {
        // Only this runner's own record: a newer runner's must survive.
        if let text = files.read(files.runnerPath), text.hasPrefix("\(pid)\n") { unlink(files.runnerPath) }
    }

    func takeSkip() -> RunQueueSkipRequest? {
        let taken = files.skipPath + ".taken-\(pid)"
        guard rename(files.skipPath, taken) == 0 else { return nil }
        defer { unlink(taken) }
        guard let text = files.read(taken) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2, let step = Int(parts[0]), step == 1 || step == -1, !parts[1].isEmpty else { return nil }
        return RunQueueSkipRequest(step: step, nonce: parts[1])
    }

    func acknowledge(nonce: String) { _ = files.write(nonce, to: files.ackPath) }
}

/// The client's end: `music skip`, `music back`, and the TUI's next and previous
/// when the queue is a runner's.
struct RunQueueSkipClient {
    enum Outcome: Equatable {
        /// No live runner owns the lease: the caller does what it always did.
        case noRunner
        /// The runner started the song the skip led to.
        case done
        /// The runner never took the request (busy, or gone): withdrawn.
        case notPickedUp
        /// The runner took it but did not say it started in time.
        case notAcknowledged
        /// The request could not be written.
        case notSent
    }

    let files: RunQueueControlFiles
    /// Whether a process is alive. The default is `kill(pid, 0)`.
    var isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    /// Whether `owner` still holds the play lease.
    var leaseIsOwners: (String) -> Bool
    var newNonce: () -> String = { UUID().uuidString }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The runner polls once a second, so a pick-up within a few seconds is a live runner.
    var pickUpWithin: TimeInterval = 4
    /// A start can take a prepare, a confirm and a correction.
    var ackWithin: TimeInterval = 20
    var pollEvery: TimeInterval = 0.1

    static func live() -> RunQueueSkipClient {
        let modes = PlaybackModeStore()
        let fence = RateFence(store: modes)
        return RunQueueSkipClient(files: .beside(modes), leaseIsOwners: { fence.leaseStatus(owner: $0) == .ours })
    }

    /// The live runner's owner, or nil: no record, a dead pid, or a lease that is
    /// someone else's (the TUI, another runner) all mean "no runner owns the queue".
    func runnerOwner() -> String? {
        guard let text = files.read(files.runnerPath) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 2, let pid = Int32(lines[0]), isAlive(pid), leaseIsOwners(lines[1]) else { return nil }
        return lines[1]
    }

    func send(step: Int) -> Outcome {
        guard runnerOwner() != nil else { return .noRunner }
        let nonce = newNonce()
        guard files.write("\(step) \(nonce)", to: files.skipPath) else { return .notSent }
        let sentAt = now()
        // Picked up: the runner removed the request file.
        while FileManager.default.fileExists(atPath: files.skipPath) {
            if now() - sentAt > pickUpWithin {
                unlink(files.skipPath)      // withdrawn: it must not fire later, unseen
                return .notPickedUp
            }
            sleep(pollEvery)
        }
        while now() - sentAt <= ackWithin {
            if files.read(files.ackPath)?.trimmingCharacters(in: .whitespacesAndNewlines) == nonce { return .done }
            sleep(pollEvery)
        }
        return .notAcknowledged
    }
}

/// `music skip` / `music back` on the Mac DAC route: the runner that owns the queue
/// steps it. True when this handled the command (a line was shown or an error was
/// reported); false when the caller should do what it always did (route off, no
/// runner).
func skipThroughRunner(step: Int, json: Bool,
                       routeIsOn: () -> Bool = { MacRouteStore(beside: PlaybackModeStore()).isOn },
                       client: RunQueueSkipClient = .live(),
                       show: (Bool) -> Void = { showNowPlaying(json: $0, waitForPlay: true) },
                       fail: (String) -> Void = { errorOut($0) }) throws -> Bool {
    guard routeIsOn() else { return false }
    switch client.send(step: step) {
    case .noRunner:
        return false
    case .done:
        show(json)
        return true
    case .notPickedUp, .notAcknowledged, .notSent:
        fail(macRouteSkipNotDoneMessage)
        throw ExitCode.failure
    }
}

let macRouteSkipNotDoneMessage = "Couldn't skip: the queue that follows the DAC's sample rate didn't answer."
