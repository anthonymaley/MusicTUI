// tools/music/Sources/TUI/LibraryArtworkWire.swift
import CryptoKit
import Foundation

// `slice.libraryArtwork`: the cover of ONE top-level library album or playlist,
// drawn by SpanDAC and handed back as a square JPEG in pulled chunks.
//
//   -> {"op":"slice.libraryArtwork","kind":"album","id":"<id>","generation":7,
//       "library_instance":"<uuid>","px":300}
//   <- {"ok":true,"op":"slice.libraryArtwork","generation":7,"library_instance":"<uuid>",
//       "artwork":{"v":1,"source":"rendered","kind":"album","id":"<id>","media_type":"image/jpeg",
//                  "px":300,"bytes":38211,"sha256":"<64 hex>","transfer":"<32 hex>",
//                  "chunk":0,"chunks":2,"data":"<base64>","next_cursor":"<opaque>"}}
//   -> {"op":"slice.libraryArtwork","cursor":"<opaque>"}
//   <- the same envelope for chunk 1..n: `media_type`, `px`, `bytes` and `sha256` on chunk 0
//      only, `next_cursor` on every chunk and null on the last.
//
// `generation` and `library_instance` are the values of the `slice.libraryAlbums` /
// `slice.libraryPlaylists` page the row came from, sent back unchanged; a
// `slice.status` value is never used as the request's instance (status only gates
// whether the client asks at all). No URL ever crosses this wire. Advertised as the
// capability `slice.libraryArtwork` on the Mac's Unix socket; a SpanDAC that does not
// list it is never sent the op.
//
// Protocol code only: the request, the reply decoder, the refusal kinds and the pure
// assembly that turns chunks into verified bytes. Nothing here touches a cache, a
// clock or a socket of its own.

/// The wire op, and the capability SpanDAC lists when it serves it.
let sourceLibraryArtworkOp = "slice.libraryArtwork"

/// The numbers the reply is checked against (the contract's table, client side).
let libraryArtworkChunkBytes = 32_768
let libraryArtworkMaximumBytes = 393_216
let libraryArtworkMaximumChunks = 12

/// What a cover is asked for: a top-level album or a playlist.
enum LibraryArtworkKind: String {
    case album, playlist
}

/// The first request of a transfer, as the assembly needs to hold the reply to it.
struct LibraryArtworkRequest: Equatable {
    let kind: LibraryArtworkKind
    let id: String
    let generation: Int
    let libraryInstance: String
    let px: Int
}

/// What one `slice.status` read says about covers.
struct LibraryArtworkReadiness: Equatable {
    /// The op is advertised AND the status names its process.
    let supported: Bool
    /// `library_instance` when it is a non-blank string.
    let instance: String?

    static let unsupported = LibraryArtworkReadiness(supported: false, instance: nil)
}

/// Why SpanDAC did not hand a cover over, decoded on `error.kind` and never on the
/// detail, which travels nowhere here.
enum LibraryArtworkRefusal: Equatable {
    /// No live snapshot yet; ask again after the hint.
    case warming(retryAfter: TimeInterval)
    /// The list the row came from is not the live one, or SpanDAC restarted since.
    case staleGeneration
    /// The transfer is gone (another run's, or aged out); ask for the cover again.
    case transferExpired
    /// Generation-scoped definitive negative: that row is not in the library.
    case notInLibrary
    /// Generation-scoped definitive negative: MusicKit holds no cover for it.
    case noArtwork
    /// The render reached SpanDAC's settle cap. `retryAfter` is SpanDAC's own estimate,
    /// in seconds, of when asking again is worth it (its cooldown for this cover); nil
    /// when the reply carried none, or a value that is not a number (an older SpanDAC
    /// sends none). Kept as received: the fetcher validates and clamps it.
    case renderTimeout(retryAfter: TimeInterval?)
    case renderFailed
    case busy
    case unlicensed
    case unauthorized
    /// An older SpanDAC that does not serve the op (`unknown_op`).
    case unsupported
    /// Any other kind, carried by name (`bad_request`, a reply this build cannot
    /// read as `unsupported_representation`, a kind from a newer SpanDAC).
    case other(String)

    /// A missing `retry_after` still means "ask again", so a default stands in for
    /// `warming`; for `render_timeout` it stays nil and the fetcher's own backoff applies.
    init(kind: String?, retryAfter: Double?) {
        switch kind {
        case "warming":          self = .warming(retryAfter: retryAfter ?? 1.0)
        case "stale_generation": self = .staleGeneration
        case "transfer_expired": self = .transferExpired
        case "not_in_library":   self = .notInLibrary
        case "no_artwork":       self = .noArtwork
        case "render_timeout":   self = .renderTimeout(retryAfter: retryAfter)
        case "render_failed":    self = .renderFailed
        case "busy":             self = .busy
        case spanDACLicenceRefusalKind: self = .unlicensed
        case "unauthorized":     self = .unauthorized
        case "unknown_op":       self = .unsupported
        default:                 self = .other(kind ?? "unknown")
        }
    }

