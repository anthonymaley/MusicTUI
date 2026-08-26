// The Home tab's rail selection policy.
//
// Apple returns a variable number of rails (17 on one probe, 10 later the same
// day with the same limit and account), and their titles are localized and
// rotate. So selection runs on API flags and on measured content, never on a
// title string.
//
// Shared with `music home` on purpose: CLI/TUI drift on shared data is this
// repo's most-repeated bug, and 1c06027 was exactly this class.
import Foundation

/// Median release year of a rail's albums, or Int.min when it has none
/// (playlist and station rails carry no releaseDate). Upper median on even
/// counts, which is arbitrary but deterministic.
func homeRailFreshness(_ rail: HomeRail) -> Int {
    let years = rail.items.compactMap { item -> Int? in
        if case .album(_, let year, _) = item.detail { return year }
        return nil
    }.sorted()
    guard !years.isEmpty else { return Int.min }
    return years[years.count / 2]
}

/// True when every item in the rail is an album released in `year`. Measured
/// live: the real "New Releases for You" rail scored min == max == the current
/// year, while the next-freshest rail spanned 2023 to 2026.
func homeRailIsAllFromYear(_ rail: HomeRail, _ year: Int) -> Bool {
    guard !rail.items.isEmpty else { return false }
    let years = rail.items.compactMap { item -> Int? in
        if case .album(_, let y, _) = item.detail { return y }
        return nil
    }
    return years.count == rail.items.count && years.allSatisfy { $0 == year }
}

/// Five curated slots, filled in priority order, then backfilled in the API's
/// own order so a thin feed still fills the dashboard.
///
///   1  recently played        (kind == "recently-played")
///   2  playlists rail         (resourceTypes == ["playlists"])
///   3  stations rail          (resourceTypes == ["stations"])
///   4  new releases           (albums rail entirely from currentYear, else freshest)
///   5  freshest remaining     (median release year; no-median rails sort last)
///
/// Deterministic by construction. No rail is returned twice. Item order within
/// a rail is Apple's and is never touched here.
func selectHomeRails(_ rails: [HomeRail], currentYear: Int, slots: Int = 5) -> [HomeRail] {
    var pool = rails
    var picked: [HomeRail] = []

    func takeFirst(_ match: (HomeRail) -> Bool) {
        guard picked.count < slots, let i = pool.firstIndex(where: match) else { return }
        picked.append(pool.remove(at: i))
    }

    takeFirst { $0.isRecentlyPlayed }
    takeFirst { $0.resourceTypes == ["playlists"] }
    takeFirst { $0.resourceTypes == ["stations"] }

    // Slot 4: the all-current-year albums rail, else the freshest albums rail.
    if picked.count < slots {
        let albums = pool.indices.filter { pool[$0].resourceTypes == ["albums"] }
        let allCurrent = albums.first { homeRailIsAllFromYear(pool[$0], currentYear) }
        let freshest = albums.sorted { a, b in
            let fa = homeRailFreshness(pool[a]), fb = homeRailFreshness(pool[b])
            return fa == fb ? a < b : fa > fb
        }.first
        if let i = allCurrent ?? freshest { picked.append(pool.remove(at: i)) }
    }

    // Slot 5: freshest remaining rail of any type. Rails with no computable
    // median sort last; ties break by original API order.
    if picked.count < slots, !pool.isEmpty {
        let ranked = pool.indices.sorted { a, b in
            let fa = homeRailFreshness(pool[a]), fb = homeRailFreshness(pool[b])
            return fa == fb ? a < b : fa > fb
        }
        if let i = ranked.first { picked.append(pool.remove(at: i)) }
    }

    // Backfill: whatever is left, in the API's own order.
    while picked.count < slots, !pool.isEmpty {
        picked.append(pool.removeFirst())
    }
    return picked
}

/// The current year, injected everywhere else so the policy stays pure and
/// testable. Only call sites at the edges use this.
func homeCurrentYear(_ now: Date = Date()) -> Int {
    Calendar.current.component(.year, from: now)
}

/// The single place a raw feed becomes Home's curated rails. Both `music home`
/// and the Home tab call THIS, not the two functions it composes.
///
/// That distinction is the point. CLI/TUI drift on shared data is this repo's
/// most-repeated bug (1c06027 shipped a divergence where each surface was
/// internally consistent, so the suite stayed green). Two call sites composing
/// the same two functions in the same order is not "one pure function both
/// callers go through" — it is two chances to drift. This is the one function.
func resolvedHomeRails(_ rails: [HomeRail], currentYear: Int = homeCurrentYear()) -> [HomeRail] {
    selectHomeRails(orderedHomeRails(rails), currentYear: currentYear)
}
