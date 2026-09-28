// tools/music/Sources/TUI/MusicTUIHandoff.swift
//
// Owned songs by exact persistent ID (score: data route and output, step 7,
// C-HANDOFF).
//
// With SpanDAC as MusicTUI's music-data source and the MusicTUI output
// selected, a SpanDAC LIBRARY row (a song, an album's tracks, an artist's
// songs, a playlist's tracks) plays on Apple's Music app by the persistent ID
// SpanDAC reported for each song (`MusicRow.alias`, a signed decimal that
// `persistentIDHex(fromAlias:)` rewrites to hex notation; a change of
// notation, never a mapping this client computes).
//
// The rule, all or nothing:
// - Every track must carry an alias that parses.
// - One read (AppleScript, read-only) looks every identity up: the library
//   playlist first; only when it is not there, every user playlist. Each must
//   be exactly ONE track (one persistent ID found in several playlists is one
//   track), and that track's name must equal the row's title (CHOSEN guard: it
//   can only refuse).
// - Only then is the queue built, addressed by persistent ID
//   (`persistentIDQueueEntry`), and played.
// - Any missing, unparsable, unresolved, ambiguous or mismatched track refuses
//   the WHOLE play with `pickASpanDACOutput`. There is no partial queue (a
//   queue silently missing songs is a different album from the one chosen)
//   and no title search, ever.
//
// The alias key MusicKit carries is undocumented, so the client checks it is
// there at all: `LibraryAliasSelfCheck` watches the first SpanDAC library
// page this process reads and, if no song on it carried one, the next
// hand-off says so once and every hand-off refuses.
//
// The verification reads run wherever the caller runs them (the shell's
// action queue, off the main loop, inside `RoutingCoordinator.perform`), and
// the routing stamp is read on entry and read again after the reads, just
// before the one sound mutation: a stamp that moved plays nothing.
import Foundation

/// The self-check's sentence: MusicKit on this macOS gave no song a
/// persistent ID, so no library row can be handed to the MusicTUI output.
/// CHOSEN wording (score default).
let spanDACReportsNoTrackIdentities =
    "SpanDAC isn't reporting track identities on this macOS, so your library plays only on a SpanDAC output."

/// One track the verification read found for a persistent ID.
struct HandoffTrackHit: Equatable {
    /// The identity looked up, as sixteen hex digits.
    let persistentID: String
    /// Found in the library playlist; false when found only in user playlists.
    let inLibrary: Bool
    /// Apple's Music app `database ID`, which tells two library tracks apart.
    let databaseID: String
    /// Position in the library playlist, for a library hit (the CLI's bounded
    /// container is seeded by it and then confirmed by identity).
    let libraryIndex: Int?
    let name: String
}

/// The read-only identity lookup behind the hand-off.
protocol PersistentIDTrackReading {
    /// For each persistent ID (hex), every track found: in the library
    /// playlist, or, only when none is there, in the user playlists. An ID
    /// with nothing found may be absent from the answer. Throws when the read
    /// itself failed, which is not the same as "not found".
    func tracks(persistentIDs: [String]) throws -> [String: [HandoffTrackHit]]
}

/// The live lookup: ONE AppleScript for every identity of a play.
struct AppleScriptPersistentIDReader: PersistentIDTrackReading {
    /// Runs a script inside `tell application "Music"` and returns its output.
    let run: (String) throws -> String

    func tracks(persistentIDs: [String]) throws -> [String: [HandoffTrackHit]] {
        guard !persistentIDs.isEmpty else { return [:] }
        return parsePersistentIDVerification(try run(persistentIDVerificationScript(persistentIDs)))
    }
}

/// The verification read: every track whose persistent ID is each given one,
/// library playlist first, then every user playlist only when the library has
/// none. Addresses tracks by persistent ID only; it reads `name` to return it,
/// never to find anything by it. One line per track found:
/// `pid<US>L|P<US>database ID<US>library index (0 for P)<US>name`.
func persistentIDVerificationScript(_ persistentIDs: [String]) -> String {
    let list = persistentIDs.map { "\"\(escapeAppleScriptString($0))\"" }.joined(separator: ", ")
    return """
    set fs to (ASCII character 31)
    set out to ""
    repeat with idRef in {\(list)}
        set pidText to contents of idRef
        set hits to (every track of library playlist 1 whose persistent ID is pidText)
        if (count of hits) > 0 then
            repeat with t in hits
                set out to out & pidText & fs & "L" & fs & (database ID of t) & fs & (index of t) & fs & (name of t) & linefeed
            end repeat
        else
            repeat with p in (every user playlist)
                try
                    repeat with t in (every track of p whose persistent ID is pidText)
                        set out to out & pidText & fs & "P" & fs & (database ID of t) & fs & "0" & fs & (name of t) & linefeed
                    end repeat
                end try
            end repeat
        end if
    end repeat
    return out
    """
}

