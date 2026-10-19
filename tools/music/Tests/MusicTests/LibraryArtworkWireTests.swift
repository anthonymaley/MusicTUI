// tools/music/Tests/MusicTests/LibraryArtworkWireTests.swift
import CryptoKit
import XCTest
@testable import music

/// `slice.libraryArtwork` on the wire: the two request shapes, the transport they
/// ride, both reply shapes, the refusal kinds, the pure chunk assembly, the
/// readiness read, and the `library_instance` the album and playlist pages gain.
/// Canned transport strings only: no socket, no cache, no MusicKit.
final class LibraryArtworkWireTests: XCTestCase {

    private static let instance = "6F1C2A44-0B1E-4C1D-9A55-2D3B6B8E1F00"
    private static let transfer = "0123456789abcdef0123456789abcdef"

    /// 40,000 bytes: chunk 0 is a full 32,768, chunk 1 the remaining 7,232.
    private static let payload = Data((0..<40_000).map { UInt8($0 % 251) })

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func slice(_ index: Int) -> Data {
        let from = min(index * libraryArtworkChunkBytes, Self.payload.count)
        return Self.payload.subdata(in: from..<min(from + libraryArtworkChunkBytes, Self.payload.count))
    }

    private var request: LibraryArtworkRequest {
        LibraryArtworkRequest(kind: .album, id: "1945713005063419934", generation: 7,
                              libraryInstance: Self.instance, px: 512)
    }

    /// One reply line in the contract's shape. Chunk 0 carries the manifest; `next`
    /// is the cursor text, or nil for the explicit null.
    private func line(chunk: Int, of chunks: Int = 2, data: String? = nil, next: String?? = nil,
                      transfer: String = LibraryArtworkWireTests.transfer, generation: Int = 7,
                      instance: String = LibraryArtworkWireTests.instance, kind: String = "album",
                      id: String = "1945713005063419934", v: Int = 1, source: String = "rendered",
                      bytes: Int = LibraryArtworkWireTests.payload.count, px: Int = 512,
                      mediaType: String = "image/jpeg", digest: String? = nil) -> String {
        let cursor: String
        switch next {
        case .none:       cursor = chunk == chunks - 1 ? "null" : #""c\#(chunk + 1)""#
        case .some(.none): cursor = "null"
        case .some(.some(let text)): cursor = #""\#(text)""#
        }
        let manifest = chunk == 0
            ? #""media_type":"\#(mediaType)","px":\#(px),"bytes":\#(bytes),"sha256":"\#(digest ?? sha(Self.payload))","#
            : ""
        let payload = data ?? slice(chunk).base64EncodedString()
        return #"{"ok":true,"op":"slice.libraryArtwork","generation":\#(generation),"library_instance":"\#(instance)","artwork":{"v":\#(v),"source":"\#(source)","kind":"\#(kind)","id":"\#(id)",\#(manifest)"transfer":"\#(transfer)","chunk":\#(chunk),"chunks":\#(chunks),"data":"\#(payload)","next_cursor":\#(cursor)}}"#
    }

    private func refusal(_ kind: String, detail: String = "words", extra: String = "") -> String {
        #"{"ok":false,"op":"slice.libraryArtwork","error":{"kind":"\#(kind)","detail":"\#(detail)"\#(extra)}}"#
    }

    private final class Wire {
        var ordinary: [String] = []
        var library: [String] = []
        let reply: String
        init(_ reply: String) { self.reply = reply }
    }

    private func control(_ wire: Wire) -> SourceAppControl {
        SourceAppControl(path: "/nonexistent",
                         transport: { _, line in wire.ordinary.append(line); return wire.reply },
                         libraryTransport: { _, line in wire.library.append(line); return wire.reply })
    }

