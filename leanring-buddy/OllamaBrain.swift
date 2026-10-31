//
//  OllamaBrain.swift
//  leanring-buddy
//
//  A Brain that runs on this Mac. It talks to the local ollama server, so with
//  this selected the screenshot never leaves the machine. The URL is hard-coded
//  to the loopback address on purpose: a configurable host could quietly turn
//  "local" into "someone else's server".
//

import Foundation

struct OllamaBrain: Brain {
    let modelIdentifier: String

    var displayName: String { "ollama (\(modelIdentifier))" }
    var screenshotDestinationName: String { "this mac" }

    private static let chatEndpointURL = URL(string: "http://127.0.0.1:11434/api/chat")!
    /// A large vision model can take a while to load the first time.
    private static let timeoutInSeconds: TimeInterval = 240
    /// Keeps the model loaded between requests so a second offer is quick.
    private static let keepModelLoadedDuration = "15m"
    private static let maximumReplyTokens = 400

    /// Ephemeral so no response or image can end up in a URL cache on disk.
    private static let urlSession: URLSession = {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = timeoutInSeconds
        sessionConfiguration.timeoutIntervalForResource = timeoutInSeconds
        return URLSession(configuration: sessionConfiguration)
    }()

    func respond(
        to request: BrainRequest,
        onTextDelta: @escaping @MainActor (String) -> Void
    ) async throws -> BrainResponse {
        var urlRequest = URLRequest(url: Self.chatEndpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try makeRequestBody(for: request)

        let startDate = Date()
        var firstTextDate: Date?
        var replyText = ""
        var finalEvent: [String: Any]?

        let bytes: URLSession.AsyncBytes
        let urlResponse: URLResponse
        do {
            (bytes, urlResponse) = try await Self.urlSession.bytes(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw BrainError(message: "couldn't reach ollama at 127.0.0.1:11434. Is it running? \(error.localizedDescription)")
        }

        if let httpResponse = urlResponse as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw BrainError(message: "ollama returned HTTP \(httpResponse.statusCode) for \(modelIdentifier). Does this model accept images?")
        }

        for try await responseLine in bytes.lines {
            try Task.checkCancellation()

            guard let lineData = responseLine.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                continue
            }

            if let errorMessage = event["error"] as? String {
                throw BrainError(message: "ollama reported an error: \(errorMessage)")
            }

            if let message = event["message"] as? [String: Any],
               let textDelta = message["content"] as? String,
               !textDelta.isEmpty {
                if firstTextDate == nil {
                    firstTextDate = Date()
                }
                replyText += textDelta
                await onTextDelta(textDelta)
            }

            if event["done"] as? Bool == true {
                finalEvent = event
            }
        }

        guard !replyText.isEmpty else {
            throw BrainError(message: "ollama returned no reply from \(modelIdentifier)")
        }

        return BrainResponse(
            text: replyText,
            usage: BrainUsage(
                backendName: "ollama",
                modelIdentifier: modelIdentifier,
                inputTokens: finalEvent?["prompt_eval_count"] as? Int,
                outputTokens: finalEvent?["eval_count"] as? Int,
                cacheReadInputTokens: nil,
                cacheCreationInputTokens: nil,
                costInUSD: nil,
                isCostEstimated: false,
                costSourceDescription: "local model, no per-call price",
                timeToFirstTextInSeconds: firstTextDate.map { $0.timeIntervalSince(startDate) },
                totalDurationInSeconds: Date().timeIntervalSince(startDate)
            )
        )
    }

    private func makeRequestBody(for request: BrainRequest) throws -> Data {
        var userTextSections = request.images.map(\.label)
        if let conversationContextText = BrainPromptFormatting.conversationContextText(from: request.conversationHistory) {
            userTextSections.append(conversationContextText)
        }
        userTextSections.append(request.userPrompt)

        let requestBody: [String: Any] = [
            "model": modelIdentifier,
            "stream": true,
            // These are thinking models. A voice reply wants the answer, and
            // reasoning output would land in the spoken text.
            "think": false,
            "keep_alive": Self.keepModelLoadedDuration,
            "options": [
                "temperature": 0.2,
                "num_predict": Self.maximumReplyTokens
            ],
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                [
                    "role": "user",
                    "content": userTextSections.joined(separator: "\n\n"),
                    "images": request.images.map { $0.imageData.base64EncodedString() }
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: requestBody)
    }
}
