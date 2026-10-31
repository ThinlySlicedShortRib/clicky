//
//  CLIBrains.swift
//  leanring-buddy
//
//  Brain implementations that shell out to an already logged-in CLI, so the
//  app needs no API keys of its own. Only the normal CLI interface is used;
//  nothing here reads a CLI's credentials or config.
//

import Foundation

// MARK: - CLI Process Runner

/// Runs a CLI, feeds it stdin, and delivers stdout one line at a time.
private final class CLIProcessRun: @unchecked Sendable {
    private let process = Process()
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
    private let standardInputPipe = Pipe()

    private let lock = NSLock()
    private var bufferedStandardOutput = Data()
    private var collectedStandardError = Data()
    private var hasFinished = false

    private static let maximumStandardErrorBytesKept = 8_192

    init(executableURL: URL, arguments: [String], workingDirectoryURL: URL) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectoryURL
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.standardInput = standardInputPipe

        // Apps launched from Finder or `open` get a minimal PATH, and CLIs
        // installed through node or homebrew need theirs to find helpers.
        var environment = ProcessInfo.processInfo.environment
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let extraSearchPaths = ["\(homeDirectoryPath)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extraSearchPaths + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
    }

    /// Launches the process and streams its lines until it exits. Returns the
    /// exit status. Terminates the process if the surrounding task is
    /// cancelled or `timeoutInSeconds` passes.
    func run(
        standardInputData: Data?,
        timeoutInSeconds: TimeInterval,
        onStandardOutputLine: @escaping @Sendable (Data) -> Void
    ) async throws -> Int32 {
        try Task.checkCancellation()

        let exitStatus: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
                    self?.receiveStandardOutput(fileHandle.availableData, onStandardOutputLine: onStandardOutputLine)
                }
                standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
                    self?.receiveStandardError(fileHandle.availableData)
                }

                process.terminationHandler = { [weak self] terminatedProcess in
                    self?.finishReadingAfterExit(onStandardOutputLine: onStandardOutputLine)
                    continuation.resume(returning: terminatedProcess.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    clearReadabilityHandlers()
                    continuation.resume(throwing: error)
                    return
                }

                writeStandardInput(standardInputData)
                scheduleTimeout(afterSeconds: timeoutInSeconds)
            }
        } onCancel: {
            self.terminate()
        }

        try Task.checkCancellation()
        return exitStatus
    }

    var standardErrorText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collectedStandardError, as: UTF8.self)
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// Image payloads are megabytes of base64, larger than a pipe buffer, so
    /// the write happens off the caller's thread while stdout is being read.
    private func writeStandardInput(_ standardInputData: Data?) {
        let standardInputHandle = standardInputPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            if let standardInputData {
                // A CLI that exits early breaks the pipe. Its exit status and
                // stderr explain why, so the write error adds nothing.
                try? standardInputHandle.write(contentsOf: standardInputData)
            }
            try? standardInputHandle.close()
        }
    }

    private func scheduleTimeout(afterSeconds timeoutInSeconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutInSeconds) { [weak self] in
            self?.terminate()
        }
    }

    private func receiveStandardOutput(_ newData: Data, onStandardOutputLine: (Data) -> Void) {
        guard !newData.isEmpty else { return }

        lock.lock()
        bufferedStandardOutput.append(newData)
        var completeLines: [Data] = []
        while let newlineIndex = bufferedStandardOutput.firstIndex(of: 0x0A) {
            completeLines.append(Data(bufferedStandardOutput[bufferedStandardOutput.startIndex..<newlineIndex]))
            bufferedStandardOutput.removeSubrange(bufferedStandardOutput.startIndex...newlineIndex)
        }
        lock.unlock()

        completeLines.forEach(onStandardOutputLine)
    }

    private func receiveStandardError(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        collectedStandardError.append(newData)
        if collectedStandardError.count > Self.maximumStandardErrorBytesKept {
            collectedStandardError = Data(collectedStandardError.suffix(Self.maximumStandardErrorBytesKept))
        }
        lock.unlock()
    }

    /// The readability handler can lag the exit, so whatever is left in the
    /// pipes has to be drained here or the final event would be lost.
    private func finishReadingAfterExit(onStandardOutputLine: (Data) -> Void) {
        lock.lock()
        let alreadyFinished = hasFinished
        hasFinished = true
        lock.unlock()
        guard !alreadyFinished else { return }

        clearReadabilityHandlers()
        receiveStandardOutput(standardOutputPipe.fileHandleForReading.readDataToEndOfFile(), onStandardOutputLine: onStandardOutputLine)
        receiveStandardError(standardErrorPipe.fileHandleForReading.readDataToEndOfFile())

        lock.lock()
        let trailingLine = bufferedStandardOutput
        bufferedStandardOutput = Data()
        lock.unlock()
        if !trailingLine.isEmpty {
            onStandardOutputLine(trailingLine)
        }
    }

    private func clearReadabilityHandlers() {
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
    }
}

