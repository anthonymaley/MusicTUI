// Discover's play transaction, as pure decisions.
//
// The safety property this file exists to hold: Discover may delete ONLY the
// library rows it demonstrably created. A first draft of the design swept every
// track of the temp playlist, which deletes pre-owned music whenever a Discover
// album overlaps the user's library. Everything here is shaped so that the
// uncertain case leaves residue rather than deleting.
import Foundation

/// Which of a set of catalog songs the user already has in their library.
/// `owned` maps catalog id -> library id. `unowned` is the deletion candidate
/// set. A song that appears in NEITHER is deliberately excluded from both: the
/// API said nothing about it, and silence is not evidence of absence.
struct LibraryMembership: Equatable {
    var owned: [String: String] = [:]
    var unowned: [String] = []
}

/// GET path for a batched membership check. nil for an empty id list, so callers
/// cannot accidentally issue a query that returns everything.
func libraryMembershipPath(storefront: String, catalogIDs: [String]) -> String? {
    guard !catalogIDs.isEmpty else { return nil }
    return "/v1/catalog/\(storefront)/songs?ids=\(catalogIDs.joined(separator: ","))&include=library"
}

/// Probed live 2026-08-26, both directions: an owned song carries one entry under
/// relationships.library.data whose id is the library id; an unowned song carries
/// an empty array.
///
/// Anything unparseable yields an EMPTY partition rather than a partition that
/// claims everything is unowned — the difference between "nothing to clean up"
/// and "delete all of it".
func parseLibraryMembership(_ data: Data) -> LibraryMembership {
    var out = LibraryMembership()
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = root["data"] as? [[String: Any]] else { return out }
    for row in rows {
        guard let id = row["id"] as? String else { continue }

        // Three-valued on purpose. Every `continue` below is a song the API said
        // nothing useful about, and an unknown must never become deletable.
        //
        // Do NOT collapse this chain with `?? []`. That was the original bug: it
        // turns an absent relationships block, an absent library key, an absent
        // data key, and a non-array data value all into "empty", which reads as
        // "not in the library", which makes the user's own music eligible for
        // deletion. Only an explicitly present empty array proves absence.
        guard let rels = row["relationships"] as? [String: Any] else { continue }
        guard let library = rels["library"] as? [String: Any] else { continue }
        guard let entries = library["data"] as? [[String: Any]] else { continue }

        if entries.isEmpty {
            out.unowned.append(id)                       // proven absent
        } else if let libID = entries.first?["id"] as? String, !libID.isEmpty {
            out.owned[id] = libID                        // proven present
        }
        // else: entries exist but carry no usable id — unknown, so neither.
    }
    return out
}

enum DiscoverReadiness: Equatable { case wait, ready, timedOut }

/// Library adds return 202 and materialize asynchronously — about two seconds for
/// one song (docs/platform-notes.md:229). Poll until the expected count lands, or
/// give up. `>= expected` rather than `==` so an extra row from Apple's side does
/// not deadlock the poll.
func discoverReadiness(observed: Int, expected: Int,
                       elapsed: TimeInterval, timeout: TimeInterval) -> DiscoverReadiness {
    if observed >= expected { return .ready }
    return elapsed >= timeout ? .timedOut : .wait
}

/// 1-based position of a track within the playlist that actually materialized.
///
/// Keyed on CATALOG ID, not title. Repeated titles are common (DJ mixes with
/// several `ID` entries, albums with a reprise, movements sharing a name) and a
/// title match plays whichever came first rather than the row the user selected.
///
/// `materializedCatalogIDs` comes from GET /v1/me/library/playlists/{id}/tracks,
/// in order, reading `attributes.playParams.catalogId` — the materialized
/// playlist, not the catalog list, because unplayable rows never land and every
/// position after a missing row shifts.
///
/// nil means the selected track did not materialize. The caller must report that
/// and play nothing; falling back to 1 plays a different song than the one
/// chosen, and a warning does not make that acceptable.
func discoverPlayPosition(catalogID: String, in materializedCatalogIDs: [String]) -> Int? {
    guard let idx = materializedCatalogIDs.firstIndex(of: catalogID) else { return nil }
    return idx + 1
}
