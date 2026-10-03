// tools/music/Sources/TUI/DiscoverFromHereTypes.swift
//
// Shared client types for Discover "play from here" on Apple's own copy of a
// playlist (score section 1.3, step C0). Types, one pure function (S0a), the
// wordings and the AppleScript lookup preamble live here so the parts that
// build on them (wire client, journal, sequencer, mode guard, end watcher) can
// be written side by side without talking to each other.
import Foundation

// MARK: K1. The row's length, as the wire gave it

/// What a `slice.containerTracks` row said about its length (W2).
enum RowLength: Equatable { case absent, null, milliseconds(Int), malformed }

/// Reads `row["duration_ms"]`. Key absent -> `.absent`; JSON null -> `.null`;
/// a number that is not a boolean, is exactly integral and is > 0 ->
/// `.milliseconds(n)`; anything else (boolean, string, fraction, zero,
/// negative) -> `.malformed`.
func rowLength(inWireRow row: [String: Any]) -> RowLength {
    guard let value = row["duration_ms"] else { return .absent }
    if value is NSNull { return .null }
    // A JSON `true` bridges to NSNumber and would read as 1; refuse it by type.
    if CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID() { return .malformed }
    guard let ms = value as? Int, ms > 0 else { return .malformed }
    return .milliseconds(ms)
}

// MARK: K2. S0a, pure

enum DiscoverPreflight: Equatable {
    case pass
    case updateSpanDAC               // capability missing, or the key absent on ANY row
    case malformedLength             // ANY row .malformed
    case noLength(title: String)     // first row in 0...selected whose length is .null
    case selectionOutOfRange
}

/// Checks in this order: capability, range, absent, malformed, null up to `selected`.
func discoverPlayFromHerePreflight(offersCatalogPlaylist: Bool, rows: [DiscoverItem],
                                   selected: Int) -> DiscoverPreflight {
    guard offersCatalogPlaylist else { return .updateSpanDAC }
    guard rows.indices.contains(selected) else { return .selectionOutOfRange }
    if rows.contains(where: { $0.length == .absent }) { return .updateSpanDAC }
    if rows.contains(where: { $0.length == .malformed }) { return .malformedLength }
    for row in rows[0...selected] where row.length == .null {
        return .noLength(title: row.name)
    }
    return .pass
}

// MARK: K3. The two SpanDAC ops, as the client sees them (W3, W4, W5)

let spandacCatalogPlaylistCapability = "library.catalog_playlist"

struct CatalogPlaylistCopy: Equatable {
    let alias: String?
    var hex: String? { alias.flatMap(persistentIDHex(fromAlias:)) }
}

enum CatalogPlaylistAddOutcome: Equatable {
    case added(copies: [CatalogPlaylistCopy])
    case copyAppeared
    case refused(String)          // confirmed: nothing was added
    case outcomeUnknown(String)   // may have been added
    case notOffered
}

protocol SpanDACCatalogPlaylistOps {
    /// `slice.status` capabilities name `library.catalog_playlist`. Unreadable status = false.
    var offersCatalogPlaylist: Bool { get }
    /// W3. Throws `SpanDACLibraryOpError.notOffered` or `.failed(detail)`; never `.outcomeUnknown`.
    func copies(ofCatalogPlaylist id: String) throws -> [CatalogPlaylistCopy]
    /// W4. Never throws.
    func addCatalogPlaylist(id: String) -> CatalogPlaylistAddOutcome
}

// MARK: K4. The journal (design section 5)

enum DiscoverCopyState: String, Codable, Equatable {
    case intent, owned, listening, uncertain, closed, preexisting
}

struct DiscoverCopyEntry: Codable, Equatable {
    let txn: String              // UUID string
    let playlistID: String       // "pl.…"
    let title: String            // the playlist's name as he was shown it
    var state: DiscoverCopyState
    var hex: String?             // sixteen uppercase hex digits once known
    var copiesRead: Int          // S1's count
    var watching: Bool           // handed to the end watcher and not yet ended
    var copySeen: Bool           // uncertain only: at least one copy was seen
    var toldAtLaunch: Bool       // uncertain only: the launch repeat has been shown
    var priorShuffle: Bool?      // nil = nothing to restore
    var priorRepeat: String?     // RepeatMode.rawValue
    /// True while his modes are known or feared not to be the recorded ones
    /// because of a set of ours, and while a restore attempt's script is in
    /// flight: the recorded values go back whatever the modes read now.
    /// Absent in a journal written before this field.
    var restorePending: Bool? = nil
    let createdAt: Int           // epoch seconds
    var updatedAt: Int
    // Album-cleanup (journal format 2). All nil on a copy entry; absent kind = a copy.
    // For an album entry: playlistID = album id, title = album name, copiesRead = 0.
    var kind: DiscoverPlayKind? = nil
    var containerName: String? = nil     // "__discover__ <txn> — <album>", the transaction token
    var writeSentAt: Double? = nil       // epoch seconds WITH fraction, written before the ensure
    var listeningEnded: Bool? = nil      // recorded at the end or a refusal after S3; gates nothing (CH8)
    var containerGone: Bool? = nil       // the container read absent (CH6)
    var endTold: Bool? = nil             // the end line was posted (CH9)
    var uncertainReason: String? = nil   // "outcome_unknown" (reconcile retries) | "not_created" | "several"
    var entryIDs: [String]? = nil        // E, the container's ordered track IDs at S7
    var beforeFile: String? = nil        // B's side file, "before-<txn>.json"
    var songs: [DiscoverAlbumSong]? = nil

