// tools/music/Sources/Commands/CLIBridgeDispatch.swift
//
// The CLI dispatch seam (slice 3, Part 1, score S5; decisions D1, D5, D6).
//
// **One mode read, the matrix decides (D1).** A dispatching verb builds one
// `CLIBridgeEnv.live()`: one `PlaybackModeStore` shared with
// `RoutingCoordinator.live(store:surface: .cli)`, which reads the mode once.
// `cliDispatch` hands the action to `routing.perform`, so the route is decided
// by the matrix at the moment the command runs. Later re-reads of the store
// (D6's revalidation) can only refuse, never re-route.
//
// **The output lock (D6).** The CLI takes `routing.outputLock` DIRECTLY. Its
// work already runs inside `perform`, which holds the coordinator's in-process
// `order` lock and has set its re-entry marker, so the ordering is `order`
// then the file lock, as in every process; nothing here enters the
// coordinator's boundary a second time. After acquiring, the persisted mode
// must still be the mode the command routed on; a mismatch refuses.
//
// Which CLI work takes the lock is a CLI classification, `requiresOutputLock`,
// not `touchesPlayback`, so no TUI route changes. Library walks, discovery and
// warm-up waits stay outside it.
//
// **What is printed.** Only refusals (the matrix's, the lock's, readiness) and
// Bridge's own errors, as one line of text or one `{"ok":false,"error":…}`
// document, then exit 1. Errors from the shipped Music.app body pass through
// untouched: that body already prints what it ships printing.
import ArgumentParser
import Foundation

// MARK: - Environment

/// Everything a dispatching CLI verb reads or writes outside itself, built once
/// per invocation.
struct CLIBridgeEnv {
    /// Read the mode once, at construction (D1).
    let routing: RoutingCoordinator
    /// The same store the coordinator read, for revalidation under the lock.
    let modeStore: PlaybackModeStore
    let cache: ResultCache
    /// One line to stdout, as `print` writes it.
    let out: (String) -> Void
    /// One line to stderr: warm-up and lock-wait progress.
    let err: (String) -> Void
    /// The warm-up wait. Injected so tests never sleep.
    let sleep: (TimeInterval) -> Void

    /// The production composition: `~/.config/music/mode.json`, the output
    /// lock beside it, the real result cache, stdout and stderr.
    static func live() -> CLIBridgeEnv {
        let store = PlaybackModeStore()
        let routing = RoutingCoordinator.live(store: store, surface: .cli)
        let err: (String) -> Void = { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        routing.outputLock?.onWaiting { err(cliOutputLockWaitingProgress) }
        return CLIBridgeEnv(routing: routing, modeStore: store, cache: ResultCache(),
                            out: { print($0) }, err: err,
                            sleep: { Thread.sleep(forTimeInterval: $0) })
    }
}

/// Stderr, once, when a command starts waiting on the output lock.
let cliOutputLockWaitingProgress = "Waiting for an Output switch to finish…"

/// Stderr, each time Bridge answers `warming` before a mutation.
let cliBridgeWarmingProgress = "Bridge is preparing your library; waiting…"

/// D5: what a command says when Bridge is selected and not ready. Nothing
/// further is sent.
func cliBridgeNotReadySentence(_ readiness: SourceReadiness) -> String {
    let label = readiness.label
    let closed = label.hasSuffix(".") || label.hasSuffix("!") || label.hasSuffix("?") ? label : label + "."
    return closed + " Switch Output to Music.app to use Music.app instead."
}

// MARK: - Classification

/// Whether a CLI action's work must hold the output lock (D6).
///
/// Every playback-changing action, plus `.airplayRoute`: a speaker action can
/// reach route healing, which pauses and then plays (`RouteHealer.swift:81-87`),
/// so it must not straddle a switch. A CLI-only classification: the TUI column
/// and `touchesPlayback` are unchanged.
func requiresOutputLock(_ action: MusicTUIAction) -> Bool {
    action.touchesPlayback || action == .airplayRoute
}

// MARK: - The Bridge session

/// One command's conversation with Bridge: the client the coordinator built,
/// a provider over it for library reads, and ONE warm-up budget shared by every
/// read and mutation the command makes.
final class CLIBridgeSession {
    let client: SourceAppClient
    let provider: BridgeMusicProvider
    let budget = WarmUpBudget()
    private let env: CLIBridgeEnv

    init(client: SourceAppClient, env: CLIBridgeEnv) {
        self.client = client
        self.provider = BridgeMusicProvider(control: client.control)
        self.env = env
    }

    /// One status read. An observation, never retried and never a reason to
    /// re-send anything (D5).
    func status() throws -> SourceStatus {
        try client.control.status()
    }

