// tools/music/Tests/MusicTests/CLIInventoryTests.swift
//
// Slice 3 score, S8: the invocation inventory (section 2), closed.
//
// The mirror below is section 2's table, one row per invocation, each ending
// Served through Bridge, Refused before any side effect, a named Exception
// that runs as it ships, or a Migration exception (Anthony's Q2 ruling [B]:
// a read-only lookup that keeps its shipped backend until Part B). The walk of
// `Music.configuration`'s subcommand tree fails on any command type the mirror
// does not classify, so a new command cannot ship unclassified; each row's
// route is checked against its letter through the real matrix.
//
// What is execution evidence and what is not: the route checks call the real
// `routeAction`/`bridgeRowsRefusal`. The "gate comes first" check reads source
// text and is STRUCTURAL only; the execution evidence for the refusals is
// S6/S7's command tests and SpeakerLockTests.
import XCTest
import ArgumentParser
@testable import music

final class CLIInventoryTests: XCTestCase {

    enum Letter: String { case served = "S", refused = "R", exception = "E", migration = "M" }

    enum Enforcement {
        /// The matrix decides, for this action, from the CLI with Bridge selected.
        case route(MusicTUIAction)
        /// A cached row's origin decides (score D3, S3), before any token read,
        /// AppleScript or REST. The matrix itself runs the verb as shipped.
        case provenance(MusicTUIAction)
        /// No matrix row: runs as shipped by design, never gated. The reason is
        /// section 2's.
        case noMatrixRow(String)
    }

    struct Row {
        let invocation: String
        let command: String
        let letter: Letter
        let enforcement: Enforcement
        let owner: String
    }

    /// Command groups: they only select a subcommand (their default included).
    private let groups: Set<String> = ["Speaker", "Playlist", "Radio", "Auth"]

