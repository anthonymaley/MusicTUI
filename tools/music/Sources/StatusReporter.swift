import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Print a diagnostic line to stderr when `Music.verbose` is enabled.
func verbose(_ message: String) {
    guard Music.verbose else { return }
    FileHandle.standardError.write(Data("[verbose] \(message)\n".utf8))
}

/// Show a transient status message on stderr during a long operation.
/// - Prints only when stdout is a TTY and not in JSON mode.
/// - Clears the line on completion (success or failure).
func withStatus<T>(_ message: String, body: () throws -> T) rethrows -> T {
    let shouldShow = isTTY() && !Music.isJSON

    if shouldShow {
        FileHandle.standardError.write(Data("\(message)\r".utf8))
    }

    defer {
        if shouldShow {
            let clearLine = "\r\(String(repeating: " ", count: message.count + 2))\r"
            FileHandle.standardError.write(Data(clearLine.utf8))
        }
    }

    return try body()
}

/// Show a progress counter on stderr (e.g., "Adding tracks... 3/10").
/// Call repeatedly as the count advances; each call overwrites the previous line.
func updateStatus(_ message: String) {
    guard isTTY() && !Music.isJSON else { return }
    FileHandle.standardError.write(Data("\r\(message)".utf8))
}

/// Clear any active status line on stderr.
func clearStatus(length: Int = 80) {
    guard isTTY() && !Music.isJSON else { return }
    FileHandle.standardError.write(Data("\r\(String(repeating: " ", count: length))\r".utf8))
}
