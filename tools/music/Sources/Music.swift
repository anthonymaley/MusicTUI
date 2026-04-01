import ArgumentParser

@main
struct Music: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "music",
        abstract: "Control Apple Music from the terminal.",
        version: "1.0.0",
        subcommands: [
            // Playback
            Play.self,
            Pause.self,
            Skip.self,
            Back.self,
            Stop.self,
            Now.self,
            Shuffle.self,
            Repeat_.self,
            // Speakers & Volume
            Speaker.self,
            Vol.self,
            // Auth
            Auth.self,
            // Catalog
            Search.self,
            Add.self,
            Playlist.self,
            // Discovery
            Similar.self,
            Suggest.self,
            NewReleases.self,
            Mix.self,
        ],
        defaultSubcommand: Now.self
    )
}
