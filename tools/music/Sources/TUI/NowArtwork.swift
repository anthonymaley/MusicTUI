// tools/music/Sources/TUI/NowArtwork.swift
// The Now tab's REST artwork fallback: when the playing track carries no
// embedded artwork (`extractArtwork()` found zero `artworks of current track`
// — true of every track on "People's Instinctive Travels a", A Tribe Called
// Quest), resolve the SAME library album cover the Library tab renders, so the
// two tabs stop disagreeing about the same album.
//
// Route (all three alternatives were probed live 2026-07-15 before this one
// was chosen):
//   1. library SEARCH by album name — REJECTED. It matches the album NAME
//      only (never artistName, so appending the artist misses EVERY album:
//      "Midnight Marauders" hits, "Midnight Marauders A Tribe Called Quest"
//      returns nothing) and is inconsistent even on names: the exact string
//      "People's Instinctive Travels a" returns nothing while the single word
//      "instinctive" returns that very album.
//   2. walking /v1/me/library/albums (the Library tab's own source) — correct
//      but 2914 albums / 30 requests / 35.8s on this library. Too slow to
//      resolve one cover, and the Radio tab already taught us what a long
//      network stall costs.
//   3. library song-search by TRACK TITLE, then the song's `albums`
//      relationship — CHOSEN. Two targeted requests, and the relationship
//      returns the same library album object (same id, same artwork URL)
//      `libraryAlbums()` hands the Library tab.
//
// Search flakiness is absorbed by trying the exact title first and then a
// short prefix of it (live: "The Baron Sleeps and Dreams" returns nothing but
// "The Baron" returns it). Wrong hits can't leak through: a candidate is only
// accepted when its artist matches, so a miss degrades to the gradient rather
// than to somebody else's cover. No new REST client — this is the existing
// `search()` plus one relationship read.
import Foundation

/// The Now tab's per-album identity for its resolved-artwork cache, from the
/// only strings AppleScript gives it. Same `album\0artist` shape as
/// PlaybackPoller's own art key, so both caches partition playback identically
/// — one resolved cover per album, not per track. Pure.
func nowAlbumKey(album: String, artist: String) -> String { "\(album)\u{0}\(artist)" }

/// The search terms to try for a track title, in order: the exact title, then
/// (when the title is longer) its first `prefixWords` words. Apple's library
/// search inconsistently misses long terms while matching a short prefix of
/// the same title — live-probed, see the file header. Never returns duplicates,
/// so a short title costs exactly one request. Pure, unit-tested.
func librarySearchTerms(forTitle title: String, prefixWords: Int = 2) -> [String] {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let words = trimmed.split(separator: " ")
    guard words.count > prefixWords else { return [trimmed] }
    return [trimmed, words.prefix(prefixWords).joined(separator: " ")]
}

/// Pick the library-search hit that is really this track. The artist must
/// match — a same-titled song by someone else would supply a wrong cover, and
/// a gradient beats wrong art. Among artist matches, one whose album also
/// matches wins: a track that appears on several albums (a single and an LP,
/// say) must resolve to the album that is actually playing, not whichever copy
/// the search happened to rank first. Pure, unit-tested.
func bestSongMatch(_ candidates: [CatalogSong], title: String, artist: String, album: String) -> CatalogSong? {
    func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
    let wantTitle = norm(title), wantArtist = norm(artist), wantAlbum = norm(album)
    guard !wantArtist.isEmpty else { return nil }
    let sameSong = candidates.filter { norm($0.title) == wantTitle && norm($0.artist) == wantArtist }
    return sameSong.first { norm($0.album) == wantAlbum } ?? sameSong.first
}

/// Resolve the playing track's library album id + {w}x{h} artwork template.
/// The id is in the same space `libraryAlbums()` returns, so the caller keys
/// ArtworkStore on it and a cover the Library tab already fetched is a disk
/// cache HIT rather than a second download — one artwork source, not two.
///
/// nil on no match / no artwork / any network failure; the caller then keeps
/// the gradient, exactly as when embedded extraction finds nothing. Never
/// throws — artwork is decoration and must never error at the user. Blocking
/// (network I/O): callers run it off the main thread (see NowPlayingScene.tick).
func lookupAlbumArtwork(api: RESTAPIBackend, title: String, artist: String, album: String) -> (id: String, url: String)? {
    guard !title.isEmpty, !artist.isEmpty else { return nil }
    for term in librarySearchTerms(forTitle: title) {
        let hits = (try? syncRun {
            try await api.search(term: term, types: [.songs], limit: 25, library: true)
        })?.songs ?? []
        guard let song = bestSongMatch(hits, title: title, artist: artist, album: album), !song.id.isEmpty else {
            continue   // this term found nothing for us — try the next (shorter) one
        }
        // The song is identified: its album relationship is authoritative, so
        // don't keep searching on a further term whatever it says.
        // `try?` flattens the method's own Optional return, so one bind covers
        // both "request failed" and "song has no album".
        guard let hit = try? syncRun({ try await api.libraryAlbumForSong(songID: song.id) }),
              let url = hit.artworkURL, !hit.id.isEmpty else { return nil }
        return (hit.id, url)
    }
    return nil
}