    /// Section 2, mirrored. Owner "—" means no Part 1 step changes the row.
    private let inventory: [Row] = [
        // Served through Bridge.
        Row(invocation: "now (and bare `music` off a TTY)", command: "Now", letter: .served, enforcement: .route(.nowStatus), owner: "S6"),
        Row(invocation: "pause", command: "Pause", letter: .served, enforcement: .route(.playPause), owner: "S6"),
        Row(invocation: "skip", command: "Skip", letter: .served, enforcement: .route(.next), owner: "S6"),
        Row(invocation: "back", command: "Back", letter: .served, enforcement: .route(.previous), owner: "S6"),
        Row(invocation: "stop", command: "Stop", letter: .served, enforcement: .route(.stop), owner: "S6"),
        Row(invocation: "seek", command: "Seek", letter: .served, enforcement: .route(.seek), owner: "S6"),
        Row(invocation: "play (resume)", command: "Play", letter: .served, enforcement: .route(.cliPlayResume), owner: "S7"),
        Row(invocation: "play N", command: "Play", letter: .served, enforcement: .route(.cliPlayIndex), owner: "S7"),
        Row(invocation: "play --playlist", command: "Play", letter: .served, enforcement: .route(.cliPlayPlaylist), owner: "S7"),
        Row(invocation: "play --album", command: "Play", letter: .served, enforcement: .route(.cliPlayAlbum), owner: "S7"),
        Row(invocation: "play --song", command: "Play", letter: .served, enforcement: .route(.cliPlaySong), owner: "S7"),
        Row(invocation: "play --artist", command: "Play", letter: .served, enforcement: .route(.cliPlayArtist), owner: "S7"),
        Row(invocation: "search --library", command: "Search", letter: .served, enforcement: .route(.searchLibrary), owner: "S7"),
        // Part 2, P6: catalogue search (`slice.search`) and song links (`slice.queue {"ids"}`).
        // `play N` on a `.bridgeCatalog` row is the `play N` row above (D6).
        Row(invocation: "search (catalogue)", command: "Search", letter: .served, enforcement: .route(.catalogSearch), owner: "P6"),
        Row(invocation: "play <Apple Music song link>", command: "Play", letter: .served, enforcement: .route(.cliPlayCatalogSong), owner: "P6"),

        // Refused before any side effect.
        Row(invocation: "shuffle", command: "Shuffle", letter: .refused, enforcement: .route(.persistentShuffleMode), owner: "S6"),
        Row(invocation: "repeat", command: "Repeat_", letter: .refused, enforcement: .route(.persistentRepeatMode), owner: "S6"),
        Row(invocation: "play <words> (and any non-song Apple Music link)", command: "Play", letter: .refused, enforcement: .route(.cliPlayQuery), owner: "S7 (Q1: refuse)"),
        Row(invocation: "add N (Bridge library or catalogue row)", command: "Add", letter: .refused, enforcement: .provenance(.addToLibrary), owner: "S3, P6 (Q3: refuse)"),
        Row(invocation: "add --to P (no song)", command: "Add", letter: .refused, enforcement: .route(.addCurrentTrackToPlaylist), owner: "existing"),
        Row(invocation: "remove", command: "Remove", letter: .refused, enforcement: .route(.removeCurrentTrackFromPlaylist), owner: "existing"),
        Row(invocation: "love", command: "Love", letter: .refused, enforcement: .route(.loveTrack), owner: "existing"),
        Row(invocation: "unlove", command: "Unlove", letter: .refused, enforcement: .route(.loveTrack), owner: "existing"),
        Row(invocation: "playlist temp", command: "PlaylistTemp", letter: .refused, enforcement: .route(.playlistTemp), owner: "S6"),
        Row(invocation: "radio play", command: "RadioPlay", letter: .refused, enforcement: .route(.radioStationPlay), owner: "S6"),
        Row(invocation: "similar (no title: current track)", command: "Similar", letter: .refused, enforcement: .route(.similarToCurrentTrack), owner: "existing"),
        Row(invocation: "suggest (no --from: current track)", command: "Suggest", letter: .refused, enforcement: .route(.suggestFromCurrentTrack), owner: "existing"),
        Row(invocation: "new-releases --like-current", command: "NewReleases", letter: .refused, enforcement: .route(.newReleasesLikeCurrentTrack), owner: "existing"),
        Row(invocation: "volume", command: "Vol", letter: .refused, enforcement: .route(.volume), owner: "S8"),
        Row(invocation: "speaker <name>/<name> N/<name> stop/<name> only/indices/wake (Lock in Music.app mode)", command: "SpeakerSmart", letter: .refused, enforcement: .route(.airplayRoute), owner: "S8"),
        Row(invocation: "speaker list/verify, interactive picker (no lock)", command: "SpeakerSmart", letter: .refused, enforcement: .route(.airplayRoute), owner: "S8"),
        Row(invocation: "speaker list (hidden subcommand)", command: "SpeakerList", letter: .refused, enforcement: .route(.airplayRoute), owner: "S8"),
        Row(invocation: "speaker set", command: "SpeakerSet", letter: .refused, enforcement: .route(.airplayRoute), owner: "S8"),
        Row(invocation: "speaker add", command: "SpeakerAdd", letter: .refused, enforcement: .route(.airplayRoute), owner: "S8"),
        Row(invocation: "speaker remove", command: "SpeakerRemove", letter: .refused, enforcement: .route(.airplayRoute), owner: "S8"),
        Row(invocation: "speaker stop", command: "SpeakerStop", letter: .refused, enforcement: .route(.airplayRoute), owner: "S8"),

        // Migration exceptions [B]: shipped backends until Part B.
        Row(invocation: "playlist list", command: "PlaylistList", letter: .migration, enforcement: .route(.playlistListing), owner: "S8"),
        Row(invocation: "playlist tracks", command: "PlaylistTracks", letter: .migration, enforcement: .route(.playlistListing), owner: "S8"),
        Row(invocation: "radio search", command: "RadioSearch", letter: .migration, enforcement: .route(.radioSearch), owner: "S8"),
        Row(invocation: "discover", command: "Discover", letter: .migration, enforcement: .route(.discoverFeed), owner: "S8"),
        Row(invocation: "similar <title>", command: "Similar", letter: .migration, enforcement: .route(.similar), owner: "S8"),
        Row(invocation: "suggest --from P", command: "Suggest", letter: .migration, enforcement: .route(.suggest), owner: "S8"),
        Row(invocation: "new-releases --artist A", command: "NewReleases", letter: .migration, enforcement: .route(.newReleases), owner: "S8"),
        Row(invocation: "recent", command: "Recent", letter: .migration, enforcement: .route(.recent), owner: "S8"),
        Row(invocation: "rotation", command: "Rotation", letter: .migration, enforcement: .route(.rotation), owner: "S8"),

        // Named exceptions: run as shipped.
        Row(invocation: "add --id X / add <query> / add N (non-Bridge row)", command: "Add", letter: .exception, enforcement: .route(.addToLibrary), owner: "—"),
        Row(invocation: "playlist create", command: "PlaylistCreate", letter: .exception, enforcement: .route(.playlistWrite), owner: "—"),
        Row(invocation: "playlist delete", command: "PlaylistDelete", letter: .exception, enforcement: .route(.playlistWrite), owner: "—"),
        Row(invocation: "playlist add", command: "PlaylistAdd", letter: .exception, enforcement: .route(.playlistWrite), owner: "—"),
        Row(invocation: "playlist remove", command: "PlaylistRemove", letter: .exception, enforcement: .route(.playlistWrite), owner: "—"),
        Row(invocation: "playlist create-from", command: "PlaylistCreateFrom", letter: .exception, enforcement: .route(.playlistWrite), owner: "—"),
        Row(invocation: "playlist cleanup", command: "PlaylistCleanup", letter: .exception, enforcement: .route(.playlistWrite), owner: "—"),
        Row(invocation: "playlist share", command: "PlaylistShare", letter: .exception, enforcement: .route(.playlistShare), owner: "—"),
        Row(invocation: "radio list", command: "RadioList", letter: .exception, enforcement: .noMatrixRow("local favourites"), owner: "—"),
        Row(invocation: "radio add URL", command: "RadioAdd", letter: .exception, enforcement: .route(.radioAddURL), owner: "S8 ([B]: unchanged)"),
        Row(invocation: "mix", command: "Mix", letter: .exception, enforcement: .route(.cliMix), owner: "—"),
        Row(invocation: "eq", command: "EQ", letter: .exception, enforcement: .route(.eq), owner: "—"),
        Row(invocation: "visualizer", command: "Visualizer", letter: .exception, enforcement: .route(.visualizer), owner: "—"),
        Row(invocation: "auth setup", command: "AuthSetup", letter: .exception, enforcement: .route(.auth), owner: "—"),
        Row(invocation: "auth status", command: "AuthStatus", letter: .exception, enforcement: .route(.auth), owner: "—"),
        Row(invocation: "auth set-token", command: "AuthSetToken", letter: .exception, enforcement: .route(.auth), owner: "—"),
        Row(invocation: "auth open", command: "AuthOpen", letter: .exception, enforcement: .route(.auth), owner: "—"),
        Row(invocation: "sync-plays", command: "SyncPlays", letter: .exception, enforcement: .noMatrixRow("both backends by design"), owner: "—"),
        Row(invocation: "__watch-container", command: "WatchContainer", letter: .exception, enforcement: .noMatrixRow("internal; finishes a Music.app album play's cleanup"), owner: "—"),
    ]