    /// One mutating request under the output lock (D6), revalidating the mode
    /// after acquiring.
    ///
    /// **Only a `warming` refusal is retried** (D5): Bridge answers it before
    /// touching the player, so nothing changed and the request is safe to
    /// repeat. The wait is outside the lock, spends this session's one budget,
    /// and each attempt re-acquires the lock and revalidates the mode. Any other
    /// outcome, success or failure, is final: a mutation is never re-sent.
    func mutate<T>(_ body: (SourceControlling) throws -> T) throws -> T {
        try retryingWhileWarming(budget: budget,
                                 onWarming: { [env] _ in env.err(cliBridgeWarmingProgress) },
                                 sleep: env.sleep) {
            try cliUnderOutputLock(expecting: env.routing.mode, env: env) {
                do {
                    return try body(client.control)
                } catch SourceAppError.warming(let why, let hint) {
                    throw MusicProviderError.warming(why, retryAfter: hint)
                }
            }
        }
    }
}

// MARK: - Dispatch

/// D1. Route `action` through the coordinator and run exactly one branch.
///
/// - `.musicApp` and `.unaffected`: the shipped body, verbatim. For a
///   `requiresOutputLock` action it runs inside the output lock with the mode
///   revalidated (section 5, deviation 1). Its errors pass through untouched.
/// - `.source`: readiness first; not ready prints D5's sentence and sends
///   nothing further. Then `bridge` with a fresh `CLIBridgeSession`. Bridge
///   errors are printed in their own words; an `ExitCode` the body threw after
///   printing passes through.
/// - `.refused`: prints exactly what `refuseInBridge` prints, exits 1.
func cliDispatch(_ action: MusicTUIAction, json: Bool, env: CLIBridgeEnv,
                 musicApp: () throws -> Void,
                 bridge: (CLIBridgeSession) throws -> Void) throws {
    do {
        try env.routing.perform(
            action,
            musicApp: {
                if requiresOutputLock(action) {
                    try cliUnderOutputLock(expecting: env.routing.mode, env: env) {
                        try CLIPassThrough.wrap(musicApp)
                    }
                } else {
                    try CLIPassThrough.wrap(musicApp)
                }
            },
            source: { client in
                let readiness = client.readiness()
                guard readiness == .ready else {
                    throw ActionError(message: cliBridgeNotReadySentence(readiness))
                }
                let session = CLIBridgeSession(client: client, env: env)
                do {
                    try bridge(session)
                } catch let exit as ExitCode {
                    throw CLIPassThrough(error: exit)
                }
            },
            unaffected: { try CLIPassThrough.wrap(musicApp) })
    } catch let passed as CLIPassThrough {
        throw passed.error
    } catch {
        env.out(cliFailureText(cliErrorMessage(error), json: json))
        throw ExitCode.failure
    }
}

/// D6 for verbs that gate with `refuseInBridge` instead of dispatching (S8's
/// speaker actions): `body` runs inside the output lock once the persisted
/// mode is confirmed to still be `expecting`. A lock or revalidation refusal is
/// printed (text, or JSON under `json`) and exits 1; `body`'s own errors pass
/// through untouched.
func withCLIOutputLock<T>(expecting mode: PlaybackMode, json: Bool = false, env: CLIBridgeEnv,
                          _ body: () throws -> T) throws -> T {
    do {
        return try cliUnderOutputLock(expecting: mode, env: env) { try CLIPassThrough.wrap(body) }
    } catch let passed as CLIPassThrough {
        throw passed.error
    } catch {
        env.out(cliFailureText(cliErrorMessage(error), json: json))
        throw ExitCode.failure
    }
}

// MARK: - private

/// Hold `routing.outputLock` for `body`, after checking the persisted mode is
/// still `expecting`. Lock failures become `ActionError`s in the CLI's words;
/// `body`'s errors are rethrown exactly as thrown. Fails closed when the
/// coordinator carries no lock, which production never builds.
private func cliUnderOutputLock<T>(expecting mode: PlaybackMode, env: CLIBridgeEnv,
                                   _ body: () throws -> T) throws -> T {
    guard let lock = env.routing.outputLock else {
        throw ActionError(message: "Internal error: this command has no output lock; nothing was changed.")
    }
    do {
        return try lock.withLock {
            let now = env.modeStore.mode()
            guard now == mode else {
                throw ActionError(message: OutputLock.cliModeChangedMessage(now: now))
            }
            do {
                return try body()
            } catch {
                throw CLIBodyError(error: error)
            }
        }
    } catch let fromBody as CLIBodyError {
        throw fromBody.error
    } catch let lockError as OutputLockError {
        throw ActionError(message: lockError.message(for: .cli))
    }
}

/// Carries a body's error through a layer that would otherwise reinterpret it.
private struct CLIBodyError: Error { let error: Error }

/// Carries an error that must reach the caller untouched and unprinted.
private struct CLIPassThrough: Error {
    let error: Error
    static func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw CLIPassThrough(error: error) }
    }
}

/// One failure, in the words of whatever produced it.
private func cliErrorMessage(_ error: Error) -> String {
    switch error {
    case let e as ActionError:        return e.message
    case let e as SourceAppError:     return e.message
    case let e as MusicProviderError: return e.errorDescription ?? String(describing: e)
    case let e as OutputLockError:    return e.message(for: .cli)
    default:                          return error.localizedDescription
    }
}

/// Exactly what `refuseInBridge` prints for `message` (CLIBridgeGate.swift),
/// so a dispatched refusal is byte-identical to a gated one.
private func cliFailureText(_ message: String, json: Bool) -> String {
    guard json else { return message }
    let body: [String: Any] = ["ok": false, "error": message]
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}
