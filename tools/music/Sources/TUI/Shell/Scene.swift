// tools/music/Sources/TUI/Shell/Scene.swift
import Foundation

/// What a scene asks the shell to do after handling a key.
enum SceneAction: Equatable {
    case none          // key ignored
    case redraw        // state changed; repaint next frame (already continuous, but explicit)
    case push(SceneID) // drill into another scene
    case pop           // go back
    case quit          // exit the shell
}

/// A renderable, interactive surface inside the shell. Implementations draw into
/// the body region the shell hands them (frame.bodyY .. frame.bodyY+bodyHeight-1)
/// and never touch chrome, tabs, or the now-playing bar.
protocol Scene: AnyObject {
    var id: SceneID { get }
    var tabTitle: String { get }

    /// When true, the shell routes every key straight to `handle` without
    /// resolving globals, Tab, or Esc — for raw text entry (filter, search).
    var capturesAllInput: Bool { get }

    /// Called once per frame before render, so the scene can fold the latest
    /// snapshot into its own view state (e.g. clamp a cursor to new row counts).
    func tick(snapshot: NowPlayingSnapshot)

    /// Return the ANSI string for the body region only.
    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String

    /// Handle a scene-local key (globals were already resolved by the shell).
    func handle(_ key: KeyPress) -> SceneAction
}

extension Scene {
    var capturesAllInput: Bool { false }
}

/// Pure decision: should the shell resolve global/navigation keys for the
/// active scene, or hand everything to the scene? Globals are skipped only when
/// the scene is capturing raw input.
func shellShouldResolveGlobals(forSceneCapturing capturing: Bool) -> Bool {
    !capturing
}
