// tools/music/Sources/TUI/MacRouteDecoderFeed.swift
import Foundation

// What Music's decoder actually opened (finding 6, live check 2026-11-18).
//
// A streamed song can START on the lossy HLS variant and upgrade to lossless a few
// seconds in: Music's own log has `[AudioFormat qaac ...] [Rendition Stereo]
// [SampleRate 48000]` when the song starts and `[AudioFormat qlac ...] [Rendition
// Lossless] [SampleRate 96000] [BitDepth 24]` about seven seconds later, while
// AppleScript's `sample rate of current track` stays 48000 for the whole song. The
// DAC was left at the 48 kHz the start confirmed and the 96 kHz stream played
// converted down.
//
// The report is one line of the unified log (process Music, subsystem
// com.apple.coremedia, category player, `fpfs_ReportAudioPlaybackThroughFigLog`),
// readable without privileges through `/usr/bin/log stream`. It names the decoder
// item, not the song, but the route hands Music ONE song at a time, so a report
// stamped after the current song's start is that song's stream.
//
// Everything here is a seam: `DecoderRateFeed` is what the player subscribes to, the
// parser is a pure function of one line, and only `LogStreamDecoderFeed` spawns a
// process (never in a test).

/// One decoder report: the sample rate Music opened, and when it said so.
struct DecoderReport: Equatable {
    let sampleRateHz: Int
    /// The log's own stamp; the receipt time when the line carries none.
    let at: Date
    /// `qaac` (lossy AAC), `qlac` (ALAC); informational.
    let format: String?
    /// `Stereo`, `Lossless`; informational.
    let rendition: String?
}

protocol DecoderRateFeed: AnyObject {
    /// Starts reporting to `onReport` (any thread). Idempotent.
    func start(onReport: @escaping (DecoderReport) -> Void)
    /// Stops, and ends whatever process feeds it. Idempotent.
    func stop()
}

enum DecoderReportParser {
    /// The log message that carries the report.
    static let marker = "fpfs_ReportAudioPlaybackThroughFigLog"

    /// The predicate `/usr/bin/log stream` is given: Music's own report lines only.
    static let predicate = "process == \"Music\" AND eventMessage CONTAINS \"\(marker)\""

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()
    private static let stampLock = NSLock()

    /// `log stream --style ndjson`: one JSON object per line, its `eventMessage` the
    /// log line and its `timestamp` `2026-11-18 15:04:20.590096-0500`. nil for any
    /// other line (the stream's own banner included) and for a report with no
    /// positive `[SampleRate n]`.
    static func parse(ndjson line: String, receivedAt: Date = Date()) -> DecoderReport? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["eventMessage"] as? String, message.contains(marker),
              let hz = field("SampleRate", in: message).flatMap(Int.init), hz > 0 else { return nil }
        var at = receivedAt
        if let text = object["timestamp"] as? String {
            stampLock.lock(); defer { stampLock.unlock() }
            at = stamp.date(from: text) ?? receivedAt
        }
        return DecoderReport(sampleRateHz: hz, at: at, format: format(in: message),
                             rendition: field("Rendition", in: message))
    }

    /// The text of `[Name value]`, up to the closing bracket.
    private static func field(_ name: String, in message: String) -> String? {
        guard let start = message.range(of: "[\(name) ") else { return nil }
        let rest = message[start.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// `[AudioFormat qlac is  decodable]`: the four-character code.
    private static func format(in message: String) -> String? {
        field("AudioFormat", in: message)?.split(separator: " ").first.map(String.init)
    }
}

/// The real feed: one `/usr/bin/log stream` child (never bare `log`, which is the zsh
/// builtin), its stdout read line by line on a background thread. Never started in a
/// test. The child ends with `stop()`; if this process is killed instead, the child
/// ends at its next write to the closed pipe.
final class LogStreamDecoderFeed: DecoderRateFeed {
    private let lock = NSLock()
    private var process: Process?

    func start(onReport: @escaping (DecoderReport) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard process == nil else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        child.arguments = ["stream", "--predicate", DecoderReportParser.predicate, "--style", "ndjson"]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        do { try child.run() } catch {
            verbose("decoder feed not started: \(error.localizedDescription)")
            return
        }
        process = child
        let reader = pipe.fileHandleForReading
        let thread = Thread {
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }          // the child ended
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let report = DecoderReportParser.parse(ndjson: line) { onReport(report) }
                }
            }
        }
        thread.name = "music.decoder-feed"
        thread.start()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let child = process else { return }
        process = nil
        if child.isRunning { child.terminate() }
    }
}
