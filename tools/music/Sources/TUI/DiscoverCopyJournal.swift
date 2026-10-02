// tools/music/Sources/TUI/DiscoverCopyJournal.swift
//
// The durable record behind Discover "play from here" on Apple's own copy of a
// playlist (score step C2, design section 5). Ownership of a library playlist
// can only be proven by what MusicTUI watched itself do, so every risky step is
// written here, on the disk itself, BEFORE it is taken. A file that cannot be
// read is never treated as empty and never overwritten: an empty journal would
// say "MusicTUI owns nothing", and a rewritten one would lose the evidence.
import Foundation

/// Where the journal and its lock live. Tests always pass a temporary
/// directory; only production uses `.live`.
struct DiscoverCopyPaths: Equatable {
    let directory: URL
    var journal: URL { directory.appendingPathComponent("journal.json") }
    var lock: URL { directory.appendingPathComponent("lock") }
    static var live: DiscoverCopyPaths {
        DiscoverCopyPaths(directory: URL(fileURLWithPath: NSHomeDirectory() + "/.config/music/discover-copies"))
    }
}

/// The newest format this build reads and the one it writes.
let discoverCopyJournalFormat = 1

/// How many closed entries are kept (CH8). One still holding prior modes is
/// never pruned, and neither is anything that is not `closed`.
let discoverCopyJournalClosedKept = 20

/// Sixteen uppercase hex digits: `persistentIDHex`'s shape.
func discoverCopyHexIsWellFormed(_ hex: String) -> Bool {
    hex.utf8.count == 16 && hex.utf8.allSatisfy {
        ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
            || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "F"))
    }
}

/// The invariants a journal entry must hold on disk: an `owned` or `listening`
/// entry names the copy by a well-formed hex, and an `intent` entry names none
/// (an intent is written before anything exists to name).
func discoverCopyEntryHoldsInvariants(_ entry: DiscoverCopyEntry) -> Bool {
    switch entry.state {
    case .owned, .listening:
        guard let hex = entry.hex else { return false }
        return discoverCopyHexIsWellFormed(hex)
    case .intent:
        return entry.hex == nil
    case .uncertain, .closed, .preexisting:
        return true
    }
}

/// CH8: drops all but the newest `discoverCopyJournalClosedKept` closed entries
/// that hold no prior modes. Order is kept; nothing else is touched.
func discoverCopyJournalPruned(_ entries: [DiscoverCopyEntry]) -> [DiscoverCopyEntry] {
    func prunable(_ entry: DiscoverCopyEntry) -> Bool {
        entry.state == .closed && entry.priorShuffle == nil && entry.priorRepeat == nil
    }
    var excess = entries.filter(prunable).count - discoverCopyJournalClosedKept
    guard excess > 0 else { return entries }
    return entries.filter { entry in
        guard excess > 0, prunable(entry) else { return true }
        excess -= 1
        return false
    }
}

final class FileDiscoverCopyJournalStore: DiscoverCopyJournalStore {

    private struct Header: Decodable { let format: Int }
    private struct Body: Codable {
        let format: Int
        let entries: [DiscoverCopyEntry]
    }

    private let paths: DiscoverCopyPaths

    init(paths: DiscoverCopyPaths) { self.paths = paths }

    func entries() throws -> [DiscoverCopyEntry] {
        switch PlaySyncLock.acquire(paths.lock, waitingUpTo: 2) {
        case .failure(.busy):
            throw DiscoverCopyJournalError.busy
        case .failure(.unavailable(let code)):
            // No directory yet means nothing was ever written. Anything else
            // is a journal that cannot be read, which is not an empty one.
            if code == ENOENT, !directoryExists() { return [] }
            throw DiscoverCopyJournalError.unreadable
        case .success(let lock):
            defer { lock.release() }
            return try readLocked()
        }
    }

    func insert(_ entry: DiscoverCopyEntry) throws {
        guard discoverCopyEntryHoldsInvariants(entry) else {
            throw DiscoverCopyJournalError.writeFailed("invariant")
        }
        try mutate { current in
            guard !current.contains(where: { $0.txn == entry.txn }) else {
                throw DiscoverCopyJournalError.writeFailed("duplicate txn")
            }
            current.append(entry)
            current = discoverCopyJournalPruned(current)
        }
    }

    @discardableResult
    func update(txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        var result: DiscoverCopyEntry?
        try mutate { current in
            guard let index = current.firstIndex(where: { $0.txn == txn }) else {
                throw DiscoverCopyJournalError.notFound
            }
            var next = current[index]
            change(&next)
            guard discoverCopyEntryHoldsInvariants(next) else {
                throw DiscoverCopyJournalError.writeFailed("invariant")
            }
            current[index] = next
            result = next
        }
        guard let result else { throw DiscoverCopyJournalError.notFound }
        return result
    }

    // MARK: Under the lock

    /// One whole read-modify-write under the cross-process lock. The file is
    /// read first, so an unreadable or too-new journal throws before anything
    /// is written and is left exactly as it was.
    private func mutate(_ body: (inout [DiscoverCopyEntry]) throws -> Void) throws {
        guard PrivateDirectory.prepare(paths.directory) else {
            throw DiscoverCopyJournalError.writeFailed("directory")
        }
        switch PlaySyncLock.acquire(paths.lock, waitingUpTo: 2) {
        case .failure(.busy):
            throw DiscoverCopyJournalError.busy
        case .failure(.unavailable(let code)):
            throw DiscoverCopyJournalError.writeFailed("lock: \(code)")
        case .success(let lock):
            defer { lock.release() }
            var current = try readLocked()
            try body(&current)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            do {
                data = try encoder.encode(Body(format: discoverCopyJournalFormat, entries: current))
            } catch {
                throw DiscoverCopyJournalError.writeFailed("encode")
            }
            do {
                try DurableFile.replace(paths.journal, with: data)
            } catch let error as DurableFileError {
                throw DiscoverCopyJournalError.writeFailed("\(error.step): \(error.code)")
            } catch {
                throw DiscoverCopyJournalError.writeFailed(error.localizedDescription)
            }
        }
    }

    private func readLocked() throws -> [DiscoverCopyEntry] {
        switch DurableFile.read(paths.journal) {
        case .missing:
            return []
        case .failed:
            throw DiscoverCopyJournalError.unreadable
        case .contents(let data):
            let decoder = JSONDecoder()
            guard let header = try? decoder.decode(Header.self, from: data), header.format >= 1 else {
                throw DiscoverCopyJournalError.unreadable
            }
            guard header.format <= discoverCopyJournalFormat else {
                throw DiscoverCopyJournalError.tooNew
            }
            guard let body = try? decoder.decode(Body.self, from: data),
                  body.entries.allSatisfy(discoverCopyEntryHoldsInvariants) else {
                throw DiscoverCopyJournalError.unreadable
            }
            return body.entries
        }
    }

    private func directoryExists() -> Bool {
        var info = stat()
        return lstat(paths.directory.path, &info) == 0
    }
}
