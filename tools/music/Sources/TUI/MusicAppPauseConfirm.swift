// tools/music/Sources/TUI/MusicAppPauseConfirm.swift
import Darwin
import Foundation
import ScriptingBridge

// The Output tab's switch away from Music.app needs positive evidence that
// Music.app is not playing: the Music.app twin of `confirmBridgeNotPlaying`.
//
// A switch must never launch Music.app. A name-addressed `tell application
// "Music"` can relaunch it when it quits between a running check and the event
// (docs/plans/2026-09-24-bridge-play-count/work.md, P0: a JXA call held across a
// quit relaunched Music.app; a pid-bound ScriptingBridge object with
// `launchFlags = []` failed -600 and left it quit). So every event here goes
// through a session bound to one process id, following the pattern of
// `PlaySync/ScriptingBridgeSession.swift` without depending on play sync.

/// Music.app's `player state` (com.apple.Music.sdef, enumeration `ePlS`).
enum MusicAppPlayerState: Equatable {
    case stopped, playing, paused, fastForwarding, rewinding
}

/// One connection to one running Music.app process, for the switch's pause and
/// its confirming read. It is bound to a process, so it can neither launch
/// Music.app nor retarget a new instance.
protocol MusicAppPauseSession {
    func pause() throws
    func playerState() throws -> MusicAppPlayerState
}

/// Thrown when Music.app may still be running but could not be reached.
struct MusicAppPauseUnconfirmed: Error, Equatable {
    let reason: String
}

/// True only on positive evidence that Music.app is not playing: no Music.app
/// process, or a `paused`/`stopped` state read through the bound session.
///
/// 1. No process: absence, true, and no session is opened.
/// 2. Otherwise pause through the session (a failure is not a verdict) and read
///    the state through the same session; true only for paused or stopped.
/// 3. If the process goes after step 1 (no session) or between the pause and
///    the read (the read fails), success needs an independent re-check that no
///    Music.app process exists. Anything else throws: uncertainty never reads
///    as absence.
///
/// A throw or false makes the coordinator refuse the switch with its existing
/// "Couldn't confirm Music.app paused; still using it".
func confirmMusicAppNotPlaying(session: () -> MusicAppPauseSession?,
                               isRunning: () -> Bool) throws -> Bool {
    guard isRunning() else { return true }
    guard let session = session() else {
        guard !isRunning() else {
            throw MusicAppPauseUnconfirmed(reason: "Music.app is running but could not be reached")
        }
        return true
    }
    try? session.pause()
    let state: MusicAppPlayerState
    do {
        state = try session.playerState()
    } catch {
        guard !isRunning() else { throw error }
        return true
    }
    return state == .paused || state == .stopped
}

/// Maps a four-character `ePlS` code to a state; nil for anything else.
func musicAppPlayerState(fourCharCode code: String) -> MusicAppPlayerState? {
    switch code {
    case "kPSS": return .stopped
    case "kPSP": return .playing
    case "kPSp": return .paused
    case "kPSF": return .fastForwarding
    case "kPSR": return .rewinding
    default: return nil
    }
}

// MARK: - The process probe

/// One row of the process table. `path` is nil when the executable path cannot
/// be read; `name` is nil when the short name cannot be read either.
struct ProcessTableEntry: Equatable {
    let pid: Int32
    let path: String?
    let name: String?
}

private let musicAppExecutableSuffix = "/Music.app/Contents/MacOS/Music"

/// Whether Music.app may be running. False only for a fully read table in
/// which every process is positively not Music.app: its path is not Music's, or
/// (path unreadable) its name is readable and is not "Music". An unreadable
/// table, or a process that cannot be ruled out, counts as running.
func musicAppMayBeRunning(_ table: [ProcessTableEntry]?) -> Bool {
    guard let table else { return true }
    return table.contains { entry in
        if let path = entry.path { return path.hasSuffix(musicAppExecutableSuffix) }
        guard let name = entry.name else { return true }
        return name == "Music"
    }
}

/// The pid a session may be bound to: the one process whose path is Music's.
/// None, more than one, or an unreadable table is nil (no guess).
func musicAppSessionPID(_ table: [ProcessTableEntry]?) -> Int32? {
    guard let table else { return nil }
    let matches = table.filter { $0.path?.hasSuffix(musicAppExecutableSuffix) == true }
    return matches.count == 1 ? matches[0].pid : nil
}

