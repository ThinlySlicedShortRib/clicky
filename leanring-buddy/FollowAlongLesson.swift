//
//  FollowAlongLesson.swift
//  leanring-buddy
//
//  The saved form of a Follow Along lesson: what the real pipeline produced
//  from one tutorial video, and where those files live. A lesson is generated
//  once and read back from disk on every later run, which is what keeps the
//  cost of the next person watching the same tutorial near zero.
//

import Foundation

// MARK: - Lesson

struct FollowAlongLessonSource: Codable {
    let videoIdentifier: String
    let videoURL: String
    let title: String
    let channelName: String
    /// YouTube's own licence field, verbatim, so credit requirements are visible.
    let licenseDescription: String
    /// YYYYMMDD, as yt-dlp reports it.
    let uploadDate: String
    let durationInSeconds: Double
}

/// What the viewer physically does in a step. The runner speaks and points the
/// same way for all of these. The value exists so a drag can show both ends.
enum FollowAlongActionKind: String, Codable {
    case click
    case drag
    case pressKey = "press_key"
    case typeValue = "type_value"
    case look
}

struct FollowAlongLessonStep: Codable, Identifiable {
    let id: String
    let title: String
    /// Said aloud when the viewer's UI matches the video.
    let spokenLine: String
    /// The purpose of the step in terms that survive a UI redesign.
    let goal: String
    /// The control to point at, described the way it appears in the video.
    let targetDescription: String
    /// Where a drag ends. Nil for everything but drags.
    let dragDestinationDescription: String?
    /// What the video shows at this moment. This is what the viewer's screen
    /// gets compared against when deciding whether the UI has changed.
    let videoInterfaceDescription: String
    /// What the screen must show for the step to count as done.
    let visualSuccessCheck: String
    /// Said on success, while the next step is being located.
    let successLine: String
    let actionKind: FollowAlongActionKind
    let keyToPress: String?
    let valueToType: String?
    let videoTimestampInSeconds: Double
    /// File inside the lesson's `frames` directory.
    let keyFrameFileName: String?
}

/// One Brain call as it happened, kept so generation cost stays attributable.
struct FollowAlongRecordedBrainCall: Codable {
    let purpose: String
    let usage: BrainUsage
}

struct FollowAlongLessonGeneration: Codable {
    let generatedAtISO8601: String
    let modelValue: String
    let brainCalls: [FollowAlongRecordedBrainCall]

    /// Nil when any call didn't report a cost, because a partial sum would
    /// look like a real total.
    var totalCostInUSD: Double? {
        let costs = brainCalls.map(\.usage.costInUSD)
        guard !costs.isEmpty, !costs.contains(where: { $0 == nil }) else { return nil }
        return costs.compactMap { $0 }.reduce(0, +)
    }
}

struct FollowAlongLesson: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let source: FollowAlongLessonSource
    let applicationName: String
    /// The version the video appears to use, as judged from the title and frames.
    let applicationVersionInVideo: String
    let lessonTitle: String
    let whatYouWillLearn: [String]
    let steps: [FollowAlongLessonStep]
    let generation: FollowAlongLessonGeneration
}

// MARK: - Storage

/// Where Follow Along keeps tools, downloads, lessons and run logs. Everything
/// is under Application Support: nothing a tutorial produces lands in a repo.
enum FollowAlongStorage {
    static var rootDirectoryURL: URL {
        if let overridePath = ProcessInfo.processInfo.environment["CLICKY_FOLLOW_ALONG_HOME"], !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        let applicationSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL.appendingPathComponent("Clicky/follow-along", isDirectory: true)
    }

    static func lessonDirectoryURL(videoIdentifier: String) -> URL {
        rootDirectoryURL.appendingPathComponent("lessons/\(videoIdentifier)", isDirectory: true)
    }

    static func lessonFileURL(videoIdentifier: String) -> URL {
        lessonDirectoryURL(videoIdentifier: videoIdentifier).appendingPathComponent("lesson.json")
    }

    static func keyFrameDirectoryURL(videoIdentifier: String) -> URL {
        lessonDirectoryURL(videoIdentifier: videoIdentifier).appendingPathComponent("frames", isDirectory: true)
    }

    static func downloadDirectoryURL(videoIdentifier: String) -> URL {
        lessonDirectoryURL(videoIdentifier: videoIdentifier).appendingPathComponent("source", isDirectory: true)
    }

    static func locationCacheFileURL(videoIdentifier: String) -> URL {
        lessonDirectoryURL(videoIdentifier: videoIdentifier).appendingPathComponent("locations.json")
    }

    static func makeRunDirectoryURL() throws -> URL {
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let runDirectoryURL = rootDirectoryURL
            .appendingPathComponent("runs/\(timestampFormatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectoryURL, withIntermediateDirectories: true)
        return runDirectoryURL
    }

    static func loadCachedLesson(videoIdentifier: String) -> FollowAlongLesson? {
        guard let lessonData = try? Data(contentsOf: lessonFileURL(videoIdentifier: videoIdentifier)),
              let lesson = try? JSONDecoder().decode(FollowAlongLesson.self, from: lessonData),
              lesson.schemaVersion == FollowAlongLesson.currentSchemaVersion else {
            return nil
        }
        return lesson
    }

    static func save(lesson: FollowAlongLesson) throws {
        let lessonFileURL = lessonFileURL(videoIdentifier: lesson.source.videoIdentifier)
        try FileManager.default.createDirectory(
            at: lessonFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(lesson).write(to: lessonFileURL, options: .atomic)
    }
}

// MARK: - YouTube Links

enum FollowAlongYouTubeLink {
    /// Pulls the video id out of the usual YouTube link shapes. Returning only
    /// the id means everything handed to yt-dlp is rebuilt from eleven safe
    /// characters, so a pasted string can never reach it as a flag or a
    /// playlist, or point it at another site.
    static func videoIdentifier(from pastedText: String) -> String? {
        let trimmedText = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:https?://)?(?:www\.|m\.|music\.)?(?:youtube\.com/(?:watch\?(?:[^#]*&)?v=|embed/|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})(?:[?&#/].*)?$"#

        guard let regularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regularExpression.firstMatch(
                in: trimmedText,
                range: NSRange(trimmedText.startIndex..., in: trimmedText)
              ),
              let identifierRange = Range(match.range(at: 1), in: trimmedText) else {
            return nil
        }
        return String(trimmedText[identifierRange])
    }

    static func canonicalURL(videoIdentifier: String) -> String {
        "https://www.youtube.com/watch?v=\(videoIdentifier)"
    }
}