    private func sentObject(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func chunk(_ reply: String, file: StaticString = #filePath, line: UInt = #line) throws -> LibraryArtworkChunk {
        let wire = Wire(reply)
        guard case .chunk(let decoded) = try control(wire).libraryArtworkChunk(cursor: "c") else {
            XCTFail("not a chunk", file: file, line: line)
            throw SourceAppError.unreadable
        }
        return decoded
    }

    /// The accepted first chunk plus the second, from the goldens.
    private func goodPair() throws -> (LibraryArtworkChunk, LibraryArtworkChunk) {
        (try chunk(self.line(chunk: 0)), try chunk(self.line(chunk: 1)))
    }

    // MARK: the requests

    func testTheFirstRequestSendsExactlyTheFiveFields() throws {
        let wire = Wire(line(chunk: 0))
        _ = try control(wire).libraryArtwork(kind: .album, id: "1945713005063419934", generation: 7,
                                             libraryInstance: Self.instance, px: 512)
        XCTAssertEqual(wire.library.count, 1)
        let sent = try sentObject(wire.library[0])
        XCTAssertEqual(Set(sent.keys), ["op", "kind", "id", "generation", "library_instance", "px"])
        XCTAssertEqual(sent["op"] as? String, "slice.libraryArtwork")
        XCTAssertEqual(sent["kind"] as? String, "album")
        XCTAssertEqual(sent["id"] as? String, "1945713005063419934")
        XCTAssertEqual(sent["generation"] as? Int, 7)
        XCTAssertEqual(sent["library_instance"] as? String, Self.instance)
        XCTAssertEqual(sent["px"] as? Int, 512)

        let playlist = Wire(line(chunk: 0, kind: "playlist"))
        _ = try control(playlist).libraryArtwork(kind: .playlist, id: "p1", generation: 7,
                                                 libraryInstance: Self.instance, px: 512)
        XCTAssertEqual(try sentObject(playlist.library[0])["kind"] as? String, "playlist")
        XCTAssertEqual(try sentObject(playlist.library[0])["px"] as? Int, 512)
    }

    func testACursorRequestSendsOnlyTheCursor() throws {
        let wire = Wire(line(chunk: 1))
        _ = try control(wire).libraryArtworkChunk(cursor: "opaque-cursor")
        XCTAssertEqual(wire.library.count, 1)
        let sent = try sentObject(wire.library[0])
        XCTAssertEqual(Set(sent.keys), ["op", "cursor"])
        XCTAssertEqual(sent["op"] as? String, "slice.libraryArtwork")
        XCTAssertEqual(sent["cursor"] as? String, "opaque-cursor")
    }

    func testBothArtworkRequestsGoOverTheLibraryTransport() throws {
        var ordinaryCalls = 0
        var libraryLines: [String] = []
        let control = SourceAppControl(
            path: "/nonexistent",
            transport: { _, _ in ordinaryCalls += 1; XCTFail("a cover request used the ordinary transport"); return "{}" },
            libraryTransport: { _, line in libraryLines.append(line); return self.line(chunk: 0) })
        _ = try control.libraryArtwork(kind: .album, id: "1", generation: 7, libraryInstance: Self.instance, px: 512)
        _ = try control.libraryArtworkChunk(cursor: "c1")
        XCTAssertEqual(libraryLines.count, 2)
        XCTAssertEqual(ordinaryCalls, 0)
        XCTAssertEqual(SourceAppControl.libraryReadTimeoutSeconds, 30, "the contract's 18 s margin assumes the 30 s transport")
    }

    // MARK: the replies

    func testChunkZeroAndALaterChunkDecode() throws {
        let zero = try chunk(line(chunk: 0))
        XCTAssertEqual(zero.generation, 7)
        XCTAssertEqual(zero.libraryInstance, Self.instance)
        XCTAssertEqual(zero.kind, .album)
        XCTAssertEqual(zero.id, "1945713005063419934")
        XCTAssertEqual(zero.transfer, Self.transfer)
        XCTAssertEqual(zero.chunk, 0)
        XCTAssertEqual(zero.chunks, 2)
        XCTAssertEqual(zero.nextCursor, "c1")
        XCTAssertEqual(zero.dataBase64, slice(0).base64EncodedString())
        XCTAssertEqual(zero.manifest, LibraryArtworkManifest(mediaType: "image/jpeg", px: 512,
                                                             bytes: 40_000, sha256: sha(Self.payload)))

        let one = try chunk(line(chunk: 1))
        XCTAssertEqual(one.chunk, 1)
        XCTAssertNil(one.nextCursor, "an explicit null ends the transfer")
        XCTAssertNil(one.manifest, "only chunk 0 carries the manifest")
        XCTAssertEqual(one.transfer, zero.transfer)
    }

    func testEachRefusalKindDecodesOnTheKind() throws {
        // Nonsense details on purpose: nothing may be decided by reading one.
        let cases: [(String, String, LibraryArtworkRefusal)] = [
            ("stale_generation", "", .staleGeneration),
            ("transfer_expired", "the moon", .transferExpired),
            ("not_in_library", "42", .notInLibrary),
            ("no_artwork", "SpanDAC has a cover for that album.", .noArtwork),
            ("render_timeout", "x", .renderTimeout(retryAfter: nil)),
            ("render_failed", "x", .renderFailed),
            ("busy", "x", .busy),
            (spanDACLicenceRefusalKind, "x", .unlicensed),
            ("unauthorized", "x", .unauthorized),
            ("unknown_op", "x", .unsupported),
            ("bad_request", "x", .other("bad_request")),
            ("some_future_kind", "x", .other("some_future_kind")),
        ]
        for (kind, detail, expected) in cases {
            let wire = Wire(refusal(kind, detail: detail))
            XCTAssertEqual(try control(wire).libraryArtwork(kind: .album, id: "1", generation: 7,
                                                            libraryInstance: Self.instance, px: 512),
                           .refused(expected), kind)
            XCTAssertEqual(try control(Wire(refusal(kind, detail: detail))).libraryArtworkChunk(cursor: "c"),
                           .refused(expected), "\(kind) on a cursor request")
        }
        let warming = Wire(refusal("warming", extra: #","retry_after":2.5"#))
        XCTAssertEqual(try control(warming).libraryArtworkChunk(cursor: "c"), .refused(.warming(retryAfter: 2.5)))
        let hintless = Wire(refusal("warming"))
        XCTAssertEqual(try control(hintless).libraryArtworkChunk(cursor: "c"), .refused(.warming(retryAfter: 1.0)))
    }

    func testARenderTimeoutRetainsItsRetryHintAsReceived() throws {
        func decoded(_ extra: String, chunkRequest: Bool = false) throws -> LibraryArtworkReply {
            let wire = Wire(refusal("render_timeout", extra: extra))
            return chunkRequest ? try control(wire).libraryArtworkChunk(cursor: "c")
                : try control(wire).libraryArtwork(kind: .album, id: "1", generation: 7,
                                                   libraryInstance: Self.instance, px: 512)
        }
        XCTAssertEqual(try decoded(#","retry_after":30"#), .refused(.renderTimeout(retryAfter: 30)))
        XCTAssertEqual(try decoded(#","retry_after":12.5"#), .refused(.renderTimeout(retryAfter: 12.5)))
        XCTAssertEqual(try decoded(#","retry_after":600"#, chunkRequest: true),
                       .refused(.renderTimeout(retryAfter: 600)))
        // Absent (an older SpanDAC), null, or not a number: no hint. Never an error.
        XCTAssertEqual(try decoded(""), .refused(.renderTimeout(retryAfter: nil)))
        XCTAssertEqual(try decoded(#","retry_after":null"#), .refused(.renderTimeout(retryAfter: nil)))
        XCTAssertEqual(try decoded(#","retry_after":"soon""#), .refused(.renderTimeout(retryAfter: nil)))
        XCTAssertEqual(try decoded(#","retry_after":[30]"#), .refused(.renderTimeout(retryAfter: nil)))
        // A JSON boolean is not a number of seconds (it would convert to 1.0 and 0.0).
        XCTAssertEqual(try decoded(#","retry_after":true"#), .refused(.renderTimeout(retryAfter: nil)))
        XCTAssertEqual(try decoded(#","retry_after":false"#), .refused(.renderTimeout(retryAfter: nil)))
        XCTAssertEqual(try decoded(#","retry_after":true"#, chunkRequest: true),
                       .refused(.renderTimeout(retryAfter: nil)))
        // Out-of-range values are kept as sent; the fetcher is where they are judged.
        XCTAssertEqual(try decoded(#","retry_after":-4"#), .refused(.renderTimeout(retryAfter: -4)))
    }

    func testATransportFailureIsRethrownNotRefused() {
        let control = SourceAppControl(path: "/nonexistent", transport: { _, _ in "{}" },
                                       libraryTransport: { _, _ in throw SourceAppError.timedOut })
        XCTAssertThrowsError(try control.libraryArtworkChunk(cursor: "c")) {
            XCTAssertEqual($0 as? SourceAppError, .timedOut)
        }
    }

    // MARK: assembly

    func testAssemblyAcceptsInOrderChunksWithAMatchingDigest() throws {
        let (zero, one) = try goodPair()
        var assembly = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        XCTAssertFalse(assembly.isComplete)
        XCTAssertNil(assembly.finish(), "not all chunks have arrived")
        XCTAssertEqual(assembly.nextCursor, "c1")
        XCTAssertTrue(assembly.add(one))
        XCTAssertTrue(assembly.isComplete)
        XCTAssertNil(assembly.nextCursor)
        XCTAssertEqual(assembly.finish(), Self.payload)
    }

    func testAssemblyAcceptsASingleChunkCover() throws {
        let small = Data(Self.payload.prefix(1_000))
        let only = try chunk(line(chunk: 0, of: 1, data: small.base64EncodedString(),
                                  bytes: small.count, digest: sha(small)))
        let assembly = try XCTUnwrap(LibraryArtworkAssembly(first: only, request: request))
        XCTAssertEqual(assembly.finish(), small)
    }

    func testAssemblyRejectsOutOfOrder() throws {
        let (zero, one) = try goodPair()
        var skipped = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        XCTAssertFalse(skipped.add(try chunk(line(chunk: 2, of: 2))))
        XCTAssertNil(skipped.finish())

        var repeated = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        XCTAssertFalse(repeated.add(zero))
        XCTAssertFalse(repeated.add(one), "a spent assembly takes nothing more")
        XCTAssertNil(repeated.finish())

        XCTAssertNil(LibraryArtworkAssembly(first: one, request: request), "a transfer starts at chunk 0")
    }

    func testAssemblyRejectsAnotherTransfer() throws {
        let (zero, _) = try goodPair()
        var assembly = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        let other = try chunk(line(chunk: 1, transfer: "ffffffffffffffffffffffffffffffff"))
        XCTAssertFalse(assembly.add(other))
        XCTAssertNil(assembly.finish())
    }

    func testAssemblyRejectsWrongLength() throws {
        let (zero, _) = try goodPair()
        var short = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        XCTAssertTrue(short.add(try chunk(line(chunk: 1, data: slice(1).prefix(7_000).base64EncodedString()))))
        XCTAssertTrue(short.isComplete)
        XCTAssertNil(short.finish(), "the bytes are not the manifest's length")

        var long = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        let padded = (slice(1) + Data(repeating: 0, count: 100)).base64EncodedString()
        XCTAssertFalse(long.add(try chunk(line(chunk: 1, data: padded))), "more bytes than the manifest promised")

        let oversized = Data(repeating: 1, count: libraryArtworkChunkBytes + 1)
        let big = try chunk(line(chunk: 0, of: 2, data: oversized.base64EncodedString()))
        XCTAssertNil(LibraryArtworkAssembly(first: big, request: request), "a chunk over 32,768 raw bytes")
    }

    func testAssemblyRejectsDigestMismatch() throws {
        let wrong = String(repeating: "0", count: 64)
        let zero = try chunk(line(chunk: 0, digest: wrong))
        var assembly = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        XCTAssertTrue(assembly.add(try chunk(line(chunk: 1))))
        XCTAssertNil(assembly.finish())

        let upper = try chunk(line(chunk: 0, digest: sha(Self.payload).uppercased()))
        var shouting = try XCTUnwrap(LibraryArtworkAssembly(first: upper, request: request))
        XCTAssertTrue(shouting.add(try chunk(line(chunk: 1))))
        XCTAssertNil(shouting.finish(), "the contract's digest is lowercase hex")
    }

    func testAssemblyRejectsTooManyChunks() throws {
        // 13 chunks of a 425,984-byte cover: over the byte maximum and the chunk maximum.
        let tooMany = try chunk(line(chunk: 0, of: 13, bytes: 13 * libraryArtworkChunkBytes))
        XCTAssertNil(LibraryArtworkAssembly(first: tooMany, request: request))
        // A chunk count that is not ceil(bytes / 32768).
        let miscounted = try chunk(line(chunk: 0, of: 3))
        XCTAssertNil(LibraryArtworkAssembly(first: miscounted, request: request))
        // The largest cover the contract allows is accepted: 12 full chunks.
        let largest = try chunk(line(chunk: 0, of: 12, bytes: libraryArtworkMaximumBytes))
        XCTAssertNotNil(LibraryArtworkAssembly(first: largest, request: request))
        // One byte over it is not.
        let over = try chunk(line(chunk: 0, of: 13, bytes: libraryArtworkMaximumBytes + 1))
        XCTAssertNil(LibraryArtworkAssembly(first: over, request: request))
    }

    func testAssemblyRejectsAMissingFinalNullCursor() throws {
        let (zero, _) = try goodPair()
        var endless = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        XCTAssertTrue(endless.add(try chunk(line(chunk: 1, next: .some("c2")))))
        XCTAssertNil(endless.finish(), "the last chunk points on")

        let nullEarly = try chunk(line(chunk: 0, next: .some(nil)))
        var truncated = try XCTUnwrap(LibraryArtworkAssembly(first: nullEarly, request: request))
        XCTAssertTrue(truncated.add(try chunk(line(chunk: 1))))
        XCTAssertNil(truncated.finish(), "an earlier chunk pointed nowhere")
    }

    func testAssemblyRejectsBadBase64() throws {
        for bad in ["not base64!", "AAAA=", "QUJD\\nREVG", "AA"] {
            let zero = try chunk(line(chunk: 0, data: bad))
            XCTAssertNil(LibraryArtworkAssembly(first: zero, request: request), "first chunk: \(bad)")
        }
        let (good, _) = try goodPair()
        var assembly = try XCTUnwrap(LibraryArtworkAssembly(first: good, request: request))
        XCTAssertFalse(assembly.add(try chunk(line(chunk: 1, data: "@@@@"))))
        XCTAssertNil(assembly.finish())
    }

    func testAssemblyRejectsAnotherGenerationOrInstance() throws {
        let otherInstance = "AAAAAAAA-0B1E-4C1D-9A55-2D3B6B8E1F00"
        XCTAssertNil(LibraryArtworkAssembly(first: try chunk(line(chunk: 0, generation: 8)), request: request))
        XCTAssertNil(LibraryArtworkAssembly(first: try chunk(line(chunk: 0, instance: otherInstance)), request: request))
        XCTAssertNil(LibraryArtworkAssembly(first: try chunk(line(chunk: 0, kind: "playlist")), request: request))
        XCTAssertNil(LibraryArtworkAssembly(first: try chunk(line(chunk: 0, id: "another")), request: request))
        XCTAssertNil(LibraryArtworkAssembly(first: try chunk(line(chunk: 0, px: 300)), request: request))
        XCTAssertNil(LibraryArtworkAssembly(first: try chunk(line(chunk: 0, mediaType: "image/png")), request: request))

        let (zero, _) = try goodPair()
        var drifted = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        XCTAssertFalse(drifted.add(try chunk(line(chunk: 1, generation: 8))))
        var moved = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        XCTAssertFalse(moved.add(try chunk(line(chunk: 1, instance: otherInstance))))
        var recounted = try XCTUnwrap(LibraryArtworkAssembly(first: zero, request: request))
        XCTAssertFalse(recounted.add(try chunk(line(chunk: 1, of: 3))))
    }

    func testAssemblyRejectsAnUnknownVersionOrSource() throws {
        for reply in [line(chunk: 0, v: 2), line(chunk: 0, source: "catalogue"), line(chunk: 0, source: "")] {
            let wire = Wire(reply)
            XCTAssertEqual(try control(wire).libraryArtworkChunk(cursor: "c"),
                           .refused(.other("unsupported_representation")),
                           "a representation this build does not know is a failure, never 'no art'")
        }
        // A reply with no artwork object, or a broken envelope, is malformed, not refused.
        for broken in [#"{"ok":true,"op":"slice.libraryArtwork","generation":7,"library_instance":"x"}"#,
                       self.line(chunk: 0).replacingOccurrences(of: #""transfer":"#, with: #""xfer":"#)] {
            XCTAssertThrowsError(try control(Wire(broken)).libraryArtworkChunk(cursor: "c")) {
                guard case SourceAppError.malformedReply = $0 else { return XCTFail("\($0)") }
            }
        }
    }

    // MARK: readiness

    func testReadinessNeedsTheCapabilityAndAnInstance() throws {
        func readiness(_ status: String) throws -> LibraryArtworkReadiness {
            let wire = Wire(#"{"ok":true,"op":"slice.status","status":\#(status)}"#)
            let result = try control(wire).libraryArtworkReadiness()
            XCTAssertEqual(wire.ordinary.count, 1, "ONE slice.status read")
            XCTAssertEqual(wire.library.count, 0)
            return result
        }
        let both = try readiness(#"{"playback":"stopped","capabilities":["slice.status","slice.libraryArtwork"],"library_instance":"\#(Self.instance)"}"#)
        XCTAssertEqual(both, LibraryArtworkReadiness(supported: true, instance: Self.instance))

        let noCapability = try readiness(#"{"capabilities":["slice.status"],"library_instance":"\#(Self.instance)"}"#)
        XCTAssertFalse(noCapability.supported)
        let noInstance = try readiness(#"{"capabilities":["slice.libraryArtwork"]}"#)
        XCTAssertEqual(noInstance, LibraryArtworkReadiness(supported: false, instance: nil))
        XCTAssertFalse(try readiness(#"{"capabilities":["slice.libraryArtwork"],"library_instance":""}"#).supported)
        XCTAssertFalse(try readiness(#"{"capabilities":["slice.libraryArtwork"],"library_instance":"  "}"#).supported)
        XCTAssertFalse(try readiness(#"{"capabilities":["slice.libraryArtwork"],"library_instance":5}"#).supported)
        XCTAssertFalse(try readiness(#"{"capabilities":["slice.libraryArtwork"],"library_instance":null}"#).supported)
        XCTAssertFalse(try readiness(#"{"library_instance":"\#(Self.instance)"}"#).supported, "no capabilities at all")

        // Through the provider: the same read, and the default is unsupported.
        let provider = BridgeMusicProvider(control: control(Wire(
            #"{"ok":true,"op":"slice.status","status":{"capabilities":["slice.libraryArtwork"],"library_instance":"\#(Self.instance)"}}"#)))
        XCTAssertEqual(try provider.libraryArtworkReadiness().instance, Self.instance)
        struct Bare: MusicDataProvider {
            func librarySongs(cursor: String?, limit: Int) throws -> MusicPage { throw MusicProviderError.unavailable("x") }
            func play(ids: [String]) throws -> BridgeNow.Queue { throw MusicProviderError.unavailable("x") }
            func nowPlaying() throws -> SourceStatus { throw MusicProviderError.unavailable("x") }
        }
        XCTAssertEqual(try Bare().libraryArtworkReadiness(), .unsupported)
        XCTAssertThrowsError(try Bare().libraryArtworkChunk(cursor: "c")) {
            guard case MusicProviderError.notImplemented = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: the pages' library_instance

    private func albumsPage(_ instance: String?) -> String {
        let key = instance.map { #""library_instance":\#($0),"# } ?? ""
        return #"{"ok":true,"op":"slice.libraryAlbums","generation":3,\#(key)"total":1,"items":[{"id":"a1","title":"In Rainbows","artist":"Radiohead","track_count":10,"kind":"album"}],"next_cursor":null,"stale":false,"refreshing":false}"#
    }

    private func playlistsPage(_ instance: String?) -> String {
        let key = instance.map { #""library_instance":\#($0),"# } ?? ""
        return #"{"ok":true,"op":"slice.libraryPlaylists","generation":3,\#(key)"total":1,"items":[{"id":"p1","title":"Top 25 Most Played","kind":"playlist"}],"next_cursor":null,"stale":false,"refreshing":false}"#
    }

    func testAlbumAndPlaylistPagesReadTheLibraryInstance() throws {
        let quoted = #""\#(Self.instance)""#
        XCTAssertEqual(try control(Wire(albumsPage(quoted))).libraryAlbums(cursor: nil, limit: 100).libraryInstance,
                       Self.instance)
        XCTAssertEqual(try control(Wire(playlistsPage(quoted))).libraryPlaylists(cursor: nil, limit: 100).libraryInstance,
                       Self.instance)
        // The rest of the page reads as it did.
        let page = try control(Wire(albumsPage(quoted))).libraryAlbums(cursor: nil, limit: 100)
        XCTAssertEqual(page.generation, 3)
        XCTAssertEqual(page.rows.map(\.id), ["a1"])

        // Absent is an older SpanDAC: nil, and the page still reads.
        XCTAssertNil(try control(Wire(albumsPage(nil))).libraryAlbums(cursor: nil, limit: 100).libraryInstance)
        XCTAssertNil(try control(Wire(playlistsPage(nil))).libraryPlaylists(cursor: nil, limit: 100).libraryInstance)

        // Present and not a non-blank string: the page is refused.
        for bad in ["5", #""""#, #""   ""#, "null", "true"] {
            XCTAssertThrowsError(try control(Wire(albumsPage(bad))).libraryAlbums(cursor: nil, limit: 100), bad) {
                guard case SourceAppError.malformedReply = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertThrowsError(try control(Wire(playlistsPage(bad))).libraryPlaylists(cursor: nil, limit: 100), bad) {
                guard case SourceAppError.malformedReply = $0 else { return XCTFail("\($0)") }
            }
        }
    }

    func testSongsPagesIgnoreIt() throws {
        let songs = #"{"ok":true,"op":"slice.librarySongs","generation":3,"library_instance":5,"total":0,"items":[],"next_cursor":null}"#
        let page = try control(Wire(songs)).librarySongs(cursor: nil, limit: 100)
        XCTAssertNil(page.libraryInstance, "only Albums and Playlists pages carry the instance")
        let artists = #"{"ok":true,"op":"slice.libraryArtists","generation":3,"library_instance":"\#(Self.instance)","total":0,"items":[],"next_cursor":null}"#
        XCTAssertNil(try control(Wire(artists)).libraryArtists(cursor: nil, limit: 100).libraryInstance)
    }
}
