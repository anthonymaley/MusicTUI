// tools/music/Tests/MusicTests/MacRouteDecoderFeedTests.swift
//
// The parser of Music's decoder report (finding 6). The lines are the real ones from
// the 2026-11-18 live check (`/usr/bin/log show ... --style ndjson`), trimmed to the
// fields used. Nothing here starts a process.
import XCTest
@testable import music

final class MacRouteDecoderFeedTests: XCTestCase {

    private func ndjson(_ message: String, timestamp: String? = "2026-11-18 15:04:20.590096-0500") -> String {
        var object: [String: Any] = ["eventMessage": message, "subsystem": "com.apple.coremedia", "category": "player",
                                     "processImagePath": "/System/Applications/Music.app/Contents/MacOS/Music"]
        if let timestamp { object["timestamp"] = timestamp }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private let lossy = "<<<< FigStreamPlayer >>>> fpfs_ReportAudioPlaybackThroughFigLog: [QE Critical][0x76906ac000|P/SW]: <0x7692f48000|I/XWM.01>: [AudioFormat qaac is  decodable] [AudioChannels 2] [Spatialization Eligible yes] [Client permits multi: no, stereo: no] [Spatialization no] [StereoSpatialization no] [Rendition Stereo] [SampleRate 48000] [BitDepth 0] [Immersive rendering no]"
    private let lossless = "<<<< FigStreamPlayer >>>> fpfs_ReportAudioPlaybackThroughFigLog: [QE Critical][0x76906ac000|P/SW]: <0x7693075c00|I/DAK.01>: [AudioFormat qlac is  decodable] [AudioChannels 2] [Spatialization Eligible yes] [Client permits multi: no, stereo: no] [Spatialization no] [StereoSpatialization no] [Rendition Lossless] [SampleRate 96000] [BitDepth 24] [Immersive rendering no]"

    func testTheLossyStartReportReadsItsRate() throws {
        let report = try XCTUnwrap(DecoderReportParser.parse(ndjson: ndjson(lossy)))
        XCTAssertEqual(report.sampleRateHz, 48000)
        XCTAssertEqual(report.format, "qaac")
        XCTAssertEqual(report.rendition, "Stereo")
    }

    func testTheLosslessUpgradeReportReadsItsRateAndTheLogsOwnStamp() throws {
        let report = try XCTUnwrap(DecoderReportParser.parse(ndjson: ndjson(lossless, timestamp: "2026-11-18 15:04:31.645000-0500")))
        XCTAssertEqual(report.sampleRateHz, 96000)
        XCTAssertEqual(report.format, "qlac")
        XCTAssertEqual(report.rendition, "Lossless")
        // 15:04:31.645 -0500 on 2026-11-18 is 20:04:31.645 UTC.
        XCTAssertEqual(report.at.timeIntervalSince1970, 1_795_032_271.645, accuracy: 0.01)
    }

    func testALineWithNoStampTakesTheReceiptTime() throws {
        let received = Date(timeIntervalSince1970: 1_800_000_000)
        let report = try XCTUnwrap(DecoderReportParser.parse(ndjson: ndjson(lossless, timestamp: nil), receivedAt: received))
        XCTAssertEqual(report.at, received)
    }

    func testAnythingThatIsNotADecoderReportWithARateIsIgnored() {
        XCTAssertNil(DecoderReportParser.parse(ndjson: ""))
        XCTAssertNil(DecoderReportParser.parse(ndjson: "Filtering the log data using ..."), "the stream's own banner")
        XCTAssertNil(DecoderReportParser.parse(ndjson: "{\"eventMessage\": 3}"))
        XCTAssertNil(DecoderReportParser.parse(ndjson: ndjson("some other Music line [SampleRate 44100]")), "not the decoder report")
        XCTAssertNil(DecoderReportParser.parse(ndjson: ndjson(lossless.replacingOccurrences(of: "[SampleRate 96000]", with: "[SampleRate 0]"))))
        XCTAssertNil(DecoderReportParser.parse(ndjson: ndjson(lossless.replacingOccurrences(of: "[SampleRate 96000]", with: ""))))
    }
}
