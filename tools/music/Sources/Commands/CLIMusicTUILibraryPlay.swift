// tools/music/Sources/Commands/CLIMusicTUILibraryPlay.swift
//
// The CLI's seam for playing rows from SpanDAC's LIBRARY on the MusicTUI
// output (score: data route and output, step 6; C-MATRIX column 4, C-HANDOFF).
//
// With SpanDAC as MusicTUI's data source and the MusicTUI output selected,
// `music play --playlist/--album/--song/--artist` resolves its name against
// SpanDAC's library on this Mac, and `music play N` of a row a SpanDAC library
// search produced carries that row here. `PersistentIDCLILibraryPlay` plays
// them by the exact persistent ID SpanDAC reported for each song (step 7), or
// refuses the whole request with `pickASpanDACOutput`: nothing falls back to
// a title search of Apple's Music app library.
import Foundation

/// One request to play SpanDAC library rows on the MusicTUI output.
struct CLIMusicTUILibraryPlayRequest: Equatable {
    /// Which `music play` form asked, for the result line.
    let kind: BridgePlayResultKind
    /// The matched row's own name (a playlist, album, artist or song title).
    let label: String
    /// SpanDAC library song rows, in SpanDAC's order, never shuffled here.
    let rows: [MusicRow]
    /// 1-based row to start from.
    let startAt: Int
    /// Whether the person asked for this set in random order.
    let shuffle: Bool
    /// `music play N`'s `N`, when the rows came from the result cache.
    let resultNumber: Int?
    let json: Bool
}

/// Plays SpanDAC library rows on the MusicTUI output. Called inside the
/// output lock, with the mode revalidated; it must play exactly the rows it is
/// given or refuse the whole request.
protocol CLIMusicTUILibraryPlaying {
    func play(_ request: CLIMusicTUILibraryPlayRequest, env: CLIBridgeEnv) throws
}

/// Refuses every request with `pickASpanDACOutput`, playing nothing.
struct RefusingCLIMusicTUILibraryPlay: CLIMusicTUILibraryPlaying {
    func play(_ request: CLIMusicTUILibraryPlayRequest, env: CLIBridgeEnv) throws {
        throw ActionError(message: pickASpanDACOutput)
    }
}

/// The real player (score step 7, C-HANDOFF): every row is verified by the
/// persistent ID SpanDAC reported for it (`verifyHandoffTracks`, the TUI's own
/// check), then the verified tracks play on the MusicTUI output through the
/// CLI's shipped bounded container: a temporary playlist seeded from the
/// library playlist, whose tracks are read back and must be EXACTLY the
/// verified identities, in the order that will play, before it plays, and which
/// the shipped watcher removes.
///
/// A one-shot command has no app-owned queue to drive, which is why the CLI
/// uses the container rather than the TUI's queue. The container duplicates
/// from the library playlist, so a track found only in a user playlist
/// refuses the whole play here (duplicating it could add it to the library).
///
/// `music play N` of a cached SpanDAC library row carries no alias (the result
/// cache does not store one), so the row's identity is read again from
/// SpanDAC's library on this Mac, keyed by the row's own id (never its name).
/// A row SpanDAC no longer lists refuses.
struct PersistentIDCLILibraryPlay: CLIMusicTUILibraryPlaying {
    let library: PersistentIDTrackReading
    let run: ScriptRunner
    let launch: ProcessLauncher
    let selfCheck: LibraryAliasSelfCheck
    /// What the command shows once playback started (the shipped now line).
    let afterPlay: (Bool) -> Void

    func play(_ request: CLIMusicTUILibraryPlayRequest, env: CLIBridgeEnv) throws {
        let refused = ActionError(message: pickASpanDACOutput)
        let rows = request.resultNumber == nil ? request.rows : try rowsWithTheirIdentity(request.rows, env: env)
        let verified = try verifyHandoffTracks(rows: rows, title: request.label, library: library,
                                               selfCheck: selfCheck)
        let indices = verified.compactMap(\.libraryIndex)
        guard indices.count == verified.count else { throw refused }

        // C-EPOCH for a one-shot process: both files, read again inside the
        // output lock, just before the one sound mutation.
        guard case .consistent(.spandacMac, .musicApp) = effectiveSelection(
            data: DataProviderStore(beside: env.modeStore), modes: env.modeStore) else {
            throw ActionError(message: sourceChangedNothingPlayed)
        }

        let order = request.shuffle ? Array(zip(indices, verified.map(\.persistentID))).shuffled()
                                    : Array(zip(indices, verified.map(\.persistentID)))
        // The exact order that will play, shuffled or not: the container is
        // confirmed against this sequence, never against the set of songs.
        let expected = order.map(\.1)
        // The shipped album path sweeps stale containers first; so does this.
        _ = run(albumStaleSweepScript())
        let uuid = UUID().uuidString
        let outcome = playBoundedContainer(name: albumContainerName(title: request.label, uuid: uuid),
                                           seed: .libraryIndices(order.map(\.0)), uuid: uuid,
                                           run: run, launch: launch,
                                           confirmOrder: { ids in ids == expected })
        let failure: BoundedAlbumOutcome
        switch outcome {
        case .playing:
            afterPlay(request.json)
            return
        case .buildFailed(let removed):   failure = .buildFailed(containerRemoved: removed)
        case .playFailed(let removed):    failure = .playFailed(containerRemoved: removed)
        case .watcherFailed(let removed): failure = .watcherFailed(containerRemoved: removed)
        }
        throw ActionError(message: albumOutcomeMessage(failure, title: request.label) ?? pickASpanDACOutput)
    }

    /// The rows again, each with the alias SpanDAC gives the row whose id it
    /// is, read from SpanDAC's library songs on this Mac. Refuses when the
    /// read fails or any id is not listed.
    private func rowsWithTheirIdentity(_ rows: [MusicRow], env: CLIBridgeEnv) throws -> [MusicRow] {
        guard rows.contains(where: { $0.alias == nil }) else { return rows }
        let wanted = Set(rows.map(\.id))
        var found: [String: MusicRow] = [:]
        let session = CLIBridgeSession(client: env.routing.dataClient(), env: env)
        let failed = walkLibraryPages(
            fetch: session.provider.librarySongs,
            onPage: { page in
                for row in page.rows where row.kind == .song && wanted.contains(row.id) { found[row.id] = row }
                return found.count < wanted.count
            },
            onRestart: { found = [:] },
            onWarming: { _ in env.err(cliBridgeWarmingProgress) },
            sleep: env.sleep, budget: session.budget)
        guard failed == nil else { throw ActionError(message: pickASpanDACOutput) }
        return try rows.map { row in
            guard let listed = found[row.id] else { throw ActionError(message: pickASpanDACOutput) }
            return listed
        }
    }
}

/// What production uses. The one line a later step changes.
func liveCLIMusicTUILibraryPlay() -> CLIMusicTUILibraryPlaying {
    let backend = AppleScriptBackend()
    return PersistentIDCLILibraryPlay(
        library: AppleScriptPersistentIDReader(run: { script in
            try syncRun { try await backend.runMusic(script, timeout: 60) }
        }),
        run: { script in try? syncRun { try await backend.runMusic(script) } },
        launch: detachedLaunch,
        selfCheck: .shared,
        afterPlay: { json in showNowPlaying(json: json, waitForPlay: true) })
}
