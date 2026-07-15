// Pure parse of the `now` AppleScript payload. No I/O, no rendering — so every
// shape (normal track, live station, stopped, loading, garbage) is unit-testable.
// Live stations have no duration/position: AppleScript emits "-" and this maps
// it to nil. Zero would be a lie about a livestream.
import Foundation

struct NowSpeaker: Equatable {
    let name: String
    let volume: Int
}

struct NowInfo: Equatable {
    let track: String
    let artist: String
    let album: String
    let duration: Int?   // nil on a live station
    let position: Int?   // nil on a live station
    let state: String
    let isLive: Bool
    let speakers: [NowSpeaker]
}

enum NowParse: Equatable {
    case stopped
    case loading
    case info(NowInfo)
}

/// Payload: track|artist|album|duration|position|state|live|speakers
/// duration/position are "-" when absent; live is "1"/"0"; speakers is
/// "Name:Vol,Name:Vol" (possibly empty). Returns nil on anything unparseable.
func parseNowOutput(_ raw: String) -> NowParse? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "STOPPED" { return .stopped }
    if trimmed == "LOADING" { return .loading }

    // maxSplits: 7 → at most 8 fields; the 8th absorbs any "|" in speaker names.
    let parts = trimmed.split(separator: "|", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 8 else { return nil }

    let optInt: (String) -> Int? = { $0 == "-" ? nil : Int($0) }

    let speakers: [NowSpeaker] = parts[7]
        .split(separator: ",")
        .compactMap { pair in
            let kv = pair.split(separator: ":", maxSplits: 1).map(String.init)
            guard let name = kv.first, !name.isEmpty else { return nil }
            return NowSpeaker(name: name, volume: Int(kv.count > 1 ? kv[1] : "0") ?? 0)
        }

    return .info(NowInfo(
        track: parts[0], artist: parts[1], album: parts[2],
        duration: optInt(parts[3]), position: optInt(parts[4]),
        state: parts[5], isLive: parts[6] == "1",
        speakers: speakers
    ))
}
