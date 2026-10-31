//
//  SayTTSClient.swift
//  leanring-buddy
//
//  Text-to-speech through the macOS `say` command. Needs no keys or network.
//  Also defines the seam CompanionManager talks to, which ElevenLabsTTSClient
//  conforms to as well, so a build can swap the voice in one line.
//

import Foundation

@MainActor
protocol CompanionTextToSpeechClient: AnyObject {
    /// True from the moment speech starts until it ends or is stopped.
    var isPlaying: Bool { get }

    /// Starts speaking and returns once playback has begun, not when it ends.
    func speakText(_ text: String) async throws

    /// Stops speech immediately. Safe to call when nothing is playing.
    func stopPlayback()
}

extension ElevenLabsTTSClient: CompanionTextToSpeechClient {}

@MainActor
final class SayTTSClient: CompanionTextToSpeechClient {
    private static let sayExecutableURL = URL(fileURLWithPath: "/usr/bin/say")
    private static let voiceEnvironmentVariableName = "CLICKY_TTS_VOICE"

    /// The only process currently speaking. A new utterance replaces it, so
    /// two voices can never overlap.
    private var speakingProcess: Process?

    /// The voice of the most recent utterance. Nil means the system default.
    private(set) var lastUsedVoiceName: String?

    /// Resolved once per launch. `say -v ?` is slow enough to delay a reply.
    private var resolvedVoiceName: String?

    var isPlaying: Bool {
        speakingProcess?.isRunning ?? false
    }

    func speakText(_ text: String) async throws {
        stopPlayback()

        let voiceName = await bestVoiceName()
        try Task.checkCancellation()
        lastUsedVoiceName = voiceName

        let process = Process()
        process.executableURL = Self.sayExecutableURL
        // `-f -` reads the text from stdin. As an argument, a reply starting
        // with a dash would be parsed as a flag.
        var arguments = ["-f", "-"]
        if let voiceName {
            arguments += ["-v", voiceName]
        }
        process.arguments = arguments

        let standardInputPipe = Pipe()
        process.standardInput = standardInputPipe

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self, self.speakingProcess === terminatedProcess else { return }
                self.speakingProcess = nil
            }
        }

        try process.run()
        speakingProcess = process

        let textData = Data(text.utf8)
        let standardInputHandle = standardInputPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? standardInputHandle.write(contentsOf: textData)
            try? standardInputHandle.close()
        }

        print("🔊 say TTS: speaking \(text.count) characters with voice \(voiceName ?? "system default")")
    }

    func stopPlayback() {
        guard let speakingProcess else { return }
        self.speakingProcess = nil
        if speakingProcess.isRunning {
            speakingProcess.terminate()
        }
    }

    private func bestVoiceName() async -> String? {
        if let environmentVoiceName = ProcessInfo.processInfo.environment[Self.voiceEnvironmentVariableName],
           !environmentVoiceName.isEmpty {
            return environmentVoiceName
        }
        if let resolvedVoiceName {
            return resolvedVoiceName
        }

        let voiceListOutput = await Task.detached(priority: .userInitiated) {
            Self.readInstalledVoiceList()
        }.value

        resolvedVoiceName = Self.chooseBestVoiceName(fromVoiceListOutput: voiceListOutput)
        return resolvedVoiceName
    }

    private nonisolated static func readInstalledVoiceList() -> String {
        let process = Process()
        process.executableURL = sayExecutableURL
        process.arguments = ["-v", "?"]
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe

        guard (try? process.run()) != nil else { return "" }
        let outputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: outputData, as: UTF8.self)
    }

    /// Picks the most natural English voice installed. Premium and Enhanced
    /// voices are optional downloads; Samantha and Daniel ship with macOS and
    /// are the most listenable of the defaults. Returns nil to use the system
    /// default voice if none of these exist.
    nonisolated static func chooseBestVoiceName(fromVoiceListOutput voiceListOutput: String) -> String? {
        let voiceLinePattern = #"^(.+?)\s+([a-z]{2,3}_[A-Z0-9]+)\s+#"#
        guard let voiceLineRegex = try? NSRegularExpression(pattern: voiceLinePattern) else { return nil }

        var englishVoiceNames: [String] = []
        for voiceLine in voiceListOutput.split(separator: "\n").map(String.init) {
            let fullLineRange = NSRange(voiceLine.startIndex..., in: voiceLine)
            guard let match = voiceLineRegex.firstMatch(in: voiceLine, range: fullLineRange),
                  let nameRange = Range(match.range(at: 1), in: voiceLine),
                  let localeRange = Range(match.range(at: 2), in: voiceLine),
                  voiceLine[localeRange].hasPrefix("en_") else {
                continue
            }
            englishVoiceNames.append(String(voiceLine[nameRange]))
        }

        let qualityTiers = ["(Premium)", "(Enhanced)"]
        for qualityTier in qualityTiers {
            if let voiceName = englishVoiceNames.first(where: { $0.contains(qualityTier) }) {
                return voiceName
            }
        }

        let preferredBuiltInVoiceNames = ["Samantha", "Daniel", "Karen", "Moira", "Tessa"]
        return preferredBuiltInVoiceNames.first(where: englishVoiceNames.contains)
    }
}
