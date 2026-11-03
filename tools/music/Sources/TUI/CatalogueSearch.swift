// tools/music/Sources/TUI/CatalogueSearch.swift
//
// The Discover catalogue search, as a pure model: query text editing, the
// editing-versus-results state, two levels (the grouped results, and one
// artist's albums), a cursor per level that never rests on a group header,
// and the one-line notes. No I/O, no clock, no host: a key goes in, an
// optional intent comes out, and answers come back as `receive` calls keyed by
// a monotonic request id.
//
// REQUEST IDS. Every request the model asks for (a search, an artist's albums)
// takes the next id from one counter, and the model remembers only the id it
// is waiting on. An answer is applied only if its id is that one, so an older
// answer can never overwrite a newer one, and an answer for a level the person
// has left (Esc, Back, a new search) finds no pending id and is dropped.
import Foundation

/// What the pane asks its host to do. The pane performs none of it.
enum CatalogueSearchIntent: Equatable {
    case search(String)
    case openArtist(CatalogueHit)
    case openAlbum(CatalogueHit)
    case playAlbum(CatalogueHit)
    case playSong(CatalogueHit)
    case close
}

/// An intent with the request id it belongs to. `search` and `openArtist`
/// carry a fresh id the host must echo back; the rest carry the latest id,
/// which the host ignores.
struct CatalogueSearchEmission: Equatable {
    let intent: CatalogueSearchIntent
    let requestID: Int
}

struct CatalogueSearchOutcome: Equatable {
    var changed = false
    var emission: CatalogueSearchEmission?
}

struct CatalogueSearchModel {
    enum Row: Equatable {
        case header(String)
        case hit(CatalogueHit)
    }

    /// The box's text. Whole while editing; equal to `lastTerm` otherwise.
    private(set) var text = ""
    /// True only while the box is open. The host's `capturesAllInput` mirrors it.
    private(set) var isEditing = true
    /// The last term sent (trimmed), what `/` reopens with.
    private(set) var lastTerm = ""
    private(set) var results: CatalogueSearchResults?
    private(set) var failure: String?
    /// Non-nil while on the artist-albums level.
    private(set) var artist: CatalogueHit?
    private(set) var artistAlbums: ArtistAlbums?
    private var artistFailure: String?
    private var resultsCursor = 0
    private var artistCursor = 0

    private var lastID = 0
    private var pendingSearch: Int?
    private var pendingArtist: Int?

    static let maxTextLength = 200
    static let albumPageNote = "First 25 albums."

    // MARK: derived view

    /// The rows of the level on screen.
    var rows: [Row] {
        if artist != nil {
            return (artistAlbums?.albums ?? []).map { .hit($0) }
        }
        guard let r = results else { return [] }
        var out: [Row] = []
        for (name, hits) in [("Artists", r.artists), ("Albums", r.albums), ("Songs", r.songs)]
        where !hits.isEmpty {
            out.append(.header(name))
            out.append(contentsOf: hits.map { .hit($0) })
        }
        return out
    }

    /// Index into `rows` of the level on screen. Meaningful only when a hit is selectable.
    var cursor: Int { artist != nil ? artistCursor : resultsCursor }

    var selectedHit: CatalogueHit? {
        let r = rows
        guard cursor >= 0, cursor < r.count, case .hit(let h) = r[cursor] else { return nil }
        return h
    }

