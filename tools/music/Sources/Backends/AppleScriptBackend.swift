import Foundation

/// Thread-safe one-way flag for the osascript watchdog (sync accessors so the
/// async `run` body doesn't lock directly).
final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
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
    func run(_ script: String, timeout: TimeInterval = 45) async throws -> String {
        try ExternalCallTripwire.shared.check(.appleScript(script: script))
        verbose("osascript: \(script.prefix(200))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            timedOut.set()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Read pipes BEFORE waiting: wait-then-read deadlocks once output
        // exceeds the pipe buffer (the subprocess blocks on write, we block
        // on exit). Reads return at EOF, including after a watchdog kill.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if timedOut.get() {
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

    /// Run a script inside `tell application "Music" ... end tell`.
    func runMusic(_ script: String, timeout: TimeInterval = 45) async throws -> String {
        let wrapped = """
        tell application "Music"
            \(script)
        end tell
        """
        return try await run(wrapped, timeout: timeout)
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