private enum CLILocator {
    /// Finds a CLI by absolute path because GUI apps don't inherit the shell's
    /// PATH. `CLICKY_<NAME>_CLI` overrides the search.
    static func locateExecutable(named executableName: String, overrideEnvironmentVariableName: String) throws -> URL {
        let fileManager = FileManager.default
        let homeDirectoryPath = fileManager.homeDirectoryForCurrentUser.path
        let overridePath = ProcessInfo.processInfo.environment[overrideEnvironmentVariableName]
        let candidatePaths = [overridePath].compactMap { $0 } + [
            "\(homeDirectoryPath)/.local/bin/\(executableName)",
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)"
        ]

        guard let executablePath = candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw BrainError(message: "\(executableName) CLI not found. Looked in: \(candidatePaths.joined(separator: ", ")). Set \(overrideEnvironmentVariableName) to its path.")
        }
        return URL(fileURLWithPath: executablePath)
    }
}

private enum BrainPromptFormatting {
    static func conversationContextText(from conversationHistory: [BrainConversationExchange]) -> String? {
        guard !conversationHistory.isEmpty else { return nil }
        let exchangeLines = conversationHistory.map { exchange in
            "user: \(exchange.userTranscript)\nyou: \(exchange.assistantResponse)"
        }
        return "conversation so far:\n\(exchangeLines.joined(separator: "\n"))"
    }
}

/// Thread-safe holder for state that accumulates as CLI output lines arrive
/// on the pipe's background queue.
private final class BrainStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private let startDate = Date()
    private var firstTextDate: Date?
    private var accumulatedText = ""
    private(set) var parsedResultEvent: [String: Any]?
    private(set) var failureMessage: String?

    func appendText(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        if firstTextDate == nil {
            firstTextDate = Date()
        }
        accumulatedText += text
    }

    func setResultEvent(_ resultEvent: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        parsedResultEvent = resultEvent
    }

    func setFailureMessage(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        failureMessage = message
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedText
    }

    var timeToFirstTextInSeconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return firstTextDate.map { $0.timeIntervalSince(startDate) }
    }

    var elapsedInSeconds: Double {
        Date().timeIntervalSince(startDate)
    }
}

// MARK: - Claude CLI

/// Runs `claude -p` in stream-json mode. Images go inline as base64 content
/// blocks rather than file paths, because a path would make the model spend a
/// tool round trip reading the file before it can start answering.
struct ClaudeCLIBrain: Brain {
    let modelIdentifier: String

    var displayName: String { "claude CLI (\(modelIdentifier))" }

    private static let timeoutInSeconds: TimeInterval = 120

    func respond(
        to request: BrainRequest,
        onTextDelta: @escaping @MainActor (String) -> Void
    ) async throws -> BrainResponse {
        let executableURL = try CLILocator.locateExecutable(named: "claude", overrideEnvironmentVariableName: "CLICKY_CLAUDE_CLI")
        let streamState = BrainStreamState()

        let processRun = CLIProcessRun(
            executableURL: executableURL,
            arguments: makeArguments(systemPrompt: request.systemPrompt),
            // A neutral directory keeps the CLI from loading this repo's
            // CLAUDE.md into a voice assistant's context.
            workingDirectoryURL: FileManager.default.temporaryDirectory
        )

        let exitStatus = try await processRun.run(
            standardInputData: try makeStandardInputData(for: request),
            timeoutInSeconds: Self.timeoutInSeconds
        ) { outputLine in
            Self.handleOutputLine(outputLine, streamState: streamState, onTextDelta: onTextDelta)
        }

        guard let resultEvent = streamState.parsedResultEvent else {
            let standardErrorText = processRun.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrainError(message: "claude CLI exited with status \(exitStatus) and no result. \(standardErrorText)")
        }

        let resultText = resultEvent["result"] as? String
        if resultEvent["is_error"] as? Bool == true {
            throw BrainError(message: "claude CLI reported an error: \(resultText ?? "no details")")
        }

        return BrainResponse(
            text: resultText ?? streamState.text,
            usage: makeUsage(from: resultEvent, streamState: streamState)
        )
    }

