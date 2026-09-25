import Foundation

/// What the CLI asks Bridge to play (score D2). There is no catalogue or
/// station case until its first caller; exhaustive switches then force it.
enum BridgePlaybackRef: Equatable {
    /// `slice.play`: resume whatever Bridge has loaded.
    case resume
    /// `slice.queue` with `library_ids`.
    case libraryQueue(ids: [String], startRequired: Bool)
}

/// Bridge `play N`: queue the row, or refuse it with a sentence.
enum BridgeIndexRoute: Equatable {
    case queue(BridgePlaybackRef)
    case refuse(String)
}

/// Music.app `play N`: re-resolve the row by title as shipped, or refuse it.
enum MusicAppIndexRoute: Equatable {
    case reResolveByTitle
    case refuse(String)
}

/// The only way a cached row becomes a Bridge reference. Decides by `origin`
/// and never reads the id's text, so a catalogue or Music.app row whose id
/// happens to look like a library id is still refused (score D3).
func bridgeRef(forCachedRow row: SongResult, index: Int) -> BridgeIndexRoute {
    switch row.origin {
    case .bridgeLibrary:
        guard let id = row.bridgeID, !id.isEmpty else {
            return .refuse("Result \(index) has no Bridge id; run the search again.")
        }
        return .queue(.libraryQueue(ids: [id], startRequired: true))
    case .catalog, .library:
        return .refuse("Result \(index) came from a Music.app or catalogue listing, so Bridge can't play it by its own id. With Bridge selected, run: music search --library \"\(row.title)\"  then  music play N")
    }
}

/// Music.app `play N` for a cached row: a Bridge row, with or without its id,
/// is refused; every other origin keeps the shipped re-resolve (score D3).
func musicAppIndexRoute(forCachedRow row: SongResult, index: Int) -> MusicAppIndexRoute {
    switch row.origin {
    case .bridgeLibrary:
        return .refuse("Result \(index) came from Bridge's library, which Music.app can't play by identity. Search again with Output set to Music.app, or switch Output to Bridge.")
    case .catalog, .library:
        return .reResolveByTitle
    }
}

/// `add N` and `playlist create/add` with indices: if ANY resolved row is a
/// Bridge row, the whole command is refused, naming every Bridge row. nil when
/// there are none. Called before any token read, AppleScript or REST.
func bridgeRowsRefusal(_ rows: [SongResult]) -> String? {
    let bridgeIndices: [Int] = rows.compactMap { row in
        switch row.origin {
        case .bridgeLibrary: return row.index
        case .catalog, .library: return nil
        }
    }
    guard !bridgeIndices.isEmpty else { return nil }
    let list = bridgeIndices.map(String.init).joined(separator: ", ")
    return "Result(s) \(list) came from Bridge's library. Adding Bridge rows to your library or a playlist isn't supported yet; search again with Output set to Music.app."
}

/// Print a cached-row refusal the way the Bridge gate prints its refusals
/// (`refuseInBridge`): the sentence, or `{"ok":false,"error":…}` under `--json`.
/// The caller throws `ExitCode.failure`.
func printCachedRowRefusal(_ why: String, json: Bool) {
    if json {
        let body: [String: Any] = ["ok": false, "error": why]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(why)
    }
}

/// The two inputs `add` and `playlist create/add` read before their shipped
/// bodies run (score S3, Revision 3's seam). Everything after them is the
/// shipped body calling the shipped concrete helpers; AppleScript and REST
/// effects in tests are counted and stopped by `ExternalCallTripwire`.
struct CachedRowCommandDeps {
    var readSongs: () throws -> [SongResult]
    /// Replaces every `AuthManager()` read on these paths. Throws only where
    /// the shipped command threw (`add`'s `require*` reads).
    var readAuth: () throws -> (dev: String?, user: String?, storefront: String)

    /// `playlist create/add`: tokens are optional reads, as shipped.
    static var live: CachedRowCommandDeps {
        CachedRowCommandDeps(
            readSongs: { try ResultCache().readSongs() },
            readAuth: {
                let auth = AuthManager()
                return (dev: try? auth.requireDeveloperToken(), user: auth.userToken(),
                        storefront: auth.storefront())
            })
    }

    /// `add`: both tokens are required and a missing or broken one throws the
    /// same `AuthError` it always has, in the same order.
    static var liveRequiringTokens: CachedRowCommandDeps {
        CachedRowCommandDeps(
            readSongs: { try ResultCache().readSongs() },
            readAuth: {
                let auth = AuthManager()
                let dev = try auth.requireDeveloperToken()
                let user = try auth.requireUserToken()
                return (dev: dev, user: user, storefront: auth.storefront())
            })
    }
}
