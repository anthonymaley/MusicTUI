// tools/music/Sources/Commands/CLIMusicTUILibraryPlay.swift
//
// The CLI's seam for playing rows from SpanDAC's LIBRARY on the MusicTUI
// output (score: data route and output, step 6; C-MATRIX column 4, C-HANDOFF).
//
// With SpanDAC as MusicTUI's data source and the MusicTUI output selected,
// `music play --playlist/--album/--song/--artist` resolves its name against
// SpanDAC's library on this Mac, and `music play N` of a row a SpanDAC library
// search produced carries that row here. What plays them is a later step's
// (owned songs by exact persistent ID). Until then every request refuses with
// `pickASpanDACOutput`: nothing is played, and nothing falls back to a title
// search of Apple's Music app library.
import Foundation

/// One request to play SpanDAC library rows on the MusicTUI output.
struct CLIMusicTUILibraryPlayRequest: Equatable {
    /// Which `music play` form asked, for the result line.
    let kind: BridgePlayResultKind
    /// The matched row's own name (a playlist, album, artist or song title).
    let label: String
    /// SpanDAC library song rows, in SpanDAC's order, never shuffled here.
    let rows: [MusicRow]
    /// 1-based row to start from.
    let startAt: Int
    /// Whether the person asked for this set in random order.
    let shuffle: Bool
    /// `music play N`'s `N`, when the rows came from the result cache.
    let resultNumber: Int?
    let json: Bool
}

/// Plays SpanDAC library rows on the MusicTUI output. Called inside the
/// output lock, with the mode revalidated; it must play exactly the rows it is
/// given or refuse the whole request.
protocol CLIMusicTUILibraryPlaying {
    func play(_ request: CLIMusicTUILibraryPlayRequest, env: CLIBridgeEnv) throws
}

/// Refuses every request with `pickASpanDACOutput`, playing nothing.
struct RefusingCLIMusicTUILibraryPlay: CLIMusicTUILibraryPlaying {
    func play(_ request: CLIMusicTUILibraryPlayRequest, env: CLIBridgeEnv) throws {
        throw ActionError(message: pickASpanDACOutput)
    }
}

/// What production uses. The one line a later step changes.
func liveCLIMusicTUILibraryPlay() -> CLIMusicTUILibraryPlaying {
    RefusingCLIMusicTUILibraryPlay()
}