    /// The whole `ok:false` reply of a refused request.
    init(reply: [String: Any]) {
        let error = reply["error"] as? [String: Any]
        self.init(kind: error?["kind"] as? String, retryAfter: error?["retry_after"] as? Double)
    }
}

/// The manifest chunk 0 carries and later chunks do not.
struct LibraryArtworkManifest: Equatable {
    let mediaType: String
    let px: Int
    let bytes: Int
    let sha256: String
}

/// One chunk of a cover, either reply shape. `dataBase64` stays text until the
/// assembly decodes it, so a base64 failure is the assembly's to reject.
struct LibraryArtworkChunk: Equatable {
    let generation: Int
    let libraryInstance: String
    let kind: LibraryArtworkKind
    let id: String
    let transfer: String
    let chunk: Int
    let chunks: Int
    let dataBase64: String
    let nextCursor: String?
    /// Chunk 0 only, and nil there when any of its four fields is missing or the
    /// wrong type (the assembly refuses a first chunk without one).
    let manifest: LibraryArtworkManifest?
}

enum LibraryArtworkReply: Equatable {
    case chunk(LibraryArtworkChunk)
    case refused(LibraryArtworkRefusal)

    /// Reads a successful reply. A representation this build does not know (`v` or
    /// `source`) is a refusal to use it, never "no art"; a reply that breaks the
    /// envelope is `malformedReply`.
    static func decode(_ reply: [String: Any]) throws -> LibraryArtworkReply {
        func malformed(_ what: String) -> SourceAppError {
            .malformedReply("SpanDAC's \(sourceLibraryArtworkOp) reply \(what)")
        }
        guard let artwork = reply["artwork"] as? [String: Any] else { throw malformed("is missing artwork") }
        guard SourceAppControl.index(artwork["v"]) == 1, artwork["source"] as? String == "rendered" else {
            return .refused(.other("unsupported_representation"))
        }
        guard let generation = SourceAppControl.index(reply["generation"]) else {
            throw malformed("is missing generation")
        }
        guard let instance = reply["library_instance"] as? String else {
            throw malformed("is missing library_instance")
        }
        guard let kind = (artwork["kind"] as? String).flatMap(LibraryArtworkKind.init(rawValue:)) else {
            throw malformed("has a kind it does not know")
        }
        guard let id = artwork["id"] as? String else { throw malformed("is missing id") }
        guard let transfer = artwork["transfer"] as? String else { throw malformed("is missing transfer") }
        guard let chunk = SourceAppControl.index(artwork["chunk"]),
              let chunks = SourceAppControl.index(artwork["chunks"]) else {
            throw malformed("is missing chunk or chunks")
        }
        guard let data = artwork["data"] as? String else { throw malformed("is missing data") }
        // A MISSING next_cursor and an explicit null are different claims (the same
        // distinction every paged list makes): null says "last chunk".
        guard let cursorValue = artwork["next_cursor"] else { throw malformed("is missing next_cursor") }
        let nextCursor: String?
        switch cursorValue {
        case is NSNull:          nextCursor = nil
        case let text as String: nextCursor = text
        default:                 throw malformed("has a next_cursor that is neither text nor null")
        }
        var manifest: LibraryArtworkManifest?
        if chunk == 0, let mediaType = artwork["media_type"] as? String,
           let px = SourceAppControl.index(artwork["px"]),
           let bytes = SourceAppControl.index(artwork["bytes"]),
           let sha256 = artwork["sha256"] as? String {
            manifest = LibraryArtworkManifest(mediaType: mediaType, px: px, bytes: bytes, sha256: sha256)
        }
        return .chunk(LibraryArtworkChunk(generation: generation, libraryInstance: instance, kind: kind, id: id,
                                          transfer: transfer, chunk: chunk, chunks: chunks, dataBase64: data,
                                          nextCursor: nextCursor, manifest: manifest))
    }
}

/// Chunks in, verified bytes out. Pure: it holds no cache and no clock, and it
/// believes nothing it was not asked for. The first chunk must answer the request
/// that was sent, every later one must belong to the same transfer and arrive in
/// order, and `finish()` returns bytes only when they are the whole cover and hash to
/// the manifest's digest. Any failure poisons the assembly for good.
struct LibraryArtworkAssembly {
    private let request: LibraryArtworkRequest
    private let transfer: String
    private let manifest: LibraryArtworkManifest
    private let chunks: Int
    private var bytes = Data()
    private var next = 0
    private var failed = false
    private var cursorShapeOK = true
    private(set) var nextCursor: String?

