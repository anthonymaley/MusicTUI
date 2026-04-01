import Foundation

struct LibrarySync {
    let backend = AppleScriptBackend()

    /// Poll until a playlist name appears in AppleScript, up to maxAttempts with 1s delay.
    func waitForPlaylist(named name: String, maxAttempts: Int = 10) async throws -> Bool {
        for _ in 0..<maxAttempts {
            let result = try await backend.runMusic("get name of every playlist")
            if result.contains(name) { return true }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }
}
