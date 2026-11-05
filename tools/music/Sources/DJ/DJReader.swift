// tools/music/Sources/DJ/DJReader.swift
//
// The DJ reader: turns a typed request into a CARD (what the DJ understood),
// or says why it cannot. This file knows nothing about FoundationModels, so
// it compiles on every toolchain and every macOS; the Apple model lives in
// DJAppleBackend.swift behind `#if canImport(FoundationModels)`.
//
// The card is a reading, never a guarantee. Whatever a model returns is
// validated here, in code, before anything downstream may act on it, and the
// box says what it understood ("Playing: ...") the moment it plays.
import Foundation

/// What the DJ understood. Only the fields its kind uses are ever set.
struct DJCard: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case artistMix
        case genreUnheard
        case unsupported
    }

    /// The longest artist or genre the DJ will carry, after trimming.
    static let maxFieldLength = 100

    let kind: Kind
    let artist: String?
    let genre: String?

    static let unsupported = DJCard(kind: .unsupported, artist: nil, genre: nil)

    /// Validate a model's raw output. Anything that is not a well-formed card of
    /// a known kind becomes `.unsupported`; a field the kind does not use is dropped.
    static func validated(_ raw: DJRawCard) -> DJCard {
        switch raw.kind {
        case Kind.artistMix.rawValue:
            guard let artist = cleanField(raw.artist) else { return .unsupported }
            return DJCard(kind: .artistMix, artist: artist, genre: nil)
        case Kind.genreUnheard.rawValue:
            guard let genre = cleanField(raw.genre) else { return .unsupported }
            return DJCard(kind: .genreUnheard, artist: nil, genre: genre)
        default:
            return .unsupported
        }
    }

    /// Trimmed, nonempty, bounded, and free of control characters (an escape
    /// sequence or newline in a field must never reach the screen or a script).
    private static func cleanField(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= maxFieldLength,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return trimmed
    }
}

/// A model's output before validation: strings exactly as it produced them.
struct DJRawCard: Equatable, Sendable {
    var kind: String
    var artist: String?
    var genre: String?
}

/// Why the DJ cannot read at all. Five distinct states, each with its own words.
enum DJUnavailable: CaseIterable, Hashable, Sendable {
    case notThisMac
    case appleIntelligenceOff
    case modelNotReady
    case unsupportedLanguage
    case builtWithoutDJ

    var message: String {
        switch self {
        case .notThisMac:
            return "The DJ needs a Mac that supports Apple Intelligence, running macOS 26 or later."
        case .appleIntelligenceOff:
            return "Apple Intelligence is off. Turn it on in System Settings, Apple Intelligence & Siri."
        case .modelNotReady:
            return "Apple's on-device model is still downloading or getting ready. Try again in a few minutes."
        case .unsupportedLanguage:
            return "The DJ does not support this language or region yet."
        case .builtWithoutDJ:
            return "This build of music was made without the DJ."
        }
    }
}

/// The result of one read.
enum DJReading: Equatable, Sendable {
    case card(DJCard)
    case unavailable(DJUnavailable)
    /// A transient failure of one read (the model errored); the text is for the user.
    case failed(String)
}

/// Reads a request into a card. Async: callers never block their own thread
/// (the TUI input loop in particular) waiting on a model.
protocol DJReader: Sendable {
    func read(_ prompt: String) async -> DJReading
}

// MARK: - The model seam

enum DJBackendError: Error, Equatable, Sendable {
    case unavailable(DJUnavailable)
    /// The model declined the request (a guardrail, a refusal): same as unsupported.
    case unsupportedPrompt
    case failed(String)
}

/// The one thing that talks to a model. The real one is Apple's on-device
/// model (DJAppleBackend.swift); tests script it.
protocol DJModelBackend: Sendable {
    /// Nil when the model can be asked right now.
    func currentAvailability() -> DJUnavailable?
    func classify(_ prompt: String) async throws -> DJRawCard
}

/// A reader whose model is unavailable for a fixed reason. Used when the DJ is
/// compiled out, or the OS is too old for the model.
struct DJUnavailableReader: DJReader {
    let reason: DJUnavailable
    init(_ reason: DJUnavailable) { self.reason = reason }
    func read(_ prompt: String) async -> DJReading { .unavailable(reason) }
}

/// The reader everything real goes through: availability, prompt guard, one
/// model call, code-side validation, and the similarity and negation guard.
struct DJBackedReader: DJReader {
    static let maxPromptLength = 400

    let backend: DJModelBackend
    init(backend: DJModelBackend) { self.backend = backend }

    func read(_ prompt: String) async -> DJReading {
        if let reason = backend.currentAvailability() { return .unavailable(reason) }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxPromptLength else { return .card(.unsupported) }

        let raw: DJRawCard
        do {
            raw = try await backend.classify(trimmed)
        } catch let error as DJBackendError {
            switch error {
            case .unavailable(let reason): return .unavailable(reason)
            case .unsupportedPrompt: return .card(.unsupported)
            case .failed(let text): return .failed(text)
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        let card = DJCard.validated(raw)
        // Defence in depth: the model is told to refuse these, but a returned
        // artistMix or genreUnheard card for a "like X" or "not X" request is
        // exactly the misread this DJ cannot honour, so code refuses it too.
        if card.kind != .unsupported, DJRequestPhrases.isSimilarityOrNegation(trimmed) {
            return .card(.unsupported)
        }
        return .card(card)
    }
}

/// Phrases that mean "similar to" or "not": things the DJ has no data for.
/// Phrase-based on purpose: bare words ("no", "like", "but", "skip") are inside
/// real artist names (No Doubt, Nothing But Thieves, Skip James).
enum DJRequestPhrases {
    private static let patterns: [NSRegularExpression] = [
        // similarity
        #"\b(sounds?|sounded) like\b"#,
        #"\bsimilar to\b"#,
        #"\b(songs?|music|stuff|tracks?|something|anything|artists?|bands?|more|things?) like\b"#,
        #"\breminds? me of\b"#,
        #"\bin the (style|vein) of\b"#,
        #"\bakin to\b"#,
        // negation
        #"\b(anything|everything|all|any music|any songs?) (but|except|besides)\b"#,
        #"\bbut not\b"#,
        #"\b(except|excluding|without|avoid|other than)\b"#,
        #"\b(don'?t|do not) (want|play|like)\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func isSimilarityOrNegation(_ prompt: String) -> Bool {
        let normalized = prompt
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        let range = NSRange(normalized.startIndex..., in: normalized)
        return patterns.contains { $0.firstMatch(in: normalized, range: range) != nil }
    }
}

// MARK: - The factory

enum DJReaders {
    /// The reader the app uses. Building one never contacts a model.
    static func makeDefault() -> DJReader {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return DJBackedReader(backend: DJAppleBackend())
        }
        return DJUnavailableReader(.notThisMac)
        #else
        return DJUnavailableReader(.builtWithoutDJ)
        #endif
    }
}
