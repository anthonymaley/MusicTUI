// tools/music/Sources/TUI/Shell/Router.swift
import Foundation

enum SceneID: Equatable {
    case nowPlaying, playlists, speakers, search, library, queue
}

/// Navigation state for the shell: a back stack of scene ids. Top-level tab
/// switches reset the stack; drill-downs push; back pops (never past root).
final class Router {
    private(set) var stack: [SceneID]

    init(root: SceneID) { stack = [root] }

    var active: SceneID { stack.last! }

    func switchTo(_ id: SceneID) { stack = [id] }
    func push(_ id: SceneID) { stack.append(id) }
    func pop() { if stack.count > 1 { stack.removeLast() } }
}
