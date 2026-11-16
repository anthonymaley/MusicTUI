// tools/music/Sources/TUI/MacRouteAlbumPlay.swift
import Foundation

// A Discover or search ALBUM on the Mac DAC route (mac-route-plan.md; score step
// P9). Off the route an album is played from a temporary library playlist
// (`discoverAlbumPreflightRefusal` and the copy sequencer), which Music plays
// straight through: nothing could change the DAC's rate between songs. On the
// route the album is instead added to the library through SpanDAC on this Mac
// (the same add the single-song `.add` path makes), each song is found by the
// persistent-ID alias SpanDAC's lookup returns for its catalogue id, and the
// songs play one at a time through the rate-aware transition
// (`MacRouteSongPlay`). No temporary playlist is built, so there is nothing to
// sweep, prove or remove; the songs the add made stay in the library, exactly as
// the single-song `.add` path leaves its song.
//
// Fail closed: a library that cannot add, an add that failed or whose outcome is
// unknown, or ANY song that has not appeared (or whose alias does not verify)
// after the resolver's own schedule refuses the whole play. Nothing plays.

extension SpanDACCataloguePlayer {

    /// Added-and-played, or why not. `title` is the album's.
    func playAlbumOnRoute(title: String, catalogueIDs: [String], library: SpanDACLibraryAdding,
                          route: MacRouteSongPlay) -> SpanDACCataloguePlayOutcome {
        guard library.canAdd else { return .refused(updateSpanDACToPlayOnMusicTUI) }
        guard !catalogueIDs.isEmpty else { return .refused("'\(title)': no tracks to play.") }
        let distinct = Array(NSOrderedSet(array: catalogueIDs)) as? [String] ?? catalogueIDs

        // What he already owns is not added again; the rest is added once, never retried.
        var owned: [String: String?]
        do {
            owned = try library.lookup(catalogueIDs: distinct)
        } catch SpanDACLibraryOpError.notOffered {
            return .refused(updateSpanDACToPlayOnMusicTUI)
        } catch {
            return .refused("SpanDAC couldn't check your library, so nothing was played. "
                            + error.localizedDescription)
        }
        let missing = distinct.filter { id in
            if case .some(.some) = owned[id] { return false }
            return true
        }
        if !missing.isEmpty {
            do {
                try library.add(catalogueIDs: missing)
            } catch SpanDACLibraryOpError.outcomeUnknown {
                return .outcomeUnknown(title: title)
            } catch {
                if case SpanDACLibraryOpError.notOffered = error { return .refused(updateSpanDACToPlayOnMusicTUI) }
                return .refused("SpanDAC couldn't add '\(title)' to your library, so nothing was played. "
                                + error.localizedDescription)
            }
        }

        // Every song's verified identity, polled inside the resolver's own schedule.
        var hexByID: [String: String] = [:]
        for attempt in 1...Self.attempts {
            if let found = try? library.lookup(catalogueIDs: distinct.filter { hexByID[$0] == nil }) {
                for (id, alias) in found {
                    guard hexByID[id] == nil, let alias,
                          let verified = verifySpanDACAlias(alias, title: nil, run: seams.run) else { continue }
                    hexByID[id] = verified.hex
                }
            }
            if hexByID.count == distinct.count { break }
            if attempt < Self.attempts { seams.wait(Self.interval) }
        }
        let ordered = catalogueIDs.compactMap { hexByID[$0] }
        guard ordered.count == catalogueIDs.count else {
            return .refused("Added \(title) to your library, but \(distinct.count - hexByID.count) of its songs had "
                            + "not appeared there after \(Self.attempts) checks, so nothing was played. "
                            + "They should be there shortly; try playing it again.")
        }
        guard route.play(title, ordered) else {
            return .refused(macRouteSongPlayNotStarted)
        }
        return .playing(title: title, note: nil)
    }
}
