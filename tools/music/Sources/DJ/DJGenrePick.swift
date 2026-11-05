// tools/music/Sources/DJ/DJGenrePick.swift
//
// "A genre I haven't heard lately", for both data sources.
//
// MusicTUI's own data: a SEPARATE, timed, off-main bulk-column AppleScript read
// in LibraryIndex's shape (one `of every track` get per column, joined by a
// record separator), not PlaySync's per-track access and not an extension of
// the global library index. Persistent ID, name, artist, album, genre and the
// played date, the last as locale-independent epoch text. A never-played song
// and a date that could not be read are different answers and stay different;
// column counts that do not line up fail the whole read; a timeout refuses.
//
// The filter (sketchbook, Defaults 3 and 4, and the two-way match ruled after
// Batch 1): the song's genre contains the wanted genre or the wanted genre
// contains the song's, ignoring case; last played more than `days` ago, or
// never; the OLDEST `limit`, then shuffled.
//
// SpanDAC's own data comes from a read in the private repo
// (`library.genreUnheard`), behind `DJSpanDACGenreSource`.
import Foundation

// MARK: - The match and the filter

/// Two-way, case-insensitive contains: "jazz" finds "Vocal Jazz", "Cool jazz"
/// finds "Jazz". An empty genre on either side matches nothing.
func djGenreMatches(songGenre: String, wanted: String) -> Bool {
    let song = songGenre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let want = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !song.isEmpty, !want.isEmpty else { return false }
    return song.contains(want) || want.contains(song)
}

/// When a song was last played.
enum DJPlayed: Equatable {
    case never
    case at(Date)
    /// The date could not be read: never treated as "never played".
    case unreadable
}

/// One track of the library as the genre read returns it.
struct DJLibrarySong: Equatable {
    let persistentID: String
    let name: String
    let artist: String
    let album: String
    let genre: String
    let played: DJPlayed
}

struct DJGenrePick: Equatable {
    /// The frozen queue order: the oldest songs, shuffled.
    let picked: [DJLibrarySong]
    /// Every eligible song before the limit.
    let eligible: Int
    /// Songs of the genre whose played date could not be read, left out.
    let unreadable: Int

    /// "Jazz you haven't played in 90 days · 50 songs", with the unreadable
    /// count when any were left out.
    func line(genre: String, days: Int) -> String {
        djGenreLine(genre: genre, days: days, songs: picked.count, unreadable: unreadable)
    }
}

func djGenreLine(genre: String, days: Int, songs: Int, unreadable: Int = 0, repeatedTitles: Int = 0) -> String {
    var notes: [String] = []
    if unreadable > 0 { notes.append("\(unreadable) with an unreadable date skipped") }
    if repeatedTitles > 0 { notes.append(djRepeatedTitlesNote(repeatedTitles)) }
    let tail = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
    return "\(genre) you haven't played in \(days) days \u{00B7} \(djCount(songs, "song"))\(tail)"
}

let djUnheardDays = 90
let djGenreSongLimit = 50

/// Eligible songs, the oldest `limit` of them (never-played before any dated
/// one, ties by persistent ID so the pick is deterministic), shuffled.
func djPickUnheard(_ songs: [DJLibrarySong], genre: String, now: Date, days: Int, limit: Int,
                   shuffler: DJShuffling) -> DJGenrePick {
    let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
    var eligible: [DJLibrarySong] = []
    var unreadable = 0
    for song in songs where djGenreMatches(songGenre: song.genre, wanted: genre) {
        switch song.played {
        case .never: eligible.append(song)
        case .at(let date): if date < cutoff { eligible.append(song) }
        case .unreadable: unreadable += 1
        }
    }
    func age(_ song: DJLibrarySong) -> Date {
        if case .at(let date) = song.played { return date }
        return .distantPast
    }
    let oldest = eligible.sorted {
        let a = age($0), b = age($1)
        return a != b ? a < b : $0.persistentID < $1.persistentID
    }
    let taken = Array(oldest.prefix(max(0, limit)))
    return DJGenrePick(picked: shuffler.shuffled(taken), eligible: eligible.count, unreadable: unreadable)
}

// MARK: - The bulk read (MusicTUI's own data)

enum DJLibraryTiming {
    /// The read itself is a second or two on a big library; the margin covers a
    /// Music that is still launching (LibraryIndex's own read allows the same).
    static let timeoutSeconds: TimeInterval = 60
}

/// The bulk read. One get per column of every track of playlist "Library",
/// coerced to text under a record separator; the played date is converted in
/// the script to epoch seconds (this machine's `date +%s` minus the seconds
/// since the play), so no locale-formatted date ever leaves it. A song never
/// played reads `N`; a date that is neither missing nor a date reads `U`.
/// The digits are built from `div` pieces on purpose: measured on the Studio's
/// library, AppleScript holds epoch seconds as a real, and a real renders as
/// 1.79E+9, which would read as an unreadable date for every song.
func djLibraryGenreScript() -> String {
    """
    set astid to AppleScript's text item delimiters
    set fs to (ASCII character 31)
    set rs to (ASCII character 30)
    set lib to playlist "Library"
    set AppleScript's text item delimiters to rs
    set ids to (persistent ID of every track of lib) as text
    set ns to (name of every track of lib) as text
    set ars to (artist of every track of lib) as text
    set als to (album of every track of lib) as text
    set gs to (genre of every track of lib) as text
    set AppleScript's text item delimiters to astid
    set pds to played date of every track of lib
    set nowEpoch to (do shell script "date +%s") as integer
    set nowDate to current date
    set stamps to {}
    repeat with d in pds
        set d to contents of d
        if d is missing value then
            set end of stamps to "N"
        else
            try
                set v to nowEpoch - ((nowDate - d) as integer)
                set hi to v div 100000
                set lo to (v - hi * 100000) div 1
                set end of stamps to (hi as text) & (text -5 thru -1 of ("00000" & (lo as text)))
            on error
                set end of stamps to "U"
            end try
        end if
    end repeat
    set AppleScript's text item delimiters to rs
    set ps to stamps as text
    set AppleScript's text item delimiters to astid
    return ids & fs & ns & fs & ars & fs & als & fs & gs & fs & ps
    """
}

