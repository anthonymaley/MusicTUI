// The SpanDACs this Mac has paired with, at ~/.config/music/spandac/paired.json.
//
// What a pair is on this side (the pairing design, sections 3.3 item 8 and 3.5
// message 11): the SpanDAC's id and name, the pair's opaque TLS identity
// (`psk_id`), its TLS key (`K_pair`), the Bonjour service name it was found
// under, and the date. Plus this Mac's own `controller_id`, minted once.
//
// **A file, mode 0600, in a 0700 directory, never the login keychain.** The
// key authenticates this Mac to the SpanDAC, so the file is treated as a
// credential, like MusicTUI's other credential files beside it; and a CLI
// run from tmux or SSH cannot use the login keychain without a prompt it has
// no way to show (errSecInteractionNotAllowed), which is the failure this repo
// already paid for once. The same-user trust this relies on is stated in the
// design's attacker model (3.2): a compromised Mac account is out of scope.
//
// **Fail closed.** A directory that is not private, or a file that is not a
// regular 0600 file owned by this user, is refused rather than repaired: a
// key that may have been readable by others is not one to keep using quietly.
import Darwin
import Foundation

struct SpanDACPairRecord: Codable, Equatable {
    /// The SpanDAC's `spandac_id` (canonical uppercase UUID).
    let sourceID: String
    /// Its name as it was bound into the pairing transcript.
    let sourceName: String
    /// The pair's TLS identity: 32 lowercase hex characters.
    let pskID: String
    /// The pair's TLS pre-shared key, 32 bytes.
    let pairKey: Data
    /// The Bonjour service instance name the SpanDAC was found under.
    var serviceName: String
    let pairedAt: Date

    enum CodingKeys: String, CodingKey {
        case sourceID = "sid"
        case sourceName = "sname"
        case pskID = "psk_id"
        case pairKey = "k_pair"
        case serviceName = "service"
        case pairedAt = "paired_at"
    }

    /// Everything a usable record must satisfy; anything else in the file is
    /// dropped on read rather than used.
    var isWellFormed: Bool {
        SpanDACPair.isCanonicalID(sourceID) && SpanDACPair.isValidName(sourceName)
            && pskID.count == 32 && pskID == pskID.lowercased() && SpanDACPair.fromHex(pskID)?.count == 16
            && pairKey.count == 32 && !serviceName.isEmpty
    }
}

struct SpanDACPairedStoreError: Error, Equatable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SpanDACPairedStore {

    /// `~/.config/music/spandac/paired.json`, beside `mode.json`.
    static var livePath: String {
        NSString(string: "~/.config/music/spandac/paired.json").expandingTildeInPath
    }

    let path: String
    private let lock = NSLock()

    init(path: String = SpanDACPairedStore.livePath) {
        self.path = path
    }

    private struct Stored: Codable {
        var version: Int
        var controllerID: String
        var pairs: [SpanDACPairRecord]

        enum CodingKeys: String, CodingKey {
            case version
            case controllerID = "controller_id"
            case pairs
        }
    }

    // MARK: - Reads

    /// Every usable pair. A missing file is none; an unreadable or unsafe one
    /// is none too, and `load()` says why.
    func pairs() -> [SpanDACPairRecord] {
        (try? load())?.pairs ?? []
    }

    func pair(for sourceID: String) -> SpanDACPairRecord? {
        pairs().first { $0.sourceID == sourceID }
    }

    /// The pair for `sourceID`, or why there is none to use. Read fresh each
    /// time, so a forget in this process or another is honoured at the very
    /// next request.
    func lookup(_ sourceID: String) -> Result<SpanDACPairRecord, SpanDACLinkFailure> {
        do {
            guard let record = try load()?.pairs.first(where: { $0.sourceID == sourceID }) else {
                return .failure(.notPaired)
            }
            return .success(record)
        } catch {
            return .failure(.pairingsUnavailable((error as? SpanDACPairedStoreError)?.message ?? "\(error)"))
        }
    }

