//
//  FollowAlongTutorialImporter.swift
//  leanring-buddy
//
//  Turns a YouTube link into a saved lesson. It runs once per video:
//
//    1. yt-dlp fetches metadata, the transcript and a small copy of the video.
//    2. The transcript goes to the Brain as text, which is cheap, and comes back
//       as draft steps plus the moment in the video where each step is visible.
//    3. ffmpeg pulls only those moments out as key frames.
//    4. The Brain sees those frames and writes the final lesson.
//
//  Reading the transcript first means the model only sees frames that matter,
//  rather than a frame every few seconds of someone talking over a slide.
//
//  The downloaded video stays in Application Support, is only read locally,
//  and is never republished by anything in this app.
//

import Foundation

struct FollowAlongImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum FollowAlongImportProgress {
    case readingVideoDetails
    case readingTranscript
    case downloadingVideo
    case planningSteps
    case extractingKeyFrames
    case writingLesson

    /// Shown in the paste surface, so it follows the product's lowercase voice.
    var statusText: String {
        switch self {
        case .readingVideoDetails: return "finding the video"
        case .readingTranscript: return "reading the transcript"
        case .downloadingVideo: return "grabbing a small copy to look at"
        case .planningSteps: return "working out the steps"
        case .extractingKeyFrames: return "pulling the key frames"
        case .writingLesson: return "writing your lesson"
        }
    }
}

// MARK: - External Tools

/// Runs yt-dlp and ffmpeg to completion. Output goes to temporary files instead
/// of pipes because yt-dlp's JSON can outgrow a pipe buffer and stall the tool.
private enum FollowAlongToolRunner {
    struct Result {
        let exitStatus: Int32
        let standardOutput: Data
        let standardErrorText: String
    }

    static func run(executableURL: URL, arguments: [String], timeoutInSeconds: TimeInterval) async throws -> Result {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let standardOutputURL = temporaryDirectoryURL.appendingPathComponent("stdout")
        let standardErrorURL = temporaryDirectoryURL.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        process.standardError = try FileHandle(forWritingTo: standardErrorURL)
        process.standardInput = FileHandle.nullDevice

        // Apps launched through `open` get a minimal PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        let exitStatus: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { terminatedProcess in
                    continuation.resume(returning: terminatedProcess.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutInSeconds) {
                    if process.isRunning {
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }

        try Task.checkCancellation()

        return Result(
            exitStatus: exitStatus,
            standardOutput: (try? Data(contentsOf: standardOutputURL)) ?? Data(),
            standardErrorText: (try? String(contentsOf: standardErrorURL, encoding: .utf8)) ?? ""
        )
    }

    /// Finds a tool by absolute path because GUI apps don't inherit the shell's
    /// PATH. `scripts/demo-follow-along.sh` installs yt-dlp into the private venv.
    static func locateExecutable(named executableName: String, candidatePaths: [String]) throws -> URL {
        guard let executablePath = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FollowAlongImportError(message: "\(executableName) not found. Looked in: \(candidatePaths.joined(separator: ", ")). Run scripts/demo-follow-along.sh --setup-only to install it.")
        }
        return URL(fileURLWithPath: executablePath)
    }

    static var youTubeDownloaderURL: URL {
        get throws {
            let privateEnvironmentPath = FollowAlongStorage.rootDirectoryURL
                .appendingPathComponent("tools/ytdlp-venv/bin/yt-dlp").path
            let overridePath = ProcessInfo.processInfo.environment["CLICKY_YT_DLP"]
            return try locateExecutable(
                named: "yt-dlp",
                candidatePaths: [overridePath, privateEnvironmentPath, "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"].compactMap { $0 }
            )
        }
    }

