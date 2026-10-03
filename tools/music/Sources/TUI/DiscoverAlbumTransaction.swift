// tools/music/Sources/TUI/DiscoverAlbumTransaction.swift
//
// One Discover "play from here" on an ALBUM, with clean-up (album-cleanup
// score step A2, design 4.3): the preflight (S0a), the record of everything
// the proof of ownership needs before it can be lost (S1-S4), the hand-over to
// the UNCHANGED copy sequencer (S5-S14) through a recorder that writes S7's
// read to the journal, and the hand-over to the proof collector.
//
// An album has no catalogue copy to add, so the play goes through a temporary
// library playlist (the container) made by `slice.libraryEnsurePlaylist`. That
// ensure adds every song of the slice to his library, and only the songs this
// play can PROVE it added may ever be removed. So, before the ensure is sent:
// the relation counts of every song (R1, then R2 just before the write), the
// full before-set of his library (B, in a side file), and the intent with one
// song per row are on the disk; `writeSentAt` and every song not already his
// (`pending`) are written in ONE durable update immediately before the send.
// Nothing here deletes anything: the songs are proven by A3's collector and
// removed by A4's guard; the container is the sequencer's `deleteIfOwned`.
import Foundation

// MARK: - B, the full before-set (score 1.5 B-script)

/// The persistent ID of every track in his library, one per line. Run inside
/// `tell application "Music"`; the caller bounds it by `beforeSetBound`.
let discoverAlbumBeforeSetScript = """
    set beforeIDList to persistent ID of every track of library playlist 1
    set AppleScript's text item delimiters to linefeed
    set beforeIDText to beforeIDList as text
    set AppleScript's text item delimiters to ""
    return beforeIDText
    """

/// Splits on newlines, trims, drops empty lines; every remaining token must be
/// sixteen `0-9A-F`, else nil (unreadable). nil in is nil out; empty output is
/// `[]` (an empty library).
func parseDiscoverAlbumBeforeSet(_ output: String?) -> [String]? {
    guard let output else { return nil }
    var ids: [String] = []
    for line in output.components(separatedBy: .newlines) {
        let token = line.trimmingCharacters(in: .whitespaces)
        if token.isEmpty { continue }
        guard discoverCopyHexIsWellFormed(token) else { return nil }
        ids.append(token)
    }
    return ids
}

// MARK: - S7's recorder (score 1.4, CH23)

/// The sequencer's player, with S7's read recorded. On a non-nil read it
/// writes E (the container's ordered track IDs) and, when E has exactly one ID
/// per song, every song's `entryHex = E[position - 1]`, in ONE durable update,
/// and returns the read only after that write returned. A failed write returns
/// nil, so the sequencer refuses `.unconfirmed` and its `deleteIfOwned`
/// removes the container: nothing plays whose rows the proof could not name.
/// Every other method forwards unchanged.
struct DiscoverAlbumEntryRecorder: DiscoverCopyPlayerControlling {
    private let player: DiscoverCopyPlayerControlling
    private let journal: DiscoverCopyJournalStore
    private let txn: String

    init(player: DiscoverCopyPlayerControlling, journal: DiscoverCopyJournalStore, txn: String) {
        self.player = player
        self.journal = journal
        self.txn = txn
    }

    func read(hex: String, k: Int) -> DiscoverCopyRead? {
        guard let read = player.read(hex: hex, k: k) else { return nil }
        do {
            try journal.update(txn: txn) { entry in
                entry.entryIDs = read.ids
                guard var songs = entry.songs, read.ids.count == songs.count else { return }
                for index in songs.indices {
                    let position = songs[index].position
                    if read.ids.indices.contains(position - 1) {
                        songs[index].entryHex = read.ids[position - 1]
                    }
                }
                entry.songs = songs
            }
        } catch {
            return nil
        }
        return read
    }

