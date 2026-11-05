// tools/music/Sources/DJ/DJBoxModel.swift
//
// The DJ box as a pure model: one line of raw text, one request id per ask,
// and a small set of stages. No I/O, no clock, no host: a key goes in, an
// optional emission comes out, and answers come back through `receive` keyed
// by the request id they were asked under.
//
// There is no card and no second Enter: when a plan arrives for the current
// request, `receive` hands it back to play and the box shows "Playing: ..." with
// its text emptied for the next request.
//
// REQUEST IDS. Every ask takes the next id; the model applies an answer only
// if it carries the current id AND the model is still waiting for it. So a
// newer prompt wins, an older answer (an error included) is dropped, and an
// edit of the text while a request is out drops that request too.
//
// Esc and the up arrow that leave the box are the HOST's: this model ignores
// them (up and down only move the artist picker).
import Foundation

struct DJBoxModel {
    /// Shown dim inside the box while it is empty and not focused.
    static let placeholder = "Make a request"
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
        /// The DJ understood; the lookups behind the plan are out. Carries the artist or genre.
        case working(String)
        case pick(Picker)
        /// The plan arrived and was handed to play: what was understood, as the card used to say it.
        case playing(String)
        case message(String)
    }

    enum Emission: Equatable {
        case ask(prompt: String, requestID: Int)
        case choose(CatalogueHit, requestID: Int)
    }

    /// What an answer did to the box.
    enum Receipt: Equatable {
        /// Not the request the box is waiting for: dropped.
        case ignored
        /// Applied; the screen changed.
        case changed
        /// A plan for the current request: play exactly this, once.
        case play(DJPlan)
    }

    struct Outcome: Equatable {
        var changed = false
        var emission: Emission?
    }

    private(set) var text = ""
    private(set) var stage: Stage = .typing
    private(set) var requestID = 0

    // MARK: derived view

    var statusLine: String? {
        switch stage {
        case .typing: return nil
        case .reading: return "Asking the DJ\u{2026}"
        case .working(let what): return "Looking up \(what)\u{2026}"
        case .pick(let picker): return "Which \(picker.artist)? \u{2191}\u{2193} to move, Enter to play"
        case .playing(let line): return "Playing: \(line)"
        case .message(let text): return text
        }
    }

    // MARK: keys

    mutating func handle(_ key: KeyPress) -> Outcome {
        switch key {
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

    /// Editing the prompt drops a picker, a message or a spent plan: it
    /// is a new prompt now. A request still out is dropped with the old text:
    /// the box is no longer waiting, so its answer (a failure too) finds
    /// nothing to land on, even before the next Enter numbers a new request.
    private mutating func leaveSpentStage() {
        stage = .typing
    }

    /// A request is out and the box is waiting for it.
    var isRequestOut: Bool {
        switch stage {
        case .reading, .working: return true
        default: return false
        }
    }

    /// The artist picker is showing: up and down move it, and the host leaves
    /// the box only on Esc.
    var isPicking: Bool {
        if case .pick = stage { return true }
        return false
    }

    private mutating func enter() -> Outcome {
        switch stage {
        case .pick(let picker):
            guard picker.hits.indices.contains(picker.cursor) else { return Outcome() }
            let hit = picker.hits[picker.cursor]
            requestID += 1
            stage = .working(hit.title)
            return Outcome(changed: true, emission: .choose(hit, requestID: requestID))
        case .typing, .reading, .working, .playing, .message:
            let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return Outcome() }
            requestID += 1
            text = prompt
            stage = .reading
            return Outcome(changed: true, emission: .ask(prompt: prompt, requestID: requestID))
        }
    }

    // MARK: answers

    @discardableResult
    mutating func receive(_ outcome: DJOutcome, requestID id: Int) -> Receipt {
        guard id == requestID else { return .ignored }
        switch stage {
        case .reading, .working: break
        default: return .ignored
        }
        switch outcome {
        case .working(let what):
            guard case .reading = stage else { return .ignored }
            stage = .working(Self.clean(what))
        case .message(let words):
            stage = .message(Self.clean(words))
        case .pick(let artist, let hits):
            guard !hits.isEmpty else { return .ignored }
            stage = .pick(Picker(artist: Self.clean(artist), hits: hits))
        case .plan(let plan):
            // Played straight away: the box empties for the next request.
            stage = .playing(Self.clean(plan.line))
            text = ""
            return .play(plan)
        }
        return .changed
    }

    /// The plan was refused or failed after the box said it was playing: the
    /// box says why instead, if it is still showing that play. False when it moved on.
    @discardableResult
    mutating func playFailed(requestID id: Int, saying words: String) -> Bool {
        guard id == requestID, case .playing = stage else { return false }
        stage = .message(Self.clean(words))
        return true
    }

    /// Whatever is held is dropped for a reason, and the box says why.
    /// Anything still out for the old request is dropped with it.
    mutating func drop(saying words: String) {
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
