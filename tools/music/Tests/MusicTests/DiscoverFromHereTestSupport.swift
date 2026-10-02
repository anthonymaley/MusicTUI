import Foundation
@testable import music

// Fakes shared by the discover-from-here steps (score step C0). Later steps
// name their own test types with a step-unique prefix or keep them `private`:
// a duplicate type name across files breaks the whole test target.

/// An in-memory `DiscoverCopyJournalStore`. Every call is recorded in order in
/// `events` as `"entries"`, `"insert:<txn>"` or `"update:<txn>"`; a write that
/// `failWrites` rejects is recorded too (with a `"!"` suffix) and throws
/// `.writeFailed` without changing anything. `failWrites` is asked with
/// `"insert:<txn>"` or `"update:<txn>:<resulting state>"`.
final class InMemoryDiscoverCopyJournalStore: DiscoverCopyJournalStore {
    private(set) var stored: [DiscoverCopyEntry]
    private(set) var events: [String] = []
    var failWrites: (String) -> Bool = { _ in false }

    init(entries: [DiscoverCopyEntry] = []) { self.stored = entries }

    func entries() throws -> [DiscoverCopyEntry] {
        events.append("entries")
        return stored
    }

    func insert(_ entry: DiscoverCopyEntry) throws {
        let label = "insert:\(entry.txn)"
        if failWrites(label) {
            events.append(label + "!")
            throw DiscoverCopyJournalError.writeFailed("injected")
        }
        events.append(label)
        stored.append(entry)
    }

    @discardableResult
    func update(txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        guard let index = stored.firstIndex(where: { $0.txn == txn }) else {
            events.append("update:\(txn)!")
            throw DiscoverCopyJournalError.notFound
        }
        var next = stored[index]
        change(&next)
        if failWrites("update:\(txn):\(next.state.rawValue)") {
            events.append("update:\(txn)!")
            throw DiscoverCopyJournalError.writeFailed("injected")
        }
        events.append("update:\(txn)")
        stored[index] = next
        return next
    }
}

/// A scripted `SpanDACCatalogPlaylistOps`. `copiesResults` is a queue: each
/// `copies(ofCatalogPlaylist:)` call takes the first; when one is left it is
/// answered again, and an empty queue answers `[]`. `calls` is the ordered
/// record: `"copies:<id>"` and `"add:<id>"`.
final class FakeCatalogPlaylistOps: SpanDACCatalogPlaylistOps {
    var offers = true
    var copiesResults: [Result<[CatalogPlaylistCopy], Error>] = []
    var addOutcome: CatalogPlaylistAddOutcome = .added(copies: [])
    var onAdd: (() -> Void)?
    private(set) var calls: [String] = []

    var offersCatalogPlaylist: Bool { offers }

    func copies(ofCatalogPlaylist id: String) throws -> [CatalogPlaylistCopy] {
        calls.append("copies:\(id)")
        guard !copiesResults.isEmpty else { return [] }
        let next = copiesResults.count > 1 ? copiesResults.removeFirst() : copiesResults[0]
        return try next.get()
    }

    func addCatalogPlaylist(id: String) -> CatalogPlaylistAddOutcome {
        calls.append("add:\(id)")
        onAdd?()
        return addOutcome
    }
}

/// A `DiscoverCopyGate` that answers `.ran` (and runs the body), or the
/// scripted `.sourceChanged` / `.superseded` at the n-th call (1-based, in
/// `scripted`), in which case the body does not run. Every call is recorded in
/// `calls` with the answer it got.
final class FakeDiscoverCopyGate {
    var scripted: [Int: DiscoverCopyGateResult]
    private(set) var calls: [DiscoverCopyGateResult] = []

    init(scripted: [Int: DiscoverCopyGateResult] = [:]) { self.scripted = scripted }

    var gate: DiscoverCopyGate {
        return { [self] body in
            let answer = scripted[calls.count + 1] ?? .ran
            calls.append(answer)
            if answer == .ran { body() }
            return answer
        }
    }
}

/// Song rows with the given lengths, ids "1"..., titles "Song 1"..., artist "Artist".
func dfhRows(_ lengths: [RowLength]) -> [DiscoverItem] {
    lengths.enumerated().map { index, length in
        DiscoverItem(id: "\(index + 1)", name: "Song \(index + 1)", subtitle: "Artist",
                     url: nil, artworkURL: nil, detail: .song, length: length)
    }
}
