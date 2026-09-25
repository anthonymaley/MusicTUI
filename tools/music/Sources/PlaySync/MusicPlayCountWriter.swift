// tools/music/Sources/PlaySync/MusicPlayCountWriter.swift
import Darwin
import Foundation
import os

// Reads and writes a library track's `played count` and `played date` in a
// Music.app that is already running, and never launches it.
//
// The staged algorithm here is pure over `MusicLibrarySession`, so every
// outcome is testable without Music.app. The only thing that talks to
// Music.app is `ScriptingBridgeSession`, which is verified live only.

// MARK: - The session seam

/// A failed call to Music.app: the Apple Event error code and its message.
/// Code -1 is a failure that was not an Apple Event error, such as a result of
/// an unexpected type.
struct AEFailure: Error, Equatable {
    let code: Int
    let message: String
}

/// One connection to one running Music.app, used for a single read or write
/// and then dropped. Every call is one bounded request.
protocol MusicLibrarySession {
    /// How many library tracks have this persistent ID.
    func matchCount(persistentID: String) -> Result<Int, AEFailure>
    /// How many tracks the library holds.
    func libraryTrackCount() -> Result<Int, AEFailure>
    /// The play state of the one track with this persistent ID.
    func playState(persistentID: String) -> Result<TrackPlayState, AEFailure>
    func setPlayedCount(_ n: Int, persistentID: String) -> Result<Void, AEFailure>
    /// `epoch` is whole seconds.
    func setPlayedDate(_ epoch: Int, persistentID: String) -> Result<Void, AEFailure>
}

// MARK: - What a failure means

enum MusicAccessSentence {
    /// Music.app refused automation from this terminal (Apple Event error -1743).
    static let automationNotPermitted = "Music.app automation is not permitted for this terminal"
    static let notRunning = "not running"
    static let timedOut = "timed out"
    static let noMatch = "no match"
    static let libraryNotLoaded = "Music.app's library hasn't finished loading"
    static let changed = "changed"
    static let invalidPersistentID = "invalid persistent ID"
    static let unexpectedResult = "unexpected scripting result"
}

extension AEFailure {
    /// -600 (the process is gone) and -609 (the connection is gone) mean
    /// Music.app is not running; -1712 is a timeout; -1743 is a refused
    /// automation permission.
    var accessError: MusicAccessError {
        switch code {
        case -600, -609: return .notRunning
        case -1712: return .timedOut
        case -1743: return .failed(MusicAccessSentence.automationNotPermitted)
        case -1: return .failed(message)
        default: return .failed("Music.app error \(code)")
        }
    }

    /// The same meaning as a short reason, for write outcomes.
    var reason: String {
        switch accessError {
        case .notRunning: return MusicAccessSentence.notRunning
        case .timedOut: return MusicAccessSentence.timedOut
        case .failed(let message): return message
        }
    }
}

/// Exactly sixteen uppercase hex digits. Checked before any call to Music.app.
func isPersistentIDHex(_ value: String) -> Bool {
    let utf8 = Array(value.utf8)
    return utf8.count == 16 && utf8.allSatisfy {
        ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
            || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "F"))
    }
}

// MARK: - The writer

/// `PlayCountWriting` over a fresh process lookup and a session opened per
/// call.
///
/// A call is addressed to one `MusicProcess`. If a fresh lookup no longer
/// finds that exact process (a different pid or start time), or no session
/// can be opened to it, Music.app counts as not running and nothing is sent.
///
/// Write stages: connect, exactly one match, recheck against `expect`, set the
/// count (only if it differs), set the date (only if it differs), read back.
/// Only a result reached before the first set call is `notSent`. Once a set
/// call has been made, anything short of a readback is `unknown` or
/// `countAppliedDateUnknown`, whatever the error said, because a timeout or an
/// error reply does not prove that nothing applied. The recheck narrows the
/// window for a change made in Music.app itself; it does not close it.
struct MusicPlayCountWriter: PlayCountWriting {
    private let locate: () -> MusicProcess?
    private let openSession: (MusicProcess) -> MusicLibrarySession?

    init(locate: @escaping () -> MusicProcess?,
         openSession: @escaping (MusicProcess) -> MusicLibrarySession?) {
        self.locate = locate
        self.openSession = openSession
    }

    /// The live writer: the process table for the lookup, ScriptingBridge for
    /// the session. The start time is the same reading the instance inspector
    /// compares against, so the two agree on what "the same process" means.
    init() {
        let locator = MusicProcessLocator(listProcesses: runningProcessPaths,
                                          startTime: { try? processStartTime(pid: $0).get() })
        self.init(locate: locator.locate,
                  openSession: { ScriptingBridgeSession(process: $0) })
    }

    func musicProcess() -> MusicProcess? {
        locate()
    }