    static var mediaConverterURL: URL {
        get throws {
            try locateExecutable(named: "ffmpeg", candidatePaths: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        }
    }
}

// MARK: - Transcript

struct FollowAlongTranscriptSegment {
    let startInSeconds: Double
    let text: String
}

enum FollowAlongTranscriptParser {
    /// Reads YouTube's json3 caption format.
    static func segments(fromJSON3Data json3Data: Data) -> [FollowAlongTranscriptSegment] {
        guard let root = (try? JSONSerialization.jsonObject(with: json3Data)) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else {
            return []
        }

        return events.compactMap { event in
            guard let startInMilliseconds = event["tStartMs"] as? Double ?? (event["tStartMs"] as? Int).map(Double.init),
                  let textPieces = event["segs"] as? [[String: Any]] else {
                return nil
            }
            let text = textPieces
                .compactMap { $0["utf8"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return FollowAlongTranscriptSegment(startInSeconds: startInMilliseconds / 1000, text: text)
        }
    }

    static func timestampedText(from segments: [FollowAlongTranscriptSegment]) -> String {
        segments
            .map { "[\(Int($0.startInSeconds))s] \($0.text)" }
            .joined(separator: "\n")
    }
}

// MARK: - Model Output Shapes

/// The planning models answer in snake_case JSON. Parsed into these, then
/// copied into the camelCase types that are saved to disk.
private struct DraftLesson: Decodable {
    struct DraftStep: Decodable {
        let id: String
        let title: String
        let spokenLine: String
        let goal: String
        let targetDescription: String
        let dragDestinationDescription: String?
        let videoInterfaceDescription: String?
        let visualSuccessCheck: String
        let successLine: String
        let actionKind: FollowAlongActionKind
        let keyToPress: String?
        let valueToType: String?
        let keyMomentSeconds: Double
    }

    let applicationName: String
    let applicationVersionInVideo: String
    let lessonTitle: String
    let whatYouWillLearn: [String]
    let steps: [DraftStep]
}

enum FollowAlongJSONExtraction {
    /// Models occasionally wrap JSON in a code fence or a sentence, so this
    /// takes everything between the first opening and last closing brace.
    static func jsonObjectData(from responseText: String) -> Data? {
        guard let firstBraceIndex = responseText.firstIndex(of: "{"),
              let lastBraceIndex = responseText.lastIndex(of: "}"),
              firstBraceIndex < lastBraceIndex else {
            return nil
        }
        return String(responseText[firstBraceIndex...lastBraceIndex]).data(using: .utf8)
    }
}

// MARK: - Importer

@MainActor
final class FollowAlongTutorialImporter {
    private static let maximumSteps = 10
    private static let youTubeDownloadTimeoutInSeconds: TimeInterval = 300
    private static let frameExtractionTimeoutInSeconds: TimeInterval = 30
    private static let keyFrameWidthInPixels = 960
    /// Subtitle endpoints rate limit quickly, and a retry after a short wait
    /// almost always succeeds.
    private static let subtitleFetchAttempts = 3
    private static let subtitleRetryDelayInSeconds: UInt64 = 8

    private static let draftingSystemPrompt = """
    you turn a software tutorial into a hands-on lesson for a complete beginner. they will not watch the video. they will do the lesson inside the real app on their own computer, while a small blue cursor points at things and a voice talks them through it. they may have a much newer version of the app than the video.

    you get the video's title and its transcript with timestamps. reply with one json object and nothing else, shaped like this:

    {
      "application_name": "the app being taught",
      "application_version_in_video": "the version the video uses, from its title if it says",
      "lesson_title": "short lowercase title",
      "what_you_will_learn": ["three short lowercase outcomes, in plain words"],
      "steps": [
        {
          "id": "step-1",
          "title": "two to four word lowercase title",
          "spoken_line": "what the voice says",
          "goal": "the outcome of this step, worded so it still makes sense if the button has moved or been renamed",
          "target_description": "the one control to point at, with the words and position the video gives it",
          "drag_destination_description": "where a drag ends, or null",
          "visual_success_check": "what a screenshot must show for this step to count as done",
          "success_line": "two to six words, said when they get it",
          "action_kind": "click, drag, press_key, type_value or look",
          "key_to_press": "the key, or null",
          "value_to_type": "the value to type, or null",
          "key_moment_seconds": 42
        }
      ]
    }

    rules for the steps:
    - keep only what the viewer physically does. skip theory, history and asides. the voice can carry one short line of why.
    - between four and \(maximumSteps) steps. pick the ones that make something visibly happen on screen.
    - keep every setting the video changes on screen, such as a dropdown it switches or a value it edits, even if it's mentioned in passing. these are the steps most likely to differ in a newer version, and the viewer needs them most.
    - one step is one physical action: one click, one drag, one key, or one typed value. opening a menu, opening a submenu, picking an entry, and placing what you picked are all separate steps.
    - some apps leave a newly added item stuck to the mouse until a click drops it, and the next step can't work until then. when the app being taught does that, dropping the item is its own click step, right after picking it. its target is an empty area with room for the item, and its visual_success_check must say the item sits still in an empty area with no move in progress.
    - action_kind describes that one action. anything the viewer has to click is "click", including getting to a starting point. use "look" only when they do nothing at all.
    - when the video assumes a starting point it never shows, such as being in the right workspace, add that as a first step.
    - key_moment_seconds is the moment in the video where the control or its result is most clearly on screen. it must fall inside the video.
    - visual_success_check describes the result, not the click. it must be judgeable from one still screenshot of the whole screen, and it must not name a control, socket or label that a newer version might have renamed. "the cube shows a pattern of flat coloured cells" is good. "the dropdown says cells" is not.
    - write spoken_line for the ear: lowercase, warm, casual, one or two short sentences, in your own words. never copy the transcript. never say "simply" or "just". no markdown.
    - success_line is warm and specific, lowercase, no exclamation spam.
    """

    private static let refiningSystemPrompt = """
    you are finishing a hands-on lesson for a complete beginner, built from a software tutorial. you get draft steps as json, plus the key frame from the video for each step.

    reply with one json object and nothing else, with the same shape as the draft, adding one field to every step:

      "video_interface_description": "exactly what the video's frame shows for this step: the control's name, its look, where it sits on screen, and any values or dropdowns visible"

    while you are there, fix the draft against what the frames really show:
    - correct target_description so it matches the frame. it should say what to look for, not only a name.
    - correct key_moment_seconds only if the frame clearly shows the wrong moment. otherwise leave it alone.
    - keep the same step ids and the same order. keep the lowercase voice. keep visual_success_check about the result, not the control.

    the frames come from an old video and are not the user's screen. describe what is in them honestly and do not guess about newer versions.
    """

    private let brain: any Brain
    private let modelValue: String
    private let onProgress: (FollowAlongImportProgress) -> Void

    init(modelValue: String, onProgress: @escaping (FollowAlongImportProgress) -> Void) {
        self.brain = BrainConfiguration.makeBrain(modelValue: modelValue)
        self.modelValue = modelValue
        self.onProgress = onProgress
    }

    /// Returns the saved lesson without touching the network or a model when
    /// one exists. Otherwise builds and saves it.
    func loadOrBuildLesson(videoIdentifier: String) async throws -> (lesson: FollowAlongLesson, wasBuiltNow: Bool) {
        if let cachedLesson = FollowAlongStorage.loadCachedLesson(videoIdentifier: videoIdentifier) {
            return (cachedLesson, false)
        }
        return (try await buildLesson(videoIdentifier: videoIdentifier), true)
    }

    private func buildLesson(videoIdentifier: String) async throws -> FollowAlongLesson {
        let videoURL = FollowAlongYouTubeLink.canonicalURL(videoIdentifier: videoIdentifier)
        let downloadDirectoryURL = FollowAlongStorage.downloadDirectoryURL(videoIdentifier: videoIdentifier)
        try FileManager.default.createDirectory(at: downloadDirectoryURL, withIntermediateDirectories: true)

        onProgress(.readingVideoDetails)
        let source = try await fetchVideoDetails(videoIdentifier: videoIdentifier, videoURL: videoURL, downloadDirectoryURL: downloadDirectoryURL)

        onProgress(.readingTranscript)
        let transcriptSegments = try await fetchTranscript(videoURL: videoURL, downloadDirectoryURL: downloadDirectoryURL)

        var recordedBrainCalls: [FollowAlongRecordedBrainCall] = []

        onProgress(.planningSteps)
        let draftResponse = try await askBrainForDraft(
            userPrompt: """
            video title: \(source.title)
            channel: \(source.channelName)
            uploaded: \(source.uploadDate)
            length: \(Int(source.durationInSeconds)) seconds

            transcript:
            \(FollowAlongTranscriptParser.timestampedText(from: transcriptSegments))
            """,
            systemPrompt: Self.draftingSystemPrompt,
            images: [],
            purpose: .planTranscript,
            recordedBrainCalls: &recordedBrainCalls
        )

        onProgress(.downloadingVideo)
        let videoFileURL = try await downloadVideo(videoURL: videoURL, downloadDirectoryURL: downloadDirectoryURL)

        onProgress(.extractingKeyFrames)
        let keyFrameDirectoryURL = FollowAlongStorage.keyFrameDirectoryURL(videoIdentifier: videoIdentifier)
        try FileManager.default.createDirectory(at: keyFrameDirectoryURL, withIntermediateDirectories: true)

        var keyFrameImages: [BrainImage] = []
        for draftStep in draftResponse.draftLesson.steps {
            let keyFrameURL = keyFrameDirectoryURL.appendingPathComponent("\(draftStep.id).jpg")
            try await extractKeyFrame(
                from: videoFileURL,
                atSeconds: min(draftStep.keyMomentSeconds, max(0, source.durationInSeconds - 1)),
                to: keyFrameURL
            )
            keyFrameImages.append(BrainImage(
                imageData: try Data(contentsOf: keyFrameURL),
                label: "key frame for \(draftStep.id), at \(Int(draftStep.keyMomentSeconds))s in the video"
            ))
        }

        onProgress(.writingLesson)
        let refinedResponse = try await askBrainForDraft(
            userPrompt: "draft steps:\n\(draftResponse.rawJSONText)\n\nfinish this lesson. reply with json only.",
            systemPrompt: Self.refiningSystemPrompt,
            images: keyFrameImages,
            purpose: .planKeyFrames,
            recordedBrainCalls: &recordedBrainCalls
        )

        let refinedDraft = refinedResponse.draftLesson
        let lesson = FollowAlongLesson(
            schemaVersion: FollowAlongLesson.currentSchemaVersion,
            source: source,
            applicationName: refinedDraft.applicationName,
            applicationVersionInVideo: refinedDraft.applicationVersionInVideo,
            lessonTitle: refinedDraft.lessonTitle,
            whatYouWillLearn: refinedDraft.whatYouWillLearn,
            steps: refinedDraft.steps.map { refinedStep in
                let keyFrameFileName = "\(refinedStep.id).jpg"
                let keyFrameExists = FileManager.default.fileExists(
                    atPath: keyFrameDirectoryURL.appendingPathComponent(keyFrameFileName).path
                )
                return FollowAlongLessonStep(
                    id: refinedStep.id,
                    title: refinedStep.title,
                    spokenLine: refinedStep.spokenLine,
                    goal: refinedStep.goal,
                    targetDescription: refinedStep.targetDescription,
                    dragDestinationDescription: refinedStep.dragDestinationDescription,
                    videoInterfaceDescription: refinedStep.videoInterfaceDescription ?? refinedStep.targetDescription,
                    visualSuccessCheck: refinedStep.visualSuccessCheck,
                    successLine: refinedStep.successLine,
                    actionKind: refinedStep.actionKind,
                    keyToPress: refinedStep.keyToPress,
                    valueToType: refinedStep.valueToType,
                    videoTimestampInSeconds: refinedStep.keyMomentSeconds,
                    keyFrameFileName: keyFrameExists ? keyFrameFileName : nil
                )
            },
            generation: FollowAlongLessonGeneration(
                generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
                modelValue: modelValue,
                brainCalls: recordedBrainCalls
            )
        )

        try FollowAlongStorage.save(lesson: lesson)
        return lesson
    }

    // MARK: Downloading

    private func downloaderArguments() -> [String] {
        var arguments = ["--no-playlist", "--no-warnings", "--no-progress"]
        // yt-dlp needs a JavaScript runtime to see every format, and it only
        // looks for deno unless told otherwise.
        for nodePath in ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        where FileManager.default.isExecutableFile(atPath: nodePath) {
            arguments += ["--js-runtimes", "node:\(nodePath)"]
            break
        }
        return arguments
    }

    private func fetchVideoDetails(
        videoIdentifier: String,
        videoURL: String,
        downloadDirectoryURL: URL
    ) async throws -> FollowAlongLessonSource {
        let result = try await FollowAlongToolRunner.run(
            executableURL: try FollowAlongToolRunner.youTubeDownloaderURL,
            arguments: downloaderArguments() + ["--dump-single-json", "--skip-download", "--", videoURL],
            timeoutInSeconds: Self.youTubeDownloadTimeoutInSeconds
        )

        guard result.exitStatus == 0,
              let details = (try? JSONSerialization.jsonObject(with: result.standardOutput)) as? [String: Any] else {
            throw FollowAlongImportError(message: "couldn't read that video: \(Self.lastLine(of: result.standardErrorText))")
        }

        return FollowAlongLessonSource(
            videoIdentifier: videoIdentifier,
            videoURL: videoURL,
            title: details["title"] as? String ?? "untitled tutorial",
            channelName: details["channel"] as? String ?? details["uploader"] as? String ?? "unknown channel",
            licenseDescription: details["license"] as? String ?? "standard YouTube licence (none declared)",
            uploadDate: details["upload_date"] as? String ?? "unknown",
            durationInSeconds: details["duration"] as? Double ?? (details["duration"] as? Int).map(Double.init) ?? 0
        )
    }

    private func fetchTranscript(videoURL: String, downloadDirectoryURL: URL) async throws -> [FollowAlongTranscriptSegment] {
        var lastFailureText = "no captions available"

        for attemptNumber in 1...Self.subtitleFetchAttempts {
            if attemptNumber > 1 {
                try await Task.sleep(nanoseconds: Self.subtitleRetryDelayInSeconds * 1_000_000_000)
            }

            let result = try await FollowAlongToolRunner.run(
                executableURL: try FollowAlongToolRunner.youTubeDownloaderURL,
                arguments: downloaderArguments() + [
                    "--skip-download", "--write-subs", "--write-auto-subs",
                    "--sub-langs", "en-orig,en,en-US,en-GB",
                    "--sub-format", "json3",
                    "--ignore-errors",
                    "--output", downloadDirectoryURL.appendingPathComponent("transcript").path,
                    "--", videoURL
                ],
                timeoutInSeconds: Self.youTubeDownloadTimeoutInSeconds
            )
            lastFailureText = Self.lastLine(of: result.standardErrorText)

            // --ignore-errors means one blocked language can still leave a usable file.
            let transcriptFileURLs = (try? FileManager.default.contentsOfDirectory(at: downloadDirectoryURL, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasSuffix(".json3") } ?? []

            for transcriptFileURL in transcriptFileURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let transcriptData = try? Data(contentsOf: transcriptFileURL) else { continue }
                let segments = FollowAlongTranscriptParser.segments(fromJSON3Data: transcriptData)
                if !segments.isEmpty {
                    return segments
                }
            }
        }

        throw FollowAlongImportError(message: "this video has no english transcript i can read: \(lastFailureText)")
    }

    private func downloadVideo(videoURL: String, downloadDirectoryURL: URL) async throws -> URL {
        let videoFileURL = downloadDirectoryURL.appendingPathComponent("video.mp4")
        if FileManager.default.fileExists(atPath: videoFileURL.path) {
            return videoFileURL
        }

        let result = try await FollowAlongToolRunner.run(
            executableURL: try FollowAlongToolRunner.youTubeDownloaderURL,
            arguments: downloaderArguments() + [
                // Video only: the transcript already carries the words.
                "--format", "bv*[height<=720][ext=mp4]/b[height<=720][ext=mp4]/b",
                "--output", videoFileURL.path,
                "--", videoURL
            ],
            timeoutInSeconds: Self.youTubeDownloadTimeoutInSeconds
        )

        guard result.exitStatus == 0, FileManager.default.fileExists(atPath: videoFileURL.path) else {
            throw FollowAlongImportError(message: "couldn't download the video: \(Self.lastLine(of: result.standardErrorText))")
        }
        return videoFileURL
    }

    private func extractKeyFrame(from videoFileURL: URL, atSeconds seconds: Double, to outputURL: URL) async throws {
        let result = try await FollowAlongToolRunner.run(
            executableURL: try FollowAlongToolRunner.mediaConverterURL,
            arguments: [
                "-y", "-loglevel", "error",
                "-ss", String(format: "%.2f", seconds),
                "-i", videoFileURL.path,
                "-frames:v", "1",
                "-vf", "scale=\(Self.keyFrameWidthInPixels):-2",
                "-q:v", "3",
                outputURL.path
            ],
            timeoutInSeconds: Self.frameExtractionTimeoutInSeconds
        )

        guard result.exitStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            throw FollowAlongImportError(message: "couldn't pull a frame at \(Int(seconds))s: \(Self.lastLine(of: result.standardErrorText))")
        }
    }

    private static func lastLine(of text: String) -> String {
        text.split(separator: "\n").last.map(String.init) ?? "no details"
    }

    // MARK: Asking the Brain

    private struct DraftResponse {
        let draftLesson: DraftLesson
        let rawJSONText: String
    }

    /// Retries once on malformed JSON. Every attempt is recorded, including a
    /// failed one, because it was paid for either way.
    private func askBrainForDraft(
        userPrompt: String,
        systemPrompt: String,
        images: [BrainImage],
        purpose: FollowAlongBrainCallPurpose,
        recordedBrainCalls: inout [FollowAlongRecordedBrainCall]
    ) async throws -> DraftResponse {
        var lastProblemDescription = ""

        for _ in 1...2 {
            let retryNote = lastProblemDescription.isEmpty
                ? ""
                : "\n\nyour last reply could not be used (\(lastProblemDescription)). reply with the json object only."

            let brainResponse = try await brain.respond(
                to: BrainRequest(
                    systemPrompt: systemPrompt,
                    conversationHistory: [],
                    userPrompt: userPrompt + retryNote,
                    images: images
                ),
                onTextDelta: { _ in }
            )
            recordedBrainCalls.append(FollowAlongRecordedBrainCall(purpose: purpose.rawValue, usage: brainResponse.usage))

            guard let jsonData = FollowAlongJSONExtraction.jsonObjectData(from: brainResponse.text) else {
                lastProblemDescription = "it contained no json object"
                continue
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            do {
                let draftLesson = try decoder.decode(DraftLesson.self, from: jsonData)
                guard !draftLesson.steps.isEmpty else {
                    lastProblemDescription = "it had no steps"
                    continue
                }
                return DraftResponse(
                    draftLesson: draftLesson,
                    rawJSONText: String(decoding: jsonData, as: UTF8.self)
                )
            } catch {
                lastProblemDescription = String(describing: error).prefix(300).description
            }
        }

        throw FollowAlongImportError(message: "the lesson plan came back unusable: \(lastProblemDescription)")
    }
}
