import XCTest
@testable import music

/// The AppleScript backend's one subprocess core, `runBlocking`, and the async
/// `run`/`runMusic` that hand it to a Dispatch queue. Every script here is a
/// small temp `/bin/sh` file standing in for osascript (it ignores the `-e
/// <script>` arguments unless it echoes them), so nothing reaches Apple's Music
/// app and nothing plays.
final class AppleScriptBackendSubprocessTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("applescript-core-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A backend whose interpreter is a `/bin/sh` script with `body`.
    private func backend(_ body: String) -> AppleScriptBackend {
        let path = dir.appendingPathComponent("script-\(UUID().uuidString).sh").path
        XCTAssertNoThrow(try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8))
        XCTAssertNoThrow(try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path))
        return AppleScriptBackend(executable: path)
    }

    /// Run `body` off the main thread and fail, rather than hang, if it does
    /// not return within `seconds`.
    private func within<T>(_ seconds: TimeInterval, _ body: @escaping () -> T) -> T? {
        let done = expectation(description: "returned")
        let box = Box<T>()
        DispatchQueue.global().async {
            box.value = body()
            done.fulfill()
        }
        wait(for: [done], timeout: seconds)
        return box.value
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: - Outcomes

    func testSuccessReturnsStdout() throws {
        XCTAssertEqual(try backend("printf 'hello\\n'").runBlocking("x"), "hello\n")
    }

    func testNonzeroExitThrowsExecutionFailedWithStderr() {
        XCTAssertThrowsError(try backend("printf 'out'; printf 'boom' >&2; exit 3").runBlocking("x")) { error in
            guard case AppleScriptBackend.ScriptError.executionFailed(let message)? = error as? AppleScriptBackend.ScriptError
            else { return XCTFail("got \(error)") }
            XCTAssertEqual(message, "boom")
        }
    }

    func testVanishedAirPlayDeviceStillMapsToSpeakerUnavailable() {
        let b = backend("printf '36:41: execution error: Music got an error: Can'\\''t get AirPlay device \"Deck\". (-1728)' >&2; exit 1")
        XCTAssertThrowsError(try b.runBlocking("x")) { error in
            guard case AppleScriptBackend.ScriptError.speakerUnavailable(let name)? = error as? AppleScriptBackend.ScriptError
            else { return XCTFail("got \(error)") }
            XCTAssertEqual(name, "Deck")
        }
    }

    /// 1 MB on each pipe, interleaved in 64 KB chunks: far past the pipe
    /// buffer on both. A serial stdout-then-stderr read deadlocks here (the
    /// script blocks writing stderr while the reader waits for stdout's EOF)
    /// until the watchdog kills it, which this reports as a timeout.
    private let interleavedMegabyte = """
        i=0
        while [ $i -lt 16 ]; do
            yes o | head -c 65536
            yes e | head -c 65536 >&2
            i=$((i + 1))
        done
        """

    func testLargeInterleavedStdoutAndStderrDoNotDeadlock() {
        let b = backend(interleavedMegabyte)
        let result = within(20) { Result { try b.runBlocking("x", timeout: 15) } }
        XCTAssertEqual(try result?.get().count, 1_048_576)
    }

    func testLargeStderrIsReadWholeOnAFailure() {
        let b = backend(interleavedMegabyte + "\nexit 1")
        let result = within(20) { Result { try b.runBlocking("x", timeout: 15) } }
        guard case .failure(let error)? = result,
              case AppleScriptBackend.ScriptError.executionFailed(let message)? = error as? AppleScriptBackend.ScriptError
        else { return XCTFail("got \(String(describing: result))") }
        XCTAssertEqual(message.utf8.count, 1_048_576)
    }

    func testLaunchFailureThrowsPromptly() {
        let b = AppleScriptBackend(executable: dir.appendingPathComponent("missing-interpreter").path)
        let start = Date()
        let result = within(5) { Result { try b.runBlocking("x", timeout: 30) } }
        guard case .failure(let error)? = result else { return XCTFail("got \(String(describing: result))") }
        XCTAssertFalse(error is AppleScriptBackend.ScriptError, "a launch failure is not a script outcome: \(error)")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// `exec`, so the sleeping process IS the one the watchdog terminates. A
    /// grandchild holding the pipes open would keep the reads waiting until it
    /// exits, as it always has; osascript starts none.
    func testTimeoutThrowsTimeoutAndReturnsPromptly() {
        let b = backend("exec sleep 30")
        let start = Date()
        let result = within(10) { Result { try b.runBlocking("x", timeout: 0.5) } }
        guard case .failure(let error)? = result,
              case AppleScriptBackend.ScriptError.timeout? = error as? AppleScriptBackend.ScriptError
        else { return XCTFail("got \(String(describing: result))") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// The termination handler arrives asynchronously: a watchdog can fire
    /// after the script has exited but before the handler has recorded it.
    /// The claim must see the exit itself and neither claim nor terminate.
    func testAWatchdogAfterAnUnreportedExitClaimsNothingAndTerminatesNothing() {
        let arbiter = ScriptExitArbiter()
        XCTAssertFalse(arbiter.claimTimeout(isRunning: { false }), "an exited script was claimed as a timeout")
        XCTAssertFalse(arbiter.finish(), "an exited script was reported as a timeout")
    }

    func testAWatchdogOnARunningScriptClaimsTheTimeout() {
        let arbiter = ScriptExitArbiter()
        XCTAssertTrue(arbiter.claimTimeout(isRunning: { true }))
        arbiter.recordExit()   // the kill's own exit does not undo the claim
        XCTAssertTrue(arbiter.finish())
    }

    /// The script exits at once, well inside the watchdog, but a background
    /// grandchild holds its stdout open past the deadline, so the drain ends
    /// after the watchdog fires. A natural exit before the deadline is the
    /// script's outcome, not a timeout: the watchdog may claim the timeout
    /// only for a process that has not exited.
    func testExitBeforeTheDeadlineIsNotATimeoutWhenTheDrainEndsAfterIt() {
        let b = backend("echo done\n( sleep 1.5 ) &\nexit 0")
        let result = within(10) { Result { try b.runBlocking("x", timeout: 0.3) } }
        guard case .success(let out)? = result else { return XCTFail("got \(String(describing: result))") }
        XCTAssertTrue(out.contains("done"), "output: \(out)")
    }

    /// Exits land on both sides of the watchdog, and some exactly on it: each
    /// run is one outcome, either the output or a timeout, with no crash and
    /// (async) no second resume of the continuation, which traps.
    func testExitAtTheTimeoutBoundaryIsOneOutcome() {
        let b = backend("sleep 0.2; printf ok")
        let outcomes = within(60) { () -> [String] in
            let group = DispatchGroup()
            let lock = NSLock()
            var seen: [String] = []
            func record(_ r: Result<String, Error>) {
                let label: String
                switch r {
                case .success(let out): label = out == "ok" ? "ok" : "unexpected output \(out)"
                case .failure(let e):
                    if case AppleScriptBackend.ScriptError.timeout? = e as? AppleScriptBackend.ScriptError { label = "timeout" }
                    else { label = "unexpected error \(e)" }
                }
                lock.lock(); seen.append(label); lock.unlock()
            }
            for i in 0..<12 {
                let timeout = 0.15 + Double(i) * 0.01
                group.enter()
                DispatchQueue.global().async {
                    record(Result { try b.runBlocking("x", timeout: timeout) })
                    group.leave()
                }
                group.enter()
                Task.detached {
                    do { record(.success(try await b.run("x", timeout: timeout))) } catch { record(.failure(error)) }
                    group.leave()
                }
            }
            group.wait()
            return seen
        }
        XCTAssertEqual(outcomes?.count, 24)
        XCTAssertEqual(outcomes?.filter { $0 != "ok" && $0 != "timeout" }, [])
    }

    // MARK: - The async wrappers

    func testAsyncRunReturnsWhatRunBlockingReturns() throws {
        let b = backend("printf '%s' \"$2\"")
        let blocking = try b.runBlocking("return 1")
        let async = try syncRun { try await b.run("return 1") }
        XCTAssertEqual(blocking, "return 1")
        XCTAssertEqual(async, blocking)
    }

    func testRunMusicAndRunMusicBlockingWrapTheScriptTheSameWay() throws {
        let b = backend("printf '%s' \"$2\"")
        let blocking = try b.runMusicBlocking("play")
        let async = try syncRun { try await b.runMusic("play") }
        XCTAssertEqual(blocking, "tell application \"Music\"\n    play\nend tell")
        XCTAssertEqual(async, blocking)
    }

    func testAsyncRunPropagatesTheSameError() {
        let b = backend("printf 'boom' >&2; exit 2")
        XCTAssertThrowsError(try syncRun { try await b.run("x") }) { error in
            guard case AppleScriptBackend.ScriptError.executionFailed(let message)? = error as? AppleScriptBackend.ScriptError
            else { return XCTFail("got \(error)") }
            XCTAssertEqual(message, "boom")
        }
    }

    // MARK: - The tripwire

    /// Armed, the blocking funnel records the script and throws before any
    /// process: the interpreter does not exist, so a missing guard would fail
    /// differently and record nothing.
    func testArmedTripwireStopsTheBlockingPathBeforeAnyProcess() {
        let b = AppleScriptBackend(executable: "/nonexistent/tripwire-osascript")
        let (thrown, calls) = withTripwire { () -> [Error] in
            var errors: [Error] = []
            do { _ = try b.runBlocking("return 1") } catch { errors.append(error) }
            do { _ = try b.runMusicBlocking("play") } catch { errors.append(error) }
            return errors
        }
        XCTAssertEqual(thrown.count, 2)
        XCTAssertTrue(thrown.allSatisfy { $0 is ExternalCallBlocked }, "\(thrown)")
        XCTAssertEqual(calls, [.appleScript(script: "return 1"),
                               .appleScript(script: "tell application \"Music\"\n    play\nend tell")])
    }
}
