// Pure navigation model for the Radio tab — mirrors LibraryNav (same [ / ]
// sub-view cycle, same reducer signature) minus the drill stack: stations are
// flat, there is nothing to drill into.
import Foundation

// Declaration order IS the on-screen order and the [ / ] cycle order.
// Favorites first: it's the home, it paints from disk with no network, and it's
// the only sub-view that works with no token.
enum RadioSubView: CaseIterable, Equatable { case favorites, live, personal }

enum RadioKey { case up, down, enter, switchNext, switchPrev, toggleFav }

enum RadioAction: Equatable {
    case none
    case play(Station)
    case toggleFavorite(Station)
}

struct RadioNav: Equatable {
    var subView: RadioSubView
    var cursor: Int

    static let initial = RadioNav(subView: .favorites, cursor: 0)
}

func radioReduce(_ state: RadioNav, _ key: RadioKey,
                 itemCount: Int, selection: Station?) -> (RadioNav, RadioAction) {
    var s = state
    switch key {
    case .up:
        s.cursor = max(0, s.cursor - 1)
        return (s, .none)

    case .down:
        s.cursor = min(max(0, itemCount - 1), s.cursor + 1)
        return (s, .none)

    case .switchNext, .switchPrev:
        let all = RadioSubView.allCases
        let idx = all.firstIndex(of: s.subView)!
        let next = key == .switchNext ? (idx + 1) % all.count : (idx - 1 + all.count) % all.count
        s.subView = all[next]
        s.cursor = 0
        return (s, .none)

    case .enter:
        guard let sel = selection else { return (s, .none) }
        return (s, .play(sel))

    case .toggleFav:
        guard let sel = selection else { return (s, .none) }
        return (s, .toggleFavorite(sel))
    }
}