    /// nil when the first chunk is not an acceptable answer to `request`.
    init?(first: LibraryArtworkChunk, request: LibraryArtworkRequest) {
        guard let manifest = first.manifest,
              manifest.mediaType == "image/jpeg",
              manifest.px == request.px,
              manifest.bytes >= 1, manifest.bytes <= libraryArtworkMaximumBytes,
              first.chunks <= libraryArtworkMaximumChunks,
              first.chunks == (manifest.bytes + libraryArtworkChunkBytes - 1) / libraryArtworkChunkBytes,
              first.chunk == 0,
              !first.transfer.isEmpty,
              first.generation == request.generation,
              first.libraryInstance == request.libraryInstance,
              first.kind == request.kind,
              first.id == request.id else { return nil }
        self.request = request
        self.transfer = first.transfer
        self.manifest = manifest
        self.chunks = first.chunks
        guard append(first) else { return nil }
    }

    /// True when every chunk has arrived (not that the bytes verify: `finish()`).
    var isComplete: Bool { !failed && next == chunks }

    /// Adds the next chunk. False, and the assembly is spent, when it is not exactly
    /// the one expected from this transfer.
    @discardableResult
    mutating func add(_ chunk: LibraryArtworkChunk) -> Bool {
        guard !failed, next < chunks,
              chunk.transfer == transfer,
              chunk.generation == request.generation,
              chunk.libraryInstance == request.libraryInstance,
              chunk.kind == request.kind,
              chunk.id == request.id,
              chunk.chunks == chunks,
              chunk.chunk == next else { failed = true; return false }
        return append(chunk)
    }

    /// The whole cover, or nil. Only when all chunks arrived, the length is the
    /// manifest's, the SHA-256 is the manifest's, and the cursors say what the
    /// transfer says: every chunk but the last points on, the last points nowhere.
    func finish() -> Data? {
        guard !failed, next == chunks, cursorShapeOK, nextCursor == nil,
              bytes.count == manifest.bytes else { return nil }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return digest == manifest.sha256 ? bytes : nil
    }

    private mutating func append(_ chunk: LibraryArtworkChunk) -> Bool {
        // Standard base64 with padding, decoded strictly: Foundation refuses any
        // other character, and a re-encode that differs is a padding or alphabet
        // variant this contract does not send.
        guard let raw = Data(base64Encoded: chunk.dataBase64),
              raw.base64EncodedString() == chunk.dataBase64,
              raw.count <= libraryArtworkChunkBytes,
              bytes.count + raw.count <= manifest.bytes else { failed = true; return false }
        bytes.append(raw)
        next += 1
        let last = next == chunks
        if last ? chunk.nextCursor != nil : chunk.nextCursor == nil { cursorShapeOK = false }
        nextCursor = chunk.nextCursor
        return true
    }
}

extension SourceAppControl {

    /// First chunk: the five fields and no other, over the library transport (a
    /// render can take seconds, and the 30 s margin is the contract's).
    func libraryArtwork(kind: LibraryArtworkKind, id: String, generation: Int, libraryInstance: String,
                        px: Int) throws -> LibraryArtworkReply {
        try libraryArtworkReply(["op": sourceLibraryArtworkOp, "kind": kind.rawValue, "id": id,
                                 "generation": generation, "library_instance": libraryInstance, "px": px])
    }

    /// A later chunk: exactly `op` and `cursor`, the cursor returned unread.
    func libraryArtworkChunk(cursor: String) throws -> LibraryArtworkReply {
        try libraryArtworkReply(["op": sourceLibraryArtworkOp, "cursor": cursor])
    }

    /// The refusal is decoded on `error.kind` from the reply `send` hands to
    /// `onRefusedReply`, so no other op's error mapping changes. A failure with no
    /// refused reply (transport, an unreadable line) is rethrown as it was.
    private func libraryArtworkReply(_ body: [String: Any]) throws -> LibraryArtworkReply {
        var refusedReply: [String: Any]?
        let reply: [String: Any]
        do {
            reply = try send(body, over: libraryTransport, onRefusedReply: { refusedReply = $0 })
        } catch let error as SourceAppError {
            if let refusedReply { return .refused(LibraryArtworkRefusal(reply: refusedReply)) }
            throw error
        }
        return try LibraryArtworkReply.decode(reply)
    }

    /// One `slice.status`, on the ordinary transport: covers are supported only when
    /// `capabilities` lists the op AND `library_instance` is a non-blank string
    /// (read where `libraryRefreshStatus` reads it). Anything else is unsupported,
    /// never an error: this only gates whether the client asks at all.
    func libraryArtworkReadiness() throws -> LibraryArtworkReadiness {
        let reply = try send(["op": "slice.status"])
        let status = reply["status"] as? [String: Any]
        let capabilities = status?["capabilities"] as? [String] ?? []
        let raw = status?["library_instance"] ?? reply["library_instance"]
        let instance = (raw as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        return LibraryArtworkReadiness(supported: capabilities.contains(sourceLibraryArtworkOp) && instance != nil,
                                       instance: instance)
    }
}
