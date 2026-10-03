import Foundation
@testable import music

// Fakes shared by the album-cleanup steps (score step A0). Later steps name
// their own test types with their step prefix (`A2…`, `A3…`) or keep them
// `private`: a duplicate type name across files breaks the whole test target.

/// A scripted `SpanDACLibraryRelationsReading`. `results` is a queue: each
/// `relations(catalogueIDs:)` call takes the first; when one is left it is
/// answered again, and an empty queue answers every requested id with `[]`
/// (no relation). `calls` is the ordered record of the ids of each call.
/// Thread-safe (the proof collector may ask from another thread).
final class FakeLibraryRelations: SpanDACLibraryRelationsReading {
    private let lock = NSLock()
    private var _offers = true
    private var _results: [Result<[String: [String?]], Error>] = []
    private var _calls: [[String]] = []

    init(offers: Bool = true, results: [Result<[String: [String?]], Error>] = []) {
        _offers = offers
        _results = results
    }

    var offers: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _offers }
        set { lock.lock(); _offers = newValue; lock.unlock() }
    }
    var results: [Result<[String: [String?]], Error>] {
        get { lock.lock(); defer { lock.unlock() }; return _results }
        set { lock.lock(); _results = newValue; lock.unlock() }
    }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }

    var offersAlbumCleanup: Bool { offers }

    func relations(catalogueIDs: [String]) throws -> [String: [String?]] {
        lock.lock()
        _calls.append(catalogueIDs)
        let next: Result<[String: [String?]], Error>?
        if _results.isEmpty {
            next = nil
        } else {
            next = _results.count > 1 ? _results.removeFirst() : _results[0]
        }
        lock.unlock()
        guard let next else {
            return Dictionary(uniqueKeysWithValues: catalogueIDs.map { ($0, [String?]()) })
        }
        return try next.get()
    }
}

/// An in-memory `DiscoverBeforeSetStore`. File names are the production ones
/// (`before-<txn>.json`). Every call is recorded in order in `calls` as
/// `"write:<txn>"`, `"read:<file>"` or `"delete:<file>"`; a write that
/// `failWrites` rejects is recorded with a `"!"` suffix and throws
/// `.writeFailed("injected")`, storing nothing. `failReads` makes every read
/// throw `.unreadable`. An unknown file reads `.unreadable`.
final class InMemoryBeforeSetStore: DiscoverBeforeSetStore {
    private let lock = NSLock()
    private var _files: [String: Set<String>] = [:]
    private var _calls: [String] = []
    private var _failWrites = false
    private var _failReads = false

    init(files: [String: Set<String>] = [:]) { _files = files }

    var failWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failWrites }
        set { lock.lock(); _failWrites = newValue; lock.unlock() }
    }
    var failReads: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failReads }
        set { lock.lock(); _failReads = newValue; lock.unlock() }
    }
    var files: [String: Set<String>] { lock.lock(); defer { lock.unlock() }; return _files }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    func writeBeforeSet(txn: String, ids: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if _failWrites {
            _calls.append("write:\(txn)!")
            throw DiscoverCopyJournalError.writeFailed("injected")
        }
        _calls.append("write:\(txn)")
        let file = "before-\(txn).json"
        _files[file] = Set(ids)
        return file
    }

    func readBeforeSet(file: String) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        _calls.append("read:\(file)")
        guard !_failReads, let ids = _files[file] else { throw DiscoverCopyJournalError.unreadable }
        return ids
    }

    func deleteBeforeSet(file: String) {
        lock.lock(); defer { lock.unlock() }
        _calls.append("delete:\(file)")
        _files[file] = nil
    }
}

/// A scripted `SpanDACLibraryAdding` for the album's ensure. `ensureResults`
/// is a queue (the last one repeats); an empty queue throws
/// `.failed("unscripted")`. `calls` is the ordered record:
/// `"ensure:<name>:<id,id,…>"`, `"add:<id,…>"`, `"lookup:<id,…>"`. `onEnsure`
/// runs inside the ensure, before it answers.
final class FakeAlbumLibrary: SpanDACLibraryAdding {
    typealias Ensured = (created: Bool, id: String, alias: String?)

    var canAdd = true
    var ensureResults: [Result<Ensured, Error>] = []
    var addError: Error?
    var lookupResult: [String: String?] = [:]
    var onEnsure: (() -> Void)?
    private(set) var calls: [String] = []

    init(ensureResults: [Result<Ensured, Error>] = []) { self.ensureResults = ensureResults }