/// Reads `persistentIDVerificationScript`'s lines. A line that does not have
/// all five fields is dropped, which can only leave a track unresolved (and
/// so refused), never resolve a wrong one.
func parsePersistentIDVerification(_ raw: String) -> [String: [HandoffTrackHit]] {
    var out: [String: [HandoffTrackHit]] = [:]
    for line in raw.components(separatedBy: "\n") where !line.isEmpty {
        let f = line.split(separator: asFieldSep, maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5, f[1] == "L" || f[1] == "P", let index = Int(f[3]) else { continue }
        let pid = f[0].uppercased()
        let inLibrary = f[1] == "L"
        out[pid, default: []].append(HandoffTrackHit(persistentID: pid, inLibrary: inLibrary, databaseID: f[2],
                                                     libraryIndex: inLibrary ? index : nil, name: f[4]))
    }
    return out
}

/// A row that passed every check, with the one track it resolved to.
struct VerifiedHandoffTrack: Equatable {
    let persistentID: String
    let name: String
    let artist: String
    let album: String?
    /// The library-playlist position, when the track is in the library.
    let libraryIndex: Int?
}

/// C-HANDOFF's client self-check for the undocumented alias key.
///
/// Records, at the first SpanDAC library page this process reads that has
/// song rows on it, whether ANY of them carried an alias. If none did, the next
/// hand-off says `spanDACReportsNoTrackIdentities` once, and every hand-off
/// after refuses with `pickASpanDACOutput`. Never a guess.
///
/// One deliberate softening: a LATER page whose songs do carry aliases clears
/// the finding (a first page made only of songs MusicKit cannot identify, such
/// as ones no longer available, would otherwise refuse the whole library for
/// the rest of the process). It never goes the other way.
final class LibraryAliasSelfCheck {
    /// The one the SpanDAC client's library reads report to.
    static let shared = LibraryAliasSelfCheck()

    private enum State { case unobserved, aliasesSeen, noAliases(said: Bool) }
    private let lock = NSLock()
    private var state: State = .unobserved

    /// Report one library read's rows. Rows other than songs decide nothing.
    func observe(_ rows: [MusicRow]) {
        let songs = rows.filter { $0.kind == .song }
        guard !songs.isEmpty else { return }
        let carried = songs.contains { $0.alias != nil }
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .unobserved:
            state = carried ? .aliasesSeen : .noAliases(said: false)
        case .noAliases where carried:
            state = .aliasesSeen
        case .noAliases, .aliasesSeen:
            break
        }
    }

    /// The refusal the check demands, or nil when it demands none. The first
    /// refusal is the self-check's own sentence; later ones are the plain one.
    func refusal() -> String? {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .unobserved, .aliasesSeen:
            return nil
        case .noAliases(let said):
            state = .noAliases(said: true)
            return said ? pickASpanDACOutput : spanDACReportsNoTrackIdentities
        }
    }
}

/// C-HANDOFF's check, shared by the TUI and the CLI: every row resolves to
/// exactly one track by identity, or the whole play is refused. Reads only.
func verifyHandoffTracks(rows: [MusicRow], title: String, library: PersistentIDTrackReading,
                         selfCheck: LibraryAliasSelfCheck) throws -> [VerifiedHandoffTrack] {
    let refused = ActionError(message: pickASpanDACOutput)
    if let said = selfCheck.refusal() { throw ActionError(message: said) }
    guard !rows.isEmpty else { throw refused }

    // Every identity parses before anything is read.
    var ids: [String] = []
    for row in rows {
        guard row.kind == .song, let alias = row.alias, let hex = persistentIDHex(fromAlias: alias) else {
            throw refused
        }
        ids.append(hex)
    }
    let verified: [HandoffTrackHit]?
    do {
        verified = try verifyExactTracks(zip(ids, rows).map { ($0, $1.title) }, library: library)
    } catch {
        throw ActionError(message: "Couldn't check '\(title)' in your library, so nothing was played.")
    }
    guard let hits = verified else { throw refused }
    return zip(rows, hits).map { row, hit in
        VerifiedHandoffTrack(persistentID: hit.persistentID, name: hit.name, artist: row.artist, album: row.album,
                             libraryIndex: hit.libraryIndex)
    }
}

/// THE identity check. Every play that hands a SpanDAC song to the MusicTUI
/// output by persistent ID goes through it: library rows
/// (`verifyHandoffTracks`) and a song SpanDAC has just added or found owned
/// (`verifySpanDACAlias`). Each wanted identity (hex) must resolve to exactly
/// ONE track, and, when a title is known, that track's name must equal it
/// (CHOSEN guard, C-HANDOFF: it can only refuse). One miss refuses the whole
/// set: nil, never a partial answer and never a title search. Reads only;
/// throws only when the read itself failed, which is not "not found".
func verifyExactTracks(_ wanted: [(persistentID: String, title: String?)],
                       library: PersistentIDTrackReading) throws -> [HandoffTrackHit]? {
    guard !wanted.isEmpty else { return nil }
    var unique: [String] = []
    var seen = Set<String>()
    for id in wanted.map(\.persistentID) where seen.insert(id).inserted { unique.append(id) }
    let found = try library.tracks(persistentIDs: unique)
    var hits: [HandoffTrackHit] = []
    for (id, title) in wanted {
        guard let hit = exactlyOneTrack(found[id] ?? [], id: id) else { return nil }
        if let title, hit.name != title { return nil }
        hits.append(hit)
    }
    return hits
}

