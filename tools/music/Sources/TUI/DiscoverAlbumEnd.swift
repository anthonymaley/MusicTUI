// tools/music/Sources/TUI/DiscoverAlbumEnd.swift
//
// Discover "play from here" on an ALBUM: what happens when listening ends
// (album-cleanup score step A5, design 4.6 and 4.8).
//
// The order is the design's: the container goes first, through the shipped
// `DiscoverCopyDeleter` and the one guarded restore; only once it has read
// absent does any song go, and then each proven (`owned`) song is its own
// action-queue item through the song guard (A4), so a keypress waits behind at
// most one song's script. This file never deletes a song itself: the guard
// behind `Seams.guardSong` is the only thing that can, and it re-checks
// everything at the moment its script runs. `pending`, `uncertain` and
// `preexisting` songs are never handed to it.
//
// He is told once (`endTold`), and the entry closes only when CH9 allows it.
import Foundation

/// The end line for an album entry whose songs are all terminal, or nil when
/// there is nothing to say (every song was already his). Posting rules (1.7):
/// kept songs only, or every song removed -> `.progress` (quiet, not an
/// error); anything left (an `uncertain` song) -> `.outcome(.refused(kept + " " + left))`.
func discoverAlbumEndToast(_ entry: DiscoverCopyEntry) -> DiscoverToast? {
    let songs = entry.songs ?? []
    let album = entry.title
    let kept = songs.filter { $0.state == .kept }
    let left = songs.filter { $0.state == .uncertain }.map(\.title)
    let removed = songs.filter { $0.state == .deleted }.count
    if !left.isEmpty {
        let leftText = discoverAlbumLeftText(titles: left, album: album)
        let text = kept.isEmpty
            ? leftText
            : discoverAlbumKeptText(kept: kept, album: album, removed: removed) + " " + leftText
        return .outcome(.refused(text), title: album)
    }
    if !kept.isEmpty {
        return .progress(discoverAlbumKeptText(kept: kept, album: album, removed: removed))
    }
    if removed > 0 {
        return .progress(discoverAlbumAllRemovedText(album: album))
    }
    return nil
}

/// Owns the song phase of every album entry: one guard item per `owned` song,
/// the 30 s retries of songs the guard spared or could not check, and the one
/// end line and the close (CH9). Thread-safe: `tick` comes from the poller and
/// every item runs on the action queue.
final class DiscoverAlbumCleaner {
    struct Seams {
        var journal: DiscoverCopyJournalStore
        var beforeSet: DiscoverBeforeSetStore
        /// A4's `DiscoverOwnedSongDeleter.run`: the only thing that can delete a song.
        var guardSong: (_ txn: String, _ position: Int) -> DiscoverSongGuardOutcome
        var enqueue: (@escaping () -> Void) -> Void      // the action queue
        var post: (DiscoverToast) -> Void
        var now: () -> Date
        var log: (String) -> Void
    }

    private struct SongKey: Hashable, Comparable {
        let txn: String
        let position: Int
        static func < (lhs: SongKey, rhs: SongKey) -> Bool {
            (lhs.txn, lhs.position) < (rhs.txn, rhs.position)
        }
    }

    private let seams: Seams
    private let lock = NSLock()
    /// Songs whose last outcome was `.spared` or `.retry`, and when each is due again.
    private var due: [SongKey: Date] = [:]
    /// Songs with an item on the queue that has not run yet: never a second one.
    private var queued: Set<SongKey> = []

    init(seams: Seams) { self.seams = seams }

    /// The album's songs, after the container read absent. Only when the
    /// journal says `containerGone`; one item per `owned` song, in album order,
    /// each running the guard and then `settle`. With no `owned` song it
    /// settles at once (every song may already be terminal).
    func songPhase(txn: String) {
        guard let entry = albumEntry(txn), entry.containerGone == true else { return }
        let owned = (entry.songs ?? []).filter { $0.state == .owned }.map(\.position)
        guard !owned.isEmpty else {
            settle(txn: txn)
            return
        }
        for position in owned { enqueueGuard(SongKey(txn: txn, position: position)) }
    }

    /// One song, the same way: only an `owned` song of an entry whose container
    /// is gone. Used by reconcile and by the proof collector for a song proven
    /// after the end.
    func handToGuard(txn: String, position: Int) {
        guard let entry = albumEntry(txn), entry.containerGone == true,
              (entry.songs ?? []).contains(where: { $0.position == position && $0.state == .owned })
        else { return }
        enqueueGuard(SongKey(txn: txn, position: position))
    }

    /// The poller's tick. Every song whose last outcome was `.spared` or
    /// `.retry` goes back on the queue `retryInterval` after that outcome.
    /// Nothing at all while no song is waiting.
    func tick() {
        lock.lock()
        guard !due.isEmpty else {
            lock.unlock()
            return
        }
        let now = seams.now()
        let ready = due.filter { $0.value <= now && !queued.contains($0.key) }.map(\.key).sorted()
        for key in ready {
            due[key] = nil
            queued.insert(key)
        }
        lock.unlock()
        for key in ready { seams.enqueue { [self] in runGuard(key) } }
    }

