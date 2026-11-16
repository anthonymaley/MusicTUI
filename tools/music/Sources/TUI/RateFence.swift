// tools/music/Sources/TUI/RateFence.swift
import Foundation

// The fence counter and the play lease: MusicTUI's half of the rate transaction
// (docs/plans/2026-11-14-day-batch/mac-route-plan.md, "Appendix: rate
// transaction protocol", rules M1 and M3; score step P2).
//
// `rate.fence` is one integer in the same directory as `output.lock`, and
// `rate.lease` names the process that holds the play lease. Like the lock
// file, neither is ever deleted. EVERY read and write of both happens inside
// the output lock, so a number read here cannot be torn by a writer, and two
// processes can never take the same fence.
//
// - **M1, fence first.** `begin` takes the lock, adds one to the fence, takes the
//   lease, builds the token and releases the lock. `run` is `begin` followed by
//   the command's own work, so no work can precede the increment.
// - **M3, revalidate and play under the lock.** `playIfCurrent` takes the lock,
//   checks the token's fence and lease against the files, and starts the sound
//   before releasing. Every other command's M1 needs the same lock, so none can
//   come between the check and the play: a newer one either incremented first
//   (this check fails and nothing plays) or increments after this play (and
//   replaces it, correctly).
//
// The two files are found beside the lock (`OutputLock.path`), so a test that
// builds its lock in a temp directory gets temp files with no further wiring,
// and nothing here names `~/.config/music`.
//
// Callers that already hold the lock (a CLI command inside
// `cliUnderOutputLock`, the coordinator's switch) use the `...HoldingLock`
// forms: the lock is not re-entrant on one thread (`OutputLock.reentryMessage`).

/// Every command that moves the fence (M1). `startsSound` is the line between a
/// command that then waits for the DAC to be quiet (M2) and one that does not.
enum RateCommand: String, CaseIterable, Equatable {
    case play, advance, next, previous, jump, shuffle, station
    case pause, resume, seek, routeChange

    /// A command whose next step is sound. Pause and a route change never wait
    /// for anything (M1). A seek is treated as silent: it is a position change
    /// on whatever is already playing or paused, with no song start.
    var startsSound: Bool {
        switch self {
        case .play, .advance, .next, .previous, .jump, .shuffle, .station, .resume: return true
        case .pause, .seek, .routeChange: return false
        }
    }
}

/// What one command carries from its increment to its play. P3 adds the rest of
/// the plan's token (queue generation, index, persistent ID, routing stamp, DAC
/// UID) and checks them through `playIfCurrent`'s `alsoCurrent`.
struct RateToken: Equatable {
    let fence: Int
    /// Who holds the play lease: one per MusicTUI process, TUI or CLI runner.
    let owner: String
    let command: RateCommand
}

enum RateFenceError: Error, Equatable {
    /// `rate.fence` or `rate.lease` could not be read or written. A command that
    /// cannot move the fence plays nothing: proceeding unordered is what the
    /// fence exists to prevent.
    case unavailable(path: String, reason: String)
}

/// Whether a token was still current when the play was due.
enum RateRevalidation<T> {
    /// The sound started, under the lock; carries the play's own result.
    case played(T)
    /// A newer command owns the player (fence, lease or the caller's own
    /// checks). This transition plays NOTHING.
    case invalidated
}

extension RateRevalidation: Equatable where T: Equatable {}

final class RateFence {

    static let fenceFileName = "rate.fence"
    static let leaseFileName = "rate.lease"

    let lock: OutputLock
    let fencePath: String
    let leasePath: String

    /// Beside `lock.path`.
    init(lock: OutputLock) {
        self.lock = lock
        let dir = (lock.path as NSString).deletingLastPathComponent
        self.fencePath = (dir as NSString).appendingPathComponent(Self.fenceFileName)
        self.leasePath = (dir as NSString).appendingPathComponent(Self.leaseFileName)
    }

    /// Beside the store's `output.lock` (`PlaybackModeStore.lockPath`).
    convenience init(store: PlaybackModeStore) {
        self.init(lock: OutputLock(path: store.lockPath))
    }

    /// One process identity for the lease: pid plus a random part, so a process
    /// that reuses a pid is a different owner.
    static func newOwnerID() -> String {
        "\(getpid())-\(UUID().uuidString.prefix(8))"
    }

