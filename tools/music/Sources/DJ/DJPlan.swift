// tools/music/Sources/DJ/DJPlan.swift
//
// What the DJ box holds between a card and Enter: the PLAN (the exact queue
// behind the card line, frozen), the stamp it was made under, and the words
// the box says. A plan is made once, shown, and played at most once.
import Foundation

/// Where the world stood when a request was sent: both routing epochs and the
/// play serial. A card plays only while all three still hold.
struct DJStamp: Equatable {
    let epoch: Int
    let dataEpoch: Int
    let playSerial: Int

    var routing: (epoch: Int, dataEpoch: Int) { (epoch, dataEpoch) }
}

/// A card's frozen queue. Enter plays exactly this.
struct DJPlan: Equatable {
    enum Payload: Equatable {
        /// Catalogue ids for one `slice.queue` on a SpanDAC output.
        case artistMix(DJArtistMix)
        /// MusicTUI's own data: persistent-ID queue entries, in play order.
        case genreOpen(AppQueue)
        /// SpanDAC's data: the library rows in play order (shuffled), and the
        /// server's pick as read, for the re-check at Enter.
        case genreSpanDAC(rows: [MusicRow], pick: DJSpanDACGenrePick, title: String)
    }

    let payload: Payload
    /// The one line shown: the interpreted kind, artist or genre, and the exact scope.
    let line: String
    let stamp: DJStamp
}

/// A background request's answer, as the box applies it.
enum DJOutcome: Equatable {
    case message(String)
    /// The DJ understood and is looking things up (the artist's name).
    case working(String)
    case pick(artist: String, hits: [CatalogueHit])
    case plan(DJPlan)
}

// MARK: - The words

let djUnsupportedRequest = "The DJ can do artist mixes and genres you haven't heard lately for now."

/// A reader call that has not answered by then is abandoned.
let djReaderTimeoutSeconds: TimeInterval = 20
/// The `failed` reading's text for it, shown as it is (no "couldn't read that" prefix).
let djReaderTimedOutLine = "The DJ took too long to answer. Try again."
func djFailedLine(_ text: String) -> String { "The DJ couldn't read that: \(text)" }

/// Said (and the coordinator's own sentence) when an artist mix would play on the MusicTUI output.
let djArtistMixSpanDACOnly =
    "The DJ plays artist mixes on the SpanDAC output only for now. Pick SpanDAC on the Output tab."

/// An artist mix reads Apple's catalogue through SpanDAC.
let djArtistMixNeedsSpanDACData = "The DJ's artist mixes need SpanDAC data on this Mac."

let djChangedLine = "The output or music source changed since the DJ answered; nothing played. Ask again."

func djNoArtistFound(_ name: String) -> String { "No artist found for \(name)." }

func djNoGenreSongs(genre: String, days: Int) -> String {
    "No \(genre) songs you haven't played in \(days) days."
}

let djLibraryReadTimedOut = "MusicTUI took too long to read your library, so the DJ couldn't use it. Nothing played."
let djLibraryMisaligned = "MusicTUI's library read didn't line up, so the DJ didn't use it. Nothing played."
let djNeedsNewerSpanDAC =
    "The DJ needs a newer SpanDAC to pick genres from your SpanDAC library. Update SpanDAC."
let djSpanDACLibraryChanged = "SpanDAC's library changed since the DJ chose these songs, so nothing played. Ask again."
let djGenreNeedsAliases =
    "Some of those songs have no identity MusicTUI can play by, so nothing played. Pick SpanDAC on the Output tab."
