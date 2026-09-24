// tools/music/Sources/TUI/Shell/LibraryProvenance.swift
// D7: each Library-tab list (Songs, Albums, Artists) records which library its
// rows actually came from, so a mid-session output switch reloads a list from
// the newly selected backend instead of leaving it showing the other one's
// rows — or worse, playing a row from a library that is no longer selected.
// Rule 3 (no silent fallback in either direction): without this, a
// Bridge-sourced row played in Music.app mode would resolve by title in
// Music.app, silently, and a Music.app row played in Bridge mode would reach
// Bridge with a Music.app id.
import Foundation

enum ListSource: Equatable {
    case musicApp
    case bridge
}

/// The two provenance-mismatch sentences, defined once so no wire string (or
/// footer string) gets a second copy.
enum LibraryProvenance {
    static let bridgeSelectedMusicAppList =
        "Bridge is selected, and this list is from the Music.app library. It is reloading from Bridge; try again in a moment."
    static let musicAppSelectedBridgeList =
        "Music.app is selected, and this list is from Bridge's library. It is reloading from Music.app; try again in a moment."

    /// C2: the Playlists tab's own provenance-switch status lines, posted the
    /// instant a mid-session output flip resets its rail (Part A D7's pattern,
    /// one status post per reset rather than the "reloading" retry sentences
    /// above, because a playlist rail reset is not something a person can hit
    /// mid-read the way a container play can).
    static let bridgePlaylistsShown = "Output changed \u{2014} showing Bridge's playlists"
    static let musicAppPlaylistsShown = "Output changed \u{2014} showing the Music.app playlists"
}
