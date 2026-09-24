// tools/music/Sources/TUI/MusicProvider.swift
import Foundation

/// The backend-neutral row the scenes render.
///
/// **`id` belongs to whichever backend produced the row and is opaque to the
/// UI.** In Music.app mode it is a Music.app identifier; in Bridge mode it is a
/// MusicKit one. Nothing above this seam may compare, parse or convert them:
/// Music.app exposes `id`/`persistent ID`/`database ID` and MusicKit exposes its
/// own resource ids, and no mapping between the two exists (verified
/// 2026-09-23). The old `(title, artist, album)` join existed only because a
/// Bridge play began from an AppleScript row; under "two modes, two libraries"
/// (Anthony, 2026-09-23) a row is played with the id its own provider gave it.
struct MusicRow: Equatable {
    enum Kind: String, Equatable { case song, album, playlist, station, artist }
    let id: String
    let title: String
    let artist: String
    let album: String?
    let kind: Kind
    /// MusicKit `Album.trackCount`, for an album row only. `nil` for every other
    /// kind — the memberwise default keeps every existing call site
    /// source-compatible.
    var trackCount: Int? = nil
}

/// One container's rows: complete, or refused — never paged and never partial
/// (D2). An album's tracks, an artist's albums, or an artist's songs.
struct MusicList: Equatable {
    let rows: [MusicRow]
    let generation: Int
    let stale: Bool
    let refreshing: Bool
}

/// One page of rows, with the provider's own place-marker.
///
/// **`cursor` is opaque.** Bridge's encodes the snapshot generation, the offset
/// and the ordering version; the client stores it and hands it back, and reads
/// nothing out of it. `total` is the row count of the observation this page came
/// from, so a list can show "of 15,646" before it has them all.
struct MusicPage: Equatable {
    let rows: [MusicRow]
    let nextCursor: String?
    let total: Int?
    /// The provider's observation boundary, when it has one. A page whose
    /// generation differs from the one a list started with is a different
    /// library, not more of the same list.
    let generation: Int?
    /// This page came from a snapshot older than the provider's refresh age.
    /// **Information, never a failure.** Under stale-while-revalidate the whole
    /// point is that an old snapshot is served instantly rather than a person
    /// waiting on a drain, so a stale page renders exactly like a fresh one.
    let stale: Bool
    /// A background refresh is running. Also information: the rows in hand are
    /// good, and better ones may follow under a new generation.
    let refreshing: Bool

    init(rows: [MusicRow], nextCursor: String?, total: Int?, generation: Int?,
         stale: Bool = false, refreshing: Bool = false) {
        self.rows = rows
        self.nextCursor = nextCursor
        self.total = total
        self.generation = generation
        self.stale = stale
        self.refreshing = refreshing
    }
}

/// What a provider could not do, in words a person can read.
enum MusicProviderError: Error, LocalizedError, Equatable {
    /// The library changed underneath a paged read. The list restarts; nothing
    /// is re-based onto the new observation behind the person's back.
    case staleGeneration(String)
    /// The backend answered, and refused.
    case refused(String)
    /// The backend could not be reached or could not be read.
    case unavailable(String)
    /// This provider does not serve this operation in this build.
    case notImplemented(String)
    /// Not ready YET, with the provider's own hint for when to ask again.
    ///
    /// **A transient, not a refusal.** A list that renders this as "empty" or
    /// as "couldn't read your library" tells a person something false about
    /// their library on an ordinary open — which is exactly what happened on
    /// 2026-09-23, when a cold read paid for a 6.4s drain inline, blew the
    /// socket timeout, and showed a library of 0 songs.
    case warming(String, retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .staleGeneration(let why), .refused(let why),
             .unavailable(let why), .notImplemented(let why), .warming(let why, _):
            return why
        }
    }
}

/// Where a scene's rows and playback come from, decided by the selected output.
///
/// **One selected output owns both halves** — data and playback — which is the
/// whole of the 2026-09-23 product decision. A provider never falls back to the
/// other backend: a failure is reported as its own backend's failure (rule 3).
///
/// Only the operations the first vertical slice needs are declared here. The
/// rest of the seam (playlists, container tracks, search, Discover rails,
/// stations, history) arrives with its own migration step rather than as empty
/// methods nobody implements.
protocol MusicDataProvider {
    /// A page of the library's songs. `cursor` nil starts at the beginning.
    func librarySongs(cursor: String?, limit: Int) throws -> MusicPage
    /// A page of the library's albums (D1): MusicKit's own album entities, not
    /// song rows grouped by title.
    func libraryAlbums(cursor: String?, limit: Int) throws -> MusicPage
    /// A page of the library's artists (D1).
    func libraryArtists(cursor: String?, limit: Int) throws -> MusicPage
    /// One album's tracks, complete or refused (D2): never a title-and-credit
    /// match, and never partial.
    func albumTracks(albumID: String) throws -> MusicList
    /// One artist's albums (D2), for the drill-in — a browse view, distinct
    /// from `artistSongs` (D1's "artist play is the song relationship").
    func artistAlbums(artistID: String) throws -> MusicList
    /// One artist's songs (D2): what an artist PLAYS, per ruling 12.2.
    func artistSongs(artistID: String) throws -> MusicList
    /// Play exactly these ids, in this order, and report the queue that
    /// resulted. Ids are this provider's own.
    func play(ids: [String]) throws -> BridgeNow.Queue
    /// What the selected backend is doing now.
    func nowPlaying() throws -> SourceStatus
}