    /// Part 1's M set under [B], as its own literal: everything Part B must
    /// retire. Never shrinks; a retired action moves to `retiredMigrations`.
    private let partOneMigrationActions: Set<MusicTUIAction> = [
        .catalogSearch, .playlistListing, .radioSearch, .discoverFeed,
        .similar, .suggest, .newReleases, .recent, .rotation,
    ]

    /// Migration exceptions Part B has already served or refused, by step.
    private let retiredMigrations: [MusicTUIAction: String] = [
        .catalogSearch: "P6",
    ]

    /// The M rows still standing.
    private var migrationActions: Set<MusicTUIAction> {
        partOneMigrationActions.subtracting(retiredMigrations.keys)
    }

    // MARK: - The walk

    private func walk(_ commands: [ParsableCommand.Type]) -> [String] {
        commands.flatMap { [String(describing: $0)] + walk($0.configuration.subcommands) }
    }

    /// Every command type in the real tree is classified, and the mirror names
    /// no command that no longer exists. A new subcommand fails here until it
    /// is given a row.
    func testEveryCommandInTheTreeIsClassified() {
        let tree = walk(Music.configuration.subcommands)
        XCTAssertEqual(tree.count, Set(tree).count, "a command type appears twice in the tree")
        let classified = Set(inventory.map(\.command)).union(groups)
        for command in tree {
            XCTAssertTrue(classified.contains(command), "\(command) is in the CLI but not in section 2's inventory")
        }
        for command in classified {
            XCTAssertTrue(tree.contains(command), "the inventory names \(command), which the CLI no longer has")
        }
        for group in groups {
            XCTAssertTrue(inventory.allSatisfy { $0.command != group }, "\(group) is a group; classify its subcommands")
        }
    }

    // MARK: - Each row's route matches its letter

