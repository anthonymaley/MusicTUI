import XCTest
@testable import music

/// S2: pure rendering for the CLI `now` and Bridge play results (D5). Every
/// input is a `SourceStatus` or explicit counts already in hand — no socket,
/// no dispatch, no command wiring. `bridgeNowLines`/`bridgeNowJSON` render
/// D5's `now`; `bridgePlayResultLines`/`bridgePlayResultJSON` render D5's
/// play-result first line and its JSON fields, which the command (S7) merges
/// with a separate `bridgeNowLines`/`bridgeNowJSON` call for "the now text".
final class CLIBridgeNowTests: XCTestCase {

    private let states = ["playing", "paused", "loading", "idle", "stopped"]

    private func status(playback: String = "playing", title: String? = "Teardrop",
                        artist: String? = "Massive Attack", phase: String? = nil,
                        requested: Int? = nil, present: Int? = nil, reason: String? = nil,
                        built: Int? = nil, index: Int? = nil) -> SourceStatus {
        SourceStatus(playback: playback, title: title, artist: artist, readiness: .ready,
                     queuePhase: phase, queueRequested: requested, queuePresent: present,
                     queueReason: reason, queueBuiltBeforeFailure: built, queueIndex: index)
    }

    // MARK: - Title line, every state

    func testTitleLineWhenTitlePresent() {
        for state in states {
            let s = status(playback: state)
            XCTAssertEqual(bridgeNowLines(s).first, "Teardrop \u{2014} Massive Attack [Bridge]", "state \(state)")
        }
    }

    func testTitleLineWithEmptyOrNilArtistDropsTheDash() {
        for state in states {
            XCTAssertEqual(bridgeNowLines(status(playback: state, artist: "")).first, "Teardrop [Bridge]")
        }
        XCTAssertEqual(bridgeNowLines(status(artist: nil)).first, "Teardrop [Bridge]")
    }

    func testEmptyTitleIsTreatedAsAbsent() {
        XCTAssertEqual(bridgeNowLines(status(playback: "idle", title: "", artist: nil)).first,
                       "Nothing playing on Bridge.")
    }

    // MARK: - The quiet case, and what must never read as it

    func testQuietCaseOnlyForIdleOrStoppedWithNoPhaseAndNoTitle() {
        for state in states {
            let first = bridgeNowLines(status(playback: state, title: nil, artist: nil)).first
            if state == "idle" || state == "stopped" {
                XCTAssertEqual(first, "Nothing playing on Bridge.", "state \(state)")
            } else {
                XCTAssertEqual(first, "Bridge is \(state).", "state \(state)")
            }
        }
    }

    func testLoadingNeverReadsAsNothingPlaying() {
        XCTAssertEqual(bridgeNowLines(status(playback: "loading", title: nil, artist: nil)).first,
                       "Bridge is loading.")
    }

    func testInvalidNeverReadsAsNothingPlayingEvenWhenIdleOrStopped() {
        for state in ["idle", "stopped"] {
            let s = status(playback: state, title: nil, artist: nil, phase: "invalid",
                          requested: 9, reason: "a song was removed", built: 7)
            let lines = bridgeNowLines(s)
            XCTAssertEqual(lines.first, "Bridge is \(state).", "state \(state)")
            XCTAssertTrue(lines.contains("Stopped: a song was removed. 7 of 9 built."))
        }
        // Without built_before_failure too.
        let s = status(playback: "idle", title: nil, artist: nil, phase: "invalid",
                       requested: 9, reason: "a song was removed", built: nil)
        let lines = bridgeNowLines(s)
        XCTAssertEqual(lines.first, "Bridge is idle.")
        XCTAssertTrue(lines.contains("Stopped: a song was removed."))
    }

    // MARK: - Status and position lines, independent of the title

    func testStatusAndPositionLinesAppendWhenTitlePresent() {
        let s = status(playback: "playing", phase: "building", requested: 12, present: 5, index: 3)
        XCTAssertEqual(bridgeNowLines(s), [
            "Teardrop \u{2014} Massive Attack [Bridge]",
            "Building queue: 5 of 12 ready.",
            "Song 4 of 12",
        ])
    }

    func testStatusAndPositionLinesAppendWithNoTitle() {
        let s = status(playback: "playing", title: nil, artist: nil, phase: "complete",
                      requested: 12, present: 12, index: 0)
        XCTAssertEqual(bridgeNowLines(s), ["Bridge is playing.", "Song 1 of 12"])
    }

    func testNoStatusOrPositionLineWhenNeitherApplies() {
        let s = status(playback: "playing", phase: "complete", requested: 10, index: nil)
        XCTAssertEqual(bridgeNowLines(s), ["Teardrop \u{2014} Massive Attack [Bridge]"])
    }

    // MARK: - JSON: output/state always present

    func testJSONAlwaysCarriesOutputAndState() {
        for state in states {
            let dict = bridgeNowJSON(status(playback: state, title: nil, artist: nil))
            XCTAssertEqual(dict["output"] as? String, "bridge")
            XCTAssertEqual(dict["state"] as? String, state)
        }
    }

