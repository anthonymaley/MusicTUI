// Discover's navigation stack: Discover -> Rail -> Item tracks.
//
// Every level owns BOTH halves of its position. The track drill-in previously
// owned only a cursor, with no viewport, so a selection past the terminal
// height became invisible with no way to follow it. Keeping cursor and scroll
// together in one type is what makes that unrepresentable.
//
// Deliberately local to Discover. Generalising this into a shared scrolling
// framework across every scene is a separate decision on separate evidence.
import Foundation

struct DiscoverCursor: Equatable {
    var index = 0
    var scroll = 0
}

enum DiscoverLevel: Equatable {
    case root
    case rail(DiscoverRail)
    case tracks(DiscoverItem)
}

struct DiscoverFrameState: Equatable {
    let level: DiscoverLevel
    var cursor: DiscoverCursor
}

/// Push a level with a fresh cursor, leaving the parent's position untouched so
/// Back can restore it exactly.
func pushLevel(_ stack: [DiscoverFrameState], _ level: DiscoverLevel) -> [DiscoverFrameState] {
    stack + [DiscoverFrameState(level: level, cursor: DiscoverCursor())]
}

/// Pop one level. Never empties the stack: Discover is the floor.
func popLevel(_ stack: [DiscoverFrameState]) -> [DiscoverFrameState] {
    stack.count > 1 ? Array(stack.dropLast()) : stack
}

/// Clamp a viewport so the selected row stays visible. Extracted from the rails
/// level, which already did this correctly inline, so that every level shares
/// one implementation instead of the track level having none.
///
/// `row` is an index into the FULL display array, headers included — NOT
/// `DiscoverCursor.index`, which is an ordinal among only the selectable rows. The
/// caller converts: `selectableDiscoverIndices(rows)[cursor.index]`. Those two
/// quantities have already been confused once in a draft of the caller, where
/// passing the ordinal straight through drifted the window by one row per
/// header above the cursor. That is also why this does not simply take a
/// DiscoverCursor: only half of one belongs here.
func scrollToShow(row: Int, scroll: Int, visibleHeight: Int, count: Int) -> Int {
    guard visibleHeight > 0, count > 0 else { return 0 }
    var s = scroll
    if row < s { s = row }
    if row >= s + visibleHeight { s = row - visibleHeight + 1 }
    return max(0, min(s, max(0, count - visibleHeight)))
}