struct DJLibraryRead: Equatable {
    let songs: [DJLibrarySong]
    /// Rows whose id was not a persistent ID (they cannot be queued) and were left out.
    let skippedBadIDs: Int
}

enum DJLibraryReadError: Error, Equatable {
    case misaligned
    case timedOut
    case failed(String)

    var message: String {
        switch self {
        case .misaligned: return djLibraryMisaligned
        case .timedOut: return djLibraryReadTimedOut
        case .failed(let text): return "Couldn't read your library from MusicTUI, so nothing played: \(text)"
        }
    }
}

/// Six column blocks of equal row count, or the whole read fails: a misaligned
/// list is worse than none.
func djParseLibraryGenreRead(_ raw: String) throws -> DJLibraryRead {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let blocks = trimmed.components(separatedBy: String(asFieldSep))
    guard blocks.count == 6 else { throw DJLibraryReadError.misaligned }
    let columns = blocks.map { $0.components(separatedBy: String(asRowSep)) }
    guard let count = columns.first?.count, columns.allSatisfy({ $0.count == count }) else {
        throw DJLibraryReadError.misaligned
    }
    var songs: [DJLibrarySong] = []
    var bad = 0
    for i in 0..<count {
        let id = columns[0][i].uppercased()
        // An empty library reads as one empty row in every column.
        if id.isEmpty && count == 1 { continue }
        guard id.count == 16, id.allSatisfy(\.isHexDigit) else { bad += 1; continue }
        songs.append(DJLibrarySong(persistentID: id, name: columns[1][i], artist: columns[2][i],
                                   album: columns[3][i], genre: columns[4][i], played: djPlayed(columns[5][i])))
    }
    return DJLibraryRead(songs: songs, skippedBadIDs: bad)
}

private func djPlayed(_ token: String) -> DJPlayed {
    let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if t == "N" { return .never }
    if let seconds = Int(t) { return .at(Date(timeIntervalSince1970: TimeInterval(seconds))) }
    return .unreadable
}

/// Run the read through `run` (script, timeout seconds). A timeout and any other
/// failure are reported as themselves, never as an empty library.
func djReadLibraryForGenre(run: (String, TimeInterval) throws -> String) throws -> DJLibraryRead {
    let raw: String
    do {
        raw = try run(djLibraryGenreScript(), DJLibraryTiming.timeoutSeconds)
    } catch let error as AppleScriptBackend.ScriptError {
        if case .timeout = error { throw DJLibraryReadError.timedOut }
        throw DJLibraryReadError.failed(djErrorText(error))
    } catch {
        throw DJLibraryReadError.failed(djErrorText(error))
    }
    return try djParseLibraryGenreRead(raw)
}

// MARK: - The frozen queue (MusicTUI's own data)

/// The picked songs as an app-owned queue addressed by persistent ID, in the
/// frozen order. Nil when any song's identity is not a persistent ID, or when
/// there is nothing to queue: the whole pick fails, nothing is substituted.
func djOpenQueue(_ songs: [DJLibrarySong], title: String) -> AppQueue? {
    guard !songs.isEmpty else { return nil }
    var entries: [TrackListEntry] = []
    for song in songs {
        guard let entry = persistentIDQueueEntry(persistentID: song.persistentID, name: song.name,
                                                 artist: song.artist, album: song.album.isEmpty ? nil : song.album)
        else { return nil }
        entries.append(entry)
    }
    return AppQueue(playlistName: persistentIDQueueSource, tracks: entries, currentIndex: 1, displayName: title)
}

// MARK: - SpanDAC's data

/// What SpanDAC's genre read returned: its oldest matches (at most 50), each a
/// library row with its verified alias when present, the total it matched, and
/// the server instance and generation the walk was bracketed by.
struct DJSpanDACGenrePick: Equatable {
    let rows: [MusicRow]
    let total: Int
    let instance: String?
    let generation: Int?
    /// What was asked. Nil on a pick that was not read through the wire client.
    /// (The re-check at Enter does not ask it again: it checks the rows.)
    var genre: String? = nil
    var days: Int? = nil
}

enum DJGenreSourceError: Error, Equatable {
    case needsNewerSpanDAC
    case libraryChanged
    case failed(String)

    var message: String {
        switch self {
        case .needsNewerSpanDAC: return djNeedsNewerSpanDAC
        case .libraryChanged: return djSpanDACLibraryChanged
        case .failed(let text): return "SpanDAC couldn't pick songs by genre, so nothing played: \(text)"
        }
    }
}

/// The SpanDAC half of the genre pick. The real client is `DJSpanDACGenreClient`
/// (DJSpanDACGenreClient.swift), over the private repo's `library.genreUnheard` contract.
protocol DJSpanDACGenreSource: Sendable {
    /// SpanDAC's own oldest matches for the genre (at most 50, server side
    /// filtered and sorted), with the total matched. The client shuffles them.
    func genreUnheard(genre: String, days: Int) throws -> DJSpanDACGenrePick
    /// Before the play: the same instance and generation still answer, and every id in
    /// `pick.rows` (the rows about to play) still resolves in that SpanDAC
    /// library. Throws when they do not, or when that cannot be checked.
    func recheck(_ pick: DJSpanDACGenrePick) throws
}