/// Defaults for the five slice-2 reads, so a provider written before D1/D2 (in
/// particular the `Fake` test doubles in `BridgeLibrarySceneTests`, which
/// implement only the three original methods) keeps compiling untouched. Each
/// default is exactly the sentence `BridgeMusicProvider` gives for an older
/// Bridge's `unknown_op` (D6), so a provider that genuinely does not implement
/// these reports the same "update Bridge" a contract mismatch would.
extension MusicDataProvider {
    func libraryAlbums(cursor: String?, limit: Int) throws -> MusicPage {
        throw MusicProviderError.notImplemented("This Bridge build can't list your albums — update Bridge")
    }
    func libraryArtists(cursor: String?, limit: Int) throws -> MusicPage {
        throw MusicProviderError.notImplemented("This Bridge build can't list your artists — update Bridge")
    }
    func albumTracks(albumID: String) throws -> MusicList {
        throw MusicProviderError.notImplemented("This Bridge build can't list an album's tracks — update Bridge")
    }
    func artistAlbums(artistID: String) throws -> MusicList {
        throw MusicProviderError.notImplemented("This Bridge build can't list an artist's albums — update Bridge")
    }
    func artistSongs(artistID: String) throws -> MusicList {
        throw MusicProviderError.notImplemented("This Bridge build can't play an artist — update Bridge")
    }
}

/// Walk every page of a paged library read, handing each page to `onPage` as it
/// arrives, and restarting ONCE when the library changes underneath.
///
/// **Generic over the fetch, not over the provider (revision 2, D1).** Songs,
/// Albums and Artists are three separate paged reads on `MusicDataProvider`
/// (`librarySongs`, `libraryAlbums`, `libraryArtists`), so the walk takes the
/// one method it should call as a closure rather than the whole provider.
/// `walkLibrarySongs` below is the one-line wrapper C1 keeps for its existing
/// callers and tests; C2 calls this directly for Albums and Artists.
///
/// Returns nil when the walk completed (or the caller asked it to stop), and the
/// error that ended it otherwise. Pure with respect to the scene: it owns no
/// state, so it is tested against a fake fetch without standing one up.
///
/// **A restart discards everything the first attempt produced.** That is the
/// whole reason this is a walk and not a loop: rows from two observations of the
/// library are two different lists, and stitching them together would show a
/// list that never existed. `onRestart` is the caller's cue to throw away what
/// it has collected; it runs BEFORE the first page of the second attempt.
///
/// **Once, and then it is a failure.** A library that changes twice under one
/// read is not a transient the person should be kept waiting through: the second
/// `staleGeneration` comes back as the returned error, so the list says so.
///
/// `onPage` returns false to abort (the scene was torn down), which ends the
/// walk with no error — nothing failed, there is just nobody to tell.
///
/// `onWarming` fires each time the provider says "not ready yet", so a list can
/// say so while the walk waits. `sleep` is injected so the wait is real in the
/// app and instant in a test.
func walkLibraryPages(fetch: (String?, Int) throws -> MusicPage,
                      limit: Int = 100,
                      onPage: (MusicPage) -> Bool,
                      onRestart: () -> Void,
                      onWarming: (TimeInterval) -> Void = { _ in },
                      sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) })
                      -> MusicProviderError? {
    func attempt() -> LibraryPageWalkOutcome {
        attemptLibraryPageWalk(fetch: fetch, limit: limit, onPage: onPage,
                               onWarming: onWarming, sleep: sleep)
    }
    switch attempt() {
    case .finished:
        return nil
    case .failed(let error):
        return error
    case .stale:
        onRestart()
        switch attempt() {
        case .finished:          return nil
        case .failed(let error): return error
        case .stale(let why):    return .staleGeneration(why)
        }
    }
}

