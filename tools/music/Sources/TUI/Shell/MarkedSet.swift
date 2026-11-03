// tools/music/Sources/TUI/Shell/MarkedSet.swift
import Foundation

/// A row the person has marked (`m`) on the Albums or Playlists list, to be
/// played together with the others as one queue. An album is its title AND
/// artist (two artists can each have a "Greatest Hits"). A playlist is its
/// `id`, captured from the rail's own read when it was marked: on MusicTUI's
/// data, the playlist's persistent ID (sixteen hex digits, upper-cased), the
/// only key a marked play reads it by; on SpanDAC data, SpanDAC's own id for
/// it (a marked play from SpanDAC data refuses before reading anything).
/// `name` is what the rail showed, kept for display and messages only: two
/// playlists sharing a name are two marks, and a playlist renamed since is
/// still the same one.
enum MarkedItem: Equatable {
    case album(title: String, artist: String)
    case playlist(id: String, name: String)

    static func == (lhs: MarkedItem, rhs: MarkedItem) -> Bool {
        switch (lhs, rhs) {
        case let (.album(lt, la), .album(rt, ra)): return lt == rt && la == ra
        case let (.playlist(lid, _), .playlist(rid, _)): return lid == rid
        default: return false
        }
    }
}

/// The marked rows, in the order they were marked. Marks are kept across tabs
/// and never mix data sources: marking a row from a different `ListSource`
/// (Music.app data vs SpanDAC data) than the set currently holds clears the set
/// first. Thread-safe (NSLock), in the style of `AppQueueStore`, since the
/// main loop marks while play and render paths read.
final class MarkedSetStore {
    private let lock = NSLock()
    private var marked: [MarkedItem] = []
    private var source: ListSource?

    /// Marks `item` at the end, or unmarks it if already marked. A `source`
    /// that differs from the set's current one clears the set first, then marks.
    func toggle(_ item: MarkedItem, source newSource: ListSource) {
        lock.lock(); defer { lock.unlock() }
        if let current = source, current != newSource {
            marked.removeAll()
        }
        source = newSource
        if let at = marked.firstIndex(of: item) {
            // Same source as the set (or the set was just cleared, so it cannot
            // contain the item): this is an unmark.
            marked.remove(at: at)
        } else {
            marked.append(item)
        }
        if marked.isEmpty { source = nil }
    }

    func contains(_ item: MarkedItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return marked.contains(item)
    }

    /// The marked rows in mark order.
    var items: [MarkedItem] {
        lock.lock(); defer { lock.unlock() }
        return marked
    }

    /// The data source the marks were made from; nil when nothing is marked.
    var listSource: ListSource? {
        lock.lock(); defer { lock.unlock() }
        return source
    }

    /// The marks and their source, read together under one lock, so a play
    /// never pairs one set's items with another's source.
    var snapshot: (items: [MarkedItem], source: ListSource?) {
        lock.lock(); defer { lock.unlock() }
        return (marked, source)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return marked.count
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return marked.isEmpty
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        marked.removeAll()
        source = nil
    }
}
