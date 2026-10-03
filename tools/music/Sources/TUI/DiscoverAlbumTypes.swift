// tools/music/Sources/TUI/DiscoverAlbumTypes.swift
//
// Shared client types for Discover "play from here" on an ALBUM, with
// clean-up (album-cleanup score section 1.3, step A0). An album has no
// catalogue copy to add, so the play goes through a temporary library playlist
// (the container) made by `slice.libraryEnsurePlaylist`, and every song that
// ensure adds to his library must be proven ours before it may be removed when
// he stops. The types, the pure request builder, the AppleScript name gate and
// the wordings live here so the parts that build on them (wire client, album
// transaction, proof collector, song guard, end and reconcile) can be written
// side by side without talking to each other.
import Foundation

// MARK: K1. Which kind of play-from-here a request or journal entry is

enum DiscoverPlayKind: String, Codable, Equatable {
    case playlistCopy = "playlist_copy"
    case albumContainer = "album_container"
}

/// The album request, or nil when the container is not a Discover album.
/// `playlistID` is the catalogue album id, `playlistTitle` the album's name,
/// `rows` the FULL rows he was shown and `selected` the cursor.
func discoverAlbumRequest(container: DiscoverItem, rows: [DiscoverItem], selected: Int) -> DiscoverCopyRequest? {
    guard container.kind == .album else { return nil }
    return DiscoverCopyRequest(playlistID: container.id, playlistTitle: container.name,
                               rows: rows, selected: selected, kind: .albumContainer)
}

// MARK: K2. One song of an album entry (journal, design 4.7)

enum DiscoverAlbumSongState: String, Codable, Equatable {
    case intent, pending, owned, preexisting, uncertain, deleted, kept

    /// `preexisting`, `uncertain`, `deleted` and `kept` never change again.
    var isTerminal: Bool {
        switch self {
        case .preexisting, .uncertain, .deleted, .kept: return true
        case .intent, .pending, .owned: return false
        }
    }
}

struct DiscoverAlbumSong: Codable, Equatable {
    let position: Int              // 1-based within the slice
    let catalogueID: String
    let title: String              // as he was shown it (DiscoverItem.name)
    let artist: String             // DiscoverItem.subtitle ?? ""
    let durationMS: Int?           // .milliseconds(n) -> n, else nil
    var relationsBefore: [Int]     // [R1] at G-a, [R1, R2] after S2
    var entryHex: String?          // e_i, written with E at S7
    var alias: String?             // a_i, once P4 has held
    var cloudStatus: String?       // as read for P7
    var state: DiscoverAlbumSongState
    var p4FirstSeenAt: Double?     // epoch seconds of the first of P4's two reads (CH7)
    var uncertainReason: String?   // diagnostics only (CH7)
    var keptReason: String?        // "loved" | "album" | "playlist" | "couldn't check"
    var keptPlaylist: String?
    var guardStrikes: Int = 0      // unreadable / still / no answer / timeout so far (3 -> kept)
    var toldAtLaunch: Bool = false
    var deletedAt: Double?

    enum CodingKeys: String, CodingKey {
        case position
        case catalogueID = "catalogue_id"
        case title, artist
        case durationMS = "duration_ms"
        case relationsBefore = "relations_before"
        case entryHex = "entry_hex"
        case alias
        case cloudStatus = "cloud_status"
        case state
        case p4FirstSeenAt = "p4_first_seen_at"
        case uncertainReason = "uncertain_reason"
        case keptReason = "kept_reason"
        case keptPlaylist = "kept_playlist"
        case guardStrikes = "guard_strikes"
        case toldAtLaunch = "told_at_launch"
        case deletedAt = "deleted_at"
    }
}

// MARK: K4. The relations op, as the client sees it (W2, W3)

let spandacLibraryRelationsOp = "slice.libraryRelations"

protocol SpanDACLibraryRelationsReading {
    /// slice.status capabilities name ALL of slice.libraryEnsurePlaylist, slice.libraryRelations
    /// and library.catalog_playlist (CH2). Unreadable status = false.
    var offersAlbumCleanup: Bool { get }
    /// Catalogue id -> every relation's alias (nil = unresolved). Throws
    /// SpanDACLibraryOpError.notOffered or .failed(detail); never .outcomeUnknown.
    func relations(catalogueIDs: [String]) throws -> [String: [String?]]
}

// MARK: K5. B, the full before-set, in its side file beside the journal (design 4.3 S1)

protocol DiscoverBeforeSetStore: AnyObject {
    /// Durable (the journal's lock, DurableFile.replace), 0600. Returns the file name.
    func writeBeforeSet(txn: String, ids: [String]) throws -> String
    /// Throws DiscoverCopyJournalError.unreadable for a missing, malformed or misnamed file.
    func readBeforeSet(file: String) throws -> Set<String>
    func deleteBeforeSet(file: String)     // best effort
}