/// The Songs list's walk, unchanged in behaviour: a thin wrapper over
/// `walkLibraryPages` bound to `provider.librarySongs`.
func walkLibrarySongs(_ provider: MusicDataProvider,
                      limit: Int = 100,
                      onPage: (MusicPage) -> Bool,
                      onRestart: () -> Void,
                      onWarming: (TimeInterval) -> Void = { _ in },
                      sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) })
                      -> MusicProviderError? {
    walkLibraryPages(fetch: provider.librarySongs, limit: limit, onPage: onPage,
                     onRestart: onRestart, onWarming: onWarming, sleep: sleep)
}

/// How long a list, or a play, waits on a provider that is still preparing
/// itself.
///
/// The hint is the provider's, the bounds are the client's: a hint of 0 would
/// spin and a hint of an hour would hang, and neither is something a caller
/// should be able to do to this process.
///
/// **60 s of total waiting, not a fixed attempt count (D5, the controller's
/// 2026-09-23 ruling).** A cold drain measured 23.16 s that same night, against
/// the old budget of 10 attempts at a clamped hint — about 10 s, well short of
/// it. 60 s covers that drain about 2.6 times over, and the budget is spent in
/// wall-clock time waited, not in requests made, so a slow drain that answers a
/// short hint gets more tries rather than running out on a technicality.
enum LibraryWarmUp {
    static let maxTotalWait: TimeInterval = 60
    static let minWait: TimeInterval = 0.25
    static let maxWait: TimeInterval = 5.0
    static func wait(forHint hint: TimeInterval) -> TimeInterval {
        min(maxWait, max(minWait, hint))
    }
    /// What a list, or a play, says when it has run out of patience. Distinct
    /// from the "still going" line, because a person needs to know it has
    /// STOPPED.
    static let gaveUp = "Bridge is still preparing your library"
}

/// One warm-up budget, spent across however many requests share it, in seconds
/// of waiting rather than in attempts (D5).
///
/// A budget is the CALLER's, not the retry helper's, so a paged walk spends one
/// allowance across a whole list rather than a fresh one on every one of 157
/// pages — which is the difference between waiting a bounded time and waiting
/// an unbounded multiple of it. A play action shares one budget across its
/// membership read and its queue (C3), for the same reason.
final class WarmUpBudget {
    private(set) var waited: TimeInterval = 0

    /// The next wait for this hint, or nil when the budget is spent: the
    /// clamped hint, shortened so `waited` never exceeds `maxTotalWait`.
    /// Records what it returns, so the last wait before giving up can be
    /// shorter than the hint would otherwise call for, rather than overshooting
    /// the budget to finish out a clamped wait.
    func nextWait(forHint hint: TimeInterval) -> TimeInterval? {
        let remaining = LibraryWarmUp.maxTotalWait - waited
        guard remaining > 0 else { return nil }
        let next = min(LibraryWarmUp.wait(forHint: hint), remaining)
        waited += next
        return next
    }

    init() {}
}

/// Run a Bridge request that may answer "not ready yet", waiting on the
/// provider's own hint until the budget runs out.
///
/// **One policy, not two.** The library walk and a cold queue both wait exactly
/// this way: same clamp, same bound, same give-up sentence. A second copy would
/// drift, and the two would disagree about how patient this app is.
///
/// **`body` must be safe to repeat.** Both current callers are: a page read
/// mutates nothing, and Bridge acquires its snapshot BEFORE it touches the
/// player, so a queue that answered `warming` changed nothing to re-send.
func retryingWhileWarming<T>(budget: WarmUpBudget = WarmUpBudget(),
                             onWarming: (TimeInterval) -> Void = { _ in },
                             sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                             _ body: () throws -> T) throws -> T {
    while true {
        do {
            return try body()
        } catch let error as MusicProviderError {
            guard case .warming(_, let hint) = error else { throw error }
            guard let wait = budget.nextWait(forHint: hint) else {
                // Not "it failed": it is STILL preparing, and this client has
                // stopped waiting. A person can ask again. Never sleeps: the
                // budget is spent, so this is the give-up itself.
                throw MusicProviderError.warming(LibraryWarmUp.gaveUp, retryAfter: hint)
            }
            onWarming(hint)
            sleep(wait)
        }
    }
}

private enum LibraryPageWalkOutcome {
    case finished
    case stale(String)
    case failed(MusicProviderError)
}

