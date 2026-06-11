// MARK: - Play query resolution order (tested in PlayResolutionTests)

enum PlayResolution {
    enum Strategy: Equatable {
        case playlistAlbumSong(query: String)
        case songArtist(title: String, artist: String)
    }

    /// Playlist/album/song lookup runs first: it matches on the whole query,
    /// so it cannot false-positive the way the split heuristic can. The
    /// song+artist split (quoted pairs like "Gypsy Woman" "Tom Misch") is the
    /// fallback once the whole-query lookup finds nothing.
    static func plan(queryArgs: [String]) -> [Strategy] {
        var strategies: [Strategy] = []
        let joined = queryArgs.joined(separator: " ")
        if !joined.isEmpty {
            strategies.append(.playlistAlbumSong(query: joined))
        }
        if queryArgs.count == 2 {
            strategies.append(.songArtist(title: queryArgs[0], artist: queryArgs[1]))
        }
        return strategies
    }
}
