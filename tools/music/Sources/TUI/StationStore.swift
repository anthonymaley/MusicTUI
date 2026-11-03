// Favorite stations, persisted locally at ~/.config/music/stations.json —
// deliberately NOT Apple's library. A station added to the library becomes a
// URL track whose *name is its id* ("ra.978194965"), which would litter the
// Songs list. Local storage also keeps stations the catalog API cannot resolve
// (BBC Radio 1) as first-class favorites: each entry carries its own url+name,
// so the tab paints and plays from disk with no network at all.
import Foundation

final class StationStore {
    private let path: String
    private let lock = NSLock()
    private var cache: [Station]?

    init(path: String = NSString(string: "~/.config/music/stations.json").expandingTildeInPath) {
        self.path = path
    }

    /// Caller must hold `lock`. Loads from the in-memory cache if present, else
    /// disk. A corrupt or missing file reads as empty — favorites are a
    /// convenience, never a reason to error at the user.
    private func loadLocked() -> [Station] {
        if let c = cache { return c }
        guard let data = FileManager.default.contents(atPath: path),
              let list = try? JSONDecoder().decode([Station].self, from: data)
        else { cache = []; return [] }
        cache = list
        return list
    }

    /// Insertion order is the display order.
    func favorites() -> [Station] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    func isFavorite(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().contains { $0.id == id }
    }

    /// Add or refresh. Re-adding replaces metadata in place, keeping position —
    /// a later API resolve can upgrade a slug-derived name to the real one.
    /// The whole read-modify-write happens under one lock hold so a concurrent
    /// add/remove can't interleave between the read and the write and lose an
    /// update (see file-level locking note).
    func add(_ station: Station) throws {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        if let i = list.firstIndex(where: { $0.id == station.id }) {
            list[i] = station
        } else {
            list.append(station)
        }
        try writeLocked(list)
    }

    /// RED STUB.
    @discardableResult
    func setArtworkIfMissing(id: String, url: String) throws -> Bool { false }

    func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try writeLocked(loadLocked().filter { $0.id != id })
    }

    func toggle(_ station: Station) throws {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        if let i = list.firstIndex(where: { $0.id == station.id }) {
            list.remove(at: i)
        } else {
            list.append(station)
        }
        try writeLocked(list)
    }

    /// Caller must hold `lock`.
    private func writeLocked(_ list: [Station]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(list)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        cache = list
    }
}