/// Reads this user's view of the process table, sending nothing to any
/// process. nil when the table cannot be listed in full. A process that has
/// gone by the time it is inspected (ESRCH) is left out.
func readProcessTable() -> [ProcessTableEntry]? {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let listed = pids.withUnsafeMutableBufferPointer {
        proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
    }
    // A full buffer may be a truncated list.
    guard listed > 0, Int(listed) < pids.count else { return nil }
    var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    var nameBuffer = [CChar](repeating: 0, count: 64)
    var table: [ProcessTableEntry] = []
    for pid in pids.prefix(Int(listed)) where pid > 0 {
        errno = 0
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            table.append(ProcessTableEntry(pid: pid, path: String(cString: pathBuffer), name: nil))
            continue
        }
        if errno == ESRCH { continue }
        errno = 0
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLength <= 0 && errno == ESRCH { continue }
        table.append(ProcessTableEntry(pid: pid, path: nil,
                                       name: nameLength > 0 ? String(cString: nameBuffer) : nil))
    }
    return table
}

/// The live probe for `confirmMusicAppNotPlaying(isRunning:)`: a fresh read of
/// the process table on every call.
func liveMusicAppMayBeRunning() -> Bool {
    musicAppMayBeRunning(readProcessTable())
}

/// The live session factory for `confirmMusicAppNotPlaying(session:)`: bound to
/// the one Music.app pid in a fresh table, or nil.
func liveMusicAppPauseSession() -> MusicAppPauseSession? {
    guard let pid = musicAppSessionPID(readProcessTable()) else { return nil }
    return ScriptingBridgeMusicAppPauseSession(pid: pid)
}

// MARK: - The live session (verified live only; tests never build one)

/// Records the first Apple Event failure of a call. With a delegate set, a
/// failed event returns nil instead of raising.
private final class PauseEventFailureCapture: NSObject, SBApplicationDelegate {
    private(set) var failure: NSError?

    func reset() {
        failure = nil
    }

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        if failure == nil { failure = error as NSError }
        return nil
    }
}

/// A pid-bound, non-launching ScriptingBridge session for the switch's pause
/// and state read. Construction fails unless the object is attached to a live
/// process with Music's scripting dictionary; that check comes before any
/// property access or command, because either on an object with no dictionary
/// raises an exception that cannot be caught.
final class ScriptingBridgeMusicAppPauseSession: MusicAppPauseSession {
    private let app: SBApplication
    private let capture = PauseEventFailureCapture()

    init?(pid: Int32) {
        guard let app = SBApplication(processIdentifier: pid) else { return nil }
        app.launchFlags = []
        app.timeout = 600  // ticks: every Apple Event is bounded to about 10 s
        app.delegate = capture
        guard app.isRunning,
              app.responds(to: NSSelectorFromString("playerState")),
              app.responds(to: NSSelectorFromString("pause")) else { return nil }
        self.app = app
    }

    func pause() throws {
        try stage {
            _ = app.perform(NSSelectorFromString("pause"))
            return ()
        }
    }

    func playerState() throws -> MusicAppPlayerState {
        try stage {
            let raw = app.value(forKey: "playerState")
            let code: OSType
            switch raw {
            case let number as NSNumber: code = number.uint32Value
            case let descriptor as NSAppleEventDescriptor: code = descriptor.enumCodeValue
            default: return nil
            }
            return musicAppPlayerState(fourCharCode: fourCharString(code))
        }
    }

    /// One event. The process is checked before it; a failure recorded by the
    /// delegate or `lastError()` fails it; a missing or unknown result is an
    /// error too.
    private func stage<T>(_ body: () -> T?) throws -> T {
        guard app.isRunning else {
            throw MusicAppPauseUnconfirmed(reason: "Music.app is no longer running")
        }
        capture.reset()
        let value = body()
        if let failure = capture.failure { throw failure }
        if let error = app.lastError() { throw error }
        guard let value else {
            throw MusicAppPauseUnconfirmed(reason: "unexpected scripting result")
        }
        return value
    }
}

private func fourCharString(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    return String(decoding: bytes, as: UTF8.self)
}
