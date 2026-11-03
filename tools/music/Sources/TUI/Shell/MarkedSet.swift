// tools/music/Sources/TUI/Shell/MarkedSet.swift
import Foundation

/// A row the person has marked (`m`) on the Albums or Playlists list, to be
/// played together with the others as one queue. Identity is by value: an album
/// is its title AND artist (two artists can each have a "Greatest Hits"), a
/// playlist is its name.
enum MarkedItem: Equatable {
    case album(title: String, artist: String)
    case playlist(name: String)
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
