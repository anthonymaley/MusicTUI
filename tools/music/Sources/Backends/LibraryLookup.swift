// tools/music/Sources/Backends/LibraryLookup.swift
import Foundation

/// The exact-then-contains library track lookup every "find a library track by
/// title/artist" script shares. Leaves the matches in `results`; the caller
/// appends its action (play / duplicate / ...). One definition instead of ~10
/// hand-rolled copies, each with its own manual escaping.
func libraryTrackLookupScript(title: String, artist: String) -> String {
    let t = escapeAppleScriptString(title)
    // Music.app's AppleScript treats `contains ""` as FALSE, not true, so an
    // empty artist clause matches nothing and defeats an otherwise exact title
    // hit. Measured on a live 14k library: title-only matched 1, while both
    // `artist is ""` and `artist contains ""` matched 0. Callers that know only
    // a title (a keyless `playlist add`) must therefore drop the clause, not
    // pass an empty string.
    guard !artist.isEmpty else {
        return """
        set results to (every track of playlist "Library" whose name is "\(t)")
        if (count of results) = 0 then
            set results to (every track of playlist "Library" whose name contains "\(t)")
        end if
        """
    }
    let a = escapeAppleScriptString(artist)
    return """
    set results to (every track of playlist "Library" whose name is "\(t)" and artist is "\(a)")
    if (count of results) = 0 then
        set results to (every track of playlist "Library" whose name contains "\(t)" and artist contains "\(a)")
    end if
    """
}

/// AppleScript fallback for playlist adds when the REST API can't see the
/// target playlist (not yet synced): duplicate a library track into it.
/// Returns false when the script failed or no library track matched.
@discardableResult
func duplicateLibraryTrack(backend: AppleScriptBackend, title: String, artist: String, toPlaylist playlist: String) -> Bool {
    let result: String
    do {
        result = try syncRun({
            try await backend.runMusic("""
                \(libraryTrackLookupScript(title: title, artist: artist))
                if (count of results) > 0 then
                    duplicate item 1 of results to playlist "\(escapeAppleScriptString(playlist))"
                    return "OK"
                end if
                return "NOT_FOUND"
            """)
        })
    } catch {
        errorOut("✗ Couldn't add to '\(playlist)' via library: \(error.localizedDescription)")
        return false
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
}

/// Wait (bounded) for an API-created playlist to sync to the local Music.app —
/// needed before AppleScript can play it. Polls instead of a fixed sleep: the
/// wait ends the moment the tracks are visible. Returns false on timeout.
func waitForLocalPlaylist(backend: AppleScriptBackend, name: String, minTracks: Int, timeoutSeconds: Double = 15) -> Bool {
    let esc = escapeAppleScriptString(name)
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let count = (try? syncRun {
            try await backend.runMusic("""
                if exists playlist "\(esc)" then
                    return (count of tracks of playlist "\(esc)") as text
                end if
                return "-1"
            """)
        }).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? -1
        if count >= minTracks { return true }
        usleep(500_000)
    }
    return false
}
