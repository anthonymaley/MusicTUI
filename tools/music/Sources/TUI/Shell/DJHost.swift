// tools/music/Sources/TUI/Shell/DJHost.swift
//
// The Apple Music DJ box's host, hosted by the Now tab (DJ Now-box score).
// `DJBoxModel` owns the text, the stages and the request ids; this class does
// the work (a model read, the lookups behind the plan, the one play) and feeds
// each answer back with the request id it was asked under. It was Discover's
// `d` box; it moved here whole so every fence moved with it.
//
// There is no card and no second Enter. A request plays the moment its answer
// arrives, so the stamp taken at Enter is the only thing standing between the
// person's intent and the sound, and it is checked again at every step.
//
// FENCES. Every request carries the box session, its request id, and the stamp
// (both routing epochs and the play serial) it was asked under. A background
// job asks `isLive` before each step and drops itself the moment any of them
// moved; `tick` applies an answer only for the current session and request and
// only while the world is still the one it was asked in. A plan plays only
// while its stamp still holds, through `routing.perform(expecting:
// expectingPlaySerial:)`, which checks both epochs and the serial again inside
// the coordinator's boundary. An edit of the text releases a request still out.
import Foundation

final class DJHost {

    /// What the box reads and plays through. Fail-closed defaults; the shell
    /// wires the real ones (`DJSeams.live`) and a test hands in fakes.
    var seams: DJSeams

    /// Called after each answer is written to the slot (kept, not refused),
    /// with "dj". A test's hook to know a background job is done; nil in production.
    var inboxWritten: ((String) -> Void)?

    /// The box. Readable so the scene can draw it and a test can see it.
    private(set) var model = DJBoxModel()

    static let searchLimit = 10

    private let routing: RoutingCoordinator
    private let status: StatusStore
    private let actions: ActionRunner

    /// Count of box lives, moved on whenever the box abandons what it held, so
    /// a late answer from before can never pass for a later request of the
    /// same number (handle/tick thread).
    private var session = 0

    /// The world the latest request was asked in (handle/tick thread).
    private var askedStamp: DJStamp?

    private let lock = NSLock()
    private typealias InboxEntry = (session: Int, requestID: Int, outcome: DJOutcome)
    private var inbox: InboxEntry?                          // guarded by lock
    /// The (session, request id) a background job may still deliver for; every
    /// job asks it before each read. (-1, -1) while nothing is out.
    private var live: (session: Int, requestID: Int) = (-1, -1)   // guarded by lock
    /// A play that failed after the box said "Playing", for the next tick.
    private var playFailure: (session: Int, requestID: Int, words: String)?   // guarded by lock

    init(routing: RoutingCoordinator, status: StatusStore, actions: ActionRunner, seams: DJSeams = DJSeams()) {
        self.routing = routing
        self.status = status
        self.actions = actions
        self.seams = seams
    }

    // MARK: stamp and liveness

    private func currentStamp() -> DJStamp {
        let stamp = routing.stamp
        return DJStamp(epoch: stamp.epoch, dataEpoch: stamp.dataEpoch, playSerial: routing.playSerial)
    }

    /// Whether the job for (`session`, `requestID`) may still read and deliver:
    /// that request is the box's latest, and the world is the one it began in.
    private func isLive(_ session: Int, _ requestID: Int, _ stamp: DJStamp) -> Bool {
        lock.lock()
        let isCurrent = live.session == session && live.requestID == requestID
        lock.unlock()
        return isCurrent && currentStamp() == stamp
    }

    private func clearSlot() {
        lock.lock(); inbox = nil; live = (-1, -1); lock.unlock()
    }

    /// Nothing is out for the box any more: the world it was asked in is
    /// forgotten, the slot is emptied, and a job still running finds itself not live.
    private func release() {
        askedStamp = nil
        clearSlot()
    }

    // MARK: keys

