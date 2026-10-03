// tools/music/Sources/TUI/DiscoverAlbumReconcile.swift
//
// The album branch of the Discover journal replay (album-cleanup score step
// A5, design 4.7; CH17). It runs at launch, after the launch sweep, and before
// every Discover play, through `DiscoverCopyReconciler.albumReplay`; the
// shipped reconciler runs the guarded mode restore after it for every entry.
//
// It never deletes a song and never runs a song-guard script inline: every
// `owned` song goes to `DiscoverAlbumCleaner.handToGuard`, which puts one item
// per song on the action queue. A read it cannot make (the container by name,
// the relations) changes nothing and waits for the next reconcile.
import Foundation

// MARK: F-script: the container by its exact name

/// AppleScript body (no `tell` wrapper) that lists the persistent ID of every
/// user playlist whose name is exactly `name`, case included, one per line
/// after a first line `ok`. The name is escaped; it carries his album title.
func discoverAlbumFindContainerScript(name: String) -> String {
    let escaped = escapeAppleScriptString(name)
    return """
    set foundText to ""
    set userLists to every user playlist
    repeat with plRef in userLists
        set plNameText to ""
        try
            set plNameText to (name of plRef) as text
        end try
        considering case
            if plNameText is "\(escaped)" then
                set foundText to foundText & ((persistent ID of plRef) as text) & linefeed
            end if
        end considering
    end repeat
    return "ok" & linefeed & foundText
    """
}

/// The F-script's answer: the hexes found, possibly none. nil (unreadable) for
/// a nil run, a first line that is not `ok`, or any later line that is not a
/// well-formed persistent ID (sixteen `0-9A-F`). Blank lines are ignored.
func parseDiscoverAlbumFoundContainers(_ output: String?) -> [String]? {
    guard let output else { return nil }
    let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let first = lines.first(where: { !$0.isEmpty }), first == "ok" else { return nil }
    var hexes: [String] = []
    var seenOK = false
    for line in lines where !line.isEmpty {
        if !seenOK {
            seenOK = true
            continue
        }
        guard discoverCopyHexIsWellFormed(line) else { return nil }
        hexes.append(line)
    }
    return hexes
}

// MARK: The replay

struct DiscoverAlbumReconciler {
    struct Seams {
        var journal: DiscoverCopyJournalStore
        var beforeSet: DiscoverBeforeSetStore
        var relations: () -> SpanDACLibraryRelationsReading
        var findContainers: (_ name: String) -> [String]?     // nil = unreadable
        var readEntryIDs: (_ hex: String) -> [String]?        // the shipped K8 read(hex:k:1).ids
        var deleteIfOwned: (_ txn: String) -> DiscoverCopyDeleteResult
        var adopt: (_ txn: String, _ hex: String) -> Void
        var startProof: (_ txn: String) -> Void
        var cleaner: DiscoverAlbumCleaner
        var spandacDataSelected: () -> Bool
        var post: (DiscoverToast) -> Void
        var now: () -> Date
        var log: (String) -> Void
    }

    private let seams: Seams

    init(seams: Seams) { self.seams = seams }

    /// What a state's branch left for the steps after it.
    private enum Next { case continueOn, closed }

    /// One album entry, for its state (design 4.7):
    /// - `closed`: nothing.
    /// - `intent` with no `writeSentAt`: nothing was sent; closed, side file deleted.
    /// - `intent` with `writeSentAt`, or `uncertain` from an unknown outcome:
    ///   only while SpanDAC data is selected, the container by its exact name:
    ///   one -> `owned` with that hex and E read now, then as `owned`; none ->
    ///   one relations read, every song still to prove at no relation ->
    ///   closed, otherwise `uncertain` (`not_created`); two or more ->
    ///   `uncertain` (`several`). An unreadable read waits.
    /// - `owned` / `listening`: the container through the deletion guard
    ///   (`.spared` re-adopts and goes no further, `.failed` goes no further),
    ///   then each `owned` song to the cleaner, each `pending` song past its
    ///   window `uncertain`, and the proof collector for any still pending.
    /// - `uncertain` for any other reason: every song not yet terminal `uncertain`.
    /// Then, at launch only, every `uncertain` song not yet told is named in
    /// one line and marked, and the cleaner settles the entry.
    func replay(_ entry: DiscoverCopyEntry, atLaunch: Bool) {
        guard entry.kind == .albumContainer, entry.songs != nil else { return }
        let txn = entry.txn
        switch entry.state {
        case .closed:
            return
        case .intent where entry.writeSentAt == nil:
            close(entry)
            return
        case .intent:
            if resolveOutcome(entry, atLaunch: atLaunch) == .closed { return }
        case .uncertain where entry.uncertainReason == "outcome_unknown":
            if resolveOutcome(entry, atLaunch: atLaunch) == .closed { return }
        case .owned, .listening:
            replayPlayed(txn)
        case .uncertain:
            markUnfinishedUncertain(txn, reason: entry.uncertainReason ?? "uncertain")
        case .preexisting:
            break
        }
        if atLaunch { tellAtLaunch(txn) }
        seams.cleaner.settle(txn: txn)
    }