    private func makeArguments(systemPrompt: String) -> [String] {
        [
            "-p",
            "--model", modelIdentifier,
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--system-prompt", systemPrompt,
            // No tools, MCP servers, or user settings: a voice reply should
            // be one model turn, and each of these adds startup time.
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--no-session-persistence"
        ]
    }

    private func makeStandardInputData(for request: BrainRequest) throws -> Data {
        var contentBlocks: [[String: Any]] = []

        for image in request.images {
            contentBlocks.append(["type": "text", "text": image.label])
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.imageData.base64EncodedString()
                ]
            ])
        }

        if let conversationContextText = BrainPromptFormatting.conversationContextText(from: request.conversationHistory) {
            contentBlocks.append(["type": "text", "text": conversationContextText])
        }
        contentBlocks.append(["type": "text", "text": request.userPrompt])

        let userMessage: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": contentBlocks]
        ]
        var messageData = try JSONSerialization.data(withJSONObject: userMessage)
        messageData.append(0x0A)
        return messageData
    }

    private static func handleOutputLine(
        _ outputLine: Data,
        streamState: BrainStreamState,
        onTextDelta: @escaping @MainActor (String) -> Void
    ) {
        guard let event = (try? JSONSerialization.jsonObject(with: outputLine)) as? [String: Any],
              let eventType = event["type"] as? String else {
            return
        }

        if eventType == "result" {
            streamState.setResultEvent(event)
            return
        }

        guard eventType == "stream_event",
              let streamEvent = event["event"] as? [String: Any],
              let delta = streamEvent["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let textDelta = delta["text"] as? String else {
            return
        }

        streamState.appendText(textDelta)
        Task { @MainActor in
            onTextDelta(textDelta)
        }
    }

    private func makeUsage(from resultEvent: [String: Any], streamState: BrainStreamState) -> BrainUsage {
        let reportedUsage = resultEvent["usage"] as? [String: Any]

        return BrainUsage(
            backendName: "claude CLI",
            modelIdentifier: modelIdentifier,
            inputTokens: reportedUsage?["input_tokens"] as? Int,
            outputTokens: reportedUsage?["output_tokens"] as? Int,
            cacheReadInputTokens: reportedUsage?["cache_read_input_tokens"] as? Int,
            cacheCreationInputTokens: reportedUsage?["cache_creation_input_tokens"] as? Int,
            costInUSD: resultEvent["total_cost_usd"] as? Double,
            // The CLI prices tokens at list rates on the client. It is not a
            // billed amount, and a logged-in subscription may not be charged
            // per token at all.
            isCostEstimated: true,
            costSourceDescription: "claude CLI total_cost_usd: list-price estimate, not a billed amount",
            timeToFirstTextInSeconds: streamState.timeToFirstTextInSeconds,
            totalDurationInSeconds: streamState.elapsedInSeconds
        )
    }
}

// MARK: - Codex CLI

/// Runs `codex exec --json`. Measured slower than the claude CLI and it only
/// emits the finished message, so it's the alternate rather than the default.
struct CodexCLIBrain: Brain {
    /// Nil uses the codex CLI's default model.
    let modelIdentifier: String?

    var displayName: String { "codex CLI (\(modelIdentifier ?? "default model"))" }

    private static let timeoutInSeconds: TimeInterval = 180

