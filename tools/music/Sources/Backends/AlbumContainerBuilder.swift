// tools/music/Sources/Backends/AlbumContainerBuilder.swift
import Foundation

/// A thing that runs one AppleScript body inside `tell application "Music"` and
/// returns its output, or nil when the call failed.
///
/// Injected rather than concrete so build and rollback are testable without a
/// live Music.app. Same closure seam as RadioCatalog, ArtworkStore, DiscoverFeed.
typealias ScriptRunner = (String) -> String?

/// Create the container and seed it in ONE script.
///
/// The old per track shape (`duplicateLibraryTrack`) spawns one osascript per
/// track, about 2s for a twelve track album. One script pays the roughly 90ms
/// first Apple Event once and about 7ms per additional one.
///
/// Indices are positions in the `Library` playlist, already disc/track ordered
/// and playability filtered by `orderedPlayableAlbumTracks`.
func albumContainerBuildScript(name: String, indices: [Int]) -> String {
    let esc = escapeAppleScriptString(name)
    let dups = indices
        .map { "    duplicate track \($0) of playlist \"Library\" to playlist \"\(esc)\"" }
        .joined(separator: "\n")
    return """
    make new playlist with properties {name:"\(esc)"}
    \(dups)
    return (count of tracks of playlist "\(esc)") as text
    """
}

/// Bulk read the container's own persistent IDs.
///
/// Read from the CONTAINER, never from the source library rows: whether a
/// duplicated playlist track shares its source's persistent ID is unverified,
/// and reading the container sidesteps the question entirely, since what plays
/// is what we read.
func containerTrackIDsScript(name: String) -> String {
    let esc = escapeAppleScriptString(name)
    return """
    set fs to (ASCII character 31)
    set total to count of tracks of playlist "\(esc)"
    if total is 0 then return ""
    set ids to persistent ID of every track of playlist "\(esc)"
    set out to ""
    repeat with i from 1 to total
        set out to out & (item i of ids)
        if i < total then set out to out & fs
    end repeat
    return out
    """
}

func parseContainerTrackIDs(_ raw: String) -> Set<String> {
    Set(raw.split(separator: asFieldSep)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty })
}

enum AlbumContainerBuildResult: Equatable {
    case built
    case noTracks
    case createFailed
    case seedMismatch(expected: Int, got: Int)
}

/// Build the container, or leave nothing behind.
///
/// Fail closed: any failure deletes the exact container by name before
/// returning, so a partial container never survives to be played or to litter
/// the sidebar.
func buildAlbumContainer(name: String, indices: [Int], run: ScriptRunner)
    -> AlbumContainerBuildResult {
    guard !indices.isEmpty else { return .noTracks }

    guard let raw = run(albumContainerBuildScript(name: name, indices: indices)) else {
        _ = run(playlistDeleteScript(name: name))
        return .createFailed
    }
    let got = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    guard got == indices.count else {
        _ = run(playlistDeleteScript(name: name))
        return .seedMismatch(expected: indices.count, got: got)
    }
    return .built
}
