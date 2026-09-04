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
/// What seeds a bounded-playback container.
///
/// The album path seeds by Library index and is unchanged by the extraction
/// that introduced this type; `testAlbumSeedScriptIsByteIdenticalToItsPre\
/// ExtractionForm` pins that as a whole string rather than by `contains`.
///
/// The song path seeds by `persistent ID` instead, because a single song is
/// often played immediately after being added from the catalog, and a freshly
/// synced row's Library index is the least trustworthy handle available at
/// that moment (measured 2026-09-03: the row was not resolvable at all until
/// t+3s, one second inside the shipped 4s sleep). The identifier is also what
/// makes the built container confirmable by identity rather than by count.
enum ContainerSeed: Equatable {
    /// Positions in the `Library` playlist, already disc/track ordered and
    /// playability filtered by `orderedPlayableAlbumTracks`.
    case libraryIndices([Int])
    /// One track's `persistent ID`. Exactly one track is expected to match;
    /// the caller confirms that from the container's own read-back.
    case persistentID(String)
}

extension ContainerSeed {
    /// How many tracks the seed should put in the container.
    var expectedCount: Int {
        switch self {
        case .libraryIndices(let indices): return indices.count
        case .persistentID: return 1
        }
    }

    var isEmpty: Bool { expectedCount == 0 }
}

/// Album seeding, unchanged. Kept as its own entry point so the byte-identical
/// pin keeps testing the thing the album path actually calls.
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

/// Song seeding: address the source row by identifier, never by index.
///
/// `whose persistent ID is` is an exact match, so a missing row duplicates
/// nothing and the container comes back with zero tracks, which the caller
/// treats as a failure and rolls back. That is the fail-closed direction: a
/// wrong or absent id must never fall through to the library-rooted play this
/// work exists to remove.
func songContainerBuildScript(name: String, persistentID: String) -> String {
    let esc = escapeAppleScriptString(name)
    let escID = escapeAppleScriptString(persistentID)
    return """
    make new playlist with properties {name:"\(esc)"}
    repeat with t in (every track of playlist "Library" whose persistent ID is "\(escID)")
        duplicate t to playlist "\(esc)"
    end repeat
    return (count of tracks of playlist "\(esc)") as text
    """
}

func containerBuildScript(name: String, seed: ContainerSeed) -> String {
    switch seed {
    case .libraryIndices(let indices):
        return albumContainerBuildScript(name: name, indices: indices)
    case .persistentID(let pid):
        return songContainerBuildScript(name: name, persistentID: pid)
    }
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
    /// A failure whose rollback delete ALSO failed, so a partial container may
    /// still exist in the user's library. Distinguished from the plain failure
    /// cases so no caller can claim the container was removed when it was not.
    /// The container is not orphaned permanently: a later album play sweeps
    /// stale containers, as does `music playlist cleanup`.
    case cleanupFailed
}

/// Build the container, or leave nothing behind.
///
/// Fail closed: any failure deletes the exact container by name before
/// returning, so a partial container never survives to be played or to litter
/// the sidebar.
func buildAlbumContainer(name: String, indices: [Int], run: ScriptRunner)
    -> AlbumContainerBuildResult {
    buildContainer(name: name, seed: .libraryIndices(indices), run: run)
}

/// Build a bounded-playback container from either seed.
///
/// Behaviour for `.libraryIndices` is exactly what `buildAlbumContainer` did
/// before the extraction: same script, same rollback on every failure, same
/// seed-count check. `.persistentID` reuses all of it with an expected count
/// of one, so a missing or duplicated id lands in `.seedMismatch` and is
/// rolled back rather than played.
func buildContainer(name: String, seed: ContainerSeed, run: ScriptRunner)
    -> AlbumContainerBuildResult {
    guard !seed.isEmpty else { return .noTracks }

    guard let raw = run(containerBuildScript(name: name, seed: seed)) else {
        if run(playlistDeleteScript(name: name)) == nil {
            verbose("album container \(name): build failed and cleanup also failed (container may remain)")
            return .cleanupFailed
        }
        return .createFailed
    }
    let got = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    guard got == seed.expectedCount else {
        if run(playlistDeleteScript(name: name)) == nil {
            verbose("album container \(name): seed mismatch (expected \(seed.expectedCount), got \(got)) and cleanup also failed (container may remain)")
            return .cleanupFailed
        }
        return .seedMismatch(expected: seed.expectedCount, got: got)
    }
    return .built
}