    /// The line under the box, or nil when there is nothing to say.
    var note: String? {
        if let a = artist {
            if let f = artistFailure { return f }
            guard let page = artistAlbums else { return "Loading albums…" }
            if page.albums.isEmpty { return "No albums for \(a.title)." }
            return page.more ? Self.albumPageNote : nil
        }
        if let f = failure { return f }
        if pendingSearch != nil, results == nil { return "Searching “\(lastTerm)”…" }
        guard let r = results else { return nil }
        let empty = r.artists.isEmpty && r.albums.isEmpty && r.songs.isEmpty
        let parts = [empty ? "No results for “\(lastTerm)”." : nil, r.artistsNote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: keys

    mutating func handle(_ key: KeyPress) -> CatalogueSearchOutcome {
        isEditing ? handleEditing(key) : handleBrowsing(vimAlias(key, listScene: true))
    }

    private mutating func handleEditing(_ key: KeyPress) -> CatalogueSearchOutcome {
        switch key {
        case .enter:
            let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return .init() }
            let id = nextID()
            pendingSearch = id
            pendingArtist = nil
            artist = nil
            artistAlbums = nil
            artistFailure = nil
            results = nil
            failure = nil
            resultsCursor = 0
            artistCursor = 0
            lastTerm = term
            text = term
            isEditing = false
            return changed(.search(term), id)
        case .escape:
            if results != nil || failure != nil || pendingSearch != nil {
                isEditing = false
                text = lastTerm
                return .init(changed: true)
            }
            return close()
        case .char(let c) where c == "\u{7F}" || c == "\u{8}":
            guard !text.isEmpty else { return .init() }
            text.removeLast()
            return .init(changed: true)
        case .space:
            return append(" ")
        case .char(let c):
            return append(c)
        default:
            return .init()
        }
    }

    private mutating func append(_ c: Character) -> CatalogueSearchOutcome {
        guard c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
              text.count < Self.maxTextLength else { return .init() }
        text.append(c)
        return .init(changed: true)
    }

    private mutating func handleBrowsing(_ key: KeyPress) -> CatalogueSearchOutcome {
        switch key {
        case .down:     return move(by: 1)
        case .up:       return move(by: -1)
        case .pageDown: return move(by: 10)
        case .pageUp:   return move(by: -10)
        case .home:     return jump(toLast: false)
        case .end:      return jump(toLast: true)
        case .enter:    return activate(drillOnly: false)
        case .right:    return activate(drillOnly: true)
        case .char("p"):
            guard let hit = selectedHit, hit.kind == .album else { return .init() }
            return emit(.playAlbum(hit))
        case .char("/"):
            // On the results level only: from the artist level it is inert.
            guard artist == nil else { return .init() }
            isEditing = true
            text = lastTerm
            return .init(changed: true)
        case .escape, .left:
            if artist != nil {
                artist = nil
                artistAlbums = nil
                artistFailure = nil
                pendingArtist = nil
                return .init(changed: true)
            }
            return close()
        default:
            return .init()
        }
    }

    private mutating func activate(drillOnly: Bool) -> CatalogueSearchOutcome {
        guard let hit = selectedHit else { return .init() }
        switch hit.kind {
        case .artist:
            let id = nextID()
            pendingArtist = id
            artist = hit
            artistAlbums = nil
            artistFailure = nil
            artistCursor = 0
            return changed(.openArtist(hit), id)
        case .album:
            return emit(.openAlbum(hit))
        case .song:
            // → drills; a song has nothing to drill into, and → never plays.
            return drillOnly ? .init() : emit(.playSong(hit))
        }
    }

    private mutating func close() -> CatalogueSearchOutcome {
        pendingSearch = nil
        pendingArtist = nil
        return emit(.close)
    }

    // MARK: answers

    /// True when the answer was applied (the screen changed).
    @discardableResult
    mutating func receive(results r: CatalogueSearchResults, requestID: Int) -> Bool {
        guard pendingSearch == requestID, artist == nil else { return false }
        pendingSearch = nil
        results = r
        failure = nil
        resultsCursor = firstHit(in: rows)
        return true
    }

    @discardableResult
    mutating func receive(albums page: ArtistAlbums, requestID: Int) -> Bool {
        guard pendingArtist == requestID, artist != nil else { return false }
        pendingArtist = nil
        artistAlbums = page
        artistFailure = nil
        artistCursor = firstHit(in: rows)
        return true
    }

    @discardableResult
    mutating func receive(failure message: String, requestID: Int) -> Bool {
        if pendingArtist == requestID, artist != nil {
            pendingArtist = nil
            artistFailure = message
            return true
        }
        if pendingSearch == requestID, artist == nil {
            pendingSearch = nil
            failure = message
            return true
        }
        return false
    }

    // MARK: cursor

    private func firstHit(in rows: [Row]) -> Int {
        rows.firstIndex { if case .hit = $0 { return true } else { return false } } ?? 0
    }

    private func hitIndexes() -> [Int] {
        rows.enumerated().compactMap { i, r in if case .hit = r { return i } else { return nil } }
    }

    private mutating func setCursor(_ i: Int) {
        if artist != nil { artistCursor = i } else { resultsCursor = i }
    }

    private mutating func move(by delta: Int) -> CatalogueSearchOutcome {
        let hits = hitIndexes()
        guard !hits.isEmpty else { return .init() }
        let at = hits.firstIndex(of: cursor) ?? 0
        let to = hits[max(0, min(hits.count - 1, at + delta))]
        guard to != cursor else { return .init() }
        setCursor(to)
        return .init(changed: true)
    }

    private mutating func jump(toLast: Bool) -> CatalogueSearchOutcome {
        let hits = hitIndexes()
        guard let to = toLast ? hits.last : hits.first, to != cursor else { return .init() }
        setCursor(to)
        return .init(changed: true)
    }

    // MARK: emission

    private mutating func nextID() -> Int {
        lastID += 1
        return lastID
    }

    private func changed(_ intent: CatalogueSearchIntent, _ id: Int) -> CatalogueSearchOutcome {
        .init(changed: true, emission: .init(intent: intent, requestID: id))
    }

    private func emit(_ intent: CatalogueSearchIntent) -> CatalogueSearchOutcome {
        changed(intent, lastID)
    }
}
