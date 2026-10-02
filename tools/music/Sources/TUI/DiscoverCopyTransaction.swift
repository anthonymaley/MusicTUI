// tools/music/Sources/TUI/DiscoverCopyTransaction.swift
//
// One Discover "play from here" attempt on Apple's own copy of a playlist, from
// the preflight (S0a) to the hand-over to the sequencer and back (S14), and the
// reconcile that replays the journal (score step C2).
//
// OWNERSHIP IS THE SAFETY PROPERTY. Apple gives no authorship for a library
// playlist, so the only proof that a copy is MusicTUI's to delete is the
// transition this transaction watched itself make: no copy read before (S1),
// none at SpanDAC's own re-read just before its request (else `copyAppeared`),
// a successful add (S3), and exactly one copy after (S4). Only then is the
// entry `owned`, and only an `owned` or `listening` entry is deletable.
// Everything else (a copy that was already there, an add whose outcome is
// unknown, two copies after a success, none after a success, a record that
// could not be written) is `preexisting` or `uncertain`, and is never deleted.
//
// The record is on the disk before each risky step: `intent` before the add,
// `owned` before the first Music.app command. This file deletes nothing itself;
// deletion is the guard behind `deleteIfOwned`, which reconcile asks and the
// sequencer calls.
import Foundation

/// The transaction-table token for a copy play (CHOSEN, score 1.3). Never a
/// playlist name, so it matches nothing in a `__discover__` name sweep.
func discoverCopyToken(_ id: UUID) -> String { "copy:" + id.uuidString }

/// S0a for a copy play: nil lets it through. Otherwise the sentence is posted
/// and the refusal returned; no other SpanDAC op, no journal write, no mint.
func discoverCopyPreflightRefusal(ops: SpanDACCatalogPlaylistOps, request: DiscoverCopyRequest,
                                  post: (DiscoverToast) -> Void) -> DiscoverRefusal? {
    let title = request.playlistTitle
    switch discoverPlayFromHerePreflight(offersCatalogPlaylist: ops.offersCatalogPlaylist,
                                         rows: request.rows, selected: request.selected) {
    case .pass:
        return nil
    case .updateSpanDAC:
        post(.outcome(.refused(updateSpanDACToPlayOnMusicTUI), title: title))
        return .libraryOpsNotOffered
    case .malformedLength:
        post(.outcome(.refused(discoverMalformedLengthText), title: title))
        return .preflight
    case .noLength(let song):
        post(.outcome(.refused(discoverNoLengthText(title: song)), title: title))
        return .preflight
    case .selectionOutOfRange:
        // The score names no sentence for this case. The rows he is looking
        // at no longer hold the row he chose, which is what this one says.
        post(.outcome(.refused(discoverCopyChangedText(playlist: title)), title: title))
        return .preflight
    }
}

/// Steps 4 to 9 of phase B (S1 to S14), for a transaction the coordinator has
/// already admitted and minted. `transition` records a state in the
/// coordinator's table; `post` is its toast seam.
struct DiscoverCopyTransaction {
    let copy: DiscoverCopySeams
    let post: (DiscoverToast) -> Void
    let transition: (DiscoverTransactionState) -> Void

    private final class Progress {
        var state: DiscoverTransactionState
        var reachedPositioning = false
        init(_ state: DiscoverTransactionState) { self.state = state }
    }