    func testEachRowsRouteMatchesItsLetter() {
        for row in inventory {
            let label = "\(row.invocation) [\(row.letter.rawValue)]"
            XCTAssertFalse(row.owner.isEmpty, label)
            switch row.enforcement {
            case .route(let action):
                XCTAssertTrue(action.surfaces.contains(.cli), "\(label): \(action) has no CLI surface")
                let bridge = routeAction(action, in: .source, from: .cli)
                let shipped = routeAction(action, in: .musicApp, from: .cli)
                if case .refused = shipped { XCTFail("\(label): refused with Music.app selected") }
                switch row.letter {
                case .served:
                    XCTAssertEqual(bridge, .source, label)
                    XCTAssertTrue(cliDispatchedOnBridge.contains(action), label)
                case .refused:
                    guard case .refused(let why) = bridge else { XCTFail("\(label) must refuse on Bridge"); continue }
                    XCTAssertFalse(why.isEmpty, label)
                    XCTAssertFalse(cliBridgeExceptions.contains(action), label)
                case .exception:
                    XCTAssertEqual(bridge, shipped, "\(label) runs as it ships")
                    XCTAssertTrue(cliBridgeExceptions.contains(action), label)
                    XCTAssertFalse(migrationActions.contains(action), "\(label) is named, not temporary")
                case .migration:
                    XCTAssertEqual(bridge, shipped, "\(label) keeps its shipped backend [B]")
                    XCTAssertTrue(cliBridgeExceptions.contains(action), label)
                    XCTAssertTrue(migrationActions.contains(action), label)
                }
            case .provenance(let action):
                XCTAssertEqual(row.letter, .refused, label)
                XCTAssertEqual(routeAction(action, in: .source, from: .cli),
                               routeAction(action, in: .musicApp, from: .cli), "\(label): the matrix runs the verb")
                for origin in [SongOrigin.bridgeLibrary, .bridgeCatalog] {
                    let bridgeRow = SongResult(index: 1, title: "T", artist: "A", album: "AL", catalogId: "",
                                               origin: origin, bridgeID: "b-1")
                    XCTAssertNotNil(bridgeRowsRefusal([bridgeRow]), "\(label): a \(origin) row is refused")
                }
                XCTAssertNil(bridgeRowsRefusal([SongResult(index: 1, title: "T", artist: "A", album: "AL",
                                                           catalogId: "1", origin: .catalog)]), label)
            case .noMatrixRow(let why):
                XCTAssertEqual(row.letter, .exception, label)
                XCTAssertFalse(why.isEmpty, label)
            }
        }
    }

    /// The exception set is exactly the E and M rows' actions: no action runs
    /// as shipped on Bridge without an inventory row saying so.
    func testTheExceptionSetIsExactlyTheInventorysEAndMRows() {
        var fromRows: Set<MusicTUIAction> = []
        for row in inventory where row.letter == .exception || row.letter == .migration {
            if case .route(let action) = row.enforcement { fromRows.insert(action) }
        }
        XCTAssertEqual(cliBridgeExceptions, fromRows)
        let migrationFromRows = Set(inventory.filter { $0.letter == .migration }.compactMap { row -> MusicTUIAction? in
            if case .route(let a) = row.enforcement { return a } else { return nil }
        })
        XCTAssertEqual(migrationFromRows, migrationActions)
    }

    /// Each retired migration exception left `cliBridgeExceptions` and is now
    /// served through Bridge or refused, and every inventory row that names it
    /// says so. Part B ends when `migrationActions` is empty (P9).
    func testRetiredMigrationExceptionsAreServedOrRefusedNeverShipped() {
        XCTAssertTrue(Set(retiredMigrations.keys).isSubset(of: partOneMigrationActions))
        for (action, step) in retiredMigrations {
            XCTAssertFalse(cliBridgeExceptions.contains(action), "\(action) was retired by \(step)")
            switch routeAction(action, in: .source, from: .cli) {
            case .source:
                XCTAssertTrue(cliDispatchedOnBridge.contains(action), "\(action)")
            case .refused(let why):
                XCTAssertFalse(why.isEmpty, "\(action)")
            case .musicApp, .unaffected:
                XCTFail("\(action) was retired by \(step) but still runs its shipped backend on Bridge")
            }
            let rows = inventory.filter {
                if case .route(let a) = $0.enforcement { return a == action } else { return false }
            }
            XCTAssertFalse(rows.isEmpty, "\(action) has no inventory row")
            for row in rows {
                XCTAssertTrue(row.letter == .served || row.letter == .refused, "\(row.invocation) is still \(row.letter)")
                XCTAssertTrue(row.owner.contains(step), "\(row.invocation) names its retiring step")
            }
        }
    }