    // MARK: - JSON: track/artist only when present

    func testJSONTrackAndArtistOnlyWhenNonEmpty() {
        var dict = bridgeNowJSON(status())
        XCTAssertEqual(dict["track"] as? String, "Teardrop")
        XCTAssertEqual(dict["artist"] as? String, "Massive Attack")

        dict = bridgeNowJSON(status(artist: ""))
        XCTAssertEqual(dict["track"] as? String, "Teardrop")
        XCTAssertNil(dict["artist"])

        dict = bridgeNowJSON(status(title: nil, artist: nil))
        XCTAssertNil(dict["track"])
        XCTAssertNil(dict["artist"])

        dict = bridgeNowJSON(status(title: ""))
        XCTAssertNil(dict["track"])
    }

    // MARK: - JSON: queue, independent of title, whenever a phase is reported

    func testQueueKeyAppearsWithNoTitleWheneverAPhaseIsReported() {
        let dict = bridgeNowJSON(status(title: nil, artist: nil, phase: "none", requested: 0))
        let queue = dict["queue"] as? [String: Any]
        XCTAssertNotNil(queue, "queue must not depend on title")
        XCTAssertEqual(queue?["phase"] as? String, "none")
    }

    func testNoQueueKeyWhenNoPhaseIsReported() {
        XCTAssertNil(bridgeNowJSON(status(phase: nil))["queue"])
    }

    func testQueueEachPhase() {
        var queue = bridgeNowJSON(status(phase: "building", requested: 12, present: 5))["queue"] as? [String: Any]
        XCTAssertEqual(queue?["phase"] as? String, "building")
        XCTAssertEqual(queue?["requested"] as? Int, 12)
        XCTAssertEqual(queue?["present"] as? Int, 5)
        XCTAssertNil(queue?["reason"])
        XCTAssertNil(queue?["built_before_failure"])

        queue = bridgeNowJSON(status(phase: "complete", requested: 12, present: 12, index: 2))["queue"] as? [String: Any]
        XCTAssertEqual(queue?["phase"] as? String, "complete")
        XCTAssertEqual(queue?["index"] as? Int, 2)

        queue = bridgeNowJSON(status(phase: "invalid", requested: 9, reason: "oops", built: 7))["queue"] as? [String: Any]
        XCTAssertEqual(queue?["phase"] as? String, "invalid")
        XCTAssertEqual(queue?["reason"] as? String, "oops")
        XCTAssertEqual(queue?["built_before_failure"] as? Int, 7)
        XCTAssertNil(queue?["present"], "invalid sends present as nil, not 0")

        queue = bridgeNowJSON(status(phase: "invalid", requested: 9, reason: "oops", built: nil))["queue"] as? [String: Any]
        XCTAssertNil(queue?["built_before_failure"])
    }

    func testNilFieldsAreAbsentNotZero() {
        let queue = bridgeNowJSON(status(phase: "building", requested: 12, present: nil))["queue"] as? [String: Any]
        XCTAssertNil(queue?["present"])
        XCTAssertNil(queue?["index"])
    }

    // MARK: - JSON: forbidden keys

    func testForbiddenKeysNeverAppear() {
        let dict = bridgeNowJSON(status(phase: "complete", requested: 12, present: 12, index: 0))
        for key in ["album", "duration", "position", "speakers", "live"] {
            XCTAssertNil(dict[key], "\(key) must never appear in Bridge now JSON")
        }
    }

    // MARK: - Sweep: every state x title presence x artist emptiness x phase