    /// A key typed into the focused box. True when the screen changed.
    func handle(_ key: KeyPress) -> Bool {
        var next = model
        let wasOut = next.isRequestOut
        let out = next.handle(key)
        model = next
        // An edit that dropped the request still out: its job is released too,
        // so it stops reading and can deliver nothing.
        if out.emission == nil, wasOut, !model.isRequestOut { release() }
        switch out.emission {
        case .ask(let prompt, let requestID)?:
            let seams = self.seams
            startRequest(requestID: requestID) { live, stamp, report in
                let reading = Self.blockingRead(seams.reader, prompt, timeout: seams.readerTimeout)
                return self.outcome(for: reading, seams: seams, stamp: stamp, report: report, live: live)
            }
            return true
        case .choose(let hit, let requestID)?:
            // The picker's world must still be the one it was read in.
            if let asked = askedStamp, asked != currentStamp() {
                drop(saying: djChangedLine)
                return true
            }
            let seams = self.seams
            startRequest(requestID: requestID) { live, stamp, report in
                self.artistMixOutcome(name: hit.title, chosen: hit, seams: seams, stamp: stamp,
                                      report: report, live: live)
            }
            return true
        case nil:
            return out.changed
        }
    }

    /// The box abandons what it held and says why: used when the person left
    /// Now while a request was out, so an answer cannot play long after, unseen.
    func abandon(saying words: String) {
        session += 1
        model.drop(saying: words)
        release()
    }

    private func drop(saying words: String) {
        model.drop(saying: words)
        release()
    }

    // MARK: asking

