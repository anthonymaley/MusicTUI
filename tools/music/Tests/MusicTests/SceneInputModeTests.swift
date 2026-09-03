import XCTest
@testable import music

private final class StubScene: Scene {
    let id: SceneID = .nowPlaying
    let tabTitle = "Stub"
    var capturing = false
    var capturesAllInput: Bool { capturing }
    func tick(snapshot: NowPlayingSnapshot) -> Bool { false }
    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String { "" }
    func handle(_ key: KeyPress) -> SceneAction { .none }
}

final class SceneInputModeTests: XCTestCase {
    func testDefaultIsFalse() {
        // NowPlayingScene does not override capturesAllInput.
        let status = StatusStore()
        let s = NowPlayingScene(backend: AppleScriptBackend(), appQueue: AppQueueStore(),
                                status: status, actions: ActionRunner(status: status))
        XCTAssertFalse(s.capturesAllInput)
    }
    func testShellRoutesGlobalsWhenNotCapturing() {
        let s = StubScene(); s.capturing = false
        // q resolves as a global only when the scene is not capturing.
        XCTAssertTrue(shellShouldResolveGlobals(forSceneCapturing: s.capturesAllInput))
    }
    func testShellSkipsGlobalsWhenCapturing() {
        let s = StubScene(); s.capturing = true
        XCTAssertFalse(shellShouldResolveGlobals(forSceneCapturing: s.capturesAllInput))
    }

    // MARK: - Routing order (design 2026-09-03 §7, B(i))

    /// Typed Ctrl-C quits from a CAPTURING scene. This is the case a global
    /// keymap entry alone cannot cover: the capture branch consumes every key
    /// before the resolver runs, so the route must be decided ahead of it.
    func testControlCQuitsWhileASceneIsCapturingInput() {
        let s = StubScene(); s.capturing = true
        XCTAssertTrue(s.capturesAllInput)
        XCTAssertEqual(shellRoute(for: .ctrlC, sceneCapturing: s.capturesAllInput), .quit)
    }

    func testControlCQuitsWhileASceneIsNotCapturing() {
        let s = StubScene()
        XCTAssertEqual(shellRoute(for: .ctrlC, sceneCapturing: s.capturesAllInput), .quit)
    }

    /// `q` is NOT hoisted the same way: typed into a search field it is a
    /// letter, and only the global resolver turns it into quit when no scene
    /// is capturing. Ctrl-C is the one key that outranks capture.
    func testQStillGoesToACapturingSceneAndToGlobalsOtherwise() {
        XCTAssertEqual(shellRoute(for: .char("q"), sceneCapturing: true), .scene)
        XCTAssertEqual(shellRoute(for: .char("q"), sceneCapturing: false), .globals)
        XCTAssertEqual(resolveGlobalKey(.char("q")), .quit)
    }

    /// Ordinary keys are unchanged by the new first decision.
    func testOtherKeysRouteAsBefore() {
        XCTAssertEqual(shellRoute(for: .char("x"), sceneCapturing: true), .scene)
        XCTAssertEqual(shellRoute(for: .char("x"), sceneCapturing: false), .globals)
        XCTAssertEqual(shellRoute(for: .escape, sceneCapturing: true), .scene)
        XCTAssertEqual(shellRoute(for: .space, sceneCapturing: false), .globals)
    }
}
