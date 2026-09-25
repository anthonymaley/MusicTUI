// tools/music/Sources/Commands/CLIBridgeRadio.swift
//
// The Bridge branches of `music radio search`, `radio add` and `radio play`
// (slice 3 Part 2, P7; decisions D2, D6, D8). Each runs inside `cliDispatch`'s
// `.source` branch, after readiness, with the command's one `CLIBridgeSession`.
//
// **No auto-pick (D8).** Music.app mode's `radio play` plays the FIRST
// favourite containing the words, else the FIRST search hit (shipped, kept).
// With Bridge selected nothing is picked for you: a favourite matches by
// case-insensitive exact name, else by a UNIQUE case-insensitive substring;
// two or more refuse with a list. Then Bridge's station search: exactly one
// hit plays, none prints the shipped not-found sentence, two or more refuse.
//
// **Favourites stay MusicTUI's own state** (`StationStore`) in both modes; the
// store is read here, never written. The only mutation is one
// `slice.playStation`, sent through `session.mutate` (output lock, mode
// revalidated) AFTER every read, so no lock is held across a search.
import Foundation

// MARK: - radio search

/// What the Bridge station search asks for: the shipped adapter's limit.
let bridgeRadioSearchLimit = 25

/// `music radio search` with Bridge selected: one `slice.searchStations`, then
/// the shipped `RadioSearch` lines (P4), the empty sentence included.
func bridgeRadioSearchCommand(_ session: CLIBridgeSession, term: [String], env: CLIBridgeEnv) throws {
    let hits = try session.provider.searchStations(term: term.joined(separator: " "), limit: bridgeRadioSearchLimit)
    stationSearchLines(hits).forEach(env.out)
}

// MARK: - radio add: the lookup

/// `radio add`'s enrichment with Bridge selected: `slice.station` by id. It
/// enriches a favourite that is saved either way, so a failure (or Apple not
/// carrying the station, `null`) is nil and the caller keeps the slug name,
/// as the shipped lookup degrades.
func bridgeRadioStationLookup(_ session: CLIBridgeSession, id: String) -> Station? {
    (try? session.provider.station(id: id)) ?? nil
}

// MARK: - radio play

/// D8's favourite rule, pure.
enum BridgeFavouriteMatch: Equatable {
    case one(Station)
    case none
    /// Every station that matched at the deciding step, in favourites order.
    case ambiguous([Station])
}

/// Case-insensitive exact name first; if none, a case-insensitive substring
/// (the shipped comparison, `localizedCaseInsensitiveContains`). One match at
/// the deciding step plays; two or more are ambiguous, never picked from.
func bridgeFavouriteMatch(_ query: String, in favourites: [Station]) -> BridgeFavouriteMatch {
    let exact = favourites.filter { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }
    if exact.count == 1 { return .one(exact[0]) }
    if exact.count > 1 { return .ambiguous(exact) }
    let containing = favourites.filter { $0.name.localizedCaseInsensitiveContains(query) }
    switch containing.count {
    case 0:  return .none
    case 1:  return .one(containing[0])
    default: return .ambiguous(containing)
    }
}

/// Up to five names, "; "-joined, then "; and <n-5> more" (D10).
private func bridgeRadioNameList(_ stations: [Station]) -> String {
    let names = stations.prefix(5).map(\.name).joined(separator: "; ")
    return stations.count > 5 ? "\(names); and \(stations.count - 5) more" : names
}

/// D10, verbatim.
func bridgeAmbiguousFavouritesRefusal(query: String, matches: [Station]) -> String {
    "'\(query)' matches \(matches.count) favourite stations: \(bridgeRadioNameList(matches)). Use the exact name or the station URL."
}

/// D10, verbatim.
func bridgeAmbiguousStationsRefusal(query: String, hits: [Station]) -> String {
    "'\(query)' matches \(hits.count) stations: \(bridgeRadioNameList(hits)). Paste the station URL, or favourite one."
}

/// The shipped not-found sentence (`radioPlayViaMusicApp`), on stderr as shipped.
func radioNoStationFoundSentence(_ input: String) -> String {
    "✗ No station found for “\(input)”. Try pasting the station URL."
}

/// `music radio play` with Bridge selected.
///
/// Order: the input's shape (a station URL, as the shipped body tests it),
/// then favourites (D8, no request), then one `slice.searchStations`; only
/// then the one `slice.playStation` under the lock. Bridge's refusal of the
/// play (a station Apple does not carry, ruling 17) prints in Bridge's words.
func bridgeRadioPlayCommand(_ session: CLIBridgeSession, query: [String], stations: StationStore,
                            env: CLIBridgeEnv) throws {
    let input = query.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !input.isEmpty else { throw ActionError(message: "Name or URL required.") }

    let id: String
    let name: String
    if ["http://", "https://", "music://"].contains(where: { input.hasPrefix($0) }) {
        guard let p = parseStationURL(input), stationPlayURL(input) != nil else {
            throw ActionError(message: "Not an Apple Music station URL.")
        }
        (id, name) = (p.id, displayNameFromSlug(p.slug))
    } else {
        switch bridgeFavouriteMatch(input, in: stations.favorites()) {
        case .one(let favourite):
            (id, name) = (favourite.id, favourite.name)
        case .ambiguous(let matches):
            throw ActionError(message: bridgeAmbiguousFavouritesRefusal(query: input, matches: matches))
        case .none:
            let hits = try session.provider.searchStations(term: input, limit: bridgeRadioSearchLimit)
            switch hits.count {
            case 0:
                env.err(radioNoStationFoundSentence(input))
                return
            case 1:
                (id, name) = (hits[0].id, hits[0].name)
            default:
                throw ActionError(message: bridgeAmbiguousStationsRefusal(query: input, hits: hits))
            }
        }
    }

    _ = try session.mutate { try sendBridgeRef(.station(id: id, name: name), to: $0) }
    env.out("▶ \(name)")
}