    /// Starts one background job for a request the model just numbered, under
    /// the session and stamp of now. A nil answer is a job that found itself
    /// stale: nothing is delivered for it.
    private func startRequest(requestID: Int,
                              _ work: @escaping (_ live: @escaping () -> Bool, _ stamp: DJStamp,
                                                 _ report: @escaping (DJOutcome) -> Void) -> DJOutcome?) {
        let session = self.session
        let stamp = currentStamp()
        askedStamp = stamp
        lock.lock(); live = (session, requestID); inbox = nil; lock.unlock()
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let live: () -> Bool = { self.isLive(session, requestID, stamp) }
            // Everything this job delivers, progress included, goes out under the
            // session and request it began in, never under whatever is current.
            let report: (DJOutcome) -> Void = { self.deliver(session: session, requestID: requestID, $0) }
            guard let outcome = work(live, stamp, report), live() else { return }
            report(outcome)
        }
    }

    /// One answer into the slot. Only the request the box is waiting on takes
    /// it, judged here under the lock that guards the slot: an answer from a
    /// box abandoned, a request since replaced or a job since released finds
    /// the pair no longer live and is dropped. (A request at least as new as
    /// the one already there replaces it; the older never does.)
    private func deliver(session: Int, requestID: Int, _ outcome: DJOutcome) {
        lock.lock()
        var written = false
        if live.session == session, live.requestID == requestID {
            if let held = inbox, (held.session, held.requestID) > (session, requestID) {
                // A newer request already holds the slot.
            } else {
                inbox = (session, requestID, outcome)
                written = true
            }
        }
        lock.unlock()
        if written { inboxWritten?("dj") }
    }

    /// The reader is async; the job is a plain background thread. Never on the
    /// input loop.
    private static func blockingRead(_ reader: DJReader, _ prompt: String, timeout: TimeInterval) -> DJReading {
        final class Slot: @unchecked Sendable { var value: DJReading = .failed("The DJ didn't answer.") }
        let slot = Slot()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let reading = await reader.read(prompt)
            if !Task.isCancelled { slot.value = reading }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            // Abandoned: whatever the reader says later is written nowhere this
            // call (or any box) reads.
            task.cancel()
            return .failed(djReaderTimedOutLine)
        }
        return slot.value
    }

    // MARK: tick

    /// Apply the answer in the slot, play a plan that arrived, and drop what
    /// the world has left behind. True when the screen changed.
    func tick() -> Bool {
        lock.lock()
        let incoming = inbox
        inbox = nil
        let failure = playFailure
        playFailure = nil
        lock.unlock()

        var changed = false
        if let failure, failure.session == session,
           model.playFailed(requestID: failure.requestID, saying: failure.words) {
            changed = true
        }
        if let incoming, incoming.session == session {
            // An answer from a world that has since moved is no answer.
            if let asked = askedStamp, asked != currentStamp() {
                model.drop(saying: djChangedLine)
                askedStamp = nil
                return true
            }
            switch model.receive(incoming.outcome, requestID: incoming.requestID) {
            case .ignored:
                break
            case .changed:
                changed = true
            case .play(let plan):
                changed = true
                play(plan, requestID: incoming.requestID)
            }
        }
        // A picker or a request in flight belongs to the world it was asked in:
        // an output switch or another play drops it, and says so.
        switch model.stage {
        case .reading, .working, .pick:
            if let asked = askedStamp, asked != currentStamp() {
                model.drop(saying: djChangedLine)
                askedStamp = nil
                clearSlot()
                changed = true
            }
        case .typing, .playing, .message:
            break
        }
        return changed
    }

    // MARK: the answer to one request

    private func outcome(for reading: DJReading, seams: DJSeams, stamp: DJStamp,
                         report: @escaping (DJOutcome) -> Void, live: @escaping () -> Bool) -> DJOutcome? {
        guard live() else { return nil }
        switch reading {
        case .unavailable(let reason):
            return .message(reason.message)
        case .failed(let text):
            return .message(text == djReaderTimedOutLine ? text : djFailedLine(text))
        case .card(let card):
            switch card.kind {
            case .unsupported:
                return .message(djUnsupportedRequest)
            case .artistMix:
                guard let artist = card.artist else { return .message(djUnsupportedRequest) }
                return artistMixOutcome(name: artist, chosen: nil, seams: seams, stamp: stamp,
                                        report: report, live: live)
            case .genreUnheard:
                guard let genre = card.genre else { return .message(djUnsupportedRequest) }
                return genreOutcome(genre: genre, seams: seams, stamp: stamp, live: live)
            }
        }
    }

    /// An artist mix: SpanDAC data on a SpanDAC output only. Every other
    /// combination is told so before anything is read (the coordinator refuses
    /// the play itself again, whatever this says).
    private func artistMixOutcome(name: String, chosen: CatalogueHit?, seams: DJSeams, stamp: DJStamp,
                                  report: @escaping (DJOutcome) -> Void, live: @escaping () -> Bool) -> DJOutcome? {
        switch routing.selection {
        case .consistent(.spandacMac, .musicApp): return .message(djArtistMixSpanDACOnly)
        case .consistent(.spandacMac, _): break
        default: return .message(djArtistMixNeedsSpanDACData)
        }
        seams.beforeProgress()
        report(.working(chosen?.title ?? name))
        do {
            let choice: ProviderChoice<DJCatalogue?> = try routing.choose(.catalogSearch,
                musicApp: { nil },
                source: { BridgeMusicProvider(control: $0.control) })
            guard live() else { return nil }
            guard choice.stamp == stamp.routing, let catalogue = choice.provider else { return .message(djChangedLine) }
            let artist: CatalogueHit
            if let chosen {
                artist = chosen
            } else {
                let results = try catalogue.browseCatalogue(term: name, limit: Self.searchLimit)
                guard live() else { return nil }
                guard results.artistsServed else {
                    return .message(results.artistsNote ?? CatalogueSearchResults.artistsNeedNewerSpanDAC)
                }
                switch djResolveArtist(named: name, in: results.artists) {
                case .none: return .message(djNoArtistFound(name))
                case .pick(let hits): return .pick(artist: name, hits: hits)
                case .chosen(let hit): artist = hit
                }
            }
            let mix = try djBuildArtistMix(artist: artist, catalogue: catalogue, shuffler: seams.shuffler,
                                           isCurrent: live)
            return .plan(DJPlan(payload: .artistMix(mix), line: mix.line, stamp: stamp))
        } catch let error as DJArtistMixError {
            return error == .cancelled ? nil : .message(error.message)
        } catch {
            return .message(djErrorText(error))
        }
    }

    /// "A genre I haven't heard lately", from the data source now selected.
    private func genreOutcome(genre: String, seams: DJSeams, stamp: DJStamp,
                              live: @escaping () -> Bool) -> DJOutcome? {
        let days = djUnheardDays
        let title = "\(genre) you haven't played"
        do {
            switch routing.selection {
            case .consistent(.open, .musicApp):
                // MusicTUI's own data on the MusicTUI output: a separate timed
                // read of Music's library, in the bulk-column shape.
                try refuseOpenDataPlayBeforeReading(.libraryPlay, routing: routing, spanDACData: false)
                let read = try djReadLibraryForGenre(run: seams.runScript)
                guard live() else { return nil }
                let pick = djPickUnheard(read.songs, genre: genre, now: seams.now(), days: days,
                                         limit: djGenreSongLimit, shuffler: seams.shuffler)
                guard !pick.picked.isEmpty else {
                    let skipped = pick.unreadable > 0
                        ? " (\(pick.unreadable) with an unreadable date skipped.)" : ""
                    return .message(djNoGenreSongs(genre: genre, days: days) + skipped)
                }
                guard let queue = djOpenQueue(pick.picked, title: title) else {
                    return .message("Some of those songs have no identity MusicTUI can play by, so nothing played.")
                }
                return .plan(DJPlan(payload: .genreOpen(queue), line: pick.line(genre: genre, days: days),
                                    stamp: stamp))

            case .consistent(.spandacMac, let output):
                let choice: ProviderChoice<DJSpanDACGenreSource> = try routing.choose(.searchLibrary,
                    musicApp: { throw ActionError(message: djChangedLine) },
                    source: { seams.spandacGenre($0) })
                guard live() else { return nil }
                guard choice.stamp == stamp.routing else { return .message(djChangedLine) }
                let result = try choice.provider.genreUnheard(genre: genre, days: days)
                guard live() else { return nil }
                // SpanDAC's own queue refuses two songs of one exact title, so on a
                // SpanDAC output keep the first (oldest) of each before the plan is
                // frozen. The MusicTUI output is a hand-off with no such refusal.
                var offered = Array(result.rows.prefix(djGenreSongLimit))
                var repeated = 0
                if output != .musicApp {
                    (offered, repeated) = djFirstPerTitle(offered, title: \.title)
                }
                let rows = seams.shuffler.shuffled(offered)
                guard !rows.isEmpty else { return .message(djNoGenreSongs(genre: genre, days: days)) }
                // The MusicTUI output plays only songs with a verified alias; one
                // without fails the whole pick, nothing substituted.
                if output == .musicApp, rows.contains(where: { $0.alias == nil }) {
                    return .message(djGenreNeedsAliases)
                }
                return .plan(DJPlan(payload: .genreSpanDAC(rows: rows, pick: result, title: title),
                                    line: djGenreLine(genre: genre, days: days, songs: rows.count,
                                                    repeatedTitles: repeated), stamp: stamp))

            default:
                // MusicTUI's own data with a SpanDAC output stored: refuses as
                // a marked play does, before any read.
                try refuseOpenDataPlayBeforeReading(.libraryPlay, routing: routing, spanDACData: false)
                return .message(djChangedLine)
            }
        } catch let error as DJLibraryReadError {
            return .message(error.message)
        } catch let error as DJGenreSourceError {
            return .message(error.message)
        } catch {
            return .message(djErrorText(error))
        }
    }

    // MARK: playing the plan

    /// Plays exactly the frozen plan, once, on the action queue. The stamp of
    /// the Enter that asked for it must still hold now (and is checked again
    /// inside the coordinator, with the play serial, when the action runs).
    private func play(_ plan: DJPlan, requestID: Int) {
        guard plan.stamp == currentStamp() else {
            drop(saying: djChangedLine)
            return
        }
        askedStamp = nil
        clearSlot()
        let routing = self.routing
        let status = self.status
        let seams = self.seams
        let stamp = plan.stamp.routing
        let serial = plan.stamp.playSerial
        let session = self.session
        actions.run("Play") { [weak self] in
            do {
                switch plan.payload {
                case .artistMix(let mix):
                    try Self.playArtistMix(mix, stamp: stamp, serial: serial, routing: routing, status: status)
                case .genreOpen(let queue):
                    try Self.playGenreOpen(queue, stamp: stamp, serial: serial, routing: routing, status: status,
                                           seams: seams)
                case .genreSpanDAC(let rows, let pick, let title):
                    try Self.playGenreSpanDAC(rows: rows, pick: pick, title: title, stamp: stamp, serial: serial,
                                              routing: routing, status: status, seams: seams)
                }
            } catch let error as ActionError {
                self?.noteFailure(session: session, requestID: requestID, error.message)
                throw error
            } catch {
                // ActionRunner reduces anything but an ActionError to "Play failed."
                let words = djErrorText(error)
                self?.noteFailure(session: session, requestID: requestID, words)
                throw ActionError(message: words)
            }
        }
    }

    /// A play that did not start: the box stops saying "Playing" at the next tick.
    private func noteFailure(session: Int, requestID: Int, _ words: String) {
        lock.lock(); playFailure = (session, requestID, words); lock.unlock()
        inboxWritten?("dj")
    }

    /// One `slice.queue` of the frozen catalogue ids on a SpanDAC output. The
    /// coordinator refuses the artist-mix origin on the MusicTUI output before
    /// any body runs.
    private static func playArtistMix(_ mix: DJArtistMix, stamp: (epoch: Int, dataEpoch: Int), serial: Int,
                                      routing: RoutingCoordinator, status: StatusStore) throws {
        try routing.perform(.discoverTrackPlay, expecting: stamp, expectingPlaySerial: serial, origin: .djArtistMix,
            musicApp: { _ in throw ActionError(message: djArtistMixSpanDACOnly) },
            source: { client in
                let skipped = try BridgeMusicProvider(control: client.control).playCatalogue(ids: mix.ids)
                let base = "Playing \(mix.artistName) mix on SpanDAC \u{2014} \(djCount(mix.ids.count, "song"))."
                status.post(skipped > 0 ? base + " " + bridgeUnavailableSongsNotice(skipped) : base,
                            untilStateChange: skipped > 0)
            },
            unaffected: {})
    }

    /// MusicTUI's own data: the app-owned queue, addressed by persistent ID,
    /// set and started exactly as a marked play does.
    private static func playGenreOpen(_ queue: AppQueue, stamp: (epoch: Int, dataEpoch: Int), serial: Int,
                                      routing: RoutingCoordinator, status: StatusStore,
                                      seams: DJSeams) throws {
        let store = seams.appQueue
        try routing.perform(.libraryPlay, expecting: stamp, expectingPlaySerial: serial,
                            origin: .openData(resultNumber: nil),
            musicApp: { path in
                guard path == .shipped else { throw ActionError(message: pickASpanDACOutput) }
                store.set(queue)
                guard seams.playFirst(queue) else {
                    store.clear()
                    throw ActionError(message: "Couldn't play '\(queue.contextLabel)'.")
                }
                status.post(LibraryProvenance.playingOnMusicTUI(queue.contextLabel))
            },
            source: { _ in throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList) },
            unaffected: {})
    }

    /// SpanDAC's data: the library rows, queued by library id on a SpanDAC
    /// output (as a combined play), or handed to the MusicTUI output by
    /// verified alias. The library is re-checked first; a changed one plays nothing.
    private static func playGenreSpanDAC(rows: [MusicRow], pick: DJSpanDACGenrePick, title: String,
                                         stamp: (epoch: Int, dataEpoch: Int), serial: Int,
                                         routing: RoutingCoordinator, status: StatusStore, seams: DJSeams) throws {
        do {
            // The check is of the very rows about to be queued or handed off.
            let chosen = DJSpanDACGenrePick(rows: rows, total: pick.total, instance: pick.instance,
                                            generation: pick.generation, genre: pick.genre, days: pick.days)
            try seams.spandacGenre(routing.dataClient()).recheck(chosen)
        } catch let error as DJGenreSourceError {
            throw ActionError(message: error.message)
        } catch {
            throw ActionError(message: DJGenreSourceError.failed(djErrorText(error)).message)
        }
        try routing.perform(.libraryPlay, expecting: stamp, expectingPlaySerial: serial, origin: .spandacLibrary,
            musicApp: { path in
                guard path == .handoff else { throw ActionError(message: pickASpanDACOutput) }
                guard rows.allSatisfy({ $0.alias != nil }) else { throw ActionError(message: djGenreNeedsAliases) }
                let report = try playThroughHandoff(seams.handoff, rows: rows, startAt: 1, startRequired: false,
                                                    shuffle: false, title: title)
                status.post(LibraryProvenance.playingOnMusicTUI(title, report: report),
                            untilStateChange: report.notice != nil)
            },
            source: { client in
                let played = try spanDACOutputPlayer(client).playRetainingToken(ids: rows.map(\.id), startRequired: false)
                routing.recordSpanDACPlay(rows, token: played.queueToken, shuffled: played.skippedUnavailable > 0)
                let base = "Playing \(title) on SpanDAC \u{2014} \(djCount(rows.count, "song"))."
                status.post(played.skippedUnavailable > 0
                                ? base + " " + bridgeUnavailableSongsNotice(played.skippedUnavailable) : base,
                            untilStateChange: played.skippedUnavailable > 0)
            },
            unaffected: {})
    }
}