    enum CodingKeys: String, CodingKey {
        case txn
        case playlistID = "playlist_id"
        case title, state, hex
        case copiesRead = "copies_read"
        case watching
        case copySeen = "copy_seen"
        case toldAtLaunch = "told_at_launch"
        case priorShuffle = "prior_shuffle"
        case priorRepeat = "prior_repeat"
        case restorePending = "restore_pending"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case kind
        case containerName = "container_name"
        case writeSentAt = "write_sent_at"
        case listeningEnded = "listening_ended"
        case containerGone = "container_gone"
        case endTold = "end_told"
        case uncertainReason = "uncertain_reason"
        case entryIDs = "entry_ids"
        case beforeFile = "before_file"
        case songs
    }

    var isDeletable: Bool { (state == .owned || state == .listening) && hex != nil }
}

enum DiscoverCopyJournalError: Error, Equatable {
    case busy, unreadable, tooNew, notFound, writeFailed(String)
}

/// Every insert and update is on the disk itself (F_FULLFSYNC, then rename)
/// before it returns, under a cross-process lock. An unreadable file is never
/// read as empty.
protocol DiscoverCopyJournalStore: AnyObject {
    func entries() throws -> [DiscoverCopyEntry]                 // creation order
    func insert(_ entry: DiscoverCopyEntry) throws
    @discardableResult
    func update(txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry
}

// MARK: K5. One play request, and what S5-S14 answer

struct DiscoverCopyRequest: Equatable {
    let playlistID: String        // the Discover container's catalogue id
    let playlistTitle: String
    let rows: [DiscoverItem]      // the FULL rows he was shown, in order
    let selected: Int             // cursor index, 0-based; k = selected + 1
    /// Album-cleanup: `.albumContainer` for an album (see `discoverAlbumRequest`).
    var kind: DiscoverPlayKind = .playlistCopy
}

enum DiscoverCopyStage: Equatable { case adding, waitingForCopy, ready, positioning }

enum DiscoverCopyRefusal: Equatable {
    case notReady                     // S5
    case countChanged                 // S6
    case unconfirmed(title: String)   // S7 read failed, or S8 refused
    case sourceChanged                // a gate found the output or the data source moved
    case superseded                   // a gate found a later play had started
    case modes                        // S10
    case firstPlayUnconfirmed         // S11 with k > 1; the copy is left protected
    case landing(title: String)       // S12
    case wontPlay(title: String)      // S13, and S11 when k = 1; the copy is left protected
}

enum DiscoverCopyPlayResult: Equatable { case listening, refused(DiscoverCopyRefusal) }

enum DiscoverCopyDeleteResult: Equatable {
    case deleted       // deleted, then read absent
    case alreadyGone   // read absent before any delete
    case spared        // our hex is the current playlist and the state is not stopped
    case kept          // not deletable (preexisting, uncertain, intent, closed): nothing was deleted
    case failed        // the script failed, or the copy still read present after the delete
}

// MARK: K6. Phase B's way back into the routing boundary (section 1.6)

/// It runs `body` inside the boundary ONLY IF the reservation still holds, and
/// says which. Cleanup (stop, restore, delete) never goes through it.
enum DiscoverCopyGateResult: Equatable { case ran, sourceChanged, superseded }
typealias DiscoverCopyGate = (_ body: () -> Void) -> DiscoverCopyGateResult

/// What the transaction reaches outside itself. Built for production by C6.
struct DiscoverCopySeams {
    var ops: () -> SpanDACCatalogPlaylistOps      // asked per play
    var journal: DiscoverCopyJournalStore
    /// S5-S14 for the copy `hex`, governed by journal entry `txn`.
    /// `commitListening` runs inside the last gate, after S13 confirmed.
    var sequence: (_ hex: String, _ txn: String, _ request: DiscoverCopyRequest,
                   _ gate: @escaping DiscoverCopyGate,
                   _ progress: @escaping (DiscoverCopyStage) -> Void,
                   _ commitListening: @escaping () -> Void) -> DiscoverCopyPlayResult
    /// The deletion guard of design section 5, for one entry.
    var deleteIfOwned: (_ txn: String) -> DiscoverCopyDeleteResult
    var restoreModes: (_ txn: String) -> Void
    /// Hand a copy to the end watcher (S14, and reconcile's re-adopt).
    var adopt: (_ txn: String, _ hex: String) -> Void
    /// Reconcile may ask SpanDAC for copies only while this is true.
    var spandacDataSelected: () -> Bool
    var now: () -> Date
    var log: (String) -> Void                      // stage timing; production: verbose()
}

// MARK: K7. Bounds. One place, so tests and code agree.

enum DiscoverCopyTiming {
    static let readinessBound: TimeInterval = 45      // S5 (design CHOSEN)
    static let readinessCadence: TimeInterval = 0.5
    static let pollCadence: TimeInterval = 0.1        // S11, S12, S13
    static let firstPlayBound: TimeInterval = 3       // S11
    static let pauseSettleBound: TimeInterval = 3     // S11's pause, CHOSEN
    static let landingBound: TimeInterval = 3         // S12, per skip (design CHOSEN)
    static let confirmBound: TimeInterval = 3         // S13
    static let endEvidenceGap: TimeInterval = 3       // watcher
    static let scriptTimeout: TimeInterval = 5        // per osascript call
}

// MARK: K8. How every script finds the copy (CHOSEN: the loop form, CH1)

/// AppleScript lines (no `tell` wrapper) that leave `pl` set to the playlist
/// whose persistent ID is `hex`, or to `missing value`. `hex` is
/// `persistentIDHex`'s output (sixteen `0-9A-F`), so it needs no escaping; for
/// anything else the preamble leaves `pl` missing.
func discoverCopyLookupPreamble(hex: String) -> String {
    let isHex = hex.utf8.count == 16 && hex.utf8.allSatisfy {
        ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
            || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "F"))
    }
    guard isHex else { return "set pl to missing value" }
    return """
    set pl to missing value
    repeat with p in playlists
        if (persistent ID of p) is "\(hex)" then
            set pl to contents of p
            exit repeat
        end if
    end repeat
    """
}

