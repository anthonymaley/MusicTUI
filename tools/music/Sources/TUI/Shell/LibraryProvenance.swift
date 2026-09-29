// tools/music/Sources/TUI/Shell/LibraryProvenance.swift
// D7: each Library-tab list (Songs, Albums, Artists) and the Playlists rail
// records which library its rows actually came from, so a mid-session switch
// reloads a list from the newly selected source instead of leaving it showing
// the other one's rows — or worse, playing a row from a library that is no
// longer selected. Rule 3 (no silent fallback in either direction): without
// this, a SpanDAC row played with MusicTUI's own data would resolve by title,
// silently, and an AppleScript row played with SpanDAC data would reach
// SpanDAC with an id it never gave out.
//
// Since the data route (score: data route and output, step 4) provenance
// tracks the DATA selection, not the output: which library a list comes from
// is decided by where MusicTUI's music data comes from, and an output switch
// alone (the Mac to an iPhone, or to MusicTUI) leaves a SpanDAC list valid.
import Foundation

enum ListSource: Equatable {
    /// MusicTUI's own data: the AppleScript library read. (The case keeps its
    /// internal name.)
    case musicApp
    /// SpanDAC on this Mac's MusicKit library.
    case bridge
}

/// The provenance-mismatch sentences, defined once so no footer string gets a
/// second copy. The names are internal and predate the data route; what each
/// says is the data selection's.
enum LibraryProvenance {
    /// A list read under MusicTUI's own data, played after the switch to
    /// SpanDAC data: C-MATRIX's "from before" sentence, the same one the
    /// routing coordinator refuses with.
    static let bridgeSelectedMusicAppList = listFromBeforeSpanDACSwitch
    /// A SpanDAC list played after MusicTUI stopped using SpanDAC for music
    /// data. CHOSEN wording.
    static let musicAppSelectedBridgeList =
        "MusicTUI stopped using SpanDAC for music data, and this list is from SpanDAC. It is reloading; try again in a moment."

    /// C2: the Playlists tab's own provenance-switch status lines, posted the
    /// instant a switch of data source resets its rail (Part A D7's pattern,
    /// one status post per reset rather than the "reloading" retry sentences
    /// above, because a playlist rail reset is not something a person can hit
    /// mid-read the way a container play can). CHOSEN wording.
    static let bridgePlaylistsShown = "Music source changed \u{2014} showing SpanDAC's playlists"
    static let musicAppPlaylistsShown = "Music source changed \u{2014} showing MusicTUI's own playlists"

    /// The Library tab's equivalent, for its three lists. CHOSEN wording.
    static let bridgeLibraryShown = "Music source changed \u{2014} showing SpanDAC's library"
    static let musicAppLibraryShown = "Music source changed \u{2014} showing MusicTUI's own library"

    /// The MusicTUI-output play of a SpanDAC library collection, once the
    /// hand-off accepted it. CHOSEN wording.
    static func playingOnMusicTUI(_ title: String) -> String {
        "Playing '\(title)' on \(musicTUIOutputName)."
    }

    /// The same, followed by what the hand-off skipped as no longer
    /// available, when it skipped anything (ruling, 2026-09-24).
    static func playingOnMusicTUI(_ title: String, report: HandoffPlayReport) -> String {
        [playingOnMusicTUI(title), report.notice].compactMap { $0 }.joined(separator: " ")
    }
}

/// Before a play from a list read under MusicTUI's own data reads anything
/// through AppleScript: refuses when that play could not run now, so a
/// refused play costs no read of Apple's Music app. `spanDACData` is the
/// scene's own provider check, and the coordinator's data selection is read
/// too, so a switch to SpanDAC data that landed after the scene last looked
/// still refuses (a list from before the switch). The route is the two-axis
/// matrix, read without taking the ordering boundary (a blocked stored
/// output, C-REPAIR, refuses every sound action).
///
/// A pre-flight only. `RoutingCoordinator.perform` decides again, inside its
/// boundary and against the stamp taken at the keypress, and that is the
/// decision that plays or refuses.
func refuseOpenDataPlayBeforeReading(_ action: MusicTUIAction, routing: RoutingCoordinator,
                                     spanDACData: Bool) throws {
    if spanDACData || routing.data == .spandacMac {
        throw ActionError(message: LibraryProvenance.bridgeSelectedMusicAppList)
    }
    if case .refused(let why) = routeAction(action, selection: routing.selection, from: .tui).sound {
        throw ActionError(message: why)
    }
}

/// The OUTPUT's player for a SpanDAC row: the client `RoutingCoordinator.perform`
/// hands its `.source` branch, which is the selected SpanDAC output's (an
/// iPhone's, when that is the output), never the data client the list was
/// read through.
func spanDACOutputPlayer(_ client: SourceAppClient) -> MusicDataProvider {
    BridgeMusicProvider(control: client.control)
}

/// Runs the hand-off (C-HANDOFF) for a SpanDAC library play on the MusicTUI
/// output, so its refusal reaches the footer in its own words: the shell's
/// `ActionRunner` shows an `ActionError`'s message and reduces any other error
/// to "Play failed.", which would hide `pickASpanDACOutput`.
@discardableResult
func playThroughHandoff(_ handoff: MusicTUIHandoff, rows: [MusicRow], startAt: Int, startRequired: Bool,
                        shuffle: Bool, title: String) throws -> HandoffPlayReport {
    do {
        return try handoff.playLibrary(rows: rows, startAt: startAt, startRequired: startRequired,
                                       shuffle: shuffle, title: title)
    } catch let error as ActionError {
        throw error
    } catch {
        throw ActionError(message: error.localizedDescription)
    }
}
