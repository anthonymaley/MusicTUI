import XCTest
@testable import music

private final class StubScene: Scene {
    let id: SceneID = .nowPlaying
    let tabTitle = "Stub"
    var capturing = false
    var capturesAllInput: Bool { capturing }
    func tick(snapshot: NowPlayingSnapshot) {}
    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String { "" }
    func handle(_ key: KeyPress) -> SceneAction { .none }
}

final class SceneInputModeTests: XCTestCase {
    func testDefaultIsFalse() {
        // NowPlayingScene does not override capturesAllInput.
        let s = NowPlayingScene(backend: AppleScriptBackend())
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
}