    // MARK: Branches

    /// `intent` with `writeSentAt`, or `uncertain` with `outcome_unknown`.
    private func resolveOutcome(_ entry: DiscoverCopyEntry, atLaunch: Bool) -> Next {
        let txn = entry.txn
        guard seams.spandacDataSelected() else { return .continueOn }
        guard let name = entry.containerName, let found = seams.findContainers(name) else {
            seams.log("discover album reconcile \(txn): container not readable by name; waiting")
            return .continueOn
        }
        switch found.count {
        case 1:
            let hex = found[0]
            let ids = seams.readEntryIDs(hex).flatMap { ids in
                ids.allSatisfy(discoverCopyHexIsWellFormed) ? ids : nil
            }
            do {
                try update(txn) { entry in
                    entry.state = .owned
                    entry.hex = hex
                    entry.uncertainReason = nil
                    guard let ids else { return }      // E unset: P3 then fails
                    entry.entryIDs = ids
                    guard var songs = entry.songs, ids.count == songs.count else { return }
                    for index in songs.indices where songs[index].state != .owned && songs[index].state != .deleted {
                        songs[index].entryHex = ids[songs[index].position - 1]
                    }
                    entry.songs = songs
                }
            } catch {
                seams.log("discover album reconcile \(txn): could not record the container: \(error)")
                return .continueOn
            }
            replayPlayed(txn)
            return .continueOn
        case 0:
            let songs = entry.songs ?? []
            let unproven = songs.filter { !$0.state.isTerminal }.map(\.catalogueID)
            if !unproven.isEmpty {
                let read: [String: [String?]]
                do {
                    read = try seams.relations().relations(catalogueIDs: unproven)
                } catch {
                    seams.log("discover album reconcile \(txn): relations not readable; waiting: \(error)")
                    return .continueOn
                }
                guard unproven.allSatisfy({ read[$0] != nil }) else {
                    seams.log("discover album reconcile \(txn): relations reply incomplete; waiting")
                    return .continueOn
                }
                if !unproven.allSatisfy({ read[$0]?.isEmpty == true }) {
                    makeUncertain(entry, reason: "not_created", atLaunch: atLaunch)
                    return .continueOn
                }
            }
            close(entry)
            return .closed
        default:
            makeUncertain(entry, reason: "several", atLaunch: atLaunch)
            return .continueOn
        }
    }

    /// `owned` / `listening`: the container, then the songs.
    private func replayPlayed(_ txn: String) {
        guard let entry = albumEntry(txn) else { return }
        if entry.containerGone != true {
            switch seams.deleteIfOwned(txn) {
            case .spared:
                do {
                    let updated = try update(txn) { entry in
                        entry.watching = true
                        if entry.state == .owned { entry.state = .listening }
                    }
                    if let hex = updated.hex { seams.adopt(txn, hex) }
                } catch {
                    seams.log("discover album reconcile \(txn): journal write failed: \(error)")
                    if let hex = entry.hex { seams.adopt(txn, hex) }
                }
                return
            case .failed:
                return      // the container is left for the next reconcile
            case .deleted, .alreadyGone, .kept:
                break
            }
        }
        guard let current = albumEntry(txn), let songs = current.songs else { return }
        for song in songs where song.state == .owned {
            seams.cleaner.handToGuard(txn: txn, position: song.position)
        }
        let nowSeconds = seams.now().timeIntervalSince1970
        let windowClosed: Bool = {
            guard let sent = current.writeSentAt else { return true }      // no window to prove in
            return nowSeconds > sent + DiscoverAlbumTiming.proofWindow
        }()
        let unproven = songs.filter { $0.state == .pending || $0.state == .intent }
        guard !unproven.isEmpty else { return }
        if windowClosed {
            do {
                try update(txn) { entry in
                    guard var songs = entry.songs else { return }
                    for index in songs.indices where songs[index].state == .pending || songs[index].state == .intent {
                        songs[index].state = .uncertain
                        songs[index].uncertainReason = "window"
                    }
                    entry.songs = songs
                }
            } catch {
                seams.log("discover album reconcile \(txn): journal write failed: \(error)")
            }
        } else {
            seams.startProof(txn)
        }
    }

