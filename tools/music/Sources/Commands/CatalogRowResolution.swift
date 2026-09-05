// tools/music/Sources/Commands/CatalogRowResolution.swift
import Foundation

/// One row the library reports, reduced to what identifies it.
struct LibraryRowIdentity: Equatable {
    let persistentID: String
    let name: String
    let artist: String
    let album: String
    /// Carried so the pre-existing fallback can require a PLAYABLE row: a
    /// pre-release or removed track would satisfy every metadata check and then
    /// silently no-op on play.
    let cloudStatus: String

    init(persistentID: String, name: String, artist: String, album: String,
         cloudStatus: String = "subscribed") {
        self.persistentID = persistentID
        self.name = name
        self.artist = artist
        self.album = album
        self.cloudStatus = cloudStatus
    }
}

/// The result of trying to find the row a catalog add just created.
enum CatalogRowResolution: Equatable {
    /// Exactly one row is plausible. Its identifier is carried forward and no
    /// further name lookup happens.
    ///
    /// `viaPreExisting` is false for a row that appeared after the add, and
    /// true for the idempotent case: the add created nothing because the track
    /// was already in the library, so the row was chosen by metadata alone.
    /// That distinction is load-bearing for the message, because the second
    /// case is a weaker claim and must not be worded like the first.
    case resolved(persistentID: String, viaPreExisting: Bool)
    /// The budget ran out and no new plausible row ever appeared.
    case notYetVisible(attempts: Int)
    /// More than one row is plausible, so we do not know which one was asked
    /// for. Fail closed: playing a coin flip is worse than not playing.
    case ambiguous(count: Int, amongPreExisting: Bool)
    /// A new plausible row was observed at least once but never confirmed
    /// twice running. The add evidently created something, so the idempotent
    /// fallback does not apply: playing the copy the user already had would be
    /// the wrong track. Codex, on 9ccb333.
    case newRowUnconfirmed
    /// The unique owned copy is there and matches, but is not playable
    /// (pre-release or removed). Distinct from "not yet visible", which would
    /// be a false diagnosis: the track appeared, it was already there.
    case ownedUnplayable(matched: Int)
    /// The library could not be read. Distinct from "no new row": we do not
    /// know what is there, rather than knowing nothing new is. §20.6's rule,
    /// applied here after Codex found the baseline treating a failed read as
    /// an empty library.
    case unreadable
}