/// One attempt at the whole list. A page whose `generation` differs from the one
/// this attempt started with is stale even when the provider did not say so —
/// the generation on the page is the observation boundary, and the client is not
/// entitled to assume a provider will always catch the change for it.
private func attemptLibraryPageWalk(fetch: (String?, Int) throws -> MusicPage, limit: Int,
                                    onPage: (MusicPage) -> Bool,
                                    onWarming: (TimeInterval) -> Void,
                                    sleep: (TimeInterval) -> Void) -> LibraryPageWalkOutcome {
    var cursor: String? = nil
    var generation: Int? = nil
    // ONE budget for the whole attempt. A restart gets a fresh one, because a
    // restarted list is a new list and deserves its own patience.
    let budget = WarmUpBudget()
    while true {
        let page: MusicPage
        do {
            // Not ready yet: ask again for the SAME page, on the provider's own
            // hint. Never a failure while the budget holds, because "empty
            // library" would be a lie — and never a restart, because the
            // library did not change, the page was just not ready.
            page = try retryingWhileWarming(budget: budget, onWarming: onWarming, sleep: sleep) {
                try fetch(cursor, limit)
            }
        } catch let error as MusicProviderError {
            if case .staleGeneration(let why) = error { return .stale(why) }
            return .failed(error)
        } catch {
            return .failed(.unavailable(error.localizedDescription))
        }
        if let seen = page.generation {
            if let started = generation, started != seen {
                return .stale("the library changed while you were reading it; start again")
            }
            generation = seen
        }
        guard onPage(page) else { return .finished }   // nobody left to tell
        guard let next = page.nextCursor else { return .finished }
        cursor = next
    }
}

/// The start-row / shuffle rule for a Bridge collection play (D3), the same
/// rule `bridgeCollectionRows` applies to Music.app-mode rows: shuffle sends
/// every id, shuffled, and ignores the start row; otherwise the start row is
/// clamped to 1...count and every row from it to the end is sent.
func bridgeQueueIDs(_ rows: [MusicRow], shuffle: Bool, startAt: Int) -> [String] {
    if shuffle { return rows.shuffled().map(\.id) }
    guard !rows.isEmpty else { return [] }
    let start = min(max(1, startAt), rows.count)
    return rows[(start - 1)...].map(\.id)
}

/// A count a person reads, grouped in threes: 15646 → "15,646".
///
/// Deliberately not a `NumberFormatter`: the separator must not change with the
/// machine's locale, because this string is part of what the Songs list claims
/// about which library it is showing.
func groupedCount(_ n: Int) -> String {
    let digits = Array(String(abs(n)))
    var out = ""
    for (i, d) in digits.enumerated() {
        if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
        out.append(d)
    }
    return (n < 0 ? "-" : "") + out
}

/// What one wire row turned out to be. Three outcomes, not two, because a row
/// this build DECLINES to serve and a row this build CANNOT READ are different
/// facts about the page they came from.
enum MusicRowReading: Equatable {
    /// A row this build serves.
    case row(MusicRow)
    /// Well-formed, and names a kind this build does not serve. **Dropped, never
    /// guessed at** — the rule the Discover feed already follows for unknown
    /// rail kinds. A page carrying one is still a good page: the peer told the
    /// truth and this client is the one that is behind.
    case unknownKind(String)
    /// Not a row at all: a required field is missing or the wrong type. The
    /// peer broke the contract, so this says what was wrong rather than
    /// shrinking the page by one and saying nothing.
    case malformed(String)
}

/// Read one wire row, distinguishing "I do not serve this" from "this is not a
/// row".
///
/// **The two rules do not conflict, and the boundary is the `kind` FIELD.** A
/// row that carries a kind this build does not know is a row: it is complete,
/// it is honest, and dropping it loses nothing a person could have used. A row
/// with no id, no title or no kind at all cannot be rendered or played and its
/// absence cannot be distinguished from a truncated page — which is why the
/// caller on the library path refuses the whole page for it.
func readMusicRow(_ item: [String: Any]) -> MusicRowReading {
    guard let id = item["id"] as? String, !id.isEmpty else {
        return .malformed("a row with no id")
    }
    guard let title = item["title"] as? String else {
        return .malformed("a row with no title (id \(id))")
    }
    guard let kindName = item["kind"] as? String else {
        return .malformed("a row with no kind (id \(id))")
    }
    guard let kind = MusicRow.Kind(rawValue: kindName) else {
        return .unknownKind(kindName)
    }
    // An album row carries its own track count (MusicKit `Album.trackCount`),
    // required and never negative: it feeds the tier filter and the "N
    // tracks" line, and a row silently missing it would misclassify or
    // mislabel rather than say so.
    var trackCount: Int? = nil
    if kind == .album {
        guard let count = item["track_count"] as? Int, count >= 0 else {
            return .malformed("an album row with no track_count (id \(id))")
        }
        trackCount = count
    }
    // An absent `artist` reads as an empty credit rather than a fault: a row
    // with no credit is a thing Apple Music genuinely has, it renders as a
    // blank credit a person can SEE, and it is still playable by its id. An
    // absent `album` is legal by the same reasoning and is already pinned.
    return .row(MusicRow(id: id, title: title,
                         artist: item["artist"] as? String ?? "",
                         album: item["album"] as? String,
                         kind: kind,
                         trackCount: trackCount))
}
