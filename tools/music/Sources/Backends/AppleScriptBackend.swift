import Foundation

struct AppleScriptBackend {
    enum ScriptError: Error, LocalizedError {
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .executionFailed(let msg): return "AppleScript error: \(msg)"
            }
        }
    }

    /// Run raw AppleScript and return stdout.
    func run(_ script: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw ScriptError.executionFailed(errStr)
        }

        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Run a script inside `tell application "Music" ... end tell`.
    func runMusic(_ script: String) async throws -> String {
        let wrapped = """
        tell application "Music"
            \(script)
        end tell
        """
        return try await run(wrapped)
    }
}
