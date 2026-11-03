// tools/music/Sources/TUI/Shell/CatalogueSearchPane.swift
//
// STUB for the red commit; see CatalogueSearch.swift.
import Foundation

protocol CatalogueSearchHost: AnyObject {
    func cataloguePane(_ pane: CatalogueSearchPane, emit intent: CatalogueSearchIntent, requestID: Int)
}

final class CatalogueSearchPane {
    enum LineStyle: Equatable { case box, note, header, row, selected }
    struct Line: Equatable {
        let text: String
        let style: LineStyle
    }

    private(set) var model = CatalogueSearchModel()
    weak var host: CatalogueSearchHost?
    var isEditing: Bool { model.isEditing }

    init(host: CatalogueSearchHost? = nil) { self.host = host }

    func handle(_ key: KeyPress) -> SceneAction { .none }
    @discardableResult
    func didReceive(results: CatalogueSearchResults, requestID: Int) -> Bool { false }
    @discardableResult
    func didReceive(albums: ArtistAlbums, requestID: Int) -> Bool { false }
    @discardableResult
    func didFail(_ message: String, requestID: Int) -> Bool { false }
    func layout(width: Int, height: Int) -> [Line] { [] }
    func render(frame: ShellFrame) -> String { "" }
}
