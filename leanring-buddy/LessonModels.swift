//
//  LessonModels.swift
//  leanring-buddy
//
//  The two file formats behind Show Me Once. A TeachRecording is the raw,
//  private capture of a teacher's demonstration and stays on their Mac. A
//  ClickyLesson is what the compiler distills from it, and is what gets shared.
//
//  A lesson's steps deliberately hold no coordinates. The follower's window,
//  document and theme all differ from the teacher's, so a step describes what
//  to do and what to look for, and follow mode finds it on the live screen.
//

import CoreGraphics
import Foundation

// MARK: - Shared Types

/// Where a recording came from. Synthetic recordings are built by scripts for
/// checking the compiler, and that label follows them onto the share card.
enum LessonProvenanceKind: String, Codable {
    case liveRecording
    case syntheticRecording
}

struct LessonProvenance: Codable, Equatable {
    let kind: LessonProvenanceKind
    /// How a synthetic recording was made. Nil for a live one.
    let note: String?

    static let liveRecording = LessonProvenance(kind: .liveRecording, note: nil)
}

struct LessonRectangle: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rectangle: CGRect) {
        x = rectangle.origin.x
        y = rectangle.origin.y
        width = rectangle.width
        height = rectangle.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct LessonPoint: Codable, Equatable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// The machine a lesson was taught on, kept so a follow run can state how its
/// setup differed.
struct LessonSetupDescription: Codable, Equatable {
    let displaySizeInPoints: LessonRectangle
    let windowSizeInPoints: LessonRectangle?
    /// "light" or "dark".
    let appearanceName: String
}

// MARK: - Recording

/// What the accessibility tree says about the thing under a click. This never
/// holds AXValue, so the contents of fields and cells can't end up in a
/// recording through this path.
struct TeachElementSnapshot: Codable, Equatable {
    let role: String?
    let subrole: String?
    let title: String?
    let accessibilityDescription: String?
    let helpText: String?
    let frameInDisplayPoints: LessonRectangle?
}

enum TeachActionKind: String, Codable {
    case click
    case doubleClick
    case rightClick
    case drag
    case typing
    case shortcut
}

/// Keystrokes are stored as counts per category and never as characters.
struct TeachKeystrokeSummary: Codable, Equatable {
    var letterCount = 0
    var digitCount = 0
    var punctuationCount = 0
    var spaceCount = 0
    var returnCount = 0
    var tabCount = 0
    var deleteCount = 0
    var arrowCount = 0
    var escapeCount = 0
    /// Command or control combinations, such as "command+c".
    var shortcutNames: [String] = []

    var totalKeystrokeCount: Int {
        letterCount + digitCount + punctuationCount + spaceCount + returnCount
            + tabCount + deleteCount + arrowCount + escapeCount + shortcutNames.count
    }

    var plainLanguageDescription: String {
        var parts: [String] = []
        if letterCount > 0 { parts.append("\(letterCount) letters") }
        if digitCount > 0 { parts.append("\(digitCount) digits") }
        if punctuationCount > 0 { parts.append("\(punctuationCount) punctuation") }
        if spaceCount > 0 { parts.append("\(spaceCount) spaces") }
        if returnCount > 0 { parts.append("return x\(returnCount)") }
        if tabCount > 0 { parts.append("tab x\(tabCount)") }
        if deleteCount > 0 { parts.append("delete x\(deleteCount)") }
        if arrowCount > 0 { parts.append("arrow keys x\(arrowCount)") }
        if escapeCount > 0 { parts.append("escape x\(escapeCount)") }
        parts += shortcutNames
        return parts.joined(separator: ", ")
    }
}

struct TeachRecordedAction: Codable, Equatable {
    let secondsFromStart: Double
    let kind: TeachActionKind
    let applicationName: String?
    let applicationBundleIdentifier: String?
    let element: TeachElementSnapshot?
    /// The drag's start for a drag, otherwise the click. Nil for keystrokes.
    let locationInDisplayPoints: LessonPoint?
    let dragEndLocationInDisplayPoints: LessonPoint?
    let windowFrameInDisplayPoints: LessonRectangle?
    let keystrokeSummary: TeachKeystrokeSummary?
    /// File names inside the recording's frames directory.
    var beforeFrameFileName: String?
    var afterFrameFileName: String?
}

struct TeachNarrationSegment: Codable, Equatable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
}

/// A stretch where secure input was on. Nothing that happened inside it is
/// kept, including narration, so someone reading out a password loses it too.
struct TeachSecureGap: Codable, Equatable {
    let startSeconds: Double
    let endSeconds: Double
}

struct TeachRecording: Codable, Equatable {
    var formatVersion = 1
    let recordingIdentifier: String
    let provenance: LessonProvenance
    let teacherName: String
    let startedAt: Date
    var durationInSeconds: Double
    let setup: LessonSetupDescription
    var actions: [TeachRecordedAction]
    var narrationSegments: [TeachNarrationSegment]
    var secureGaps: [TeachSecureGap]
    /// The teacher's voice for the whole recording, if it was kept.
    var narrationAudioFileName: String?