    func trackCount(hex: String) -> Int? { player.trackCount(hex: hex) }
    func playCopy(hex: String) -> Bool { player.playCopy(hex: hex) }
    func pause() -> Bool { player.pause() }
    func nextTrack() -> Bool { player.nextTrack() }
    func play() -> Bool { player.play() }
    func stop() -> Bool { player.stop() }
    func stopIfCurrent(hex: String) -> Bool { player.stopIfCurrent(hex: hex) }
    func firstPlay(hex: String, track: String) -> DiscoverCopyPoll { player.firstPlay(hex: hex, track: track) }
    func landing(hex: String, expected: String, previous: String, settling: Bool) -> DiscoverCopyPoll {
        player.landing(hex: hex, expected: expected, previous: previous, settling: settling)
    }
    func confirm(hex: String, track: String) -> DiscoverCopyConfirm { player.confirm(hex: hex, track: track) }
}

// MARK: - S0a

/// The rows from the cursor to the end: what the container holds, in order.
/// Empty when the cursor is outside the rows.
private func discoverAlbumSlice(_ request: DiscoverCopyRequest) -> [DiscoverItem] {
    guard request.rows.indices.contains(request.selected) else { return [] }
    return Array(request.rows[request.selected...])
}

/// S0a for an album play: nil lets it through. Otherwise the sentence is
/// posted and the refusal returned. No write, no journal write, no SpanDAC op
/// beyond the capability read. In order: the capability (CH2); the reused
/// length rules over the slice with its LAST row as the cursor, so a null
/// length on any slice row refuses (CH3); distinct catalogue ids; at most 100
/// rows (CH4); the journal readable, and no song of the slice removed by
/// MusicTUI within `recentDeleteBlock` of `now`. Every refusal but the
/// capability's is `.preflight`.
func discoverAlbumPreflightRefusal(relations: SpanDACLibraryRelationsReading, request: DiscoverCopyRequest,
                                   journal: DiscoverCopyJournalStore, now: Date,
                                   post: (DiscoverToast) -> Void) -> DiscoverRefusal? {
    let album = request.playlistTitle
    func refuse(_ text: String, _ refusal: DiscoverRefusal = .preflight) -> DiscoverRefusal {
        post(.outcome(.refused(text), title: album))
        return refusal
    }

    guard relations.offersAlbumCleanup else { return refuse(updateSpanDACToPlayOnMusicTUI, .libraryOpsNotOffered) }

    let slice = discoverAlbumSlice(request)
    switch discoverPlayFromHerePreflight(offersCatalogPlaylist: true, rows: slice, selected: slice.count - 1) {
    case .pass:
        break
    case .updateSpanDAC:
        // A row without the length key: an older SpanDAC (the copy path's mapping).
        return refuse(updateSpanDACToPlayOnMusicTUI, .libraryOpsNotOffered)
    case .malformedLength:
        return refuse(discoverMalformedLengthText)
    case .noLength(let song):
        return refuse(discoverNoLengthText(title: song))
    case .selectionOutOfRange:
        return refuse(discoverCopyChangedText(playlist: album))
    }

    let ids = slice.map(\.id)
    guard Set(ids).count == ids.count else { return refuse(discoverAlbumRepeatedSongText(album: album)) }
    guard ids.count <= DiscoverAlbumTiming.maxSongs else { return refuse(discoverAlbumTooManyText) }

    let entries: [DiscoverCopyEntry]
    do {
        entries = try journal.entries()
    } catch {
        return refuse(discoverJournalUnwritableText(playlist: album))
    }
    let sliceIDs = Set(ids)
    let nowSeconds = now.timeIntervalSince1970
    let recentlyRemoved = entries.lazy.flatMap { $0.songs ?? [] }.contains { song in
        guard let deletedAt = song.deletedAt, sliceIDs.contains(song.catalogueID) else { return false }
        return nowSeconds - deletedAt <= DiscoverAlbumTiming.recentDeleteBlock
    }
    if recentlyRemoved { return refuse(discoverAlbumRecentlyCleanedText(album: album)) }
    return nil
}

// MARK: - S1-S14

/// Steps 4 to 10 of the album's phase B, for a transaction the coordinator has
/// already preflighted, admitted, minted (`name`, protected in the table from
/// both sweeps) and reconciled. `transition` records a state in the
/// coordinator's table under `name`; `post` is its toast seam; `awaitAlias` is
/// the coordinator's shipped alias wait (re-sends the same ensure).
struct DiscoverAlbumTransaction {
    let copy: DiscoverCopySeams
    let album: DiscoverAlbumSeams
    let post: (DiscoverToast) -> Void
    let transition: (DiscoverTransactionState) -> Void
    let awaitAlias: (_ name: String, _ ids: [String], _ playlistID: String) -> String?

