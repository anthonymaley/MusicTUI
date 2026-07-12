import Foundation

struct SongResult: Codable, Equatable {
    let index: Int
    let title: String
    let artist: String
    let album: String
    let catalogId: String
}

struct SpeakerResult: Codable, Equatable {
    let index: Int
    let name: String
    let selected: Bool
    let volume: Int
}

enum CacheError: Error, LocalizedError {
    case noCache(String)
    case indexOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .noCache(let domain): return "No cached \(domain) results. Run a search or list command first."
        case .indexOutOfRange(let i): return "Index \(i) is out of range."
        }
    }
}

struct ResultCache {
    let directory: String

    init(directory: String? = nil) {
        if let dir = directory {
            self.directory = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.directory = "\(home)/.config/music"
        }
    }

    private var songsPath: String { "\(directory)/last-songs.json" }
    private var speakersPath: String { "\(directory)/last-speakers.json" }

    func writeSongs(_ songs: [SongResult]) throws {
        let data = try JSONEncoder().encode(songs)
        try ensureDirectory()
        try data.write(to: URL(fileURLWithPath: songsPath))
    }

    func readSongs() throws -> [SongResult] {
        guard FileManager.default.fileExists(atPath: songsPath) else {
            throw CacheError.noCache("songs")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: songsPath))
        return try JSONDecoder().decode([SongResult].self, from: data)
    }

    func lookupSong(index: Int) throws -> SongResult {
        let songs = try readSongs()
        guard let song = songs.first(where: { $0.index == index }) else {
            throw CacheError.indexOutOfRange(index)
        }
        return song
    }

    /// Resolve multiple cached indices at once, separating hits from misses
    /// (missing cache or out-of-range index) so the caller can report the
    /// dropped indices instead of silently building a shorter result. Reads the
    /// cache once.
    func lookupSongs(indices: [Int]) -> (resolved: [SongResult], dropped: [Int]) {
        let songs = (try? readSongs()) ?? []
        var resolved: [SongResult] = []
        var dropped: [Int] = []
        for index in indices {
            if let song = songs.first(where: { $0.index == index }) {
                resolved.append(song)
            } else {
                dropped.append(index)
            }
        }
        return (resolved, dropped)
    }

    func writeSpeakers(_ speakers: [SpeakerResult]) throws {
        let data = try JSONEncoder().encode(speakers)
        try ensureDirectory()
        try data.write(to: URL(fileURLWithPath: speakersPath))
    }

    func readSpeakers() throws -> [SpeakerResult] {
        guard FileManager.default.fileExists(atPath: speakersPath) else {
            throw CacheError.noCache("speakers")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: speakersPath))
        return try JSONDecoder().decode([SpeakerResult].self, from: data)
    }

    func lookupSpeaker(index: Int) throws -> SpeakerResult {
        let speakers = try readSpeakers()
        guard let speaker = speakers.first(where: { $0.index == index }) else {
            throw CacheError.indexOutOfRange(index)
        }
        return speaker
    }

    // MARK: - Speaker IP memoization

    struct CachedSpeakerIP: Codable, Equatable {
        let name: String
        let ip: String
        let resolvedAt: Date
    }

    private var speakerIPsPath: String { "\(directory)/speaker-ips.json" }

    /// Cached IP for a speaker name if it was resolved within `ttl`. Keyed
    /// case-insensitively (the AirPlay name is the key and varies only in
    /// display case). Returns nil on miss or expiry — the caller resolves live.
    func cachedSpeakerIP(forName name: String, ttl: TimeInterval = 3600) -> String? {
        let key = name.lowercased()
        guard let hit = readSpeakerIPs().first(where: { $0.name.lowercased() == key }) else { return nil }
        guard Date().timeIntervalSince(hit.resolvedAt) < ttl else { return nil }
        return hit.ip
    }

    /// Remember (or refresh) a name→IP mapping. Best-effort: a write failure
    /// silently degrades to a cache miss next time, never blocks a play.
    func rememberSpeakerIP(name: String, ip: String) {
        var entries = readSpeakerIPs().filter { $0.name.lowercased() != name.lowercased() }
        entries.append(CachedSpeakerIP(name: name, ip: ip, resolvedAt: Date()))
        writeSpeakerIPs(entries)
    }

    private func readSpeakerIPs() -> [CachedSpeakerIP] {
        guard FileManager.default.fileExists(atPath: speakerIPsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: speakerIPsPath)),
              let entries = try? JSONDecoder().decode([CachedSpeakerIP].self, from: data)
        else { return [] }
        return entries
    }

    private func writeSpeakerIPs(_ entries: [CachedSpeakerIP]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? ensureDirectory()
        try? data.write(to: URL(fileURLWithPath: speakerIPsPath))
    }

    // MARK: - Artist-tier filter memoization (Library tab `a` filter)

    struct CachedArtistTiers: Codable, Equatable {
        let ep: [String]       // normalized artist names with a 2–5 track album (12"/EP)
        let albums: [String]   // normalized artist names with a 6+ track album
        let cachedAt: Date
    }

    private var artistTiersPath: String { "\(directory)/artist-tiers.json" }

    /// Cached (12"/EP, Albums) artist-name sets if written within `ttl` — lets the
    /// Library `a` tier filter paint instantly on its first activation of a session
    /// while a fresh album walk revalidates in the background. nil on miss/expiry.
    func cachedArtistTiers(ttl: TimeInterval = 604_800) -> (ep: Set<String>, albums: Set<String>)? {
        guard FileManager.default.fileExists(atPath: artistTiersPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: artistTiersPath)),
              let entry = try? JSONDecoder().decode(CachedArtistTiers.self, from: data),
              Date().timeIntervalSince(entry.cachedAt) < ttl
        else { return nil }
        return (Set(entry.ep), Set(entry.albums))
    }

    /// Persist the tier sets. Best-effort: a write failure silently degrades to a
    /// cache miss next session, never blocks the UI.
    func rememberArtistTiers(ep: Set<String>, albums: Set<String>) {
        let entry = CachedArtistTiers(ep: Array(ep), albums: Array(albums), cachedAt: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? ensureDirectory()
        try? data.write(to: URL(fileURLWithPath: artistTiersPath))
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
    }
}
