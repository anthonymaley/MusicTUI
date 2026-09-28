// tools/music/Sources/Commands/CLIMusicTUICataloguePlay.swift
//
// The CLI's seam for playing a SpanDAC CATALOGUE song on the MusicTUI output
// (score: data route and output, step 6; C-MATRIX column 4, C-ADD).
//
// With SpanDAC as MusicTUI's data source and the MusicTUI output selected,
// `music play N` of a row a SpanDAC catalogue search produced, and `music play
// <Apple Music song link>`, carry the song's catalogue id here. What plays it
// is a later step's (add through SpanDAC on this Mac, then play exactly that
// row). Until then every request refuses with `pickASpanDACOutput`: nothing
// is added, nothing is played, and no developer key is read.
import Foundation

/// One request to play a catalogue song on the MusicTUI output.
struct CLIMusicTUICataloguePlayRequest: Equatable {
    /// The Apple Music catalogue id.
    let catalogueID: String
    /// What the cached row said, when there was one (nil for a song link).
    let title: String?
    let artist: String?
    let album: String?
    /// `music play N`'s `N`, when the song came from the result cache.
    let resultNumber: Int?
    let json: Bool
}

/// Plays a catalogue song on the MusicTUI output. Called inside the output
/// lock, with the mode revalidated; it plays exactly that song or refuses.
protocol CLIMusicTUICataloguePlaying {
    func play(_ request: CLIMusicTUICataloguePlayRequest, env: CLIBridgeEnv) throws
}

/// Refuses every request with `pickASpanDACOutput`, adding and playing nothing.
struct RefusingCLIMusicTUICataloguePlay: CLIMusicTUICataloguePlaying {
    func play(_ request: CLIMusicTUICataloguePlayRequest, env: CLIBridgeEnv) throws {
        throw ActionError(message: pickASpanDACOutput)
    }
}

/// What production uses. The one line a later step changes.
func liveCLIMusicTUICataloguePlay() -> CLIMusicTUICataloguePlaying {
    RefusingCLIMusicTUICataloguePlay()
}
