// tools/music/Sources/TUI/Shell/Router.swift
import Foundation

enum SceneID: Equatable {
    case nowPlaying, playlists, speakers, search, library, queue, radio, discover
}

/// Navigation state for the shell: a back stack of scene ids. Top-level tab
/// switches reset the stack; drill-downs push; back pops (never past root).
final class Router {
    private(set) var stack: [SceneID]

    init(root: SceneID) { stack = [root] }

    /// Called synchronously, on the caller's thread, the moment the active scene
    /// actually changes, with the scene just left. Not called when the switch
    /// lands on the scene already active, or a pop at the root changes nothing.
    var onDeparture: ((SceneID) -> Void)?

    var active: SceneID { stack.last! }

    func switchTo(_ id: SceneID) { stack = [id] }
    func push(_ id: SceneID) { stack.append(id) }
    func pop() { if stack.count > 1 { stack.removeLast() } }
}

/// Wires a router's departures to the scenes' `resignedActive()`, so a scene
/// hears it left at the moment of the key that left, not on the next loop pass.
func connectDepartures(of router: Router, to scene: @escaping (SceneID) -> Scene?) {
    router.onDeparture = { scene($0)?.resignedActive() }
}