// MARK: K6. The song guard's answers and what the deleter made of them (A4 produces, A5 consumes)

enum DiscoverSongGuardAnswer: Equatable {
    case gone, keptLoved, keptAlbum, keptPlaylist(String), spared, deleted, still, unreadable, checked
}

enum DiscoverSongGuardOutcome: Equatable {
    case deleted                              // now `deleted` (deleted, or already gone)
    case kept(reason: String, playlist: String?)
    case spared                               // left `owned`; retried
    case retry(strikes: Int)                  // left `owned`; retried
    case gaveUp                               // third strike: `kept`, "couldn't check"
    case notRun                               // no script: not owned, bad hex, or container not gone
}

// MARK: K7. What the album phase B and reconcile reach outside themselves. Built by W.

struct DiscoverAlbumSeams {
    var library: () -> SpanDACLibraryAdding                 // the ensure; asked per play
    var relations: () -> SpanDACLibraryRelationsReading     // asked per play and per reconcile
    var beforeSet: DiscoverBeforeSetStore
    /// B by AppleScript (1.5 B-script), bounded by beforeSetBound; nil = unreadable or past the bound.
    var readBeforeSet: () -> [String]?
    /// S5-S14 over A2's DiscoverAlbumEntryRecorder; same shape as DiscoverCopySeams.sequence.
    var sequence: (_ hex: String, _ txn: String, _ request: DiscoverCopyRequest,
                   _ gate: @escaping DiscoverCopyGate,
                   _ progress: @escaping (DiscoverCopyStage) -> Void,
                   _ commitListening: @escaping () -> Void) -> DiscoverCopyPlayResult
    var startProof: (_ txn: String) -> Void                 // A3's collector.adopt
    var replay: (_ entry: DiscoverCopyEntry, _ atLaunch: Bool) -> Void   // A5's reconcile branch
}

// MARK: K8. Bounds. One place, so tests and code agree.

enum DiscoverAlbumTiming {
    static let proofWindow: TimeInterval = 180       // design CHOSEN: [writeSentAt, +180 s]
    static let collectorCadence: TimeInterval = 5    // design CHOSEN
    static let p4MinGap: TimeInterval = 2            // design: two reads at least 2 s apart
    static let p5LateSlack = 2                       // design rev 3: date added in [S, S + 2 s]
    static let beforeSetBound: TimeInterval = 2      // design CHOSEN from L0 (0.23-0.25 s)
    static let guardScriptTimeout: TimeInterval = 10 // design CHOSEN from L0 (1.71-1.74 s)
    static let proofReadTimeout: TimeInterval = 5    // CHOSEN: the shipped scriptTimeout
    static let retryInterval: TimeInterval = 30      // design (spared); CH16 for strikes
    static let guardStrikes = 3                      // design CHOSEN
    static let recentDeleteBlock: TimeInterval = 120 // design CHOSEN (S0a)
    static let maxSongs = 100                        // the server's bound, checked first (CH4)
}

// MARK: K10. The AppleScript name gate (section 1.5)

/// Every variable an album-cleanup script may assign (CHOSEN). Two-word camelCase,
/// so none can be a Music.app or AppleScript term.
let discoverAlbumScriptVariables: Set<String> = [
    "beforeIDList", "beforeIDText",                                        // B-script
    "fieldSep", "songHits", "hitCount", "songRef", "titleText", "artistText",
    "lengthText", "addedValue", "addedText", "cloudText",                  // P-read
    "userLists", "liveHolds", "plRef", "plSmart", "plIDText", "plNameText",
    "plHitCount", "lovedFlag", "albumLovedFlag", "stateText", "currentSongID",
    "afterHits",                                                           // G-script
    "foundText",                                                           // F-script
]

/// Never a variable: measured failures first, then terms these scripts touch.
let discoverAppleScriptReservedNames: Set<String> = [
    "active", "left", "right", "name", "id", "index", "count", "class", "kind", "state",
    "position", "duration", "start", "finish", "rating", "loved", "favorited", "album",
    "artist", "track", "tracks", "playlist", "playlists", "source", "volume", "time",
    "date", "year", "size", "result", "text", "item", "items", "first", "last", "front",
    "back", "beginning", "end", "every", "some", "contents", "version", "selection",
    "current", "smart", "shuffle", "repeat", "mode", "genre", "location", "container",
    "added", "played", "cloud", "status", "special", "persistent", "description",
]