    func respond(
        to request: BrainRequest,
        onTextDelta: @escaping @MainActor (String) -> Void
    ) async throws -> BrainResponse {
        let executableURL = try CLILocator.locateExecutable(named: "codex", overrideEnvironmentVariableName: "CLICKY_CODEX_CLI")
        let streamState = BrainStreamState()

        let temporaryImageDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-brain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryImageDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryImageDirectoryURL) }

        let imageFileURLs = try writeImageFiles(from: request.images, into: temporaryImageDirectoryURL)

        let processRun = CLIProcessRun(
            executableURL: executableURL,
            arguments: makeArguments(for: request, imageFileURLs: imageFileURLs, workingDirectoryURL: temporaryImageDirectoryURL),
            workingDirectoryURL: temporaryImageDirectoryURL
        )

        let exitStatus = try await processRun.run(
            standardInputData: nil,
            timeoutInSeconds: Self.timeoutInSeconds
        ) { outputLine in
            Self.handleOutputLine(outputLine, streamState: streamState, onTextDelta: onTextDelta)
        }

        if let failureMessage = streamState.failureMessage {
            throw BrainError(message: "codex CLI reported an error: \(failureMessage)")
        }

        guard exitStatus == 0, !streamState.text.isEmpty else {
            let standardErrorText = processRun.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrainError(message: "codex CLI exited with status \(exitStatus) and no reply. \(String(standardErrorText.suffix(500)))")
        }

        return BrainResponse(text: streamState.text, usage: makeUsage(streamState: streamState))
    }

    private func writeImageFiles(from images: [BrainImage], into directoryURL: URL) throws -> [URL] {
        try images.enumerated().map { imageIndex, image in
            let fileExtension = image.mediaType == "image/png" ? "png" : "jpg"
            let imageFileURL = directoryURL.appendingPathComponent("screen\(imageIndex + 1).\(fileExtension)")
            try image.imageData.write(to: imageFileURL)
            return imageFileURL
        }
    }

    private func makeArguments(for request: BrainRequest, imageFileURLs: [URL], workingDirectoryURL: URL) -> [String] {
        var arguments = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--ephemeral",
            // Skips the user's MCP servers, which cost seconds at startup.
            "--ignore-user-config",
            "--sandbox", "read-only",
            "--cd", workingDirectoryURL.path
        ]
        if let modelIdentifier {
            arguments += ["--model", modelIdentifier]
        }
        for imageFileURL in imageFileURLs {
            arguments += ["--image", imageFileURL.path]
        }
        // `--image` accepts several values, so the separator is what stops it
        // from swallowing the prompt.
        arguments += ["--", makePromptText(for: request)]
        return arguments
    }

    /// codex exec has no system prompt flag, so instructions lead the prompt.
    private func makePromptText(for request: BrainRequest) -> String {
        var promptSections = [request.systemPrompt]
        promptSections.append("do not run any commands. reply with text only.")

        for (imageIndex, image) in request.images.enumerated() {
            promptSections.append("attached image \(imageIndex + 1): \(image.label)")
        }
        if let conversationContextText = BrainPromptFormatting.conversationContextText(from: request.conversationHistory) {
            promptSections.append(conversationContextText)
        }
        promptSections.append("user: \(request.userPrompt)")
        return promptSections.joined(separator: "\n\n")
    }

    private static func handleOutputLine(
        _ outputLine: Data,
        streamState: BrainStreamState,
        onTextDelta: @escaping @MainActor (String) -> Void
    ) {
        guard let event = (try? JSONSerialization.jsonObject(with: outputLine)) as? [String: Any],
              let eventType = event["type"] as? String else {
            return
        }

        switch eventType {
        case "item.completed":
            guard let item = event["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let messageText = item["text"] as? String else {
                return
            }
            streamState.appendText(messageText)
            Task { @MainActor in
                onTextDelta(messageText)
            }
        case "turn.completed":
            streamState.setResultEvent(event)
        case "turn.failed", "error":
            let errorDetails = event["error"] as? [String: Any]
            let failureMessage = errorDetails?["message"] as? String ?? event["message"] as? String ?? "unknown failure"
            streamState.setFailureMessage(failureMessage)
        default:
            break
        }
    }

    private func makeUsage(streamState: BrainStreamState) -> BrainUsage {
        let reportedUsage = streamState.parsedResultEvent?["usage"] as? [String: Any]

        return BrainUsage(
            backendName: "codex CLI",
            modelIdentifier: modelIdentifier ?? "codex default",
            inputTokens: reportedUsage?["input_tokens"] as? Int,
            outputTokens: reportedUsage?["output_tokens"] as? Int,
            cacheReadInputTokens: reportedUsage?["cached_input_tokens"] as? Int,
            cacheCreationInputTokens: reportedUsage?["cache_write_input_tokens"] as? Int,
            costInUSD: nil,
            isCostEstimated: false,
            costSourceDescription: "codex CLI reports tokens only, no cost",
            timeToFirstTextInSeconds: streamState.timeToFirstTextInSeconds,
            totalDurationInSeconds: streamState.elapsedInSeconds
        )
    }
}