    /// `token` is the name in the transaction table; `txn` is the journal id a
    /// NEW entry gets. A reused entry keeps its own id, and that one governs.
    func run(token: String, txn newTxn: String, request: DiscoverCopyRequest,
             ops: SpanDACCatalogPlaylistOps, gate: @escaping DiscoverCopyGate) -> DiscoverTransactionState {
        let playlist = request.playlistTitle
        let journal = copy.journal

        func fail(_ stage: DiscoverFailureStage, _ text: String?) -> DiscoverTransactionState {
            let state = DiscoverTransactionState.failedBeforePlay(token, stage)
            transition(state)
            if let text { post(.outcome(.refused(text), title: playlist)) }
            return state
        }

        // S1. What is in his library now.
        let found: [CatalogPlaylistCopy]
        do {
            found = try timed("S1 copies", newTxn) { try ops.copies(ofCatalogPlaylist: request.playlistID) }
        } catch {
            let state = DiscoverTransactionState.failedBeforePlay(token, .create)
            transition(state)
            post(.outcome(spandacCreateFailureOutcome(error), title: playlist))
            return state
        }
        guard found.count <= 1 else {
            return fail(.create, discoverSeveralCopiesText(playlist: playlist))
        }

        // Gate G-a: the first journal write, only while the reservation holds.
        var txn = newTxn
        var hex: String?
        var writeError: Error?
        let gateResult: DiscoverCopyGateResult
        if let one = found.first {
            // CH5: one copy that cannot be named cannot be played or recorded.
            guard let oneHex = one.hex, discoverCopyHexIsWellFormed(oneHex) else {
                return fail(.create, discoverCopyNoIDText(playlist: playlist))
            }
            let reusable: DiscoverCopyEntry?
            do {
                reusable = try journal.entries().last(where: { $0.hex == oneHex && $0.isDeletable })
            } catch {
                copy.log("discover copy \(newTxn): journal unreadable before G-a: \(error)")
                return fail(.create, discoverJournalUnwritableText(playlist: playlist))
            }
            hex = oneHex
            if let reusable {
                // A copy this journal already proves MusicTUI made: reuse its entry.
                txn = reusable.txn
                gateResult = timed("G-a reuse", txn) { gate {} }
            } else {
                // It was there before this play: recorded as such, never deletable.
                let entry = newEntry(txn: newTxn, request: request, state: .preexisting,
                                     hex: oneHex, copiesRead: 1)
                gateResult = timed("G-a preexisting", txn) {
                    gate { do { try journal.insert(entry) } catch { writeError = error } }
                }
            }
        } else {
            // S2. No copy: the intent is on disk before the add is sent.
            let entry = newEntry(txn: newTxn, request: request, state: .intent, hex: nil, copiesRead: 0)
            gateResult = timed("G-a S2 intent", txn) {
                gate { do { try journal.insert(entry) } catch { writeError = error } }
            }
        }
        switch gateResult {
        case .ran:
            break
        case .sourceChanged:
            return fail(.selectionChanged, discoverCopyRefusalText(.sourceChanged, playlist: playlist))
        case .superseded:
            return fail(.superseded, discoverCopyRefusalText(.superseded, playlist: playlist))
        }
        if let writeError {
            copy.log("discover copy \(txn): journal write failed at G-a: \(writeError)")
            return fail(.create, discoverJournalUnwritableText(playlist: playlist))
        }

        if hex == nil {
            // S3. The add, outside any gate.
            post(.progress(discoverAddingText(playlist: playlist)))
            let outcome = timed("S3 add", txn) { ops.addCatalogPlaylist(id: request.playlistID) }
            let added: [CatalogPlaylistCopy]
            switch outcome {
            case .refused:
                mark(txn, .closed, copySeen: false)
                return fail(.create, discoverAddRefusedText(playlist: playlist))
            case .notOffered:
                mark(txn, .closed, copySeen: false)
                return fail(.create, updateSpanDACToPlayOnMusicTUI)
            case .copyAppeared:
                mark(txn, .uncertain, copySeen: true)
                return fail(.create, discoverCopyLeftText(playlist: playlist))
            case .outcomeUnknown:
                mark(txn, .uncertain, copySeen: false)
                return fail(.create, discoverCopyMaybeAddedText(playlist: playlist))
            case .added(let copies):
                added = copies
            }
            guard added.count == 1, let addedHex = added[0].hex, discoverCopyHexIsWellFormed(addedHex) else {
                let seen = !added.isEmpty
                mark(txn, .uncertain, copySeen: seen)
                return fail(.create, seen ? discoverCopyLeftText(playlist: playlist)
                                          : discoverCopyMaybeAddedText(playlist: playlist))
            }

            // S4. Exactly one copy, after none and a successful add: this one
            // is ours. Not gated: it records a fact about his library, and
            // cleanup needs it. Only an entry still `intent` is promoted.
            let promoted = try? timed("S4 owned", txn) {
                try update(txn) { entry in
                    guard entry.state == .intent else { return }
                    entry.state = .owned
                    entry.hex = addedHex
                }
            }
            guard let promoted, promoted.state == .owned, promoted.hex == addedHex else {
                mark(txn, .uncertain, copySeen: true)
                return fail(.create, discoverCopyLeftText(playlist: playlist))
            }
            hex = addedHex
        }
        guard let hex else { return fail(.create, discoverCopyNoIDText(playlist: playlist)) }
        transition(.created(token))

        // S5-S14 belong to the sequencer.
        let progress = Progress(.created(token))
        let chosen = request.rows.indices.contains(request.selected) ? request.rows[request.selected].name : ""
        let step: (DiscoverTransactionState) -> Void = { [transition] next in
            guard discoverTransitionIsLegal(from: progress.state, to: next) else { return }
            progress.state = next
            transition(next)
        }
        let onProgress: (DiscoverCopyStage) -> Void = { [post] stage in
            switch stage {
            case .adding:
                post(.progress(discoverAddingText(playlist: playlist)))
            case .waitingForCopy:
                post(.progress(discoverWaitingText(playlist: playlist)))
            case .ready:
                step(.ready(token))
            case .positioning:
                step(.positioning(token))
                progress.reachedPositioning = true
                post(.progress(discoverPositioningText(title: chosen)))
            }
        }
        let governing = txn
        let commitListening: () -> Void = { [copy] in
            // S14, inside gate G-f. A failed write is not fatal: the music is
            // already playing, and reconcile repeats this for a spared copy.
            do {
                try journal.update(txn: governing) { entry in
                    if entry.state == .owned { entry.state = .listening }
                    entry.watching = true
                    entry.updatedAt = Int(copy.now().timeIntervalSince1970)
                }
            } catch {
                copy.log("discover copy \(governing): journal write failed at S14: \(error)")
            }
            copy.adopt(governing, hex)
        }
        let result = timed("S5-S14 sequence", txn) {
            copy.sequence(hex, governing, request, gate, onProgress, commitListening)
        }

        let ended: DiscoverTransactionState
        switch result {
        case .listening:
            ended = .listening(token)
            transition(ended)
            post(.outcome(.playing(title: playlist), title: playlist))
            return ended
        case .refused(let refusal):
            switch refusal {
            case .notReady: ended = .failedBeforePlay(token, .readiness)
            case .countChanged, .unconfirmed: ended = .failedBeforePlay(token, .identity)
            case .sourceChanged: ended = .failedBeforePlay(token, .selectionChanged)
            case .superseded: ended = .failedBeforePlay(token, .superseded)
            case .modes: ended = .failedBeforePlay(token, .modes)
            case .landing: ended = .failedBeforePlay(token, .positioning)
            case .firstPlayUnconfirmed, .wontPlay:
                ended = progress.reachedPositioning ? .unconfirmed(token) : .playAmbiguous(token)
            }
            transition(ended)
            if let text = discoverCopyRefusalText(refusal, playlist: playlist) {
                post(.outcome(.refused(text), title: playlist))
            }
            return ended
        }
    }