    static let manifestFileName = "recording.json"
    static let framesDirectoryName = "frames"
}

// MARK: - Lesson

/// What the follower has to do at a step, which decides how the step is
/// described to them. Follow mode never performs the action itself.
enum LessonActionKind: String, Codable {
    case click
    case doubleClick
    case rightClick
    case drag
    case type
    case shortcut
    case look
}

/// App chrome keeps its name everywhere, so it can be found through the
/// accessibility tree. Document content differs on every Mac, so it can only
/// be found by looking at the screen.
enum LessonElementKind: String, Codable {
    case applicationControl
    case documentContent
}

struct LessonElementTarget: Codable, Equatable {
    /// What the thing is, by meaning. Never a position in pixels.
    let description: String
    let kind: LessonElementKind
    let accessibilityRole: String?
    let accessibilityTitleHints: [String]
    /// A rough, human hint such as "in the toolbar along the top".
    let whereToLook: String?
    /// A small crop from the teacher's screen. Nil for document content, so a
    /// shared lesson can't carry a piece of the teacher's private data.
    let referenceImageFileName: String?
}

struct LessonSuccessCheck: Codable, Equatable {
    /// What will be visibly true once the step is done, on anyone's document.
    let description: String
    /// UI text that appears only after the step. An on-device OCR match passes
    /// the check without a model call, which keeps replay cheap.
    let newlyVisibleTextAnyOf: [String]
}

/// Whether a step's spoken line is the teacher's own phrasing.
enum LessonSpokenLineSource: String, Codable {
    /// The model's cleaned-up version, which overlaps the teacher's words.
    case teacherWords
    /// The model drifted from the teacher, so their raw narration replaced it.
    case teacherNarrationFallback
    /// The teacher said nothing here, so the line has no words of theirs.
    case generatedBecauseTeacherWasSilent
}

struct LessonStep: Codable, Equatable {
    let stepNumber: Int
    let intent: String
    let spokenLine: String
    /// A few words for the bubble beside the cursor.
    let bubbleText: String
    let action: LessonActionKind
    let element: LessonElementTarget
    let successCheck: LessonSuccessCheck
    let spokenLineSource: LessonSpokenLineSource
    /// Share of the spoken line's words found in the teacher's narration.
    let teacherWordOverlap: Double
    /// True when the line names something from the teacher's own document, so
    /// follow mode must reword it to fit the follower's screen.
    let usesDocumentSpecificWords: Bool
    /// The teacher's actual voice for this step, if it can play unchanged.
    let voiceClipFileName: String?
}

/// One model call a lesson cost, tagged with what it was for.
struct LessonCostSample: Codable, Equatable {
    /// "compile", "locate", "check" or "question".
    let purpose: String
    let usage: BrainUsage
}

/// Every model call behind a whole follow run.
struct LessonReplayRun: Codable, Equatable {
    let finishedAt: Date
    let captureSource: String
    let calls: [LessonCostSample]
}

/// The real usage numbers a share card's estimate is built from. Figures come
/// from BrainUsage and nowhere else, so a nil stays "not reported".
struct LessonCostEvidence: Codable, Equatable {
    var compileCalls: [LessonCostSample]
    var rehearsalCalls: [LessonCostSample]
    var replayRuns: [LessonReplayRun]
}

struct ClickyLesson: Codable, Equatable {
    var formatVersion = 1
    let lessonIdentifier: String
    let title: String
    let summary: String
    let teacherName: String
    let createdAt: Date
    let provenance: LessonProvenance
    let applicationName: String
    let applicationBundleIdentifier: String?
    /// Said before step one. Assumes nothing about the follower's screen.
    let openingLine: String
    let closingLine: String
    /// Everything the teacher said, for answering follow-up questions.
    let teacherNarrationTranscript: String
    let taughtOnSetup: LessonSetupDescription
    let steps: [LessonStep]
    var costEvidence: LessonCostEvidence

    static let manifestFileName = "lesson.json"
    static let imagesDirectoryName = "images"
    static let voiceDirectoryName = "voice"
    static let fileExtension = "clicky"
}

extension BrainUsage: Equatable {
    static func == (firstUsage: BrainUsage, secondUsage: BrainUsage) -> Bool {
        firstUsage.backendName == secondUsage.backendName
            && firstUsage.modelIdentifier == secondUsage.modelIdentifier
            && firstUsage.inputTokens == secondUsage.inputTokens
            && firstUsage.outputTokens == secondUsage.outputTokens
            && firstUsage.costInUSD == secondUsage.costInUSD
            && firstUsage.totalDurationInSeconds == secondUsage.totalDurationInSeconds
    }
}