    func testMatrixInvariantsHoldAcrossEveryCombination() {
        let phases: [String?] = [nil, "none", "building", "complete", "invalid"]
        for state in states {
            for titlePresent in [true, false] {
                for artistEmpty in [true, false] {
                    for phase in phases {
                        let requested: Int? = phase == nil ? nil : 10
                        let present: Int?
                        switch phase {
                        case "building": present = 4
                        case "complete": present = 10
                        default: present = nil
                        }
                        let reason: String? = phase == "invalid" ? "r" : nil
                        let builtOptions: [Int?] = phase == "invalid" ? [nil, 3] : [nil]
                        for built in builtOptions {
                            let s = status(playback: state,
                                          title: titlePresent ? "T" : nil,
                                          artist: artistEmpty ? "" : "A",
                                          phase: phase, requested: requested, present: present,
                                          reason: reason, built: built)
                            let dict = bridgeNowJSON(s)
                            let tag = "state=\(state) phase=\(String(describing: phase)) title=\(titlePresent) artistEmpty=\(artistEmpty) built=\(String(describing: built))"

                            XCTAssertEqual(dict["output"] as? String, "bridge", tag)
                            XCTAssertEqual(dict["state"] as? String, state, tag)
                            for key in ["album", "duration", "position", "speakers", "live"] {
                                XCTAssertNil(dict[key], "\(key): \(tag)")
                            }
                            if phase == nil {
                                XCTAssertNil(dict["queue"], "no phase must mean no queue key: \(tag)")
                            } else {
                                XCTAssertNotNil(dict["queue"], "a reported phase must always produce a queue key: \(tag)")
                            }
                            XCTAssertEqual(dict["track"] as? String, titlePresent ? "T" : nil, tag)
                            XCTAssertEqual(dict["artist"] as? String, artistEmpty ? nil : "A", tag)

                            let lines = bridgeNowLines(s)
                            XCTAssertFalse(lines.isEmpty, tag)
                            let isQuiet = !titlePresent && (phase == nil || phase == "none")
                                && (state == "idle" || state == "stopped")
                            if isQuiet {
                                XCTAssertEqual(lines.first, "Nothing playing on Bridge.", tag)
                            } else {
                                XCTAssertNotEqual(lines.first, "Nothing playing on Bridge.", tag)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Play results: playlist

    func testPlaylistPlayResultLine() {
        let lines = bridgePlayResultLines(kind: .playlist, label: "Top 25 Most Played", sent: 40,
                                          skippedUnavailable: 1, skippedVideos: 2, shuffle: false)
        XCTAssertEqual(lines, [
            "Playing 39 of 42 from 'Top 25 Most Played' on Bridge: 2 videos skipped. 1 song isn't available to Bridge.",
        ])
    }

    func testPlaylistPlayResultJSON() {
        let dict = bridgePlayResultJSON(kind: .playlist, sent: 40, skippedUnavailable: 1, skippedVideos: 2)
        XCTAssertEqual(dict["sent"] as? Int, 40)
        XCTAssertEqual(dict["queued"] as? Int, 39)
        XCTAssertEqual(dict["skipped_unavailable"] as? Int, 1)
        XCTAssertEqual(dict["skipped_videos"] as? Int, 2)
        XCTAssertEqual(dict["playlist_members"] as? Int, 42)
    }

    func testPlaylistWithNoSkipsUsesTheWholeCollectionForm() {
        let lines = bridgePlayResultLines(kind: .playlist, label: "Top 25 Most Played", sent: 25,
                                          skippedUnavailable: 0, skippedVideos: 0, shuffle: false)
        XCTAssertEqual(lines, ["Playing 'Top 25 Most Played' on Bridge \u{2014} 25 tracks."])
    }

    // MARK: - Play results: album / artist

    func testAlbumAndArtistPlayResultLine() {
        for kind in [BridgePlayResultKind.album, .artist] {
            let lines = bridgePlayResultLines(kind: kind, label: "OK Computer", sent: 12,
                                              skippedUnavailable: 0, skippedVideos: 0, shuffle: false)
            XCTAssertEqual(lines, ["Playing 'OK Computer' on Bridge \u{2014} 12 tracks."])
        }
    }

    func testAlbumPlayResultWithUnavailableNotice() {
        let lines = bridgePlayResultLines(kind: .album, label: "OK Computer", sent: 12,
                                          skippedUnavailable: 2, skippedVideos: 0, shuffle: false)
        XCTAssertEqual(lines, ["Playing 'OK Computer' on Bridge \u{2014} 10 tracks. 2 songs aren't available to Bridge."])
    }

    func testAlbumArtistJSONHasNoPlaylistOnlyKeys() {
        let dict = bridgePlayResultJSON(kind: .album, sent: 12, skippedUnavailable: 2, skippedVideos: 0)
        XCTAssertEqual(dict["sent"] as? Int, 12)
        XCTAssertEqual(dict["queued"] as? Int, 10)
        XCTAssertEqual(dict["skipped_unavailable"] as? Int, 2)
        XCTAssertNil(dict["skipped_videos"])
        XCTAssertNil(dict["playlist_members"])
    }

    // MARK: - Play results: song

    func testSongPlayResultLine() {
        let lines = bridgePlayResultLines(kind: .song, label: "Teardrop", sent: 1,
                                          skippedUnavailable: 0, skippedVideos: 0, shuffle: false)
        XCTAssertEqual(lines, ["Playing 'Teardrop' on Bridge."])
    }

    func testSongPlayResultJSON() {
        let dict = bridgePlayResultJSON(kind: .song, sent: 1, skippedUnavailable: 0, skippedVideos: 0)
        XCTAssertEqual(dict["sent"] as? Int, 1)
        XCTAssertEqual(dict["queued"] as? Int, 1)
        XCTAssertEqual(dict["skipped_unavailable"] as? Int, 0)
        XCTAssertNil(dict["skipped_videos"])
        XCTAssertNil(dict["playlist_members"])
    }

    // MARK: - Play results: resume (D5 "resume none")

    func testResumeHasNoResultLineOrJSON() {
        XCTAssertEqual(bridgePlayResultLines(kind: .resume, label: "", sent: 0,
                                             skippedUnavailable: 0, skippedVideos: 0, shuffle: false), [])
        XCTAssertTrue(bridgePlayResultJSON(kind: .resume, sent: 0, skippedUnavailable: 0, skippedVideos: 0).isEmpty)
    }
}
