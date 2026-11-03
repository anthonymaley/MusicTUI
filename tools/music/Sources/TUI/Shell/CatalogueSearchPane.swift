// tools/music/Sources/TUI/Shell/CatalogueSearchPane.swift
//
// The Discover catalogue search's screen: a one-line box at the top, a note
// line, then the grouped list. It performs no I/O. A key becomes an intent
// handed to the `CatalogueSearchHost`; the host does the work (a read, a play)
// and feeds the answer back with the request id it was given, so this pane can
// later move to a tab of its own without changing.
//
// The host's `capturesAllInput` must mirror `isEditing`, and while the pane is
// on screen the host should hand it every key it does not itself own.
import Foundation

protocol CatalogueSearchHost: AnyObject {
    /// `requestID` is fresh for `.search` and `.openArtist` (echo it back with
    /// the answer); for every other intent it is the latest id and can be ignored.
    func cataloguePane(_ pane: CatalogueSearchPane, emit intent: CatalogueSearchIntent, requestID: Int)
}

final class CatalogueSearchPane {
    enum LineStyle: Equatable { case box, note, header, row, selected }

    struct Line: Equatable {
        let text: String
        let style: LineStyle
    }

    static let boxPrefix = "Search Apple Music: "
    static let caret = "▏"

    private(set) var model = CatalogueSearchModel()
    weak var host: CatalogueSearchHost?

    var isEditing: Bool { model.isEditing }

    init(host: CatalogueSearchHost? = nil) { self.host = host }

    // MARK: keys

    /// `.redraw` when the screen changed, else `.none`. A host should treat the
    /// key as consumed either way: an inert key (`r`) is swallowed, not passed on.
    func handle(_ key: KeyPress) -> SceneAction {
        let outcome = model.handle(key)
        if let e = outcome.emission { host?.cataloguePane(self, emit: e.intent, requestID: e.requestID) }
        return outcome.changed ? .redraw : .none
    }

    // MARK: answers (each returns whether the screen changed)

    @discardableResult
    func didReceive(results: CatalogueSearchResults, requestID: Int) -> Bool {
        model.receive(results: results, requestID: requestID)
    }

    @discardableResult
    func didReceive(albums: ArtistAlbums, requestID: Int) -> Bool {
        model.receive(albums: albums, requestID: requestID)
    }

    @discardableResult
    func didFail(_ message: String, requestID: Int) -> Bool {
        model.receive(failure: message, requestID: requestID)
    }

    // MARK: layout

    /// The lines of the pane, top to bottom, each no wider than `width`:
    /// the box, the note line (always reserved, possibly empty), then the rows.
    func layout(width: Int, height: Int) -> [Line] {
        guard width > 0, height > 0 else { return [] }
        var lines = [Line(text: boxText(width: width), style: .box)]
        guard height > 1 else { return lines }
        lines.append(Line(text: truncText(model.note ?? "", to: width), style: .note))
        let area = height - 2
        guard area > 0 else { return lines }

        let rows = model.rows
        let top = rows.count <= area ? 0 : max(0, min(rows.count - area, model.cursor - area / 2))
        for i in top..<min(rows.count, top + area) {
            switch rows[i] {
            case .header(let name):
                lines.append(Line(text: truncText(name, to: width), style: .header))
            case .hit(let hit):
                let selected = i == model.cursor
                let text = (selected ? "▸ " : "  ") + Self.label(for: hit)
                lines.append(Line(text: truncText(text, to: width), style: selected ? .selected : .row))
            }
        }
        return lines
    }

    private func boxText(width: Int) -> String {
        let prefix = Self.boxPrefix
        if model.isEditing {
            let room = width - prefix.count - Self.caret.count
            guard room > 0 else { return truncText(prefix + Self.caret, to: width) }
            let text = model.text
            let shown = text.count > room ? "…" + String(text.suffix(max(0, room - 1))) : text
            return prefix + shown + Self.caret
        }
        return truncText(prefix + model.text, to: width)
    }

    private static func label(for hit: CatalogueHit) -> String {
        switch hit.kind {
        case .artist:
            return hit.title
        case .album:
            return [hit.title, hit.subtitle].compactMap { $0 }.joined(separator: " · ")
        case .song:
            return [hit.title, hit.subtitle, hit.album].compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: render

    /// Draws the pane into the shell's body region, one column in from the left.
    func render(frame: ShellFrame) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let lines = layout(width: max(1, frame.width - 2), height: frame.bodyHeight)
        for (i, line) in lines.enumerated() {
            out += ANSICode.moveTo(row: frame.bodyY + i, col: 2) + styled(line)
        }
        return out
    }

    private func styled(_ line: Line) -> String {
        let reset = ANSICode.reset
        switch line.style {
        case .box:
            guard line.text.hasPrefix(Self.boxPrefix) else {
                return "\(ANSICode.brightWhite)\(line.text)\(reset)"
            }
            let rest = String(line.text.dropFirst(Self.boxPrefix.count))
            return "\(ANSICode.cyan)\(Self.boxPrefix)\(reset)\(ANSICode.brightWhite)\(rest)\(reset)"
        case .note:     return "\(ANSICode.dim)\(line.text)\(reset)"
        case .header:   return "\(ANSICode.bold)\(ANSICode.cyan)\(line.text)\(reset)"
        case .row:      return line.text
        case .selected: return "\(ANSICode.bold)\(ANSICode.brightWhite)\(line.text)\(reset)"
        }
    }
}