    func add(catalogueIDs: [String]) throws {
        calls.append("add:" + catalogueIDs.joined(separator: ","))
        if let addError { throw addError }
    }

    func lookup(catalogueIDs: [String]) throws -> [String: String?] {
        calls.append("lookup:" + catalogueIDs.joined(separator: ","))
        return lookupResult
    }

    func ensurePlaylist(name: String, catalogueIDs: [String]) throws -> Ensured {
        calls.append("ensure:\(name):" + catalogueIDs.joined(separator: ","))
        onEnsure?()
        guard !ensureResults.isEmpty else { throw SpanDACLibraryOpError.failed("unscripted") }
        let next = ensureResults.count > 1 ? ensureResults.removeFirst() : ensureResults[0]
        return try next.get()
    }
}

/// A fixed, well-formed album txn (an uppercase UUID, as production mints).
let albumTestTxn = "A1B2C3D4-0000-4000-8000-00000000A1B0"
let albumTestAlbumID = "1440000001"
let albumTestAlbum = "Test Album"

/// The catalogue id of album song `position` (1-based): digits only.
func albumTestCatalogueID(_ position: Int) -> String { String(1_000_000_000 + position) }

/// The persistent ID hex whose alias is `"\(n)"`: `persistentIDHex(fromAlias: "\(n)")`.
func albumTestHex(_ n: Int) -> String { String(format: "%016llX", UInt64(n)) }

/// Album song rows with the given lengths: ids `albumTestCatalogueID(1)`…,
/// titles "Track 1"…, artist "Album Artist".
func albumTestRows(_ lengths: [RowLength]) -> [DiscoverItem] {
    lengths.enumerated().map { index, length in
        DiscoverItem(id: albumTestCatalogueID(index + 1), name: "Track \(index + 1)", subtitle: "Album Artist",
                     url: nil, artworkURL: nil, detail: .song, length: length)
    }
}

/// One album song at `position`. An `owned` song defaults to a matching
/// entry hex and alias (`albumTestHex(position)`, `"\(position)"`); a
/// `deleted` one to a matching entry hex. Pass values to override.
func albumTestSong(_ position: Int, state: DiscoverAlbumSongState = .intent,
                   entryHex: String? = nil, alias: String? = nil,
                   keptReason: String? = nil, keptPlaylist: String? = nil) -> DiscoverAlbumSong {
    let defaultHex = (state == .owned || state == .deleted) ? albumTestHex(position) : nil
    let defaultAlias = state == .owned ? "\(position)" : nil
    return DiscoverAlbumSong(position: position, catalogueID: albumTestCatalogueID(position),
                             title: "Track \(position)", artist: "Album Artist",
                             durationMS: 1000 * position, relationsBefore: [0],
                             entryHex: entryHex ?? defaultHex, alias: alias ?? defaultAlias,
                             cloudStatus: nil, state: state, p4FirstSeenAt: nil, uncertainReason: nil,
                             keptReason: keptReason, keptPlaylist: keptPlaylist, deletedAt: nil)
}

/// A journal entry for an album play that holds every invariant: kind
/// `.albumContainer`, `containerName` = prefix + txn + separator + album,
/// `beforeFile` = `before-<txn>.json`, and `songCount` songs in `songState`
/// unless `songs` is given. `copiesRead` is 0.
func albumTestEntry(txn: String = albumTestTxn, state: DiscoverCopyState = .intent, hex: String? = nil,
                    songs: [DiscoverAlbumSong]? = nil, songCount: Int = 3,
                    songState: DiscoverAlbumSongState = .intent,
                    album: String = albumTestAlbum, albumID: String = albumTestAlbumID,
                    watching: Bool = false, containerGone: Bool? = nil,
                    priorShuffle: Bool? = nil, priorRepeat: String? = nil,
                    createdAt: Int = 5) -> DiscoverCopyEntry {
    DiscoverCopyEntry(txn: txn, playlistID: albumID, title: album, state: state, hex: hex,
                      copiesRead: 0, watching: watching, copySeen: false, toldAtLaunch: false,
                      priorShuffle: priorShuffle, priorRepeat: priorRepeat,
                      createdAt: createdAt, updatedAt: createdAt,
                      kind: .albumContainer,
                      containerName: discoverPlaylistPrefix + txn + discoverPlaylistNameSeparator + album,
                      containerGone: containerGone,
                      beforeFile: "before-\(txn).json",
                      songs: songs ?? (1...max(songCount, 1)).map { albumTestSong($0, state: songState) })
}
