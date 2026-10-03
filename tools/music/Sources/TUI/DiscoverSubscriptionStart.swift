// tools/music/Sources/TUI/DiscoverSubscriptionStart.swift
//
// S8 of Discover "play from here" on Apple's own copy: where in the copy the
// chosen row is. Pure. Position is fixed (the cursor's row is track k of the
// copy, never a shifted or searched one); the title, artist and length of
// track k only CONFIRM that position, they never find it.
import Foundation

/// The one normalisation S8 compares by (CH3), and nothing else: canonical
/// precomposition, a locale-independent case fold, then leading and trailing
/// whitespace dropped and every inner run of whitespace collapsed to one
/// space. No punctuation, accent, "feat." or suffix stripping.
func discoverNormalizedForMatch(_ text: String) -> String {
    let folded = text.precomposedStringWithCanonicalMapping
        .folding(options: .caseInsensitive, locale: nil)
    return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Track k of the copy, as Music.app read it.
struct DiscoverCopyTrack: Equatable {
    let title: String
    let artist: String
    let durationMS: Int?
}

enum DiscoverStartRefusal: Equatable {
    case selectionOutOfRange, countDiffers(rows: Int, copy: Int)
    case malformedID(position: Int), repeatedID(position: Int)     // 1-based, within 1...k
    case rowLengthMissing, copyLengthMissing
    case titleDiffers, artistDiffers, lengthDiffers(deltaMS: Int)
}

enum DiscoverStart: Equatable {
    case start(k: Int, path: [String])     // path = P[1...k], the exact IDs S11-S13 verify
    case refuse(DiscoverStartRefusal)
}

/// Checks, in this order: the selection is a row; the copy holds as many
/// tracks as rows were shown; the first k IDs are each sixteen `0-9A-F` and
/// all distinct; both lengths are known; title, artist (normalised, exact) and
/// length (under one second apart) of track k agree with the chosen row.
func discoverSubscriptionStart(rows: [DiscoverItem], selected: Int,
                               copyIDs: [String], trackK: DiscoverCopyTrack) -> DiscoverStart {
    guard rows.indices.contains(selected) else { return .refuse(.selectionOutOfRange) }
    guard copyIDs.count == rows.count else {
        return .refuse(.countDiffers(rows: rows.count, copy: copyIDs.count))
    }
    let k = selected + 1
    let path = Array(copyIDs[0..<k])
    for (index, id) in path.enumerated() where !isPersistentIDHex(id) {
        return .refuse(.malformedID(position: index + 1))
    }
    var seen = Set<String>()
    for (index, id) in path.enumerated() where !seen.insert(id).inserted {
        return .refuse(.repeatedID(position: index + 1))
    }
    let row = rows[selected]
    guard case .milliseconds(let rowMS) = row.length else { return .refuse(.rowLengthMissing) }
    guard let copyMS = trackK.durationMS else { return .refuse(.copyLengthMissing) }
    guard discoverNormalizedForMatch(row.name) == discoverNormalizedForMatch(trackK.title) else {
        return .refuse(.titleDiffers)
    }
    guard discoverNormalizedForMatch(row.subtitle ?? "") == discoverNormalizedForMatch(trackK.artist) else {
        return .refuse(.artistDiffers)
    }
    let delta = abs(rowMS - copyMS)
    guard delta < 1000 else { return .refuse(.lengthDiffers(deltaMS: delta)) }
    return .start(k: k, path: path)
}
