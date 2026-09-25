// tools/music/Sources/Commands/CLIBridgeTransport.swift
//
// The Bridge branches of `music now` and the transport verbs (slice 3 score,
// S6; decision D5). Each runs inside `cliDispatch`'s `.source` branch, after
// readiness, with the command's one `CLIBridgeSession`.
//
// **Observation is not the mutation (D5).** Every mutating request goes through
// `session.mutate`, which holds the output lock, revalidates the mode and
// retries only a `warming` refusal of the request itself. The status read that
// follows a mutation is outside the lock and is never a reason to re-send: if
// it fails, the command still succeeds and says the status couldn't be read.
//
// Output goes through `env.out` / `env.err`; failures are thrown for
// `cliDispatch` to print in their own words. Nothing here names Music.app's
// or the catalogue's backends.
import ArgumentParser
import Foundation

// MARK: - now

/// `music now` with Bridge selected: one status read, rendered per D5.
func bridgeNowCommand(_ session: CLIBridgeSession, json: Bool, env: CLIBridgeEnv) throws {
    let status = try session.status()
    if json {
        env.out(OutputFormat(mode: .json).render(bridgeNowJSON(status)))
    } else {
        bridgeNowLines(status).forEach(env.out)
    }
}

// MARK: - pause

/// What a Bridge pause established, from the status read under the same lock.
enum BridgePauseOutcome: Equatable {
    case paused
    case nothingPlaying
    case stillPlaying

    /// The same verdict as `confirmBridgeNotPlaying` (Shell/SpeakersScene.swift):
    /// only a reported paused, stopped or idle status is evidence; anything
    /// else means Bridge may still be playing. Split three ways so the CLI can
    /// say which.
    init(playback: String) {
        switch playback {
        case "paused":          self = .paused
        case "stopped", "idle": self = .nothingPlaying
        default:                self = .stillPlaying
        }
    }
}

/// `music pause` with Bridge selected (D5): `confirmBridgeNotPlaying`'s
/// sequence under the lock. The pause is sent and its refusal is not a
/// verdict (an idle Bridge refuses `slice.pause`); the status read that
/// follows decides. A status that cannot be read fails in its own words and,
/// because it is not the mutation's own refusal, is never retried.
func bridgePauseCommand(_ session: CLIBridgeSession, env: CLIBridgeEnv) throws {
    let playback = try session.mutate { control -> String in
        try? control.pause()
        do {
            return try control.status().playback
        } catch let error as SourceAppError {
            // Not `warming` any more by the time `mutate` sees it: a warming
            // answer to the confirming read must not re-send the pause.
            throw ActionError(message: error.message)
        }
    }
    switch BridgePauseOutcome(playback: playback) {
    case .paused:
        env.out("Paused.")
    case .nothingPlaying:
        env.out("Nothing playing on Bridge.")
    case .stillPlaying:
        env.out("Bridge is still playing.")
        throw ExitCode.failure
    }
}

// MARK: - skip, back, stop

/// `music skip` / `music back` with Bridge selected: the step under the lock,
/// then the now text or JSON.
func bridgeStepCommand(_ session: CLIBridgeSession, json: Bool, env: CLIBridgeEnv,
                       step: (SourceControlling) throws -> Void) throws {
    try session.mutate { try step($0) }
    bridgeShowAfterMutation(session, json: json, env: env)
}

/// `music stop` with Bridge selected.
func bridgeStopCommand(_ session: CLIBridgeSession, env: CLIBridgeEnv) throws {
    try session.mutate { try $0.stop() }
    env.out("Stopped.")
}

// MARK: - seek

/// The shipped seek usage sentence (PlaybackCommands.swift, `Seek`).
let seekPositionUsage = "Position must be +N / -N, seconds, or m:ss (e.g. +30, 90, 1:30)."

/// `music seek` with Bridge selected. The position is parsed here, in this
/// branch (the Music.app body parses its own). Bridge reports no position, so
/// the reply names what was requested, never an observed position.
func bridgeSeekCommand(_ session: CLIBridgeSession, position: String, json: Bool,
                       env: CLIBridgeEnv) throws {
    guard let target = parseSeekTarget(position) else {
        throw ActionError(message: seekPositionUsage)
    }
    let requested: [String: Any]
    let text: String
    if let delta = target.delta {
        try session.mutate { try $0.seek(byOffset: Double(delta)) }
        requested = ["offset": delta]
        text = "Seeked \(delta >= 0 ? "+" : "")\(delta)s on Bridge."
    } else {
        let absolute = target.absolute ?? 0
        try session.mutate { try $0.seek(toSeconds: Double(absolute)) }
        requested = ["position": absolute]
        text = "Seeked to \(formatTime(absolute)) on Bridge."
    }
    if json {
        env.out(OutputFormat(mode: .json).render(["ok": true, "output": "bridge", "requested": requested]))
    } else {
        env.out(text)
    }
}

// MARK: - shared

/// D5's observation after an accepted mutation: `resultLines` then the now
/// text, or one JSON document (`resultJSON` merged over the now dict). If the
/// status read fails, the mutation still succeeded: text prints `resultLines`
/// and the failure goes to stderr; JSON carries `status_error`. Never throws,
/// never re-sends.
func bridgeShowAfterMutation(_ session: CLIBridgeSession, json: Bool, env: CLIBridgeEnv,
                             resultLines: [String] = [], resultJSON: [String: Any] = [:]) {
    do {
        let status = try session.status()
        if json {
            env.out(OutputFormat(mode: .json).render(bridgeNowJSON(status).merging(resultJSON) { _, r in r }))
        } else {
            (resultLines + bridgeNowLines(status)).forEach(env.out)
        }
    } catch {
        let message = cliErrorMessage(error)
        if json {
            var doc: [String: Any] = ["output": "bridge", "status_error": message]
            doc.merge(resultJSON) { _, r in r }
            env.out(OutputFormat(mode: .json).render(doc))
        } else {
            resultLines.forEach(env.out)
            env.err("Bridge accepted the request, but its status couldn't be read: \(message)")
        }
    }
}

/// The Bridge branch of a verb the matrix refuses from the CLI (shuffle,
/// repeat, radio play, playlist temp). Unreachable while the matrix refuses
/// it; if the route ever changed without a Bridge body, it refuses rather than
/// doing nothing.
func cliBridgeNotServed(_ action: MusicTUIAction) -> (CLIBridgeSession) throws -> Void {
    { _ in throw ActionError(message: cliBridgeNotServedReason(action)) }
}