    // MARK: Journal helpers

    private func newEntry(txn: String, request: DiscoverCopyRequest, state: DiscoverCopyState,
                          hex: String?, copiesRead: Int) -> DiscoverCopyEntry {
        let stamp = Int(copy.now().timeIntervalSince1970)
        return DiscoverCopyEntry(txn: txn, playlistID: request.playlistID, title: request.playlistTitle,
                                 state: state, hex: hex, copiesRead: copiesRead, watching: false,
                                 copySeen: false, toldAtLaunch: false, priorShuffle: nil, priorRepeat: nil,
                                 createdAt: stamp, updatedAt: stamp)
    }

    @discardableResult
    private func update(_ txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        let stamp = Int(copy.now().timeIntervalSince1970)
        return try copy.journal.update(txn: txn) { entry in
            change(&entry)
            entry.updatedAt = stamp
        }
    }

    /// Best effort. If it fails the entry stays as it was (`intent`, with no
    /// hex), which is not deletable either, and reconcile settles it.
    private func mark(_ txn: String, _ state: DiscoverCopyState, copySeen: Bool) {
        do {
            try update(txn) { entry in
                entry.state = state
                entry.copySeen = copySeen
            }
        } catch {
            copy.log("discover copy \(txn): could not record \(state.rawValue): \(error)")
        }
    }

