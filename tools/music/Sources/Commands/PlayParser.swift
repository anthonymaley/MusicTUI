// MARK: - Play smart parser (tested in PlayParserTests)

/// Splits free-form `music play` args into query, speakers, volume, and shuffle.
/// Args are atomic tokens (the shell already split them); a quoted multi-word
/// arg stays one token. Speaker names match whole token spans only — never
/// substrings — and connective filler words ("in the kitchen and living room
/// at 60") are dropped only when they touch a removed span, so filler inside
/// the query ("Live at the BBC") survives.
enum PlayParser {
    struct Result: Equatable {
        var queryArgs: [String] = []
        var speakers: [String] = []
        var volume: Int? = nil
        var shuffle: Bool = false
    }

    private static let filler: Set<String> = ["in", "the", "on", "and", "at", "to", "&", "+"]

    static func parse(_ args: [String], deviceNames: [String]) -> Result {
        var result = Result()
        guard !args.isEmpty else { return result }

        let lower = args.map { $0.lowercased() }
        var removed = [Bool](repeating: false, count: args.count)
        var end = args.count

        if lower[end - 1] == "shuffle" {
            result.shuffle = true
            removed[end - 1] = true
            end -= 1
        }

        // Volume: trailing digits with optional % suffix, only if a query/speaker remains.
        if end >= 2 {
            var candidate = lower[end - 1]
            if candidate.hasSuffix("%") { candidate = String(candidate.dropLast()) }
            if let vol = Int(candidate), (0...100).contains(vol) {
                result.volume = vol
                removed[end - 1] = true
            }
        }

        // Speakers: longest device names claim their token spans first.
        var matches: [(start: Int, name: String)] = []
        for device in deviceNames.sorted(by: { $0.count > $1.count }) {
            let devLower = device.lowercased()
            let devTokens = devLower.split(separator: " ").map(String.init)
            var i = 0
            while i < args.count {
                if removed[i] { i += 1; continue }
                if lower[i] == devLower {
                    removed[i] = true
                    matches.append((i, device))
                    i += 1
                    continue
                }
                if devTokens.count > 1, i + devTokens.count <= args.count {
                    let span = i..<(i + devTokens.count)
                    if zip(span, devTokens).allSatisfy({ !removed[$0] && lower[$0] == $1 }) {
                        span.forEach { removed[$0] = true }
                        matches.append((i, device))
                        i += devTokens.count
                        continue
                    }
                }
                i += 1
            }
        }
        result.speakers = matches.sorted { $0.start < $1.start }.map { $0.name }

        // Filler cascade: drop connectives that border a removed span, repeating
        // until stable so chains like "in the <speaker>" fall together.
        if removed.contains(true) {
            var changed = true
            while changed {
                changed = false
                for i in args.indices where !removed[i] && filler.contains(lower[i]) {
                    let prevRemoved = i > 0 && removed[i - 1]
                    let nextRemoved = i < args.count - 1 && removed[i + 1]
                    if prevRemoved || nextRemoved {
                        removed[i] = true
                        changed = true
                    }
                }
            }
        }

        result.queryArgs = args.indices.filter { !removed[$0] }.map { args[$0] }
        return result
    }
}

/// AppleScript `whose`-clause fragment matching an artist by track artist OR
/// album artist: remix/compilation albums credit each track to the remixer,
/// so `artist contains Y` alone can match 0 tracks for the album artist.
func albumArtistFilter(artist: String?) -> String {
    guard let artist = artist else { return "" }
    let esc = escapeAppleScriptString(artist)
    return " and (artist contains \"\(esc)\" or album artist contains \"\(esc)\")"
}
