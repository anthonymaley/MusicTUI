// tools/music/Sources/TUI/DiscoverAlbumProof.swift
//
// The proof rule and the proof collector (album-cleanup score step A3). A song
// an album play added to his library may be removed when he stops ONLY when it
// is `owned`, and it becomes `owned` only when P1-P7 are all POSITIVELY
// observed (design 4.5). Every other outcome is `pending` (still inside its
// window, nothing failed), `preexisting` or `uncertain`. Nothing is assumed
// about how Apple folds an add.
//
// The rule is evaluated in CH13's order, each failure stopping evaluation:
// P1, the E-shape (P3's first half), P6, P2, P4, P3's second half, P5, P7.
// The pure stages below are what the collector composes; the collector only
// reads, never deletes, and uses no gate.
import Foundation

// MARK: P-read: one song's P3, P5 and P7 facts, read from Music.app (section 1.5)

/// What the P-read script answered for one entry hex. `matches` is how many
/// library tracks carry the hex; every other field is nil when `matches` is
/// not 1, or when its field came back empty or did not parse.
struct DiscoverAlbumEntryRead: Equatable {
    let matches: Int
    let title: String?
    let artist: String?
    let durationMS: Int?
    let dateAdded: Int?        // whole epoch seconds
    let cloudStatus: String?   // as read, untrimmed
}

/// The P-read body (run inside `tell application "Music"` by a `ScriptRunner`).
/// Fields are joined by ASCII 31: `count<US>N` when the hex does not name
/// exactly one library track, else `ok` and five fields: title, artist, length
/// in whole milliseconds, date added as ISO text, cloud status. A malformed
/// hex builds no script: the answer is the empty string, which no caller runs
/// (the collector reads only an E-shape-checked hex) and which parses as nil.
func discoverAlbumProofReadScript(hex: String) -> String {
    guard discoverCopyHexIsWellFormed(hex) else { return "" }
    return """
    set fieldSep to (ASCII character 31)
    set songHits to (every track of library playlist 1 whose persistent ID is "\(hex)")
    set hitCount to count of songHits
    if hitCount is not 1 then return "count" & fieldSep & (hitCount as text)
    set songRef to item 1 of songHits
    set titleText to ""
    try
        set titleText to (name of songRef) as text
    end try
    set artistText to ""
    try
        set artistText to (artist of songRef) as text
    end try
    set lengthText to ""
    try
        set lengthText to (round ((duration of songRef) * 1000) rounding as taught in school) as text
    end try
    set addedText to ""
    try
        set addedValue to date added of songRef
        set addedText to (addedValue as «class isot») as string
    end try
    set cloudText to ""
    try
        set cloudText to (cloud status of songRef) as text
    end try
    return "ok" & fieldSep & titleText & fieldSep & artistText & fieldSep & lengthText & fieldSep & addedText & fieldSep & cloudText
    """
}

