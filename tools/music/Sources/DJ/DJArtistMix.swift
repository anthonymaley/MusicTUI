// tools/music/Sources/DJ/DJArtistMix.swift
//
// The DJ's artist mix, as pure planning over a catalogue seam. Nothing here
// plays, adds or writes: it reads (artist search results are handed in; an
// artist's first 25 albums and each album's tracks are read through
// `DJCatalogue`) and returns the exact catalogue ids a later Enter queues.
//
// Rulings carried here (sketchbook, Score r3):
// - Exactly ONE artist whose normalized name equals the model's (case
//   insensitive, a leading "The"/"A" ignored) is taken; two of one name, or no
//   exact match, go to a picker of up to 5, and the picker keeps the chosen
//   CATALOGUE id (the name is never resolved a second time).
// - An artist's albums are the first 25 (as search); any failed album read
//   fails the WHOLE mix; songs are de-duplicated by id; a song SpanDAC gave no
//   length is unavailable, dropped and counted; the mix is a uniformly random
//   50 (or all, when fewer) in shuffled order.
import Foundation

/// Shuffles a list. A seam so tests can fix the order; the real one is random.
protocol DJShuffling {
    func shuffled<T>(_ items: [T]) -> [T]
}

struct DJSystemShuffle: DJShuffling {
    func shuffled<T>(_ items: [T]) -> [T] { items.shuffled() }
}

/// The two reads a mix makes: an artist's albums (`slice.artistAlbums`) and an
/// album's tracks (`slice.containerTracks`). `BridgeMusicProvider` is the real one.
protocol DJCatalogue: CatalogueBrowsing {
    func containerTracks(for item: DiscoverItem) throws -> [DiscoverItem]
}

extension BridgeMusicProvider: DJCatalogue {}

// MARK: - Choosing the artist

enum DJArtistResolution: Equatable {
    /// Exactly one artist's normalized name equals the model's.
    case chosen(CatalogueHit)
    /// Up to 5 artists to pick from.
    case pick([CatalogueHit])
    case none
}

/// Lowercased, trimmed, with a leading "the " or "a " removed. A bare article
/// is a name, not an article.
func djNormalizedArtistName(_ name: String) -> String {
    let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for article in ["the ", "a "] where lowered.hasPrefix(article) {
        let rest = lowered.dropFirst(article.count).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { return rest }
    }
    return lowered
}

let djArtistPickerLimit = 5

func djResolveArtist(named name: String, in artists: [CatalogueHit]) -> DJArtistResolution {
    guard !artists.isEmpty else { return .none }
    let wanted = djNormalizedArtistName(name)
    let exact = artists.filter { djNormalizedArtistName($0.title) == wanted }
    if exact.count == 1 { return .chosen(exact[0]) }
    return .pick(Array((exact.isEmpty ? artists : exact).prefix(djArtistPickerLimit)))
}

// MARK: - Building the mix

/// A mix, frozen: the catalogue ids in play order and what they came from.
struct DJArtistMix: Equatable {
    static let songLimit = 50

    let artistName: String
    let artistID: String
    let ids: [String]
    /// The albums the chosen songs come from.
    let albumCount: Int
    /// The artist has more albums than the first 25 that were read.
    let moreAlbums: Bool
    /// Songs SpanDAC gave no length, dropped.
    let unavailable: Int

    /// "Radiohead · 50 songs from 9 albums (3 unavailable skipped)", with
    /// "first 25 albums" when the artist has more.
    var line: String {
        var notes: [String] = []
        if moreAlbums { notes.append("first \(DiscoverScene.artistAlbumsLimit) albums") }
        if unavailable > 0 { notes.append("\(unavailable) unavailable skipped") }
        let tail = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
        return "\(artistName) \u{00B7} \(djCount(ids.count, "song")) from \(djCount(albumCount, "album"))\(tail)"
    }
}

func djCount(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

enum DJArtistMixError: Error, Equatable {
    case albumListFailed(detail: String)
    case albumReadFailed(album: String, detail: String)
    case noSongs(artist: String)
    /// The fence turned (the request, the data source or the output moved on).
    case cancelled

    var message: String {
        switch self {
        case .albumListFailed(let detail):
            return "Couldn't read this artist's albums, so nothing is ready: \(detail)"
        case .albumReadFailed(let album, let detail):
            return "Couldn't read '\(album)', so the mix isn't ready and nothing played: \(detail)"
        case .noSongs(let artist):
            return "No playable songs found for \(artist)."
        case .cancelled:
            return djChangedLine
        }
    }
}

/// The words for whatever a read threw.
func djErrorText(_ error: Error) -> String {
    switch error {
    case let e as SourceAppError: return e.message
    case let e as ActionError: return e.message
    case let e as MusicProviderError: return e.errorDescription ?? "\(e)"
    case let e as LocalizedError: return e.errorDescription ?? e.localizedDescription
    default: return error.localizedDescription
    }
}

/// Reads the artist's first 25 albums and every album's tracks and returns the
/// mix. `isCurrent` is asked before every read; false stops reading at once.
/// Sequential reads, stopping at the first failure.
func djBuildArtistMix(artist: CatalogueHit, catalogue: DJCatalogue, shuffler: DJShuffling,
                      isCurrent: () -> Bool) throws -> DJArtistMix {
    guard isCurrent() else { throw DJArtistMixError.cancelled }
    let page: ArtistAlbums
    do {
        page = try catalogue.artistAlbums(artistID: artist.id, limit: DiscoverScene.artistAlbumsLimit)
    } catch {
        throw DJArtistMixError.albumListFailed(detail: djErrorText(error))
    }

    var seen = Set<String>()
    var songs: [(id: String, album: String)] = []
    var unavailable = 0
    for album in page.albums {
        guard isCurrent() else { throw DJArtistMixError.cancelled }
        let tracks: [DiscoverItem]
        do {
            tracks = try catalogue.containerTracks(for: DiscoverItem(
                id: album.id, name: album.title, subtitle: album.subtitle, url: nil, artworkURL: nil,
                detail: .album(trackCount: nil, year: nil, genre: nil)))
        } catch {
            throw DJArtistMixError.albumReadFailed(album: album.title, detail: djErrorText(error))
        }
        for track in tracks where seen.insert(track.id).inserted {
            if track.length == .null { unavailable += 1; continue }
            songs.append((track.id, album.id))
        }
    }
    guard isCurrent() else { throw DJArtistMixError.cancelled }
    guard !songs.isEmpty else { throw DJArtistMixError.noSongs(artist: artist.title) }

    // A full shuffle, then the first 50: uniform over every subset of 50.
    let chosen = Array(shuffler.shuffled(songs).prefix(DJArtistMix.songLimit))
    return DJArtistMix(artistName: artist.title, artistID: artist.id, ids: chosen.map(\.id),
                       albumCount: Set(chosen.map(\.album)).count, moreAlbums: page.more,
                       unavailable: unavailable)
}