// MARK: K9. Wordings (CHOSEN, 1.5). `P` is the playlist title, `T` the row's title.
// Every refusal is posted as `.outcome(.refused(text), title: P)`.

func discoverNoLengthText(title: String) -> String {
    "Apple Music gave no length for '\(title)', so MusicTUI can't confirm it; nothing played."
}

let discoverMalformedLengthText = "SpanDAC sent a song length MusicTUI can't read; nothing played."

func discoverSeveralCopiesText(playlist: String) -> String {
    "Your library has more than one copy of '\(playlist)'; MusicTUI won't choose between them. Nothing played."
}

func discoverCopyNoIDText(playlist: String) -> String {
    "Apple Music hasn't given '\(playlist)' an ID MusicTUI can play it by yet; nothing played. Try again in a moment."
}

func discoverJournalUnwritableText(playlist: String) -> String {
    "MusicTUI couldn't save its record for '\(playlist)', so nothing was added and nothing played."
}

func discoverAddRefusedText(playlist: String) -> String {
    "Apple Music didn't add '\(playlist)' to your library; nothing played."
}

/// A copy WAS seen.
func discoverCopyLeftText(playlist: String) -> String {
    "MusicTUI left '\(playlist)' in your library because it couldn't be sure it added it."
}

/// No copy was seen.
func discoverCopyMaybeAddedText(playlist: String) -> String {
    "MusicTUI couldn't confirm whether '\(playlist)' was added to your library; if it was, it stays there. Nothing played."
}

func discoverCopyChangedText(playlist: String) -> String {
    "'\(playlist)' changed since you opened it; nothing played. Open it again to play from here."
}

func discoverCopyUnconfirmedText(title: String, playlist: String) -> String {
    "Couldn't confirm '\(title)' in Apple's copy of '\(playlist)'; nothing played."
}

func discoverModesText(playlist: String) -> String {
    "MusicTUI couldn't switch shuffle and repeat off for '\(playlist)'; nothing played."
}

func discoverFirstPlayText(playlist: String) -> String {
    "Couldn't start '\(playlist)' in Apple Music; nothing played."
}

func discoverLandingText(title: String, playlist: String) -> String {
    "Couldn't reach '\(title)' in '\(playlist)'; nothing played."
}

func discoverWontPlayText(title: String) -> String {
    "'\(title)' won't play in Apple Music right now; nothing else played."
}

func discoverCopyBusyText(playlist: String) -> String {
    "MusicTUI is still starting another playlist; '\(playlist)' was not started."
}

// Progress wordings.

func discoverAddingText(playlist: String) -> String {
    "Adding '\(playlist)' to play from here…"
}

func discoverWaitingText(playlist: String) -> String {
    "Waiting for Apple Music to load '\(playlist)'…"
}

func discoverPositioningText(title: String) -> String {
    "Finding '\(title)'…"
}

/// Maps a refusal to its sentence, or nil for `.superseded` (nothing is posted).
func discoverCopyRefusalText(_ refusal: DiscoverCopyRefusal, playlist: String) -> String? {
    switch refusal {
    case .notReady: return "'\(playlist)' is still loading — try again in a moment."
    case .countChanged: return discoverCopyChangedText(playlist: playlist)
    case .unconfirmed(let title): return discoverCopyUnconfirmedText(title: title, playlist: playlist)
    case .sourceChanged: return sourceChangedNothingPlayed
    case .superseded: return nil
    case .modes: return discoverModesText(playlist: playlist)
    case .firstPlayUnconfirmed: return discoverFirstPlayText(playlist: playlist)
    case .landing(let title): return discoverLandingText(title: title, playlist: playlist)
    case .wontPlay(let title): return discoverWontPlayText(title: title)
    }
}
