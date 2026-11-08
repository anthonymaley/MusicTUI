// tools/music/Sources/DJ/DJAppleBackend.swift
//
// The Apple on-device model behind the DJ reader. Wholly inside
// `#if canImport(FoundationModels)` and `@available(macOS 26, *)`: the package
// floor stays macOS 14, the framework is weak-linked, and on a toolchain
// without the module this file compiles to nothing (the factory in
// DJReader.swift then reports "built without the DJ").
#if canImport(FoundationModels)
import Foundation
import FoundationModels

// The card schema is built at runtime (DynamicGenerationSchema), not with the
// `@Generable` / `@Guide` macros: Homebrew's `swift build` on a Tahoe runner
// (Xcode 26.6) could not load the FoundationModelsMacros plugin, so the macro
// form failed to compile there (v3.26.0's arm64_tahoe bottle). Same fields,
// same choices and descriptions as the macro version it replaces.
@available(macOS 26, *)
enum DJModelSchema {
    static let kinds = ["artistMix", "genreUnheard", "unsupported"]

    static func make() throws -> GenerationSchema {
        let kind = DynamicGenerationSchema(name: "DJModelKind", anyOf: kinds)
        let card = DynamicGenerationSchema(name: "DJModelCard", properties: [
            .init(name: "kind",
                  description: "artistMix: the user asks to play a mix of one named artist's albums. genreUnheard: the user asks for music of one genre that they have not heard or played in a while. unsupported: anything else, including music similar to or like an artist, anything excluded or negated, and anything not about those two.",
                  schema: kind),
            .init(name: "artist",
                  description: "The one artist named by the user, spelled as the artist is normally known. Only for artistMix; otherwise leave empty.",
                  schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            .init(name: "genre",
                  description: "The one genre named by the user, as a short common genre name such as Jazz. Only for genreUnheard; otherwise leave empty.",
                  schema: DynamicGenerationSchema(type: String.self), isOptional: true),
        ])
        return try GenerationSchema(root: card, dependencies: [])
    }
}

@available(macOS 26, *)
struct DJAppleBackend: DJModelBackend {
    static let instructions = """
    You read one short music request and fill in a card. You never answer the request and you never play anything.

    Choose the kind:
    - artistMix: the request asks for a mix of the albums or music OF one named artist or band ("a mix of Radiohead albums", "play some Miles Davis"). Set artist to that name.
    - genreUnheard: the request asks for music of one genre the user has not heard or played in a while ("cool jazz I haven't heard in a while", "some old house I haven't played lately"). Set genre to the genre name, such as Jazz.
    - unsupported: everything else. In particular, always choose unsupported when the request asks for music LIKE, SIMILAR TO, or in the style of an artist ("like Tribe Called Quest", "similar to Radiohead", "sounds like Bonobo"), when it excludes or negates something ("anything but jazz", "not rock", "no country", "without Drake"), when it names no artist and no genre, when it names more than one artist or genre, or when it is not a music request.

    Never invent an artist or a genre that the request does not contain. When unsure, choose unsupported.
    """

    func currentAvailability() -> DJUnavailable? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale.current) ? nil : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .notThisMac
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
    }

    func classify(_ prompt: String) async throws -> DJRawCard {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: Self.instructions)
        do {
            let response = try await session.respond(to: prompt, schema: try DJModelSchema.make())
            let card = response.content
            return DJRawCard(kind: try card.value(String.self, forProperty: "kind"),
                             artist: try card.value(String?.self, forProperty: "artist"),
                             genre: try card.value(String?.self, forProperty: "genre"))
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .unsupportedLanguageOrLocale: throw DJBackendError.unavailable(.unsupportedLanguage)
            case .assetsUnavailable: throw DJBackendError.unavailable(.modelNotReady)
            case .guardrailViolation, .refusal: throw DJBackendError.unsupportedPrompt
            default: throw DJBackendError.failed("The DJ could not read that: \(error.localizedDescription)")
            }
        }
    }
}
#endif