    private final class Progress {
        var state: DiscoverTransactionState
        var reachedPositioning = false
        init(_ state: DiscoverTransactionState) { self.state = state }
    }

    /// `name` is the minted container name and the transaction token; `txn`
    /// is the mint's UUID string, the journal entry's id.
    func run(name: String, txn: String, request: DiscoverCopyRequest,
             gate: @escaping DiscoverCopyGate) -> DiscoverTransactionState {
        let albumTitle = request.playlistTitle
        let journal = copy.journal
        let slice = discoverAlbumSlice(request)
        let ids = slice.map(\.id)

        func refused(_ text: String?) {
            if let text { post(.outcome(.refused(text), title: albumTitle)) }
        }
        func fail(_ stage: DiscoverFailureStage, _ text: String?) -> DiscoverTransactionState {
            let state = DiscoverTransactionState.failedBeforePlay(name, stage)
            transition(state)
            refused(text)
            return state
        }
        /// The relation count of every slice song, or nil when the answer is
        /// unreadable or leaves a song out. A `null` alias still counts (CH1).
        func counts(_ answer: [String: [String?]]) -> [Int]? {
            var result: [Int] = []
            for id in ids {
                guard let aliases = answer[id] else { return nil }
                result.append(aliases.count)
            }
            return result
        }

        guard !slice.isEmpty else { return fail(.create, discoverCopyChangedText(playlist: albumTitle)) }
        let relations = album.relations()

        // S1. R1, then B, then B's side file. Nothing is written to his
        // library, and nothing to the journal, if any of them fails.
        guard let r1 = (try? relations.relations(catalogueIDs: ids)).flatMap(counts) else {
            copy.log("discover album \(txn): R1 unreadable")
            return fail(.create, discoverAlbumRelationsUnreadableText(album: albumTitle))
        }
        let beforeStart = copy.now()
        let beforeRead = album.readBeforeSet()
        let beforeElapsed = copy.now().timeIntervalSince(beforeStart)
        guard let before = beforeRead, beforeElapsed <= DiscoverAlbumTiming.beforeSetBound else {
            copy.log("discover album \(txn): B unreadable or past its bound (\(beforeElapsed) s)")
            return fail(.create, discoverAlbumBeforeSetText(album: albumTitle))
        }
        let beforeFile: String
        do {
            beforeFile = try album.beforeSet.writeBeforeSet(txn: txn, ids: before)
        } catch {
            copy.log("discover album \(txn): B side file not written: \(error)")
            return fail(.create, discoverJournalUnwritableText(playlist: albumTitle))
        }

        // G-a. The intent, one song per slice row, only while the reservation holds.
        let stamp = Int(copy.now().timeIntervalSince1970)
        let songs = slice.enumerated().map { index, row -> DiscoverAlbumSong in
            var durationMS: Int?
            if case .milliseconds(let ms) = row.length { durationMS = ms }
            return DiscoverAlbumSong(position: index + 1, catalogueID: row.id, title: row.name,
                                     artist: row.subtitle ?? "", durationMS: durationMS,
                                     relationsBefore: [r1[index]], entryHex: nil, alias: nil,
                                     cloudStatus: nil, state: .intent, p4FirstSeenAt: nil,
                                     uncertainReason: nil, keptReason: nil, keptPlaylist: nil,
                                     deletedAt: nil)
        }
        let intent = DiscoverCopyEntry(txn: txn, playlistID: request.playlistID, title: albumTitle,
                                       state: .intent, hex: nil, copiesRead: 0, watching: false,
                                       copySeen: false, toldAtLaunch: false, priorShuffle: nil,
                                       priorRepeat: nil, createdAt: stamp, updatedAt: stamp,
                                       kind: .albumContainer, containerName: name,
                                       beforeFile: beforeFile, songs: songs)
        var insertError: Error?
        let gateResult = gate { do { try journal.insert(intent) } catch { insertError = error } }
        switch gateResult {
        case .ran:
            break
        case .sourceChanged:
            album.beforeSet.deleteBeforeSet(file: beforeFile)
            return fail(.selectionChanged, discoverAlbumRefusalText(.sourceChanged, album: albumTitle))
        case .superseded:
            album.beforeSet.deleteBeforeSet(file: beforeFile)
            return fail(.superseded, discoverAlbumRefusalText(.superseded, album: albumTitle))
        }
        if let insertError {
            copy.log("discover album \(txn): journal write failed at G-a: \(insertError)")
            album.beforeSet.deleteBeforeSet(file: beforeFile)
            return fail(.create, discoverJournalUnwritableText(playlist: albumTitle))
        }

        /// Closes the entry and deletes B's side file: nothing was sent.
        func closeUnsent() {
            mark(txn) { $0.state = .closed }
            album.beforeSet.deleteBeforeSet(file: beforeFile)
        }

        // S2. R2, immediately before the write.
        guard let r2 = (try? relations.relations(catalogueIDs: ids)).flatMap(counts) else {
            copy.log("discover album \(txn): R2 unreadable")
            closeUnsent()
            return fail(.create, discoverAlbumRelationsUnreadableText(album: albumTitle))
        }
        let preexisting = Set(ids.indices.filter { r1[$0] >= 1 || r2[$0] >= 1 }.map { $0 + 1 })

        // S3. One durable update (CH22): R2 recorded, a song already his is
        // `preexisting` for good, every other song `pending`, and the moment
        // of the send; then the ensure, outside any gate.
        do {
            let sentAt = copy.now().timeIntervalSince1970
            try update(txn) { entry in
                entry.writeSentAt = sentAt
                guard var recorded = entry.songs else { return }
                for index in recorded.indices {
                    let position = recorded[index].position
                    if r2.indices.contains(position - 1) { recorded[index].relationsBefore.append(r2[position - 1]) }
                    recorded[index].state = preexisting.contains(position) ? .preexisting : .pending
                }
                entry.songs = recorded
            }
        } catch {
            copy.log("discover album \(txn): journal write failed at S3: \(error)")
            closeUnsent()
            return fail(.create, discoverJournalUnwritableText(playlist: albumTitle))
        }

        let library = album.library()
        let ensured: (created: Bool, id: String, alias: String?)
        do {
            ensured = try library.ensurePlaylist(name: name, catalogueIDs: ids)
        } catch SpanDACLibraryOpError.outcomeUnknown {
            // The container and the songs may exist: reconcile retries it by name.
            mark(txn) { entry in
                entry.state = .uncertain
                entry.uncertainReason = "outcome_unknown"
                entry.listeningEnded = true
            }
            transition(.unknownOutcome(name))
            refused(discoverAlbumMaybeAddedText(album: albumTitle))
            return .unknownOutcome(name)
        } catch {
            // Confirmed: SpanDAC or Apple refused, or nothing was sent.
            closeUnsent()
            let state = DiscoverTransactionState.failedBeforePlay(name, .create)
            transition(state)
            post(.outcome(spandacCreateFailureOutcome(error), title: albumTitle))
            return state
        }
        guard ensured.created else {
            // A playlist of this name was already there: nothing proves the
            // songs were added by this play, so none of them may ever leave.
            mark(txn) { entry in
                entry.state = .uncertain
                entry.uncertainReason = "not_created"
                entry.listeningEnded = true
                guard var recorded = entry.songs else { return }
                for index in recorded.indices where recorded[index].state != .preexisting {
                    recorded[index].state = .uncertain
                    recorded[index].uncertainReason = "not_created"
                }
                entry.songs = recorded
            }
            return fail(.create, discoverAlbumNotOursText(album: albumTitle))
        }

        // S4. Made by this play: play it by identity only.
        transition(.created(name))
        let alias = ensured.alias ?? awaitAlias(name, ids, ensured.id)
        guard let alias, let hex = persistentIDHex(fromAlias: alias) else {
            // The entry stays `intent` with `writeSentAt`, for reconcile (design test 7).
            mark(txn) { $0.listeningEnded = true }
            return fail(.identity, discoverAlbumNoIDText(album: albumTitle))
        }
        // Not gated: it records a fact about his library. Only an `intent`
        // entry is promoted.
        let promoted = try? update(txn) { entry in
            guard entry.state == .intent else { return }
            entry.state = .owned
            entry.hex = hex
        }
        guard let promoted, promoted.state == .owned, promoted.hex == hex else {
            // The entry stays `intent` with `writeSentAt`, as for a missing ID:
            // reconcile finds the container by its name.
            copy.log("discover album \(txn): journal write failed at S4")
            mark(txn) { $0.listeningEnded = true }
            return fail(.identity, discoverAlbumMaybeAddedText(album: albumTitle))
        }

        // S5-S14 belong to the sequencer, over the slice: k = 1.
        let sliceRequest = DiscoverCopyRequest(playlistID: request.playlistID, playlistTitle: albumTitle,
                                               rows: slice, selected: 0, kind: .albumContainer)
        let first = slice[0].name
        let progress = Progress(.created(name))
        let step: (DiscoverTransactionState) -> Void = { [transition] next in
            guard discoverTransitionIsLegal(from: progress.state, to: next) else { return }
            progress.state = next
            transition(next)
        }
        let onProgress: (DiscoverCopyStage) -> Void = { [post] stage in
            switch stage {
            case .adding:
                post(.progress(discoverAddingText(playlist: albumTitle)))
            case .waitingForCopy:
                post(.progress(discoverWaitingText(playlist: albumTitle)))
            case .ready:
                step(.ready(name))
            case .positioning:
                step(.positioning(name))
                progress.reachedPositioning = true
                post(.progress(discoverPositioningText(title: first)))
            }
        }
        let commitListening: () -> Void = { [copy] in
            // S14, inside gate G-f. A failed write is not fatal: the music is
            // already playing.
            do {
                try journal.update(txn: txn) { entry in
                    if entry.state == .owned { entry.state = .listening }
                    entry.watching = true
                    entry.updatedAt = Int(copy.now().timeIntervalSince1970)
                }
            } catch {
                copy.log("discover album \(txn): journal write failed at S14: \(error)")
            }
            copy.adopt(txn, hex)
        }
        let result = album.sequence(hex, txn, sliceRequest, gate, onProgress, commitListening)

        // Whatever it returned, the proof collector takes the entry (CH24).
        album.startProof(txn)

        let ended: DiscoverTransactionState
        switch result {
        case .listening:
            ended = .listening(name)
            transition(ended)
            let tail = preexisting.count == slice.count
                ? discoverAlbumPlayingOwnedTail(song: first)
                : discoverAlbumPlayingTail(song: first)
            post(.outcome(.playing(title: tail), title: albumTitle))
            return ended
        case .refused(let refusal):
            switch refusal {
            case .notReady: ended = .failedBeforePlay(name, .readiness)
            case .countChanged, .unconfirmed: ended = .failedBeforePlay(name, .identity)
            case .sourceChanged: ended = .failedBeforePlay(name, .selectionChanged)
            case .superseded: ended = .failedBeforePlay(name, .superseded)
            case .modes: ended = .failedBeforePlay(name, .modes)
            case .landing: ended = .failedBeforePlay(name, .positioning)
            case .firstPlayUnconfirmed, .wontPlay:
                ended = progress.reachedPositioning ? .unconfirmed(name) : .playAmbiguous(name)
            }
            mark(txn) { $0.listeningEnded = true }
            transition(ended)
            refused(discoverAlbumRefusalText(refusal, album: albumTitle))
            return ended
        }
    }

    // MARK: Journal helpers

    @discardableResult
    private func update(_ txn: String, _ change: (inout DiscoverCopyEntry) -> Void) throws -> DiscoverCopyEntry {
        let stamp = Int(copy.now().timeIntervalSince1970)
        return try copy.journal.update(txn: txn) { entry in
            change(&entry)
            entry.updatedAt = stamp
        }
    }

    /// Best effort: a failure is logged and the entry stays as it was.
    private func mark(_ txn: String, _ change: (inout DiscoverCopyEntry) -> Void) {
        do {
            try update(txn, change)
        } catch {
            copy.log("discover album \(txn): journal write failed: \(error)")
        }
    }
}