    /// CH9. When every song is terminal and the container is gone, the end
    /// line is posted once (`endTold` is written first, so a failed write posts
    /// nothing and a second call posts nothing). The entry closes when every
    /// song is terminal, every `uncertain` song has been told at a launch, and
    /// the container is gone; B's side file is deleted on close.
    ///
    /// Design silent, CHOSEN here: only an entry that played (`owned` /
    /// `listening`) gets the end line, because every other album entry was
    /// already told by the refusal or reconcile that made it so. An `intent`
    /// entry is never closed here (reconcile decides it), nor an `uncertain`
    /// one whose ensure outcome reconcile is still resolving.
    func settle(txn: String) {
        guard var entry = albumEntry(txn), entry.state != .closed, let songs = entry.songs else { return }
        let allTerminal = songs.allSatisfy { $0.state.isTerminal }
        let played = entry.state == .owned || entry.state == .listening
        let containerGone = entry.containerGone == true

        if allTerminal, played, containerGone, entry.endTold != true {
            let toast = discoverAlbumEndToast(entry)
            do {
                entry = try update(txn) { $0.endTold = true }
            } catch {
                seams.log("discover album \(txn): end line not recorded, so not posted: \(error)")
                return
            }
            if let toast { seams.post(toast) }
        }

        let closable: Bool
        switch entry.state {
        case .owned, .listening: closable = containerGone
        case .uncertain: closable = entry.uncertainReason != "outcome_unknown"
        case .intent, .preexisting, .closed: closable = false
        }
        let allTold = songs.filter { $0.state == .uncertain }.allSatisfy(\.toldAtLaunch)
        guard closable, allTerminal, allTold else { return }
        do {
            try update(txn) { entry in
                entry.state = .closed
                entry.watching = false
            }
        } catch {
            seams.log("discover album \(txn): could not close: \(error)")
            return
        }
        if let file = entry.beforeFile { seams.beforeSet.deleteBeforeSet(file: file) }
        lock.lock()
        for key in due.keys where key.txn == txn { due[key] = nil }
        lock.unlock()
    }

    // MARK: Items

    private func enqueueGuard(_ key: SongKey) {
        lock.lock()
        guard !queued.contains(key) else {
            lock.unlock()
            return
        }
        queued.insert(key)
        due[key] = nil
        lock.unlock()
        seams.enqueue { [self] in runGuard(key) }
    }

    /// One action-queue item: the guard for one song, then settle.
    private func runGuard(_ key: SongKey) {
        lock.lock()
        queued.remove(key)
        lock.unlock()
        let outcome = seams.guardSong(key.txn, key.position)
        seams.log("discover album \(key.txn): song \(key.position) guard: \(outcome)")
        lock.lock()
        switch outcome {
        case .spared, .retry:
            due[key] = seams.now().addingTimeInterval(DiscoverAlbumTiming.retryInterval)
        case .deleted, .kept, .gaveUp, .notRun:
            due[key] = nil
        }
        lock.unlock()
        settle(txn: key.txn)
    }

    // MARK: Journal helpers

    private func albumEntry(_ txn: String) -> DiscoverCopyEntry? {
        do {
            guard let entry = try seams.journal.entries().first(where: { $0.txn == txn }),
                  entry.kind == .albumContainer else { return nil }
            return entry
        } catch {
            seams.log("discover album \(txn): journal unreadable: \(error)")
            return nil
        }
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

/// What the watcher's `enqueueEnd` runs for an ALBUM entry, on the action
/// queue. The container first, through the shipped `discoverCopyHandleEnd`
/// (the delete, then the one guarded restore for EVERY result, and `.spared`
/// re-adopting); then `listeningEnded` is recorded (it gates nothing, CH8);
/// then only `.deleted` / `.alreadyGone` start the song phase. `.spared`,
/// `.kept` and `.failed` touch no song.
@discardableResult
func discoverAlbumHandleEnd(txn: String, deleter: DiscoverCopyDeleter, journal: DiscoverCopyJournalStore,
                            restoreModes: (String) -> Void, readopt: (String, String) -> Void,
                            cleaner: DiscoverAlbumCleaner) -> DiscoverCopyDeleteResult {
    let result = discoverCopyHandleEnd(txn: txn, deleter: deleter, journal: journal,
                                       restoreModes: restoreModes, readopt: readopt)
    _ = try? journal.update(txn: txn) { entry in
        if entry.kind == .albumContainer { entry.listeningEnded = true }
    }
    switch result {
    case .deleted, .alreadyGone:
        cleaner.songPhase(txn: txn)
    case .spared, .kept, .failed:
        break
    }
    return result
}