    /// Every CLI-reachable action appears in some row, so the matrix has no
    /// CLI case the inventory forgot. One named omission: `.collectionShuffle`'s
    /// CLI surface is the trailing `shuffle` word inside `music play`
    /// (PlayParser.swift:27), which the play rows own; `playAction` never
    /// routes it on its own.
    func testEveryCliActionHasAnInventoryRow() {
        var named: Set<MusicTUIAction> = []
        for row in inventory {
            switch row.enforcement {
            case .route(let a), .provenance(let a): named.insert(a)
            case .noMatrixRow: break
            }
        }
        let cli = Set(MusicTUIAction.allCases.filter { $0.surfaces.contains(.cli) })
        XCTAssertEqual(cli.subtracting(named), [.collectionShuffle], "CLI actions with no inventory row")
    }

    /// The closing counts: one row per invocation, every row served, refused
    /// or an exception (named or migration).
    func testTheInventoryCloses() {
        func count(_ l: Letter) -> Int { inventory.filter { $0.letter == l }.count }
        // P6: catalogue search moved M → S; the song link moved R → S.
        XCTAssertEqual(count(.served), 15)
        XCTAssertEqual(count(.refused), 21)
        XCTAssertEqual(count(.migration), 9)
        XCTAssertEqual(count(.exception), 19)
        XCTAssertEqual(inventory.count, 64)
    }

    // MARK: - The gate comes first (STRUCTURAL: source text, not execution evidence)

    /// Each command with a refused row asks first: its `run()`'s first
    /// statement is the Bridge gate (`try refuseInBridge(`), or a call to a
    /// `run<Verb>` whose first statement is `try cliDispatch(`. A gate naming
    /// its action literally must name one of the command's refused actions.
    func testEveryRefusingCommandsRunStartsWithTheGate() throws {
        let commands = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Commands")
        let files = try FileManager.default.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let sources = try files.map { try String(contentsOf: $0, encoding: .utf8) }

        var refusing: [String: Set<MusicTUIAction>] = [:]
        for row in inventory where row.letter == .refused {
            switch row.enforcement {
            case .route(let a), .provenance(let a): refusing[row.command, default: []].insert(a)
            case .noMatrixRow: break
            }
        }
        XCTAssertFalse(refusing.isEmpty)
        for (command, actions) in refusing {
            guard let source = sources.first(where: { $0.contains("struct \(command): ParsableCommand") }),
                  let first = firstLineOfRun(command, in: source)
            else { XCTFail("\(command) not found"); continue }
            if first.hasPrefix("try refuseInBridge(.") {
                let named = actions.contains { first.hasPrefix("try refuseInBridge(.\($0),") || first.hasPrefix("try refuseInBridge(.\($0))") }
                XCTAssertTrue(named, "\(command) gates on the wrong action: \(first)")
            } else if first.hasPrefix("try refuseInBridge(") {
                // The action is computed from the flags (e.g. `addAction(…)`); the
                // selectors are pinned in CLIBridgeGateTests.
            } else if let verb = first.range(of: #"^try (run[A-Za-z]+)\("#, options: .regularExpression)
                        .map({ String(first[$0].dropFirst(4).dropLast()) }) {
                let body = sources.lazy.compactMap { self.firstStatement(ofFunction: verb, in: $0) }.first
                XCTAssertEqual(body.map { $0.hasPrefix("try cliDispatch(") }, true,
                               "\(command): \(verb) must start with try cliDispatch(")
            } else {
                XCTFail("\(command).run() must ask the Bridge gate first; it starts with: \(first)")
            }
        }
    }

    private func firstLineOfRun(_ command: String, in source: String) -> String? {
        guard let decl = source.range(of: "struct \(command): ParsableCommand"),
              let run = source.range(of: "func run() throws {\n", range: decl.upperBound..<source.endIndex)
        else { return nil }
        return String(source[run.upperBound...].prefix { $0 != "\n" }).trimmingCharacters(in: .whitespaces)
    }

    private func firstStatement(ofFunction name: String, in source: String) -> String? {
        guard let decl = source.range(of: "\nfunc \(name)("),
              let open = source.range(of: "{\n", range: decl.upperBound..<source.endIndex)
        else { return nil }
        return String(source[open.upperBound...].prefix { $0 != "\n" }).trimmingCharacters(in: .whitespaces)
    }
}
