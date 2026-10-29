// tools/music/Sources/TUI/LibraryNav.swift
// Pure navigation model for the Library tab. No I/O, no rendering — the scene
// executes the emitted LibraryAction. Kept pure so every transition is unit-
// testable (mirrors how PlaylistBrowserModel pulls geometry out of the scene).
import Foundation

// Declaration order IS the on-screen sub-view order and the [ / ] cycle order:
// Artists first (the primary browse axis), then Albums, then Songs.
enum LibrarySubView: CaseIterable, Equatable { case artists, albums, songs }

enum LibraryLevel: Equatable {
    case albumList, artistList, songList
    case artistAlbums(artistID: String, artistName: String)
    case tracks(albumID: String, albumTitle: String, artist: String)
}

/// Identity of whatever row is under the cursor when a key is pressed. Passed in
/// so the reducer stays pure (no dependency on the live data arrays).
struct LibrarySelection: Equatable {
    let id: String
    let primary: String    // album title / artist name / song title
    let secondary: String  // artist for album/song; "" for artist
}

enum LibraryTarget: Equatable {
    case album(id: String, title: String, artist: String)
    case song(id: String, title: String, artist: String)
    case artist(id: String, name: String)
}

enum LibraryAction: Equatable {
    case none
    case fetchArtistAlbums(artistID: String, artistName: String)
    case fetchAlbumTracks(albumID: String, albumTitle: String, artist: String)
    case play(LibraryTarget)
    case shuffle(LibraryTarget)
}

enum LibraryKey { case up, down, enter, back, switchNext, switchPrev, play, shuffle }

struct LibraryNav: Equatable {
    var subView: LibrarySubView
    var stack: [LibraryLevel]   // stack.last == current level
    var cursor: Int
    /// The cursor each level above `stack.last` had when it was drilled into, so
    /// Back lands on the row that was opened rather than row 0. Parallel to
    /// `stack.dropLast()`.
    var returnCursors: [Int] = []

    static let initial = LibraryNav(subView: .artists, stack: [.artistList], cursor: 0)
    var current: LibraryLevel { stack.last! }

    static func root(for sub: LibrarySubView) -> LibraryLevel {
        switch sub {
        case .albums: return .albumList
        case .artists: return .artistList
        case .songs: return .songList
        }
    }
}

/// `albumRow` says the selection is an album although the level is `.artistList`:
/// the Artists list's Uploaded rows (SpanDAC albums with no track count) are
/// albums, so Enter opens their tracks and `p`/`s` play the album, exactly as an
/// album row does on the album lists. Ignored at every other level.
func libraryReduce(_ state: LibraryNav, _ key: LibraryKey,
                   itemCount: Int, selection: LibrarySelection?,
                   albumRow: Bool = false) -> (LibraryNav, LibraryAction) {
    var s = state
    switch key {
    case .up:   s.cursor = max(0, s.cursor - 1); return (s, .none)
    case .down: s.cursor = min(max(0, itemCount - 1), s.cursor + 1); return (s, .none)

    case .switchNext, .switchPrev:
        let all = LibrarySubView.allCases
        let idx = all.firstIndex(of: s.subView)!
        let next = key == .switchNext ? (idx + 1) % all.count : (idx - 1 + all.count) % all.count
        s.subView = all[next]
        s.stack = [LibraryNav.root(for: s.subView)]
        s.returnCursors = []
        s.cursor = 0
        return (s, .none)

    case .back:
        if s.stack.count > 1 {
            s.stack.removeLast()
            s.cursor = s.returnCursors.popLast() ?? 0
        }
        return (s, .none)

    case .enter:
        guard let sel = selection else { return (s, .none) }
        switch s.current {
        case .albumList, .artistAlbums, .artistList where albumRow:
            s.stack.append(.tracks(albumID: sel.id, albumTitle: sel.primary, artist: sel.secondary))
            s.returnCursors.append(s.cursor)
            s.cursor = 0
            return (s, .fetchAlbumTracks(albumID: sel.id, albumTitle: sel.primary, artist: sel.secondary))
        case .artistList:
            s.stack.append(.artistAlbums(artistID: sel.id, artistName: sel.primary))
            s.returnCursors.append(s.cursor)
            s.cursor = 0
            return (s, .fetchArtistAlbums(artistID: sel.id, artistName: sel.primary))
        case .songList:
            return (s, .play(.song(id: sel.id, title: sel.primary, artist: sel.secondary)))
        case .tracks(let id, let title, let artist):
            return (s, .play(.album(id: id, title: title, artist: artist)))
        }

    case .play:
        return (s, playOrShuffle(s.current, selection, shuffle: false, albumRow: albumRow))
    case .shuffle:
        return (s, playOrShuffle(s.current, selection, shuffle: true, albumRow: albumRow))
    }
}

private func playOrShuffle(_ level: LibraryLevel, _ sel: LibrarySelection?, shuffle: Bool,
                           albumRow: Bool) -> LibraryAction {
    let target: LibraryTarget?
    switch level {
    case .albumList, .artistAlbums, .artistList where albumRow:
        target = sel.map { .album(id: $0.id, title: $0.primary, artist: $0.secondary) }
    case .artistList:
        target = sel.map { .artist(id: $0.id, name: $0.primary) }
    case .songList:
        target = sel.map { .song(id: $0.id, title: $0.primary, artist: $0.secondary) }
    case .tracks(let id, let title, let artist):
        target = .album(id: id, title: title, artist: artist)
    }
    guard let t = target else { return .none }
    return shuffle ? .shuffle(t) : .play(t)
}