    // MARK: M1

    /// M1: under the lock, add one to the fence, take the lease, release.
    func begin(_ command: RateCommand, owner: String,
               timeout: TimeInterval = OutputLock.defaultTimeout) throws -> RateToken {
        try lock.withLock(timeout: timeout) { try beginHoldingLock(command, owner: owner) }
    }

    /// `begin` for a caller that already holds the lock.
    func beginHoldingLock(_ command: RateCommand, owner: String) throws -> RateToken {
        let next = try readFence() + 1
        try writeFence(next)
        try writeLease(owner)
        return RateToken(fence: next, owner: owner, command: command)
    }

    /// A command's whole shape: the fence moves first, and only then does `work`
    /// run, with the token. If the fence cannot move, `work` never runs.
    func run<T>(_ command: RateCommand, owner: String,
                timeout: TimeInterval = OutputLock.defaultTimeout,
                _ work: (RateToken) throws -> T) throws -> T {
        let token = try begin(command, owner: owner, timeout: timeout)
        return try work(token)
    }

    // MARK: M3

    /// M3: take the lock, revalidate, and start the sound before releasing. The
    /// token is current when the fence file still holds its fence, the lease is
    /// its owner's, and `alsoCurrent` (the rest of the plan's token, P3) agrees.
    /// `play` runs only then.
    func playIfCurrent<T>(_ token: RateToken, timeout: TimeInterval = OutputLock.defaultTimeout,
                          alsoCurrent: () -> Bool = { true },
                          play: () throws -> T) throws -> RateRevalidation<T> {
        try lock.withLock(timeout: timeout) {
            try playIfCurrentHoldingLock(token, alsoCurrent: alsoCurrent, play: play)
        }
    }

    /// `playIfCurrent` for a caller that already holds the lock.
    func playIfCurrentHoldingLock<T>(_ token: RateToken, alsoCurrent: () -> Bool = { true },
                                     play: () throws -> T) throws -> RateRevalidation<T> {
        guard try readFence() == token.fence, try readLease() == token.owner, alsoCurrent() else {
            return .invalidated
        }
        return .played(try play())
    }

    /// Whether the fence file still holds `fence`, read under the lock. M4's
    /// regression test: SpanDAC answered `superseded` and this is still true.
    func fenceFileHolds(_ fence: Int, timeout: TimeInterval = OutputLock.defaultTimeout) throws -> Bool {
        try lock.withLock(timeout: timeout) { try readFence() == fence }
    }

    /// The fence file's number, read under the lock. 0 when it does not exist.
    func current(timeout: TimeInterval = OutputLock.defaultTimeout) throws -> Int {
        try lock.withLock(timeout: timeout) { try readFence() }
    }

    // MARK: files (callers hold the lock)

    /// A missing file reads as 0 (first use). A file that exists and is not an
    /// integer reads as 0 as well: it is the plan's "file lost" case, and the
    /// next increment goes below SpanDAC's highest fence, which SpanDAC answers
    /// `superseded` and the client reads as a regression (M4), not as a command
    /// to refuse. A file that cannot be read at all throws.
    private func readFence() throws -> Int {
        guard let text = try readText(fencePath) else { return 0 }
        guard let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), n >= 0 else { return 0 }
        return n
    }

    private func readLease() throws -> String? {
        try readText(leasePath).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func writeFence(_ n: Int) throws { try writeText(String(n), to: fencePath) }
    private func writeLease(_ owner: String) throws { try writeText(owner, to: leasePath) }

    private func readText(_ path: String) throws -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw RateFenceError.unavailable(path: path, reason: String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &bytes, bytes.count)
        if n < 0 { throw RateFenceError.unavailable(path: path, reason: String(cString: strerror(errno))) }
        return String(decoding: bytes[0..<n], as: UTF8.self)
    }

    /// In place, never replaced: the same inode for the life of the file, as the
    /// lock file is. Every reader holds the lock, so no one sees the short
    /// window between the truncate and the write.
    private func writeText(_ text: String, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw RateFenceError.unavailable(path: path, reason: String(cString: strerror(errno)))
        }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        guard ftruncate(fd, 0) == 0, pwrite(fd, bytes, bytes.count, 0) == bytes.count else {
            throw RateFenceError.unavailable(path: path, reason: String(cString: strerror(errno)))
        }
    }
}
