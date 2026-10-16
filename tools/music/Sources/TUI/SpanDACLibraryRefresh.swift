// tools/music/Sources/TUI/SpanDACLibraryRefresh.swift
import Foundation

// `slice.libraryRefresh`: ask SpanDAC to re-read the Mac's library now.
//
// SpanDAC serves its held snapshot and never pushes a change, so a playlist made
// in Apple's Music app after the snapshot is missing until SpanDAC rebuilds it.
// This op starts that rebuild. It takes no fields, answers at once (the rebuild
// runs behind it), and its reply body carries nothing the client needs: the
// rebuilt list is read afterwards with the ordinary paged reads, which come back
// flagged `stale`/`refreshing` until the rebuild lands and are then re-asked
// (`LibraryReask`).
//
// Protocol code only. Additive, advertised as `library.refresh`; a SpanDAC that
// does not list it is never sent the op.

/// The wire op, and the capability SpanDAC lists when it serves it.
let sourceLibraryRefreshOp = "slice.libraryRefresh"
let sourceLibraryRefreshCapability = "library.refresh"

extension SourceAppControl {

    /// The request body: the op and nothing else.
    static func libraryRefreshBody() -> [String: Any] {
        ["op": sourceLibraryRefreshOp]
    }

    /// `slice.libraryRefresh`. A refusal (including `unknown_op`) throws like any
    /// other op's; the caller decides it is not worth showing. The reply body is
    /// not read. It travels on the library transport, with the other library ops.
    func libraryRefresh() throws {
        _ = try send(Self.libraryRefreshBody(), over: libraryTransport)
    }
}