    /// Why pairings cannot be read, or nil when they can (a missing file can).
    func problem() -> String? {
        do { _ = try load(); return nil } catch {
            return (error as? SpanDACPairedStoreError)?.message ?? "\(error)"
        }
    }

    // MARK: - Writes

    /// This Mac's `controller_id`, minted and saved the first time it is asked
    /// for, the same ever after.
    func controllerID() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let stored = try loadLocked() { return stored.controllerID }
        let fresh = Stored(version: 1, controllerID: UUID().uuidString, pairs: [])
        try writeLocked(fresh)
        return fresh.controllerID
    }

    /// Saves `record`, replacing any earlier pair with the same SpanDAC (a
    /// re-pair mints a new identity and key; the old ones go).
    func save(_ record: SpanDACPairRecord) throws {
        guard record.isWellFormed else {
            throw SpanDACPairedStoreError(message: "the pair is not well formed")
        }
        lock.lock(); defer { lock.unlock() }
        var stored = try loadLocked() ?? Stored(version: 1, controllerID: UUID().uuidString, pairs: [])
        stored.pairs.removeAll { $0.sourceID == record.sourceID }
        stored.pairs.append(record)
        try writeLocked(stored)
    }

    /// Forgets the pair with `sourceID`. True when there was one.
    @discardableResult
    func forget(sourceID: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var stored = try loadLocked() else { return false }
        let before = stored.pairs.count
        stored.pairs.removeAll { $0.sourceID == sourceID }
        guard stored.pairs.count != before else { return false }
        try writeLocked(stored)
        return true
    }

    /// Records a new Bonjour service name for a paired SpanDAC (a name
    /// conflict on the network can rename it). Nothing else changes.
    func updateServiceName(_ name: String, for sourceID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var stored = try loadLocked(),
              let index = stored.pairs.firstIndex(where: { $0.sourceID == sourceID }),
              stored.pairs[index].serviceName != name, !name.isEmpty else { return }
        stored.pairs[index].serviceName = name
        try writeLocked(stored)
    }

    // MARK: - File

    private func load() throws -> Stored? {
        lock.lock(); defer { lock.unlock() }
        return try loadLocked()
    }

    private var directoryURL: URL { URL(fileURLWithPath: path).deletingLastPathComponent() }

    private func loadLocked() throws -> Stored? {
        var dirInfo = stat()
        if lstat(directoryURL.path, &dirInfo) != 0 {
            guard errno == ENOENT else { throw unsafe("its folder cannot be read (errno \(errno))") }
            return nil
        }
        guard PrivateDirectory.isPrivate(dirInfo) else {
            throw unsafe("its folder \(directoryURL.path) is not private to you (it must be mode 0700)")
        }
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw unsafe("it cannot be read (errno \(errno))") }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o600 else {
            throw unsafe("\(path) must be a file of yours with mode 0600")
        }
        let data: Data
        switch DurableFile.read(URL(fileURLWithPath: path)) {
        case .missing: return nil
        case .failed(let code): throw unsafe("it cannot be read (errno \(code))")
        case .contents(let contents): data = contents
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var stored = try? decoder.decode(Stored.self, from: data), stored.version == 1,
              SpanDACPair.isCanonicalID(stored.controllerID) else {
            throw unsafe("\(path) is not readable by this MusicTUI")
        }
        stored.pairs = stored.pairs.filter(\.isWellFormed)
        return stored
    }

    private func writeLocked(_ stored: Stored) throws {
        guard PrivateDirectory.prepare(directoryURL) else {
            throw unsafe("its folder \(directoryURL.path) could not be made private (mode 0700)")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        do {
            try DurableFile.replace(URL(fileURLWithPath: path), with: data)
        } catch let error as DurableFileError {
            throw unsafe("it could not be written (\(error.step), errno \(error.code))")
        }
    }

    private func unsafe(_ why: String) -> SpanDACPairedStoreError {
        SpanDACPairedStoreError(message: "SpanDAC pairings are unavailable: \(why).")
    }
}
