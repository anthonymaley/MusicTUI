import ArgumentParser

@main
struct Music: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "music",
        abstract: "Control Apple Music from the terminal.",
        version: "3.0.0",
        subcommands: [
            // Playback
            Play.self,
            Pause.self,
            Skip.self,
            Back.self,
            Stop.self,
            Now.self,
            Seek.self,
            Shuffle.self,
            Repeat_.self,
            Love.self,
            Unlove.self,
            // Speakers & Volume
            Speaker.self,
            Vol.self,
            // Auth
            Auth.self,
            // Catalog
            Search.self,
            Add.self,
            Remove.self,
            Playlist.self,
            // Discovery
            Similar.self,
            Suggest.self,
            NewReleases.self,
            Mix.self,
            Recent.self,
            Rotation.self,
        ],
        defaultSubcommand: Now.self
    )

    // Global config — set once at process start, read-only thereafter
    static var verbose: Bool = false
    static var isJSON: Bool = false
}