    private func timed<T>(_ stage: String, _ txn: String, _ body: () throws -> T) rethrows -> T {
        let start = copy.now()
        defer {
            let ms = Int((copy.now().timeIntervalSince(start) * 1000).rounded())
            copy.log("discover copy \(txn): \(stage) \(ms) ms")
        }
        return try body()
    }
}

/// Replays the journal: after the launch sweep (`atLaunch` true) and before
/// every Discover play (false). It uses no gate: it deletes only what the
/// deletion guard allows, and restores.
struct DiscoverCopyReconciler {
    let copy: DiscoverCopySeams
    let post: (DiscoverToast) -> Void

    func run(atLaunch: Bool) {
        let start = copy.now()
        // An unreadable journal: do nothing, post nothing.
        guard let entries = try? copy.journal.entries() else {
            copy.log("discover copy reconcile: journal not readable; nothing done")
            return
        }
        for entry in entries { reconcile(entry, atLaunch: atLaunch) }
        let ms = Int((copy.now().timeIntervalSince(start) * 1000).rounded())
        copy.log("discover copy reconcile: \(entries.count) entries, \(ms) ms")
    }

    private func reconcile(_ entry: DiscoverCopyEntry, atLaunch: Bool) {
        let txn = entry.txn
        switch entry.state {
        case .closed:
            if entry.priorShuffle != nil || entry.priorRepeat != nil { copy.restoreModes(txn) }

        case .uncertain:
            // Never touched. He is told once, at the next launch.
            guard atLaunch, !entry.toldAtLaunch else { return }
            post(.outcome(.refused(uncertainText(title: entry.title, copySeen: entry.copySeen)),
                          title: entry.title))
            update(txn) { $0.toldAtLaunch = true }

        case .intent:
            // CH7: asking would start SpanDAC on this Mac; otherwise it waits.
            guard copy.spandacDataSelected() else { return }
            guard let found = try? copy.ops().copies(ofCatalogPlaylist: entry.playlistID) else { return }
            if found.isEmpty {
                update(txn) { $0.state = .closed }
            } else {
                // A copy exists and nothing proves the add made it.
                update(txn) {
                    $0.state = .uncertain
                    $0.copySeen = true
                    $0.toldAtLaunch = atLaunch
                }
                post(.outcome(.refused(discoverCopyLeftText(playlist: entry.title)), title: entry.title))
            }

        case .owned, .listening, .preexisting:
            guard let hex = entry.hex else { return }
            switch copy.deleteIfOwned(txn) {
            case .spared:
                update(txn) {
                    $0.watching = true
                    if $0.state == .owned { $0.state = .listening }
                }
                copy.adopt(txn, hex)
            case .deleted, .alreadyGone, .kept:
                copy.restoreModes(txn)
                if entry.state == .preexisting {
                    update(txn) { if $0.state == .preexisting { $0.state = .closed } }
                }
            case .failed:
                break   // left for the next reconcile
            }
        }
    }

    private func uncertainText(title: String, copySeen: Bool) -> String {
        copySeen ? discoverCopyLeftText(playlist: title) : discoverCopyMaybeAddedText(playlist: title)
    }

    private func update(_ txn: String, _ change: (inout DiscoverCopyEntry) -> Void) {
        let stamp = Int(copy.now().timeIntervalSince1970)
        do {
            try copy.journal.update(txn: txn) { entry in
                change(&entry)
                entry.updatedAt = stamp
            }
        } catch {
            copy.log("discover copy reconcile \(txn): journal write failed: \(error)")
        }
    }
}
