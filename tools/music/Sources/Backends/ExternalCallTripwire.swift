import Foundation

/// One call that would leave the process: an AppleScript run, a REST request,
/// or a process launch (score: data route and output, C-START — starting or
/// bringing forward the Mac-hosted alternate source).
enum ExternalCall: Equatable, CustomStringConvertible {
    case appleScript(script: String)
    case http(method: String, path: String)
    case launchApp(bundleID: String)

    var description: String {
        switch self {
        case .appleScript(let script): return "osascript: \(script.prefix(80))"
        case .http(let method, let path): return "\(method) \(path)"
        case .launchApp(let bundleID): return "open the app \(bundleID)"
        }
    }
}

/// Thrown by an armed tripwire in place of the call it stopped.
struct ExternalCallBlocked: Error, LocalizedError {
    let call: ExternalCall
    var errorDescription: String? { "Test tripwire blocked \(call)" }
}

/// A test-only tripwire at the process funnels (`AppleScriptBackend.run`,
/// `RESTAPIBackend.get`/`post`, and the Mac SpanDAC launch/bring-forward call
/// in `MacSpanDACStarter.swift`). Production never arms it, and unarmed it is a
/// lock and a flag read. A test arms it so that every AppleScript, REST or
/// launch call is recorded and throws before any `Process` or `URLSession`
/// runs: "0 AppleScript/REST/launch calls" is then a count, not an inference
/// (score S3; score: data route and output, C-START).
final class ExternalCallTripwire: @unchecked Sendable {
    static let shared = ExternalCallTripwire()

    private let lock = NSLock()
    private var armed = false
    private var calls: [ExternalCall] = []

    var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return armed }
    var recorded: [ExternalCall] { lock.lock(); defer { lock.unlock() }; return calls }

    /// Arm and clear the record.
    func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true
        calls = []
    }

    /// Disarm, clear the record, and return what it held.
    @discardableResult
    func disarm() -> [ExternalCall] {
        lock.lock(); defer { lock.unlock() }
        armed = false
        let made = calls
        calls = []
        return made
    }

    /// The funnel guard: inert when unarmed; armed, record the call and throw.
    func check(_ call: @autoclosure () -> ExternalCall) throws {
        lock.lock()
        guard armed else { lock.unlock(); return }
        let made = call()
        calls.append(made)
        lock.unlock()
        throw ExternalCallBlocked(call: made)
    }
}
