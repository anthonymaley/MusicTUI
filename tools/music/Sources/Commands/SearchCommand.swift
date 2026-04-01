import ArgumentParser
import Foundation

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search Apple Music catalog.")
    @Argument(help: "Search query") var query: [String]
    @Option(name: .long, help: "Filter by artist") var artist: String?
    @Option(name: .long, help: "Filter by album") var album: String?
    @Option(name: .long, help: "Max results") var limit: Int = 10
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: nil, storefront: auth.storefront())

        var searchQuery = query.joined(separator: " ")
        if let artist = artist { searchQuery += " \(artist)" }
        if let album = album { searchQuery += " \(album)" }

        let songs = try syncRun { try await api.searchSongs(query: searchQuery, limit: limit) }

        if songs.isEmpty {
            print("No results for '\(searchQuery)'")
            throw ExitCode.failure
        }

        if json {
            let output = OutputFormat(mode: .json)
            print(output.render(songs.map { $0.toDict() }))
        } else {
            for (i, song) in songs.enumerated() {
                print("\(i + 1). \(song.title) — \(song.artist) [\(song.album)] (id: \(song.id))")
            }
        }
    }
}
