// Pure model for the Now Playing playback-control grid: fixed rows of option
// cells, which cell is the active value given current modes, and cursor
// clamping. Rendering, focus, and the AppleScript writes live in the scene.
import Foundation

enum ControlRow: Int, CaseIterable {
    case shuffle, order, repeatMode, genius
}

enum ControlGrid {
    static let labels = ["Shuffle", "Order", "Repeat", "Genius"]
    static let cells: [[String]] = [
        ["On", "Off"],
        ["Songs", "Albums", "Grp"],
        ["Off", "All", "One"],
        ["Shuffle now"],
    ]
    // Value mappings, aligned to the cell columns above.
    static let orderModes: [ShuffleMode] = [.songs, .albums, .groupings]
    static let repeatModes: [RepeatMode] = [.off, .all, .one]

    static var rowCount: Int { cells.count }
    static func cellCount(row: Int) -> Int { cells[row].count }

    /// The active column for a row, derived from current modes (nil = no active
    /// value, e.g. the Genius action row).
    static func activeColumn(row: Int, modes: PlaybackModes) -> Int? {
        switch ControlRow(rawValue: row) {
        case .shuffle:    return modes.shuffleEnabled ? 0 : 1
        case .order:      return orderModes.firstIndex(of: modes.shuffleMode)
        case .repeatMode: return repeatModes.firstIndex(of: modes.songRepeat)
        case .genius, .none: return nil
        }
    }

    // MARK: SpanDAC
    //
    // The same grid on a SpanDAC output. SpanDAC has its own shuffle and repeat
    // (`slice.shuffle`, `slice.repeat`) and nothing for Order or Genius, so
    // those two rows are drawn disabled rather than hidden.

    /// A row's cells are live on SpanDAC: Shuffle and Repeat when the app's
    /// `capabilities` list their op; Order and Genius never.
    static func spanDACEnabled(row: Int, offersShuffle: Bool, offersRepeat: Bool) -> Bool {
        switch ControlRow(rawValue: row) {
        case .shuffle:    return offersShuffle
        case .repeatMode: return offersRepeat
        case .order, .genius, .none: return false
        }
    }

    /// The active column from SpanDAC's own state (nil when it sent none, and
    /// for the rows it has no state for).
    static func spanDACActiveColumn(row: Int, shuffle: Bool?, repeatMode: String?) -> Int? {
        switch ControlRow(rawValue: row) {
        case .shuffle:
            return shuffle.map { $0 ? 0 : 1 }
        case .repeatMode:
            return repeatMode.flatMap(RepeatMode.init(rawValue:)).flatMap { repeatModes.firstIndex(of: $0) }
        case .order, .genius, .none:
            return nil
        }
    }

    /// The row the cursor lands on moving `delta` rows from `row`, skipping
    /// disabled rows; stays put when there is nowhere to go.
    static func spanDACStep(from row: Int, by delta: Int, offersShuffle: Bool, offersRepeat: Bool) -> Int {
        var r = row + delta
        while r >= 0, r < rowCount {
            if spanDACEnabled(row: r, offersShuffle: offersShuffle, offersRepeat: offersRepeat) { return r }
            r += delta
        }
        return row
    }
}