    /// Two or more containers by the name, or none while a relation reads:
    /// the entry and every song not yet terminal become `uncertain`, and he is
    /// told. At launch the launch line tells him (once); before a play, here,
    /// and the next launch repeats it.
    private func makeUncertain(_ entry: DiscoverCopyEntry, reason: String, atLaunch: Bool) {
        let txn = entry.txn
        var newlyUncertain: [String] = []
        do {
            try update(txn) { entry in
                entry.state = .uncertain
                entry.uncertainReason = reason
                guard var songs = entry.songs else { return }
                for index in songs.indices where !songs[index].state.isTerminal {
                    songs[index].state = .uncertain
                    songs[index].uncertainReason = reason
                    newlyUncertain.append(songs[index].title)
                }
                entry.songs = songs
            }
        } catch {
            seams.log("discover album reconcile \(txn): journal write failed: \(error)")
            return
        }
        guard !atLaunch, !newlyUncertain.isEmpty else { return }
        seams.post(.outcome(.refused(discoverAlbumLeftText(titles: newlyUncertain, album: entry.title)),
                            title: entry.title))
    }

    /// `uncertain` for any reason but an unknown outcome: nothing will prove
    /// any of its songs now.
    private func markUnfinishedUncertain(_ txn: String, reason: String) {
        guard let entry = albumEntry(txn), let songs = entry.songs,
              songs.contains(where: { !$0.state.isTerminal }) else { return }
        do {
            try update(txn) { entry in
                guard var songs = entry.songs else { return }
                for index in songs.indices where !songs[index].state.isTerminal {
                    songs[index].state = .uncertain
                    songs[index].uncertainReason = reason
                }
                entry.songs = songs
            }
        } catch {
            seams.log("discover album reconcile \(txn): journal write failed: \(error)")
        }
    }

    /// At launch: every `uncertain` song not yet told, in ONE line for the
    /// entry, then marked (posted first, as the shipped copy replay does, so a
    /// failed write repeats it at a later launch rather than never telling him).
    private func tellAtLaunch(_ txn: String) {
        guard let entry = albumEntry(txn), let songs = entry.songs else { return }
        let untold = songs.filter { $0.state == .uncertain && !$0.toldAtLaunch }
        guard !untold.isEmpty else { return }
        seams.post(.outcome(.refused(discoverAlbumLeftText(titles: untold.map(\.title), album: entry.title)),
                            title: entry.title))
        let positions = Set(untold.map(\.position))
        do {
            try update(txn) { entry in
                guard var songs = entry.songs else { return }
                for index in songs.indices where positions.contains(songs[index].position) {
                    songs[index].toldAtLaunch = true
                }
                entry.songs = songs
            }
        } catch {
            seams.log("discover album reconcile \(txn): journal write failed: \(error)")
        }
    }

    /// Closed, and B's side file deleted (only after the close is on disk).
    private func close(_ entry: DiscoverCopyEntry) {
        do {
            try update(entry.txn) { entry in
                entry.state = .closed
                entry.watching = false
            }
        } catch {
            seams.log("discover album reconcile \(entry.txn): could not close: \(error)")
            return
        }
        if let file = entry.beforeFile { seams.beforeSet.deleteBeforeSet(file: file) }
    }

    // MARK: Journal helpers

    private func albumEntry(_ txn: String) -> DiscoverCopyEntry? {
        guard let entry = (try? seams.journal.entries())?.first(where: { $0.txn == txn }),
              entry.kind == .albumContainer else { return nil }
        return entry
    }

    @discardableResult
    private func update(_ txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        let stamp = Int(seams.now().timeIntervalSince1970)
        return try seams.journal.update(txn: txn) { entry in
            change(&entry)
            entry.updatedAt = stamp
        }
    }
}
