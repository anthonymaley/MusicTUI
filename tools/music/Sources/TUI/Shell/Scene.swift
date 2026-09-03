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

    /// Called once per loop iteration before render, so the scene can fold the
    /// latest snapshot into its own view state (e.g. clamp a cursor to new row
    /// counts) and drain any background-fetch inboxes. Returns true when the
    /// scene's own state changed in a way the snapshot generation can't see
    /// (drained inbox, async load landed), so the shell repaints. Runs every
    /// iteration regardless of whether the last frame was painted.
    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool

    /// Return the ANSI string for the body region only.
    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String

    /// Handle a scene-local key (globals were already resolved by the shell).
    func handle(_ key: KeyPress) -> SceneAction

    /// Short scene-specific key hints for the shell footer (the shell appends the
    /// global playback keys). Empty by default.
    var footerHint: String { get }

    /// Called right after the shell clears every kitty placement on a scene
    /// switch (`kittyDeletePlacementsEscape`, d=a — placements only, data
    /// stays transmitted). Art-rendering scenes reset their placement-dedup
    /// state (`lastPlaced = nil`) so the next render re-places instead of
    /// assuming a placement the shell just deleted is still on screen. Default
    /// no-op for scenes with no art.
    func artPlacementsInvalidated()
}

extension Scene {
    var capturesAllInput: Bool { false }
    var footerHint: String { "" }
    func artPlacementsInvalidated() {}
}

/// Pure decision: should the shell resolve global/navigation keys for the
/// active scene, or hand everything to the scene? Globals are skipped only when
/// the scene is capturing raw input.
func shellShouldResolveGlobals(forSceneCapturing capturing: Bool) -> Bool {
    !capturing
}

/// Where the shell sends a key, in the order the input loop applies it.
enum ShellRoute: Equatable {
    /// Leave the loop through the same path as `q`, so the exit `defer`
    /// (admission close, poller stop, Discover exit sweep) runs exactly once.
    case quit
    /// The active scene gets the key unmediated (it is capturing raw text).
    case scene
    /// Globals, then Tab/Shift-Tab, then the scene.
    case globals
}

/// The shell's FIRST decision on every key. Typed Ctrl-C quits from every
/// scene, including the four that capture all input while searching,
/// filtering or showing a menu: a mapping in the global keymap alone would
/// leave it dead inside those states, because the capture branch runs before
/// the global resolver (design 2026-09-03 §7, option B(i); Codex I3). The
/// named loss: Ctrl-C typed to abandon a search or filter field quits the app
/// instead, where before this it did nothing at all.
func shellRoute(for key: KeyPress, sceneCapturing capturing: Bool) -> ShellRoute {
    if key == .ctrlC { return .quit }
    return shellShouldResolveGlobals(forSceneCapturing: capturing) ? .globals : .scene
}