/// Find the library row a catalog add just created.
///
/// Identity first, attributes second (Anthony, 2026-09-03: "identify the newly
/// added catalog song using every stable attribute available, not merely its
/// name, and fail closed if multiple library rows remain plausible").
///
/// The primary signal is a set difference over `persistent ID`: whatever is in
/// the library now and was not there before the add is a candidate. That is
/// stronger than any attribute match, because it does not care what the row is
/// called. Attributes then narrow the candidates, using normalised title,
/// artist and album rather than the title alone, which is what makes a
/// same-titled track by a different artist fall out.
///
/// Ambiguity is decided over CANDIDATES, not over the whole library, so the
/// user's own pre-existing copy of the same song is not a source of ambiguity:
/// it was there before, so it is not new.
///
/// The scheduled attempts are followed by exactly one more read, which both
/// confirms a candidate first seen on the last attempt and is the only
/// snapshot the pre-existing fallback consults. So the effective deadline for
/// a new row's FIRST sighting is the last scheduled attempt, about
/// `(attempts - 1) * interval` seconds; a row that first appears later than
/// that is reported as not yet visible rather than played on one look.
///
/// Polling exists because the row is not there immediately. Measured
/// 2026-09-03: an added track was not resolvable at t+0, t+1 or t+2 and
/// appeared at t+3, one second inside the fixed four-second sleep this
/// replaces. A fixed sleep tuned to one machine on one connection is exactly
/// the wrong shape; a bounded retry that reports honestly when it gives up is
/// the right one.
func resolveAddedCatalogRow(title: String,
                            artist: String,
                            album: String,
                            idsBefore: Set<String>,
                            attempts: Int = 20,
                            readRows: () -> [LibraryRowIdentity]?,
                            wait: (Double) -> Void,
                            interval: Double = 0.5) -> CatalogRowResolution {
    let wantTitle = normalizeAlbumTitle(title)
    let wantArtist = normalizeCredit(artist)
    let wantAlbum = normalizeAlbumTitle(album)

    /// Every attribute we have, applied to one row. Album is only compared when
    /// both sides carry one, so a row with a blank album is not excluded by a
    /// comparison it cannot win.
    func matches(_ row: LibraryRowIdentity) -> Bool {
        guard normalizeAlbumTitle(row.name) == wantTitle else { return false }
        guard wantArtist.isEmpty || normalizeCredit(row.artist) == wantArtist else { return false }
        guard wantAlbum.isEmpty || row.album.isEmpty
                || normalizeAlbumTitle(row.album) == wantAlbum else { return false }
        return true
    }

    let budget = max(1, attempts)
    // The candidate seen alone in the PREVIOUS successful observation. A new
    // row must be the sole plausible arrival twice running before it is played
    // (Anthony, 2026-09-04, as cheap hardening against a coincidental arrival
    // winning a single look). This narrows that residual; it does not close it.
    var confirmedOnce: String?
    // Whether ANY successful read, scheduled or final, showed a plausible new
    // row. A new row seen even once is evidence the add was not idempotent, so
    // the owned fallback below is available only while this stays false
    // (Codex, on 9ccb333: otherwise a transient arrival vanishes and the copy
    // the user already had is played as if nothing new existed).
    var sawNewArrival = false

    func newPlausible(in rows: [LibraryRowIdentity]) -> [LibraryRowIdentity] {
        rows.filter { !idsBefore.contains($0.persistentID) }.filter(matches)
    }

    for attempt in 1...budget {
        guard let rows = readRows() else {
            // Unknown, not empty. Keep looking: a transient AppleScript failure
            // should not be reported as "the track never arrived". But an
            // unreadable observation is no evidence the candidate survived, so
            // it breaks the consecutive run (Codex, on 9773068: seen, unknown,
            // seen is not two in a row).
            confirmedOnce = nil
            if attempt < budget { wait(interval) }
            continue
        }
        let plausible = newPlausible(in: rows)
        if !plausible.isEmpty { sawNewArrival = true }
        if plausible.count > 1 {
            // Waiting cannot disambiguate what is already ambiguous.
            return .ambiguous(count: plausible.count, amongPreExisting: false)
        }
        if let only = plausible.first {
            if confirmedOnce == only.persistentID {
                return .resolved(persistentID: only.persistentID, viaPreExisting: false)
            }
            confirmedOnce = only.persistentID
        } else {
            // It vanished, so any earlier sighting does not count.
            confirmedOnce = nil
        }
        if attempt < budget { wait(interval) }
    }

    // One fresh read after the budget, and it does two jobs. It is the
    // confirming observation for a candidate first seen on the final scheduled
    // attempt, so the budget does not starve a legitimate late arrival. And it
    // is the ONLY snapshot the pre-existing fallback may use: an earlier read
    // that happened to succeed is stale by now, and acting on it would turn
    // "the library is unreadable" into a positive selection (Codex, on
    // 9773068). If this read fails, we do not know what is there.
    wait(interval)
    guard let current = readRows() else { return .unreadable }

    let arrived = newPlausible(in: current)
    if !arrived.isEmpty { sawNewArrival = true }
    if arrived.count > 1 {
        return .ambiguous(count: arrived.count, amongPreExisting: false)
    }
    if let only = arrived.first, confirmedOnce == only.persistentID {
        return .resolved(persistentID: only.persistentID, viaPreExisting: false)
    }
    // Something new was seen and never confirmed twice running. The add did
    // create something, so the idempotent fallback does not apply; say so
    // rather than playing the old copy or claiming nothing appeared.
    if sawNewArrival { return .newRowUnconfirmed }

    // The idempotent add: the track was already in the library, so nothing new
    // ever appeared. Fall back to a row that WAS there before the add, by the
    // identity fact `idsBefore` already holds, then by metadata, and only to a
    // row that can actually play. A new row seen once is not pre-existing and
    // must never be described to the user as if it were. This is a weaker
    // claim than the set difference and the message says so.
    let ownedMatches = current
        .filter { idsBefore.contains($0.persistentID) }
        .filter(matches)
    let playable = ownedMatches.filter { isPlayableCloudStatus($0.cloudStatus) }
    if playable.count == 1, let only = playable.first {
        return .resolved(persistentID: only.persistentID, viaPreExisting: true)
    }
    if playable.count > 1 {
        return .ambiguous(count: playable.count, amongPreExisting: true)
    }
    if !ownedMatches.isEmpty {
        // It is there. It is just not playable. "Not yet visible" would be a
        // false diagnosis for the likeliest case, a pre-release catalog URL.
        return .ownedUnplayable(matched: ownedMatches.count)
    }
    return .notYetVisible(attempts: budget)
}

/// User facing text for a resolution that did not resolve.
func catalogRowResolutionMessage(_ resolution: CatalogRowResolution, title: String) -> String? {
    switch resolution {
    case .resolved:
        return nil
    case .notYetVisible(let attempts):
        return "Added '\(title)' to your library, but it had not appeared there after \(attempts) checks, "
            + "so nothing was played. It should be there shortly; try playing it again."
    case .ambiguous(let count, let amongPreExisting):
        return amongPreExisting
            ? "'\(title)' is already in your library \(count) times and they cannot be told apart by "
                + "title, artist and album, so nothing was played."
            : "Added '\(title)' to your library, but \(count) new tracks match it, "
                + "so it is not clear which one you meant and nothing was played."
    case .newRowUnconfirmed:
        return "Added '\(title)' to your library and a new track appeared, but it could not be confirmed "
            + "as the one you asked for before the time ran out, so nothing was played. Try again."
    case .ownedUnplayable(let matched):
        return "'\(title)' is already in your library (\(matched) matching track(s)), but none of them is "
            + "playable yet (pre-release or removed), so nothing was played."
    case .unreadable:
        // Only what is known: the add ran, so what the library holds now
        // cannot be claimed either way; no container was built and nothing
        // played.
        return "Added '\(title)' to your library, but your library could not be read afterwards, "
            + "so nothing was played and no temporary playlist was created."
    }
}

/// What to tell the user when a track was chosen from what they already owned.
///
/// Said out loud rather than assumed, because it is a weaker claim than the
/// rest of this path makes: the row was chosen by matching title, artist and
/// album, not by any identifier tying it to the catalog song that was asked
/// for. Apple exposes no such identifier to AppleScript (checked 2026-09-03,
/// and independently by Codex), so this is the strongest available answer, not
/// a shortcut past a better one.
func preExistingResolutionNote(title: String) -> String {
    "'\(title)' is already in your library, so it was matched by title, artist and album rather than "
        + "by a catalog identifier."
}