private let discoverAlbumISODatePattern = try! NSRegularExpression(
    pattern: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"#)

/// CH10: `yyyy-MM-dd'T'HH:mm:ss`, `en_US_POSIX`, in `timeZone`, to whole
/// epoch seconds. Anything else is nil.
func discoverAlbumParseDateAdded(_ text: String, timeZone: TimeZone) -> Int? {
    let whole = NSRange(text.startIndex..., in: text)
    guard discoverAlbumISODatePattern.firstMatch(in: text, range: whole) != nil else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.isLenient = false
    guard let date = formatter.date(from: text) else { return nil }
    return Int(floor(date.timeIntervalSince1970))
}

/// nil = the call failed (no output) or the reply is neither `count<US>N`
/// (N a whole number) nor `ok` plus exactly five fields. Inside an `ok` reply
/// an empty field, or a length or date that does not parse, is a nil field.
func parseDiscoverAlbumEntryRead(_ output: String?, timeZone: TimeZone = .current) -> DiscoverAlbumEntryRead? {
    guard let output else { return nil }
    let separator = Character(UnicodeScalar(31))
    // osascript ends its output with a newline; strip line ends only, so a
    // trailing space inside the last field (cloud status) is kept for P7 to trim.
    let body = output.trimmingCharacters(in: .newlines)
    let fields = body.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
    if fields.count == 2, fields[0] == "count" {
        guard let matches = Int(fields[1].trimmingCharacters(in: .whitespaces)), matches >= 0 else { return nil }
        return DiscoverAlbumEntryRead(matches: matches, title: nil, artist: nil,
                                      durationMS: nil, dateAdded: nil, cloudStatus: nil)
    }
    guard fields.count == 6, fields[0] == "ok" else { return nil }
    func present(_ text: String) -> String? { text.isEmpty ? nil : text }
    let length = Int(fields[3].trimmingCharacters(in: .whitespaces))
    let added = discoverAlbumParseDateAdded(fields[4].trimmingCharacters(in: .whitespaces), timeZone: timeZone)
    return DiscoverAlbumEntryRead(matches: 1, title: present(fields[1]), artist: present(fields[2]),
                                  durationMS: length, dateAdded: added, cloudStatus: present(fields[5]))
}

/// NFC, then runs of whitespace collapsed to one space and the ends trimmed.
/// NO case fold: P3 keeps a capital-letter difference as a mismatch.
func discoverNormalizedStrict(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}

// MARK: The rule, in CH13's order

enum DiscoverAlbumVerdict: Equatable {
    case pending
    case owned(alias: String)
    case preexisting
    case uncertain(String)   // the reason, recorded as the song's uncertainReason (diagnostics)
}

/// e_i for `song`: E[position - 1] when E is recorded, as long as the slice,
/// every ID well-formed and all distinct, and the song's recorded entry hex
/// agrees with it; nil otherwise (the E-shape fails).
func discoverAlbumEntryHex(entry: DiscoverCopyEntry, song: DiscoverAlbumSong) -> String? {
    guard let ids = entry.entryIDs, let songs = entry.songs, ids.count == songs.count,
          ids.allSatisfy(discoverCopyHexIsWellFormed), Set(ids).count == ids.count,
          ids.indices.contains(song.position - 1) else { return nil }
    let hex = ids[song.position - 1]
    guard song.entryHex == hex else { return nil }
    return hex
}

/// The verdicts that need no read from Music.app or SpanDAC, for one `pending`
/// song: P1, the E-shape, P6, P2, then the window. `.pending` means none of
/// them decided and evaluation goes on. `beforeSet` is asked only when P6 is
/// reached; nil from it is B unreadable.
///
/// - P1: `relationsBefore` is exactly `[0, 0]`. A count of 1 or more is
///   `preexisting`; a shape that is not two non-negative counts cannot be
///   evaluated and is `uncertain`.
/// - The window closes (`now` past `writeSentAt + proofWindow`) only for a
///   song whose P4 has not held yet (no alias recorded); a held song waits for
///   its P-read, which has no window.
func discoverAlbumVerdictBeforeReads(entry: DiscoverCopyEntry, song: DiscoverAlbumSong,
                                     beforeSet: () -> Set<String>?, now: Date) -> DiscoverAlbumVerdict {
    // P1
    let before = song.relationsBefore
    guard before.count == 2, before.allSatisfy({ $0 >= 0 }) else { return .uncertain("p1_unreadable") }
    guard before == [0, 0] else { return .preexisting }
    // E-shape (P3, first half)
    guard let hex = discoverAlbumEntryHex(entry: entry, song: song) else { return .uncertain("e_shape") }
    // P6
    guard let beforeIDs = beforeSet() else { return .uncertain("p6_unreadable") }
    if beforeIDs.contains(hex) { return .preexisting }
    // P2
    switch entry.state {
    case .owned, .listening: break
    case .intent: return .uncertain("p2_container_unknown")
    case .uncertain, .closed, .preexisting: return .uncertain("p2_not_ours")
    }
    // The window (P4's bound)
    guard let sent = entry.writeSentAt else { return .uncertain("no_write_time") }
    if song.alias == nil, now.timeIntervalSince1970 > sent + DiscoverAlbumTiming.proofWindow {
        return .uncertain("window_closed")
    }
    return .pending
}

/// One collector read of P4 for one song.
enum DiscoverAlbumP4Step: Equatable {
    case notYet(firstSeenAt: Double?)            // stays pending; the streak start to record
    case held(alias: String, firstSeenAt: Double)
    case uncertain(String)
}

/// P4 over consecutive reads. `aliases` is this read's answer for c_i (nil =
/// unreadable: the reply failed or left the id out, CH12).
/// - `[]` or `[null]` (CH11): not yet, and the streak is cleared.
/// - exactly `[a]` with `persistentIDHex(fromAlias: a) == entryHex`: starts the
///   streak if none, and HOLDS once the streak's first read is at least
///   `p4MinGap` earlier (the first of the two reads is what is recorded, CH7).
/// - `[a]` with any other hex, two or more relations, or unreadable: uncertain.
/// The caller applies it only inside the window.
func discoverAlbumP4Step(entryHex: String, firstSeenAt: Double?, aliases: [String?]?,
                         now: Date) -> DiscoverAlbumP4Step {
    guard let aliases else { return .uncertain("p4_unreadable") }
    switch aliases.count {
    case 0:
        return .notYet(firstSeenAt: nil)
    case 1:
        guard let alias = aliases[0] else { return .notYet(firstSeenAt: nil) }
        guard persistentIDHex(fromAlias: alias) == entryHex else { return .uncertain("p4_other_row") }
        let nowSeconds = now.timeIntervalSince1970
        guard let first = firstSeenAt else { return .notYet(firstSeenAt: nowSeconds) }
        if nowSeconds - first >= DiscoverAlbumTiming.p4MinGap {
            return .held(alias: alias, firstSeenAt: first)
        }
        return .notYet(firstSeenAt: first)
    default:
        return .uncertain("p4_several_relations")
    }
}

/// P3's second half, P5 and P7 from one P-read of e_i, for a song whose P4
/// has held with `alias`. All holding is `owned(alias:)`; anything else,
/// including a nil read or any nil field, is `uncertain`.
func discoverAlbumVerdictAfterRead(entry: DiscoverCopyEntry, song: DiscoverAlbumSong, alias: String,
                                   read: DiscoverAlbumEntryRead?) -> DiscoverAlbumVerdict {
    // P3, second half
    guard let read else { return .uncertain("p3_unreadable") }
    guard read.matches == 1 else { return .uncertain("p3_matches") }
    guard let title = read.title, let artist = read.artist else { return .uncertain("p3_unreadable") }
    guard discoverNormalizedStrict(song.title) == discoverNormalizedStrict(title) else {
        return .uncertain("p3_title")
    }
    guard discoverNormalizedStrict(song.artist) == discoverNormalizedStrict(artist) else {
        return .uncertain("p3_artist")
    }
    guard let rowLength = song.durationMS, let readLength = read.durationMS else {
        return .uncertain("p3_unreadable")
    }
    guard abs(rowLength - readLength) < 1000 else { return .uncertain("p3_length") }
    // P5: date added in [S, S + 2 s], S = floor(writeSentAt), inclusive
    guard let sent = entry.writeSentAt, let added = read.dateAdded else { return .uncertain("p5_unreadable") }
    let windowStart = Int(floor(sent))
    guard added >= windowStart, added <= windowStart + DiscoverAlbumTiming.p5LateSlack else {
        return .uncertain("p5_date_added")
    }
    // P7
    guard let cloud = read.cloudStatus else { return .uncertain("p7_unreadable") }
    guard cloud.trimmingCharacters(in: .whitespacesAndNewlines) == "subscription" else {
        return .uncertain("p7_cloud_status")
    }
    return .owned(alias: alias)
}

/// Writes one verdict onto a song. `owned` sets state, alias and cloud status
/// together (the journal's owned-song invariant holds in the same update).
/// `pending` changes nothing.
private func discoverAlbumApply(_ verdict: DiscoverAlbumVerdict, to song: inout DiscoverAlbumSong,
                                cloudStatus: String?) {
    switch verdict {
    case .pending:
        return
    case .owned(let alias):
        song.state = .owned
        song.alias = alias
        song.cloudStatus = cloudStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
    case .preexisting:
        song.state = .preexisting
    case .uncertain(let reason):
        song.state = .uncertain
        song.uncertainReason = reason
        if let cloudStatus { song.cloudStatus = cloudStatus }
    }
}

// MARK: The collector

/// Proves each `pending` song of an adopted album entry, or rules it out.
///
/// `tick()` (the poller's 1 s tick) enqueues ONE item per adopted entry whose
/// last read is at least `collectorCadence` old and has no item outstanding.
/// The item (a) re-reads the entry; (b) applies the no-read verdicts (P1,
/// E-shape, P6, P2, window closed) to every pending song, whatever data
/// source is selected; (c) only while SpanDAC data is selected, reads
/// relations for every song still pending whose P4 has not held, in one call,
/// and applies P4; (d) enqueues one P-read item per song whose P4 has held
/// (CH14), which finishes P3, P5 and P7. Each batch of terminal verdicts is
/// written, then `settled(txn)` is called; an `owned` verdict written while the
/// container reads gone also calls `ownedAfterEnd(txn, position)` first. An
/// entry with no pending song left is dropped. It never deletes.
final class DiscoverAlbumProofCollector {
    struct Seams {
        var journal: DiscoverCopyJournalStore
        var beforeSet: DiscoverBeforeSetStore
        var relations: () -> SpanDACLibraryRelationsReading
        var readEntry: (_ hex: String) -> DiscoverAlbumEntryRead?
        var spandacDataSelected: () -> Bool
        var now: () -> Date
        var enqueue: (@escaping () -> Void) -> Void           // the action queue, quiet
        var ownedAfterEnd: (_ txn: String, _ position: Int) -> Void
        var settled: (_ txn: String) -> Void
        var log: (String) -> Void
    }

    private struct Adopted {
        var lastReadAt: Date?
        var outstanding = false
        var proofReadsOutstanding: Set<Int> = []
    }

    private let seams: Seams
    private let lock = NSLock()
    private var adopted: [String: Adopted] = [:]

    init(seams: Seams) { self.seams = seams }

    /// Thread-safe. Adopting an entry already adopted changes nothing.
    func adopt(txn: String) {
        lock.lock()
        if adopted[txn] == nil { adopted[txn] = Adopted() }
        lock.unlock()
    }

    /// The txns currently adopted, sorted (diagnostics and tests).
    var adoptedTxns: [String] {
        lock.lock(); defer { lock.unlock() }
        return adopted.keys.sorted()
    }

    /// The poller's 1 s tick; no work while nothing is adopted.
    func tick() {
        lock.lock()
        guard !adopted.isEmpty else { lock.unlock(); return }
        let now = seams.now()
        var due: [String] = []
        for txn in adopted.keys.sorted() {
            guard var state = adopted[txn], !state.outstanding else { continue }
            if let last = state.lastReadAt,
               now.timeIntervalSince(last) < DiscoverAlbumTiming.collectorCadence { continue }
            state.outstanding = true
            adopted[txn] = state
            due.append(txn)
        }
        lock.unlock()
        for txn in due { seams.enqueue { [self] in self.collect(txn: txn) } }
    }

    private func drop(_ txn: String) {
        lock.lock(); adopted[txn] = nil; lock.unlock()
    }

    // MARK: The entry item

    private func collect(txn: String) {
        let now = seams.now()
        lock.lock()
        adopted[txn]?.lastReadAt = now
        lock.unlock()
        defer {
            lock.lock(); adopted[txn]?.outstanding = false; lock.unlock()
        }

        // (a) re-read the entry. An unreadable journal does nothing (the shipped
        // rule); the entry stays adopted and is read again next cadence.
        let entry: DiscoverCopyEntry
        do {
            guard let found = try seams.journal.entries().first(where: { $0.txn == txn }),
                  found.kind == .albumContainer, let songs = found.songs else {
                seams.log("album proof \(txn): no album entry; dropped")
                drop(txn)
                return
            }
            guard songs.contains(where: { $0.state == .pending }) else { drop(txn); return }
            entry = found
        } catch {
            seams.log("album proof \(txn): journal unreadable: \(error)")
            return
        }
        let songs = entry.songs ?? []

        // B, read at most once per item and only when a song reaches P6.
        var beforeCache: Set<String>??
        let beforeSet: () -> Set<String>? = { [seams] in
            if let cached = beforeCache { return cached }
            var read: Set<String>?
            if let file = entry.beforeFile {
                read = try? seams.beforeSet.readBeforeSet(file: file)
            }
            beforeCache = .some(read)
            return read
        }

        // (b) the no-read verdicts
        var verdicts: [Int: DiscoverAlbumVerdict] = [:]
        var streaks: [Int: Double?] = [:]
        var held: [Int: String] = [:]
        for song in songs where song.state == .pending {
            let verdict = discoverAlbumVerdictBeforeReads(entry: entry, song: song, beforeSet: beforeSet, now: now)
            if verdict != .pending { verdicts[song.position] = verdict }
        }

        // (c) P4, only while SpanDAC data is selected
        if seams.spandacDataSelected(), let sent = entry.writeSentAt, now.timeIntervalSince1970 >= sent {
            let asking = songs.filter { $0.state == .pending && $0.alias == nil && verdicts[$0.position] == nil }
            if !asking.isEmpty {
                var answer: [String: [String?]]?
                do {
                    answer = try seams.relations().relations(catalogueIDs: asking.map(\.catalogueID))
                } catch {
                    seams.log("album proof \(txn): relations unreadable: \(error)")
                    answer = nil
                }
                for song in asking {
                    guard let hex = discoverAlbumEntryHex(entry: entry, song: song) else {
                        verdicts[song.position] = .uncertain("e_shape")
                        continue
                    }
                    let aliases = answer.flatMap { $0[song.catalogueID] }
                    switch discoverAlbumP4Step(entryHex: hex, firstSeenAt: song.p4FirstSeenAt,
                                               aliases: aliases, now: now) {
                    case .notYet(let first):
                        if first != song.p4FirstSeenAt { streaks.updateValue(first, forKey: song.position) }
                    case .held(let alias, let first):
                        held[song.position] = alias
                        streaks.updateValue(first, forKey: song.position)
                    case .uncertain(let reason):
                        verdicts[song.position] = .uncertain(reason)
                    }
                }
            }
        }

        // Write every verdict and streak change of this item in one update.
        var updated = entry
        if !verdicts.isEmpty || !streaks.isEmpty || !held.isEmpty {
            var decided = 0
            do {
                updated = try seams.journal.update(txn: txn) { current in
                    guard var all = current.songs else { return }
                    for index in all.indices where all[index].state == .pending {
                        let position = all[index].position
                        if let verdict = verdicts[position] {
                            discoverAlbumApply(verdict, to: &all[index], cloudStatus: nil)
                            decided += 1
                            continue
                        }
                        if let first = streaks[position] { all[index].p4FirstSeenAt = first }
                        if let alias = held[position] { all[index].alias = alias }
                    }
                    current.songs = all
                }
            } catch {
                seams.log("album proof \(txn): verdict write failed: \(error)")
                return
            }
            if decided > 0 { seams.settled(txn) }
        }

        // (d) one P-read item per song whose P4 has held and has none outstanding
        let ready = (updated.songs ?? []).filter { $0.state == .pending && $0.alias != nil }
        lock.lock()
        var reads: [Int] = []
        if var state = adopted[txn] {
            for song in ready where !state.proofReadsOutstanding.contains(song.position) {
                state.proofReadsOutstanding.insert(song.position)
                reads.append(song.position)
            }
            adopted[txn] = state
        }
        lock.unlock()
        for position in reads {
            seams.enqueue { [self] in self.proofRead(txn: txn, position: position) }
        }

        if !(updated.songs ?? []).contains(where: { $0.state == .pending }) { drop(txn) }
    }

    // MARK: The P-read item (one song, CH14)

    private func proofRead(txn: String, position: Int) {
        defer {
            lock.lock(); adopted[txn]?.proofReadsOutstanding.remove(position); lock.unlock()
        }
        let entry: DiscoverCopyEntry
        do {
            guard let found = try seams.journal.entries().first(where: { $0.txn == txn }) else { return }
            entry = found
        } catch {
            seams.log("album proof \(txn) #\(position): journal unreadable: \(error)")
            return
        }
        guard let song = entry.songs?.first(where: { $0.position == position }),
              song.state == .pending, let alias = song.alias,
              let hex = discoverAlbumEntryHex(entry: entry, song: song) else { return }

        let read = seams.readEntry(hex)
        let verdict = discoverAlbumVerdictAfterRead(entry: entry, song: song, alias: alias, read: read)
        let updated: DiscoverCopyEntry
        var applied = false
        do {
            updated = try seams.journal.update(txn: txn) { current in
                guard var all = current.songs,
                      let index = all.firstIndex(where: { $0.position == position }),
                      all[index].state == .pending, all[index].alias == alias else { return }
                discoverAlbumApply(verdict, to: &all[index], cloudStatus: read?.cloudStatus)
                current.songs = all
                applied = true
            }
        } catch {
            seams.log("album proof \(txn) #\(position): verdict write failed: \(error)")
            return
        }
        guard applied, verdict != .pending else { return }
        if case .owned = verdict, updated.containerGone == true {
            seams.ownedAfterEnd(txn, position)
        }
        seams.settled(txn)
        if !(updated.songs ?? []).contains(where: { $0.state == .pending }) { drop(txn) }
    }
}
