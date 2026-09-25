import Foundation

/// A play record that was replaced while this journal still had a cursor in it.
struct RetiredLedger: Codable, Equatable {
    let ledgerID: String
    let consumedThrough: Int
    /// Epoch seconds.
    let retiredAt: Int

    enum CodingKeys: String, CodingKey {
        case ledgerID = "ledger_id"
        case consumedThrough = "consumed_through"
        case retiredAt = "retired_at"
    }
}

/// Everything play sync remembers between passes: how far into Bridge's play
/// record it has read, and every captured play until it is recorded or set
/// aside.
///
/// It is the barrier against counting a play twice. It is only ever read and
/// written inside a pass, under the play-sync lock, and a file that cannot be
/// read is never treated as empty.
struct PlaySyncJournal: Codable, Equatable {
    static let currentFormat = 1

    var format = PlaySyncJournal.currentFormat
    /// The play record `consumedThrough` belongs to; nil means no cursor yet,
    /// and then `consumedThrough` is 0.
    var ledgerID: String?
    /// The highest seq captured into `entries` (captured, not recorded).
    var consumedThrough: Int
    /// In fetch order, which is also processing order.
    var entries: [PlaySyncEntry]
    var retiredLedgers: [RetiredLedger]

    enum CodingKeys: String, CodingKey {
        case format
        case ledgerID = "ledger_id"
        case consumedThrough = "consumed_through"
        case entries
        case retiredLedgers = "retired_ledgers"
    }

    static let empty = PlaySyncJournal(ledgerID: nil, consumedThrough: 0, entries: [], retiredLedgers: [])
}

extension PlaySyncJournal {

    enum Load: Equatable {
        case loaded(PlaySyncJournal)
        /// Present but not readable as a journal: unreadable bytes, a failed
        /// read, a missing field, or entries that break the journal's rules.
        case unreadable
        /// Written by a newer MusicTUI.
        case tooNew
    }

    /// A missing file is an empty journal. Anything else that fails is
    /// `unreadable` or `tooNew`, never empty.
    static func load(from url: URL) -> Load {
        switch DurableFile.read(url) {
        case .missing: return .loaded(.empty)
        case .failed: return .unreadable
        case .contents(let data): return decode(data)
        }
    }

    static func decode(_ data: Data) -> Load {
        struct FormatProbe: Decodable { let format: Int }
        guard let probe = try? JSONDecoder().decode(FormatProbe.self, from: data) else { return .unreadable }
        if probe.format > currentFormat { return .tooNew }
        guard probe.format == currentFormat,
              let journal = try? JSONDecoder().decode(PlaySyncJournal.self, from: data),
              journal.isConsistent else {
            return .unreadable
        }
        return .loaded(journal)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Replaces the journal file durably and atomically (mode 0600).
    func save(to url: URL) throws {
        try DurableFile.replace(url, with: try encoded())
    }

    /// The rules a journal written by this code always satisfies. A file that
    /// breaks them is not guessed at.
    var isConsistent: Bool {
        guard consumedThrough >= 0, ledgerID != nil || consumedThrough == 0 else { return false }
        for entry in entries {
            if entry.state != .done, entry.state != .unmatched, entry.state != .conflict,
               entry.phase == .dateOnly, entry.target?.date == nil {
                return false   // a date-only write needs the date it is writing
            }
            switch entry.state {
            case .writing, .unresolved:
                // An attempt that may still land must say what it was aiming at,
                // what it started from, and which Music.app received it.
                guard entry.persistentID != nil, entry.attempt != nil,
                      entry.before != nil, entry.target != nil else { return false }
            case .pending:
                if entry.phase == .dateOnly || entry.target != nil {
                    guard entry.persistentID != nil, entry.before != nil, entry.target != nil else { return false }
                }
            case .done, .unmatched, .conflict:
                break
            }
        }
        return true
    }

    /// A `writing` entry found at load was interrupted somewhere around its set
    /// call, so whether that call took effect is unknown: it becomes
    /// `unresolved`, keeping its phase, target and attempt.
    mutating func recoverInterruptedWrites() {
        for index in entries.indices where entries[index].state == .writing {
            entries[index].state = .unresolved
            entries[index].reported = false
        }
    }

    /// Keeps the newest `keepingDone` recorded entries. No other entry is ever
    /// removed: every other state is either still to be written or still to be
    /// reported.
    mutating func compact(keepingDone limit: Int) {
        let doneCount = entries.reduce(0) { $0 + ($1.state == .done ? 1 : 0) }
        var toDrop = doneCount - max(0, limit)
        guard toDrop > 0 else { return }
        var kept: [PlaySyncEntry] = []
        kept.reserveCapacity(entries.count - toDrop)
        for entry in entries {
            if toDrop > 0, entry.state == .done {
                toDrop -= 1   // the oldest recorded entries go first
            } else {
                kept.append(entry)
            }
        }
        entries = kept
    }
}