private let discoverAppleScriptSetPattern = try! NSRegularExpression(
    pattern: #"\bset\s+([A-Za-z_][A-Za-z0-9_]*)\s+to\b"#)
private let discoverAppleScriptRepeatPattern = try! NSRegularExpression(
    pattern: #"\brepeat\s+with\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b"#)

/// Names a script assigns: `set X to` (not `set AppleScript's …`) and `repeat with X in`.
func appleScriptAssignedNames(_ script: String) -> Set<String> {
    let whole = NSRange(script.startIndex..., in: script)
    var names = Set<String>()
    for pattern in [discoverAppleScriptSetPattern, discoverAppleScriptRepeatPattern] {
        for match in pattern.matches(in: script, range: whole) {
            guard let range = Range(match.range(at: 1), in: script) else { continue }
            names.insert(String(script[range]))
        }
    }
    return names
}

// MARK: K9. Wordings (CH19, section 1.7). `A` is the album's name, `T` a song's title.
// Refusals are posted as `.outcome(.refused(text), title: A)`.

/// Posted as `.outcome(.playing(title: tail), title: A)`, so it reads
/// "Playing from 'T'. …".
func discoverAlbumPlayingTail(song: String) -> String {
    "from '\(song)'. Songs it adds to your library leave when you stop, unless you love one or add it to a playlist first."
}

/// CH20: every slice song was already his, so nothing will leave.
func discoverAlbumPlayingOwnedTail(song: String) -> String {
    "from '\(song)'"
}

func discoverAlbumRepeatedSongText(album: String) -> String {
    "'\(album)' lists the same song twice, so MusicTUI couldn't tell which one it added; nothing played."
}

let discoverAlbumTooManyText = "SpanDAC takes at most 100 songs at once; nothing played."

func discoverAlbumRecentlyCleanedText(album: String) -> String {
    "Apple Music hasn't caught up with songs MusicTUI removed from '\(album)' a moment ago; try again in a minute or two. Nothing played."
}

func discoverAlbumRelationsUnreadableText(album: String) -> String {
    "SpanDAC couldn't check which songs from '\(album)' are already in your library; nothing was added and nothing played."
}

func discoverAlbumBeforeSetText(album: String) -> String {
    "MusicTUI couldn't read your library in time to play '\(album)' safely; nothing was added and nothing played."
}

func discoverAlbumMaybeAddedText(album: String) -> String {
    "MusicTUI couldn't confirm whether songs from '\(album)' were added to your library; any it can't prove it added stay there. Nothing played."
}

func discoverAlbumNotOursText(album: String) -> String {
    "MusicTUI left songs from '\(album)' in your library because it couldn't be sure it added them. Nothing played."
}

func discoverAlbumNoIDText(album: String) -> String {
    "Apple Music didn't finish making the temporary playlist for '\(album)' in time; nothing played."
}

/// `.unconfirmed(T)` names the temporary playlist; every other refusal is the
/// shipped copy sentence with the album as the playlist (nil for `.superseded`).
func discoverAlbumRefusalText(_ refusal: DiscoverCopyRefusal, album: String) -> String? {
    if case .unconfirmed(let title) = refusal {
        return "Couldn't confirm '\(title)' in the temporary playlist for '\(album)'; nothing played."
    }
    return discoverCopyRefusalText(refusal, playlist: album)
}

/// `'T1'`, `'T1' and 'T2'`, `'T1', 'T2' and 'T3'` …
func discoverAlbumJoinedList(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

/// The label a kept song carries in the end line (CH26's stored reasons).
func discoverAlbumKeptLabel(reason: String?, playlist: String?) -> String {
    switch reason {
    case "loved": return "loved"
    case "album": return "album loved"
    case "playlist": return playlist.map { "in '\($0)'" } ?? "in a playlist"
    default: return "couldn't check"
    }
}

/// `Kept 'T1' (loved) and 'T2' (in 'House') from 'A'; removed the other N.`
/// With N = 0: `Kept 'T1' (loved) from 'A'.` `kept` are the songs in state
/// `kept`, in album order; each is labelled by its `keptReason` / `keptPlaylist`.
func discoverAlbumKeptText(kept: [DiscoverAlbumSong], album: String, removed: Int) -> String {
    let items = kept.map { "'\($0.title)' (\(discoverAlbumKeptLabel(reason: $0.keptReason, playlist: $0.keptPlaylist)))" }
    let head = "Kept \(discoverAlbumJoinedList(items)) from '\(album)'"
    return removed > 0 ? head + "; removed the other \(removed)." : head + "."
}

/// One title: `… left 'T' from 'A' … it added it.`; more: `… 'T1' and 'T2' … it added them.`
func discoverAlbumLeftText(titles: [String], album: String) -> String {
    let list = discoverAlbumJoinedList(titles.map { "'\($0)'" })
    let pronoun = titles.count == 1 ? "it" : "them"
    return "MusicTUI left \(list) from '\(album)' in your library because it couldn't prove it added \(pronoun)."
}

func discoverAlbumAllRemovedText(album: String) -> String {
    "Removed the songs '\(album)' added."
}
