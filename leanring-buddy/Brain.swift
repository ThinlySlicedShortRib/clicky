//
//  Brain.swift
//  leanring-buddy
//
//  The seam between Clicky and whatever produces its replies. The app hands a
//  Brain the transcript, conversation context and screenshots, and gets text
//  back plus whatever usage figures the backend reported. Builds that want a
//  different backend implement this protocol and nothing else changes.
//

import Foundation

struct BrainImage {
    let imageData: Data
    /// Sent next to the image. Carries the screen label and pixel dimensions,
    /// which are the coordinate space for [POINT:...] tags.
    let label: String

    /// Screenshots are JPEG, but test fixtures can be PNG, and the API rejects
    /// a media type that doesn't match the bytes.
    var mediaType: String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        return [UInt8](imageData.prefix(4)) == pngSignature ? "image/png" : "image/jpeg"
    }
}

struct BrainConversationExchange {
    let userTranscript: String
    let assistantResponse: String
}

struct BrainRequest {
    let systemPrompt: String
    let conversationHistory: [BrainConversationExchange]
    let userPrompt: String
    let images: [BrainImage]
}

/// Tokens, cost and timing for one Brain call, for showing on screen.
/// A nil figure means the backend did not report it. Never display a nil as 0.
struct BrainUsage: Codable {
    let backendName: String
    let modelIdentifier: String

    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    let costInUSD: Double?
    /// True when costInUSD was not read from an invoice or billing API. Any
    /// on-screen cost must say "estimated" when this is true.
    let isCostEstimated: Bool
    /// Plain-language origin of costInUSD, suitable for a footnote.
    let costSourceDescription: String

    /// From process launch to the first text delta, as measured by the app.
    /// This includes CLI startup, which is the delay the user actually feels.
    let timeToFirstTextInSeconds: Double?
    let totalDurationInSeconds: Double
}

struct BrainResponse {
    let text: String
    let usage: BrainUsage
}

struct BrainError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

protocol Brain {
    var displayName: String { get }

    /// Who receives a screenshot sent to this Brain, in the words the UI uses.
    /// Must stay honest: only a Brain that runs on this Mac may say "this mac".
    var screenshotDestinationName: String { get }

    /// Returns the complete reply. `onTextDelta` fires on the main actor with
    /// each new piece of text as it arrives; backends that cannot stream call
    /// it once with the whole reply. Throws CancellationError when the
    /// surrounding task is cancelled, after stopping any underlying work.
    func respond(
        to request: BrainRequest,
        onTextDelta: @escaping @MainActor (String) -> Void
    ) async throws -> BrainResponse
}

enum BrainConfiguration {
    /// Used only if the Info.plist key is missing.
    private static let fallbackModelValue = "claude-sonnet-5-5"
    private static let modelEnvironmentVariableName = "CLICKY_BRAIN_MODEL"

    /// The one value that selects the Brain, read from `BrainModel` in
    /// Info.plist and overridable without a rebuild by CLICKY_BRAIN_MODEL.
    ///   claude-sonnet-5-5  -> claude CLI with that model (any claude-* id)
    ///   codex              -> codex CLI with its default model
    ///   codex:<model>      -> codex CLI with that model
    ///   ollama:<model>     -> local ollama server with that model
    static var configuredModelValue: String {
        if let environmentValue = ProcessInfo.processInfo.environment[modelEnvironmentVariableName],
           !environmentValue.isEmpty {
            return environmentValue
        }
        return AppBundleConfiguration.stringValue(forKey: "BrainModel") ?? fallbackModelValue
    }

    static func makeBrain(modelValue: String) -> any Brain {
        if modelValue == "codex" {
            return CodexCLIBrain(modelIdentifier: nil)
        }
        if modelValue.hasPrefix("codex:") {
            return CodexCLIBrain(modelIdentifier: String(modelValue.dropFirst("codex:".count)))
        }
        if modelValue.hasPrefix("ollama:") {
            return OllamaBrain(modelIdentifier: String(modelValue.dropFirst("ollama:".count)))
        }
        return ClaudeCLIBrain(modelIdentifier: modelValue)
    }
}
