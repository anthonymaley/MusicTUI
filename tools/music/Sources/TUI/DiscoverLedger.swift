// The durable record of what a Discover play transaction created.
//
// This is not a list of the tracks that were played. It is a list of the LIBRARY
// ROWS this feature added, and those two sets differ exactly when the user
// already owned part of the album. Only what is in `createdLibraryIDs` may ever
// be deleted.
import Foundation

struct DiscoverTransaction: Codable, Equatable {
    let id: String                    // uuid; also the playlist's identity
    let playlistName: String          // "__discover__ <uuid>"
    let title: String                 // display only, NEVER an identifier
    let createdLibraryIDs: [String]   // rows this transaction created, and only those
    let createdAt: String             // ISO8601, stamped by the caller
}

/// Mirrors QueueStore: injectable path, atomic write, corrupt reads as empty.
final class DiscoverLedgerStore {
    private let path: String

    init(path: String = NSString(string: "~/.config/music/discover-ledger.json").expandingTildeInPath) {
        self.path = path
    }

    func save(_ entries: [DiscoverTransaction]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(entries)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Absent or corrupt reads as empty. The consequence is residue, which is the
    /// safe direction; erroring at the user over a cleanup file is not.
    func load() -> [DiscoverTransaction] {
        guard let data = FileManager.default.contents(atPath: path),
              let e = try? JSONDecoder().decode([DiscoverTransaction].self, from: data)
        else { return [] }
        return e
    }

    func clear() { try? FileManager.default.removeItem(atPath: path) }
}

let discoverPlaylistPrefix = "__discover__ "

struct DiscoverSweepPlan: Equatable {
    let sweep: [DiscoverTransaction]
    let spared: [DiscoverTransaction]
}

/// Which ledgered transactions may be swept now. The playing one is spared:
/// deleting library rows behind the playhead collapses the queue (measured
/// 2026-08-25), while deleting the container does not.
func discoverSweepPlan(ledger: [DiscoverTransaction],
                       currentPlaylistName: String?) -> DiscoverSweepPlan {
    let playing = currentPlaylistName
    return DiscoverSweepPlan(
        sweep: ledger.filter { $0.playlistName != playing },
        spared: ledger.filter { $0.playlistName == playing })
}

/// Library ids a sweep may actually delete: those claimed ONLY by transactions
/// being swept. A row claimed by any retained transaction survives, whichever
/// transaction created it — two plays can legitimately claim the same row when
/// both pre-checked it before either materialized, and deleting it out from
/// under the one still playing would collapse the queue.
func discoverDeletableIDs(sweeping: [DiscoverTransaction],
                          retaining: [DiscoverTransaction]) -> [String] {
    let keep = Set(retaining.flatMap(\.createdLibraryIDs))
    var seen = Set<String>()
    return sweeping.flatMap(\.createdLibraryIDs)
        .filter { !keep.contains($0) && seen.insert($0).inserted }
}

/// Discover playlists on disk with NO ledger entry — a crash before the ledger
/// was written, a corrupt file, a manual edit.
///
/// These are deleted as CONTAINERS ONLY and this function returns names, never
/// song ids, so a caller cannot use it to delete library rows. Attribution is
/// unknown here, and the rule is that unknown attribution deletes nothing from
/// the library.
func discoverOrphanPlan(playlistNames: [String],
                        ledger: [DiscoverTransaction],
                        currentPlaylistName: String?) -> [String] {
    let known = Set(ledger.map(\.playlistName))
    return playlistNames.filter {
        $0.hasPrefix(discoverPlaylistPrefix) && !known.contains($0) && $0 != currentPlaylistName
    }
}