    func read(_ process: MusicProcess, persistentID: String) throws -> TrackLookup {
        guard isPersistentIDHex(persistentID) else {
            throw MusicAccessError.failed(MusicAccessSentence.invalidPersistentID)
        }
        guard let session = connect(process) else { throw MusicAccessError.notRunning }
        let matches: Int
        switch session.matchCount(persistentID: persistentID) {
        case .failure(let failure): throw failure.accessError
        case .success(let n): matches = n
        }
        if matches == 0 {
            switch session.libraryTrackCount() {
            case .failure(let failure): throw failure.accessError
            case .success(let total): return .notFound(libraryTrackCount: total)
            }
        }
        if matches > 1 { return .ambiguous(matches: matches) }
        switch session.playState(persistentID: persistentID) {
        case .failure(let failure): throw failure.accessError
        case .success(let state): return .found(state)
        }
    }

    func write(_ process: MusicProcess, persistentID: String,
               expect: TrackPlayState, target: TrackPlayState) -> WriteOutcome {
        stagedWrite(process, persistentID: persistentID, expect: expect,
                    count: target.count, date: target.date)
    }

    func writeDate(_ process: MusicProcess, persistentID: String,
                   expect: TrackPlayState, date: Int) -> WriteOutcome {
        stagedWrite(process, persistentID: persistentID, expect: expect,
                    count: nil, date: date)
    }

    private func connect(_ process: MusicProcess) -> MusicLibrarySession? {
        guard locate() == process else { return nil }
        return openSession(process)
    }

    /// `count` nil never sets the count. A nil `date` never sets the date: a
    /// played date cannot be cleared.
    private func stagedWrite(_ process: MusicProcess, persistentID: String,
                             expect: TrackPlayState, count: Int?, date: Int?) -> WriteOutcome {
        guard isPersistentIDHex(persistentID) else {
            return .notSent(current: nil, reason: MusicAccessSentence.invalidPersistentID)
        }
        guard let session = connect(process) else {
            return .notSent(current: nil, reason: MusicAccessSentence.notRunning)
        }
        switch session.matchCount(persistentID: persistentID) {
        case .failure(let failure): return .notSent(current: nil, reason: failure.reason)
        case .success(0): return .notSent(current: nil, reason: MusicAccessSentence.noMatch)
        case .success(1): break
        case .success(let n): return .notSent(current: nil, reason: "matches=\(n)")
        }
        let current: TrackPlayState
        switch session.playState(persistentID: persistentID) {
        case .failure(let failure): return .notSent(current: nil, reason: failure.reason)
        case .success(let state): current = state
        }
        guard current == expect else {
            return .notSent(current: current, reason: MusicAccessSentence.changed)
        }

        var setCalled = false
        var countSet = false
        if let count, count != current.count {
            setCalled = true
            if case .failure(let failure) = session.setPlayedCount(count, persistentID: persistentID) {
                return .unknown(failure.reason)
            }
            countSet = true
        }
        if let date, date != current.date {
            setCalled = true
            if case .failure(let failure) = session.setPlayedDate(date, persistentID: persistentID) {
                return countSet ? .countAppliedDateUnknown(failure.reason) : .unknown(failure.reason)
            }
        }
        switch session.playState(persistentID: persistentID) {
        case .success(let readback):
            return .applied(readback)
        case .failure(let failure):
            // With no set call made, nothing was submitted, so the result is
            // still positively not sent.
            return setCalled ? .unknown(failure.reason) : .notSent(current: nil, reason: failure.reason)
        }
    }
}

// MARK: - Finding the running Music.app

/// The pid of the one running Music.app among `processes`, by executable path.
/// Only a path ending `/Music.app/Contents/MacOS/Music` counts. None, or more
/// than one, is nil.
func musicAppPID(_ processes: [(pid: Int32, path: String)]) -> Int32? {
    let matches = musicAppMatches(processes)
    return matches.count == 1 ? matches[0] : nil
}

private func musicAppMatches(_ processes: [(pid: Int32, path: String)]) -> [Int32] {
    processes.filter { $0.path.hasSuffix("/Music.app/Contents/MacOS/Music") }.map(\.pid)
}

/// A fresh lookup of the running Music.app on every call, from the process
/// table. Nothing is cached, so a long-lived process never holds a stale pid.
struct MusicProcessLocator {
    let listProcesses: () -> [(pid: Int32, path: String)]
    /// The process's start time, or nil when it cannot be read.
    let startTime: (Int32) -> Double?

    private static let log = Logger(subsystem: "music", category: "play-sync")

    func locate() -> MusicProcess? {
        let matches = musicAppMatches(listProcesses())
        if matches.count > 1 {
            Self.log.notice("more than one Music.app is running (\(matches.count, privacy: .public)); not choosing one")
        }
        guard matches.count == 1, let started = startTime(matches[0]) else { return nil }
        return MusicProcess(pid: matches[0], startedAt: started)
    }
}

/// Every process this user can see, with its executable path. Reads the
/// process table only; it sends nothing to any process.
func runningProcessPaths() -> [(pid: Int32, path: String)] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let listed = pids.withUnsafeMutableBufferPointer {
        proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
    }
    guard listed > 0 else { return [] }
    let size = 4 * Int(MAXPATHLEN)
    var buffer = [CChar](repeating: 0, count: size)
    var result: [(pid: Int32, path: String)] = []
    for pid in pids.prefix(Int(listed)) where pid > 0 {
        let length = proc_pidpath(pid, &buffer, UInt32(size))
        guard length > 0 else { continue }
        result.append((pid: pid, path: String(cString: buffer)))
    }
    return result
}
