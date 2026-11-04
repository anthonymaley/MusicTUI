// tools/music/Sources/DJ/DJBoxModel.swift
//
// The DJ box as a pure model: one line of raw text, one request id per ask,
// and a small set of stages. No I/O, no clock, no host: a key goes in, an
// optional emission comes out, and answers come back through `receive` keyed
// by the request id they were asked under.
//
// REQUEST IDS. Every ask takes the next id; the model applies an answer only
// if it carries the current id AND the model is still waiting for it. So a
// newer prompt wins, an older answer (an error included) is dropped, and a
// closed box accepts nothing.
import Foundation

struct DJBoxModel {
    static let boxPrefix = "Apple Music DJ: "
    static let caret = "\u{258F}"
    static let maxTextLength = 400

    struct Picker: Equatable {
        let artist: String
        let hits: [CatalogueHit]
        var cursor = 0
    }

    enum Stage: Equatable {
        /// The text is being edited; nothing is out.
        case typing
        /// A request is out.
        case reading
        /// The DJ understood; the lookups behind the card are out. Carries the artist or genre.
        case working(String)
        case pick(Picker)
        case card(DJPlan)
        /// Enter was pressed on the card: the plan is spent.
        case sent(String)
        case message(String)
    }

    enum Emission: Equatable {
        case ask(prompt: String, requestID: Int)
        case choose(CatalogueHit, requestID: Int)
        case play(DJPlan)
        case close
    }

    struct Outcome: Equatable {
        var changed = false
        var emission: Emission?
    }

    private(set) var text = ""
    private(set) var stage: Stage = .typing
    private(set) var requestID = 0
    private(set) var isClosed = false

    // MARK: derived view

    var statusLine: String? {
        switch stage {
        case .typing: return nil
        case .reading: return "Asking the DJ\u{2026}"
        case .working(let what): return "Looking up \(what)\u{2026}"
        case .pick(let picker): return "Which \(picker.artist)? \u{2191}\u{2193} to move, Enter to choose"
        case .card(let plan): return "\(plan.line) \u{2014} Enter plays, Esc drops it"
        case .sent(let line): return "Sent: \(line)"
        case .message(let text): return text
        }
    }

    // MARK: keys

    mutating func handle(_ key: KeyPress) -> Outcome {
        guard !isClosed else { return Outcome() }
        switch key {
        case .escape:
            isClosed = true
            stage = .typing
            return Outcome(changed: true, emission: .close)
        case .enter:
            return enter()
        case .up, .down:
            guard case .pick(var picker) = stage else { return Outcome() }
            let moved = min(max(0, picker.cursor + (key == .down ? 1 : -1)), picker.hits.count - 1)
            guard moved != picker.cursor else { return Outcome() }
            picker.cursor = moved
            stage = .pick(picker)
            return Outcome(changed: true)
        case .char(let c) where c == "\u{7F}" || c == "\u{8}":
            guard !text.isEmpty else { return Outcome() }
            text.removeLast()
            leaveSpentStage()
            return Outcome(changed: true)
        case .space:
            return append(" ")
        case .char(let c):
            return append(c)
        default:
            return Outcome()
        }
    }

    private mutating func append(_ c: Character) -> Outcome {
        guard c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
              text.count < Self.maxTextLength else { return Outcome() }
        text.append(c)
        leaveSpentStage()
        return Outcome(changed: true)
    }

    /// Editing the prompt drops a card, a picker, a message or a spent plan: it
    /// is a new prompt now. A request already out is left to land (or to be
    /// replaced by the next Enter).
    private mutating func leaveSpentStage() {
        switch stage {
        case .reading, .working, .typing: break
        case .pick, .card, .sent, .message: stage = .typing
        }
    }

    private mutating func enter() -> Outcome {
        switch stage {
        case .card(let plan):
            stage = .sent(plan.line)
            return Outcome(changed: true, emission: .play(plan))
        case .pick(let picker):
            guard picker.hits.indices.contains(picker.cursor) else { return Outcome() }
            let hit = picker.hits[picker.cursor]
            requestID += 1
            stage = .working(hit.title)
            return Outcome(changed: true, emission: .choose(hit, requestID: requestID))
        case .sent:
            return Outcome()
        case .typing, .reading, .working, .message:
            let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return Outcome() }
            requestID += 1
            text = prompt
            stage = .reading
            return Outcome(changed: true, emission: .ask(prompt: prompt, requestID: requestID))
        }
    }

    // MARK: answers

    /// True when the answer was applied (the screen changed).
    @discardableResult
    mutating func receive(_ outcome: DJOutcome, requestID id: Int) -> Bool {
        guard !isClosed, id == requestID else { return false }
        switch stage {
        case .reading, .working: break
        default: return false
        }
        switch outcome {
        case .working(let what):
            guard case .reading = stage else { return false }
            stage = .working(Self.clean(what))
        case .message(let words):
            stage = .message(Self.clean(words))
        case .pick(let artist, let hits):
            guard !hits.isEmpty else { return false }
            stage = .pick(Picker(artist: Self.clean(artist), hits: hits))
        case .plan(let plan):
            stage = .card(plan)
        }
        return true
    }

    /// The card (or anything else held) is dropped for a reason, and the box
    /// says why. Anything still out for the old request is dropped with it.
    mutating func drop(saying words: String) {
        guard !isClosed else { return }
        requestID += 1
        stage = .message(Self.clean(words))
    }

    /// Text from Apple, SpanDAC or a model never carries a control scalar to the screen.
    static func clean(_ words: String) -> String {
        String(String.UnicodeScalarView(words.unicodeScalars.filter {
            !($0.value < 0x20 || (0x7F...0x9F).contains($0.value))
        }))
    }
}
