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
    var everyReadFailed = true
    var lastRows: [LibraryRowIdentity]?
    // The candidate seen alone in the PREVIOUS observation. A new row must be
    // the sole plausible arrival twice running before it is played (Anthony,
    // 2026-09-04, as cheap hardening against a coincidental arrival winning a
    // single look). This does not close that residual; it narrows it.
    var confirmedOnce: String?

    for attempt in 1...budget {
        guard let rows = readRows() else {
            // Unknown, not empty. Keep looking: a transient AppleScript failure
            // should not be reported as "the track never arrived".
            if attempt < budget { wait(interval) }
            continue
        }
        everyReadFailed = false
        lastRows = rows

        let plausible = rows.filter { !idsBefore.contains($0.persistentID) }.filter(matches)

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
            // It vanished, so any earlier sighting does not count towards the
            // two consecutive observations.
            confirmedOnce = nil
        }
        if attempt < budget { wait(interval) }
    }

    if everyReadFailed { return .unreadable }

    // The idempotent add: the track was already in the library, so nothing new
    // ever appeared. Fall back to metadata alone, and only to a row that can
    // actually play. This is a weaker claim than the set difference and the
    // message says so.
    let owned = (lastRows ?? []).filter(matches).filter { isPlayableCloudStatus($0.cloudStatus) }
    if owned.count == 1, let only = owned.first {
        return .resolved(persistentID: only.persistentID, viaPreExisting: true)
    }
    if owned.count > 1 {
        return .ambiguous(count: owned.count, amongPreExisting: true)
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
    case .unreadable:
        return "Added '\(title)' to your library, but your library could not be read afterwards, "
            + "so nothing was played. Nothing else was changed."
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
