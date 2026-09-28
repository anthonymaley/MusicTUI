// tools/music/Sources/Commands/CLIMusicTUICataloguePlay.swift
//
// The CLI's seam for playing a SpanDAC CATALOGUE song on the MusicTUI output
// (score: data route and output, step 6; C-MATRIX column 4, C-ADD).
//
// With SpanDAC as MusicTUI's data source and the MusicTUI output selected,
// `music play N` of a row a SpanDAC catalogue search produced, and `music play
// <Apple Music song link>`, carry the song's catalogue id here. It plays by the
// shipped add-then-play path with SpanDAC on this Mac making the add
// (`SpanDACCataloguePlayer`, C-ADD): an owned song plays by its identity with
// no add; only a confirmed failed add refuses; an add whose outcome is unknown
// refuses without retrying, and running the command again reconciles by a
// lookup first. No developer key is read.
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

/// Said when SpanDAC could not confirm the add (CHOSEN wording).
func cliSpanDACAddOutcomeUnknown(_ title: String) -> String {
    "Couldn't confirm SpanDAC added '\(title)' to your library, so nothing was played. "
        + "Run the same command again to check."
}

/// The real seam: SpanDAC on this Mac adds, the MusicTUI output plays exactly
/// that song. The library ops go over the command's own DATA client, so the
/// socket is the one every other read in this command used.
struct SpanDACCLICataloguePlay: CLIMusicTUICataloguePlaying {
    let seams: CatalogAddPlaySeams
    /// The shipped success display (`showNowPlaying`), injected so a test
    /// never reads Apple's Music app.
    let showPlaying: (_ json: Bool) -> Void
    /// SpanDAC's library ops. Nil in production: SpanDAC on this Mac, over the
    /// command's own data client socket. A test hands in a fake.
    var library: ((CLIBridgeEnv) -> SpanDACLibraryAdding)? = nil

    func play(_ request: CLIMusicTUICataloguePlayRequest, env: CLIBridgeEnv) throws {
        let song = SpanDACCatalogueSong(catalogueID: request.catalogueID, title: request.title,
                                        artist: request.artist, album: request.album)
        let player = SpanDACCataloguePlayer(seams: seams)
        let ops = library?(env)
            ?? env.routing.dataClient().libraryWrites(starter: env.routing.macStarter)
        switch player.play(song, library: ops) {
        case .playing(_, let note):
            // The note is the shipped one; `--json` keeps stdout a document.
            if let note { request.json ? env.err(note) : env.out(note) }
            showPlaying(request.json)
        case .refused(let why):
            throw ActionError(message: why)
        case .outcomeUnknown(let title):
            throw ActionError(message: cliSpanDACAddOutcomeUnknown(title))
        }
    }
}

/// What production uses.
func liveCLIMusicTUICataloguePlay() -> CLIMusicTUICataloguePlaying {
    SpanDACCLICataloguePlay(seams: .live(backend: AppleScriptBackend(), showsProgress: true),
                            showPlaying: { json in showNowPlaying(json: json, waitForPlay: true) })
}