/// The one track `hits` names, or nil when it names none or more than one.
/// Library hits decide when there are any: two different library tracks with
/// one identity is ambiguous. Hits only in user playlists all share the
/// identity, so they are one track, provided they agree on its name.
private func exactlyOneTrack(_ hits: [HandoffTrackHit], id: String) -> HandoffTrackHit? {
    guard !hits.isEmpty, hits.allSatisfy({ $0.persistentID == id }) else { return nil }
    let library = hits.filter(\.inLibrary)
    let deciding = library.isEmpty ? hits : library
    if !library.isEmpty, Set(library.map(\.databaseID)).count != 1 { return nil }
    guard Set(deciding.map(\.name)).count == 1 else { return nil }
    return deciding[0]
}

/// Plays one verified queue: the one sound mutation of a hand-off.
protocol HandoffQueuePlaying {
    func play(_ queue: AppQueue) throws
}

/// The TUI's player: the app-owned queue (`AppQueueStore`), whose entries are
/// addressed by persistent ID, so the poller's auto-advance, next/previous,
/// Now's jump and shuffle all keep playing by identity.
struct AppQueueHandoffPlayer: HandoffQueuePlaying {
    let store: AppQueueStore
    /// Plays the queue's current entry; false on failure.
    let playFirst: (AppQueue) -> Bool

    func play(_ queue: AppQueue) throws {
        store.set(queue)
        guard playFirst(queue) else {
            // A queue that never started is not left for the poller to drive.
            store.clear()
            throw ActionError(message: "Couldn't play '\(queue.contextLabel)'.")
        }
    }
}

/// What the hand-off compares before and after its reads: both routing
/// epochs. Nil means MusicTUI no longer has SpanDAC data on its own output.
struct MusicTUIHandoffStamp: Equatable {
    let epoch: Int
    let dataEpoch: Int
}

/// The real `MusicTUIHandoff` (replacing the seeded `RefusingHandoff`).
struct PersistentIDHandoff: MusicTUIHandoff {
    let library: PersistentIDTrackReading
    let player: HandoffQueuePlaying
    let selfCheck: LibraryAliasSelfCheck
    let currentStamp: () -> MusicTUIHandoffStamp?

    func playLibrary(rows: [MusicRow], startAt: Int, shuffle: Bool, title: String) throws {
        guard let entry = currentStamp() else { throw ActionError(message: sourceChangedNothingPlayed) }
        let verified = try verifyHandoffTracks(rows: rows, title: title, library: library, selfCheck: selfCheck)
        let entries = verified.compactMap {
            persistentIDQueueEntry(persistentID: $0.persistentID, name: $0.name, artist: $0.artist, album: $0.album)
        }
        guard entries.count == verified.count else { throw ActionError(message: pickASpanDACOutput) }
        // The whole set is queued, as the shipped library plays do: shuffled
        // from the top, or in order from the chosen track.
        let ordered = shuffle ? entries.shuffled() : entries
        let current = shuffle ? 1 : min(max(1, startAt), ordered.count)
        // C-EPOCH: re-read after the reads, before the one sound mutation.
        guard currentStamp() == entry else { throw ActionError(message: sourceChangedNothingPlayed) }
        try player.play(AppQueue(playlistName: persistentIDQueueSource, tracks: ordered, currentIndex: current,
                                 displayName: title))
    }
}

/// The shell's hand-off: AppleScript reads and the app-owned queue, stamped
/// by `routing`. Constructs nothing and reads nothing until a play asks.
func liveMusicTUIHandoff(backend: AppleScriptBackend, appQueue: AppQueueStore,
                         routing: RoutingCoordinator) -> MusicTUIHandoff {
    PersistentIDHandoff(
        // CHOSEN: 60 s for one read of every track of a play (the shipped
        // default is 45 s); unmeasured for a very large artist.
        library: AppleScriptPersistentIDReader(run: { script in
            try syncRun { try await backend.runMusic(script, timeout: 60) }
        }),
        player: AppQueueHandoffPlayer(store: appQueue, playFirst: { queue in
            playQueueTrack(backend: backend, playlist: queue.playlistName, position: queue.currentSourcePosition)
        }),
        selfCheck: .shared,
        currentStamp: { routing.musicTUISpanDACStamp })
}

extension RoutingCoordinator {
    /// Both routing epochs while MusicTUI has SpanDAC data on its own output;
    /// nil otherwise. A play by persistent ID reads it on entry and again just
    /// before its one sound mutation: a stamp that moved plays nothing.
    var musicTUISpanDACStamp: MusicTUIHandoffStamp? {
        guard selection == .consistent(data: .spandacMac, output: .musicApp) else { return nil }
        let stamp = self.stamp
        return MusicTUIHandoffStamp(epoch: stamp.epoch, dataEpoch: stamp.dataEpoch)
    }
}
