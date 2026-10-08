import Foundation

/// The one arbitration between a script's natural exit and its watchdog, under
/// one lock. The exit side (the process's termination handler, or the caller
/// once it has seen exit and both EOFs) records `exited`; the watchdog may
/// claim the timeout, and terminate, only while `exited` is still false. So a
/// script that exits before its deadline is never reported as a timeout, even
/// when draining its pipes runs past the deadline (a grandchild holding them).
final class ScriptExitArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var timedOut = false

    /// The process has exited. Idempotent; a timeout already claimed stands.
    func recordExit() { lock.lock(); exited = true; lock.unlock() }

    /// The watchdog's claim: if the process has not exited, record the timeout
    /// and run `terminate` while still holding the lock, so no exit can be
    /// recorded between the check and the kill. Returns whether it claimed.
    @discardableResult
    func claimTimeout(terminate: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !exited else { return false }
        timedOut = true
        terminate()
        return true
    }

    /// Read once, after exit and both EOFs: records the exit (the caller has
    /// seen it) and returns whether the watchdog claimed the timeout first.
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        exited = true
        return timedOut
    }
}

struct AppleScriptBackend {
    /// The interpreter every script runs through. Production never changes it.
    /// A test that drives a Music.app-mode play path points it at something
    /// inert, because the real one plays the person's library out loud: on
    /// 2026-09-23 two call-site tests played a library track through the
    /// speakers on every suite run, from 13:55 until it was traced at 17:55.
    var executable = "/usr/bin/osascript"

    enum ScriptError: Error, LocalizedError {
        case executionFailed(String)
        case speakerNotFound(name: String, available: [String])
        case speakerUnavailable(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .executionFailed(let msg):
                return "AppleScript error: \(msg)"
            case .speakerNotFound(let name, let available):
                let list = available.joined(separator: ", ")
                return "Speaker \"\(name)\" not found. Available: \(list)"
            case .speakerUnavailable(let name):
                return "\(name) is not responding. Try: music speaker wake"
            case .timeout(let operation):
                return "Timed out: \(operation). Speaker may be offline."
            }
        }
    }

    /// Run raw AppleScript and return stdout.
    ///
    /// `timeout` is a watchdog, not advisory: a `set selected` to a half-dead
    /// AirPlay device can stall for the full 2-minute Apple Event timeout (or
    /// forever if Music wedges), and before this every caller — including the
    /// shell's single serial action queue — blocked with it. On expiry the
    /// osascript subprocess is terminated and `ScriptError.timeout` thrown.
    ///
    /// The subprocess runs in `runBlocking` on a Dispatch queue, never on a
    /// thread of Swift's cooperative pool: the work blocks for its whole
    /// length, and a blocking body on the pool both starves it and waits on it
    /// (a full pool once held a library play's AppleScript back for as long as
    /// the pool stayed full).
    func run(_ script: String, timeout: TimeInterval = 45) async throws -> String {
        try ExternalCallTripwire.shared.check(.appleScript(script: script))
        let backend = self
        return try await withCheckedThrowingContinuation { continuation in
            appleScriptQueue.async {
                continuation.resume(with: Result { try backend.runBlocking(script, timeout: timeout) })
            }
        }
    }

    /// Run a script inside `tell application "Music" ... end tell`.
    func runMusic(_ script: String, timeout: TimeInterval = 45) async throws -> String {
        let backend = self
        return try await withCheckedThrowingContinuation { continuation in
            appleScriptQueue.async {
                continuation.resume(with: Result { try backend.runMusicBlocking(script, timeout: timeout) })
            }
        }
    }

    /// `runMusic`, on the calling thread. For synchronous callers: it needs no
    /// `Task`, so it cannot wait on the cooperative pool.
    func runMusicBlocking(_ script: String, timeout: TimeInterval = 45) throws -> String {
        try runBlocking(musicWrapped(script), timeout: timeout)
    }

    private func musicWrapped(_ script: String) -> String {
        """
        tell application "Music"
            \(script)
        end tell
        """
    }

    /// The one subprocess core: `run`, on the calling thread, which it blocks
    /// until the script has exited and both of its pipes are at end of file.
    ///
    /// stdout is read here and stderr on a Dispatch thread at the same time. A
    /// serial read (stdout to EOF, then stderr) deadlocks once the script fills
    /// the stderr pipe while we still wait on stdout: it blocks on the write,
    /// we block on the read. Reads start BEFORE the wait for exit for the same
    /// reason. A watchdog kill closes the script's ends of both pipes, so both
    /// reads still return, and the timeout is reported only after they have.
    /// Exit versus timeout is decided once, by `ScriptExitArbiter`.
    func runBlocking(_ script: String, timeout: TimeInterval = 45) throws -> String {
        try ExternalCallTripwire.shared.check(.appleScript(script: script))
        verbose("osascript: \(script.prefix(200))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Set before launch so no exit can be missed. On a launch failure the
        // handler never runs, and nothing waits on it: the outcome is read
        // after `waitUntilExit`, never from the handler.
        let arbiter = ScriptExitArbiter()
        process.terminationHandler = { _ in arbiter.recordExit() }

        // A launch failure throws here, before any reader or watchdog exists,
        // so nothing is left waiting on a pipe no process will ever close.
        try process.run()

        let watchdog = DispatchWorkItem {
            arbiter.claimTimeout { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let errReader = PipeReader(stderr.fileHandleForReading)
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = errReader.waitForEOF()
        process.waitUntilExit()
        watchdog.cancel()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()

        // Read once, after exit and both EOFs: this one read is the decision
        // between a natural exit and a timeout, so it cannot be made twice.
        // A watchdog that fires during a drain that outlives the script (a
        // grandchild holding a pipe) finds `exited` and claims nothing.
        if arbiter.finish() {
            verbose("osascript timed out after \(Int(timeout))s, terminated")
            throw ScriptError.timeout(String(script.prefix(80)))
        }

        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            verbose("osascript failed: \(errStr)")
            // -1728 against an AirPlay device = it vanished / stopped responding;
            // surface the actionable message instead of raw AppleScript noise.
            if errStr.contains("Can't get AirPlay device") || (errStr.contains("AirPlay device") && errStr.contains("-1728")) {
                throw ScriptError.speakerUnavailable(speakerName(fromAppleScriptError: errStr) ?? "Speaker")
            }
            throw ScriptError.executionFailed(errStr)
        }

        let result = String(data: outData, encoding: .utf8) ?? ""
        verbose("osascript result: \(result.prefix(200))")
        return result
    }
}

/// Where the async `run`/`runMusic` do their blocking work: a Dispatch queue,
/// so a subprocess never holds a cooperative-pool thread. Concurrent, so one
/// slow script (a wedged AirPlay device, up to its watchdog) does not hold the
/// others back.
private let appleScriptQueue = DispatchQueue(label: "music.applescript", qos: .userInitiated,
                                             attributes: .concurrent)

/// Reads one pipe to end of file on a Dispatch thread of its own, so the
/// caller can read the other pipe at the same time.
private final class PipeReader: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Written once, before the signal; read only after the wait.
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    /// Blocks until the pipe is at end of file, then returns what it held.
    func waitForEOF() -> Data {
        done.wait()
        return data
    }
}

/// Pull the device name out of an AppleScript error like
/// `36:41: execution error: Music got an error: Can't get AirPlay device "Deck". (-1728)`.
/// Pure, for testability.
func speakerName(fromAppleScriptError errStr: String) -> String? {
    guard let start = errStr.range(of: "AirPlay device \"") else { return nil }
    let rest = errStr[start.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    let name = String(rest[..<end])
    return name.isEmpty ? nil : name
}
