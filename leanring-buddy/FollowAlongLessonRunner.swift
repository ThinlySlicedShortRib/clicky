//
//  FollowAlongLessonRunner.swift
//  leanring-buddy
//
//  Teaches a saved lesson inside the real app. For each step it looks at the
//  screen, finds the control, flies the cursor there, speaks, and then waits
//  until a screenshot shows the step really happened.
//
//  Model calls are the cost of a lesson, so the runner avoids them wherever a
//  free local answer exists:
//
//    - Screens are compared on this machine, and only a real, settled change
//      reaches a model. An idle screen costs nothing however long it sits.
//    - A step whose screen matches the last time it was located reuses that
//      answer instead of asking again.
//    - "go back", "repeat" and friends are understood locally.
//
//  The runner never sees where a screenshot came from or how speech reaches a
//  speaker. Those live behind FollowAlongScreenSource and FollowAlongPresenter.
//

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Seams

@MainActor
protocol FollowAlongScreenSource: AnyObject {
    /// Shown in run logs, so a rehearsal can never be mistaken for a real capture.
    var sourceDescription: String { get }
    func captureScreen() async throws -> CompanionScreenCapture
}

@MainActor
protocol FollowAlongPresenter: AnyObject {
    var isSpeaking: Bool { get }
    func lessonDidBegin()
    func lessonDidEnd()
    func setThinking(_ isThinking: Bool)
    /// Returns when the cursor lands, with where its tip ended up.
    func flyPointer(toGlobalAppKitLocation globalLocation: CGPoint, displayFrame: CGRect, bubbleText: String?) async -> CGPoint?
    /// Starts speaking and returns once speech has begun.
    func speak(_ text: String) async
    func stopSpeaking()
}

// MARK: - Screen Comparison

/// A tiny greyscale thumbnail used to tell whether the screen changed, without
/// spending a model call. Coarse enough to ignore compression noise, fine
/// enough that a thin new wire in a node editor still registers.
struct FollowAlongScreenFingerprint: Codable, Equatable {
    static let columnCount = 96
    static let rowCount = 62
    /// A cell has to move this far, out of 255, to count as changed.
    static let cellChangeThreshold = 5

    let luminanceCells: [UInt8]

    init?(imageData: Data) {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let context = CGContext(
                data: nil,
                width: Self.columnCount,
                height: Self.rowCount,
                bitsPerComponent: 8,
                bytesPerRow: Self.columnCount,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: Self.columnCount, height: Self.rowCount))

        guard let pixelData = context.data else { return nil }
        let pixelBuffer = pixelData.bindMemory(to: UInt8.self, capacity: Self.columnCount * Self.rowCount)
        luminanceCells = Array(UnsafeBufferPointer(start: pixelBuffer, count: Self.columnCount * Self.rowCount))
    }

    func changedCellCount(comparedTo otherFingerprint: FollowAlongScreenFingerprint) -> Int {
        zip(luminanceCells, otherFingerprint.luminanceCells).reduce(0) { changedCellCount, cellPair in
            let difference = abs(Int(cellPair.0) - Int(cellPair.1))
            return changedCellCount + (difference > Self.cellChangeThreshold ? 1 : 0)
        }
    }
}

// MARK: - Voice Commands

enum FollowAlongVoiceCommand: Equatable {
    case goBack
    case repeatStep
    case markDone
    case skipStep
    case stopLesson
    case pause
    case resume
    case question(String)

    /// Answers the common navigation phrases for free. Only short utterances
    /// that aren't phrased as questions count: "how do i go back to object
    /// mode?" is a real question, and treating it as navigation would be
    /// exactly the wrong kind of clever.
    static func interpret(transcript: String) -> FollowAlongVoiceCommand {
        let normalizedTranscript = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))

        let words = normalizedTranscript
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }

        let questionOpeners: Set<String> = [
            "how", "what", "what's", "whats", "why", "where", "where's", "which", "who",
            "when", "can", "could", "does", "do", "is", "are", "should", "would", "will"
        ]
        let startsLikeQuestion = words.first.map(questionOpeners.contains) ?? false
        let maximumCommandWordCount = 6

        guard words.count <= maximumCommandWordCount, !startsLikeQuestion else {
            return .question(transcript)
        }

        func containsAny(_ phrases: [String]) -> Bool {
            phrases.contains { phrase in
                normalizedTranscript.range(of: "\\b\(phrase)\\b", options: .regularExpression) != nil
            }
        }

        if containsAny(["go back", "back up", "previous step", "last step", "step back"]) { return .goBack }
        if containsAny(["repeat", "say that again", "say again", "one more time", "come again"]) { return .repeatStep }
        if containsAny(["stop", "quit", "end the lesson", "end lesson", "exit", "i'm finished"]) { return .stopLesson }
        if containsAny(["skip"]) { return .skipStep }
        if containsAny(["resume", "continue", "keep going", "carry on", "i'm back"]) { return .resume }
        if containsAny(["pause", "hold on", "wait", "one sec", "one second", "give me a sec"]) { return .pause }
        if containsAny(["done", "next", "got it", "did it", "i did", "finished", "move on"]) { return .markDone }
        return .question(transcript)
    }
}

// MARK: - Located Targets

/// What a model reported for one step on one screen. Coordinates are in that
/// screenshot's pixels. Saved to disk, which is why it stores the screen size.
struct FollowAlongLocatedTarget: Codable {
    var isAlreadyDone: Bool
    var isTargetFound: Bool
    var pointXInPixels: Double?
    var pointYInPixels: Double?
    var label: String?
    var dragDestinationXInPixels: Double?
    var dragDestinationYInPixels: Double?
    var interfaceMatchesVideo: Bool
    var whatChanged: String?
    var spokenAdaptation: String?
    var adaptedSuccessCheck: String?
    var adaptedActionKind: FollowAlongActionKind?
    var adaptedKeyToPress: String?
    var adaptedValueToType: String?
    var prerequisiteLine: String?
    var prerequisiteKeyToPress: String?
    var screenshotWidthInPixels: Int
    var screenshotHeightInPixels: Int
}

private struct FollowAlongLocationCacheEntry: Codable {
    let stepIdentifier: String
    let screenFingerprint: FollowAlongScreenFingerprint
    let locatedTarget: FollowAlongLocatedTarget
}

private struct FollowAlongLocateModelReply: Decodable {
    let alreadyDone: Bool?
    let targetFound: Bool?
    let x: Double?
    let y: Double?
    let label: String?
    let dragToX: Double?
    let dragToY: Double?
    let interfaceMatchesVideo: Bool?
    let whatChanged: String?
    let spokenAdaptation: String?
    let adaptedSuccessCheck: String?
    let adaptedActionKind: FollowAlongActionKind?
    let adaptedKeyToPress: String?
    let adaptedValueToType: String?
    let prerequisiteLine: String?
    let prerequisiteKey: String?
}

private struct FollowAlongCheckModelReply: Decodable {
    let state: String
    let evidence: String?
}

// MARK: - Run Results

struct FollowAlongAdaptationRecord: Codable {
    let stepIdentifier: String
    let stepTitle: String
    let whatChanged: String
}

struct FollowAlongRunSummary: Codable {
    let lessonTitle: String
    let whatYouLearned: [String]
    let adaptations: [FollowAlongAdaptationRecord]
    let stepsCompleted: Int
    let stepCount: Int
    let finishedEveryStep: Bool
    let failureMessage: String?
    let captureSourceDescription: String
    let costSnapshot: FollowAlongCostSnapshot
    let ledgerEntries: [FollowAlongLedgerEntry]
}

/// Live state for the HUD.
struct FollowAlongRunProgress {
    let stepNumber: Int
    let stepCount: Int
    let stepTitle: String
    let statusText: String
    let costSnapshot: FollowAlongCostSnapshot
}

// MARK: - Runner

@MainActor
final class FollowAlongLessonRunner {
    private enum StepOutcome {
        case passed
        case skipped
        case goBack
        case stopped
        case failed(String)
    }

    private static let pollIntervalInNanoseconds: UInt64 = 1_000_000_000
    /// Mouse hovers light up single buttons. Anything smaller than this many
    /// grid cells isn't a real change in the app.
    private static let meaningfulChangeCellCount = 4
    /// Below this, two polls are the same picture, so the screen has settled.
    private static let settledChangeCellCount = 3
    /// How close a screen must be to reuse a saved location. Stricter than the
    /// change gate, because a stale point is worse than a paid call.
    private static let locationReuseCellCount = 2
    private static let minimumSecondsBetweenChecks = 2.5
    /// Each one is a paid call, but stopping too early strands a beginner on a
    /// step they can't see, which is worse.
    private static let maximumRelocateAttempts = 6
    /// A fifth of the screen. Enough that this is a different place, not a
    /// menu or a new panel opening.
    private static let leftTheStepCellCount = FollowAlongScreenFingerprint.columnCount * FollowAlongScreenFingerprint.rowCount / 5
    /// How long the screen must sit unchanged after the cheap model said "not
    /// yet" before the stronger model is asked. A beginner stuck on a step they
    /// actually finished is worse than one extra paid look.
    private static let secondOpinionDelayInSeconds = 8.0
    private static let flightHoldBeforeDragSeconds: UInt64 = 1
    private static let flightTimeoutWhenCursorMissing: UInt64 = 5

    private static let locateSystemPrompt = """
    you are the eyes of clicky, a small blue cursor teaching a beginner inside a real app on their own computer. a lesson was built from a tutorial video, which may be years old. right now you have to find where this step happens on their screen.

    you get up to two images. "video frame" is from the tutorial and is not their screen. "user's screen" is live, with its pixel size in the label, and that pixel size is your coordinate space. origin is the top left, x goes right, y goes down.

    reply with one json object and nothing else:
    {
      "already_done": false,
      "target_found": true,
      "x": 412,
      "y": 88,
      "label": "one to three lowercase words",
      "drag_to_x": null,
      "drag_to_y": null,
      "interface_matches_video": true,
      "what_changed": null,
      "spoken_adaptation": null,
      "adapted_success_check": null,
      "adapted_action_kind": null,
      "adapted_key_to_press": null,
      "adapted_value_to_type": null,
      "prerequisite_line": null,
      "prerequisite_key": null
    }

    how to decide:
    - look at the user's screen first. point at the exact centre of the real control there, never where it sat in the video.
    - already_done is true only if the user's screen clearly satisfies the step's success check before they have done anything.
    - if the step is a drag, x,y is where it starts and drag_to_x,drag_to_y is where it ends.
    - if the control lives inside something closed, such as a menu, set target_found to false, point x,y at the thing that opens it, and put a short spoken instruction in prerequisite_line.
    - if an action is still unfinished on their screen, nothing else will work until it's done. a new item stuck to the mouse waiting to be placed is the usual case, and a status bar showing hints for a move in progress is how you can tell. set target_found to false, point x,y at a clear empty spot close to where this step happens, and use prerequisite_line to tell them to click there to finish it. choose the spot by size: assume the new item is as big as the largest item already there, and that it lands with its top centre at your point. the whole of that area must be clear, because an item dropped on top of another hides it. pick the largest clear area right beside the existing items, whichever side that's on. stay inside the panel, and don't go further from the other items than you need to, because a distant drop makes everything shrink to tiny controls later.
    - if they've wandered away from where the lesson is, such as a different workspace or screen, set target_found to false, point x,y at the one control that takes them back, and use prerequisite_line to say so kindly. "lesson so far" shows how they got here, so use it to find the way back. never send them somewhere new.
    - when something needs doing first, ask for one easy action: a single click or a single key. if it's a key, put the key's name in prerequisite_key and point at the panel it applies to. never ask a beginner to hold a mouse button and drag when one key would do.

    when the interface differs from the video:
    - compare only what this step needs. a different theme, window size, or layout around it does not count. interface_matches_video goes false only when the control this step needs was renamed, moved somewhere else, replaced, or removed, and you can see that in the two images.
    - if the control is gone, first work out what it did. use this step and the step after it, which together show the result the video was after. then find what gives that result in this version. never swap in another control because it sits in the same place or looks similar, and never invent a control. only point at something you can see.
    - if that result is already on their screen, set already_done to true, and still fill what_changed and spoken_adaptation so they learn why there's nothing to do. a step that was only a way to reach that result counts too, such as opening a list that no longer exists.
    - if "already told them" covers this same change, leave spoken_adaptation null rather than saying it twice.
    - what_changed is one plain sentence for the record: what the video shows, and what this version has.
    - spoken_adaptation replaces the voice line for this step. say it in lowercase like a friend looking over their shoulder: name what the video did, say it's different here, then tell them what to do. two short sentences, no more. never say "simply" or "just".
    - when you adapt, the old success check, action and values may no longer apply. fill adapted_success_check, adapted_action_kind and adapted_key_to_press or adapted_value_to_type for what they should really do on this screen. adapted_action_kind is one of click, drag, press_key, type_value, look.
    """

    private static let checkSystemPrompt = """
    you watch a beginner doing one step of a lesson inside a real app. you see a screenshot of their screen, with its pixel size in the label. decide if the step is done.

    reply with one json object and nothing else:
    {
      "state": "passed",
      "evidence": "the few words of what you see that decided it"
    }

    state is one of:
    - "passed": the screenshot clearly shows the success check is true.
    - "not_yet": it isn't true yet, and nothing is in the way of them doing it.
    - "off_track": they have ended up somewhere the step can't be done from, such as the wrong workspace, wrong mode, or an unexpected window or dialog on top.

    if the check has several parts and one is too subtle to read at this size, such as a slight sheen on a small object, judge it on the parts you can see clearly. wires can run behind other panels, so a socket that has lost its value field counts as connected.

    you only ever see this one moment, never the screen before it. if the success check compares against earlier, such as something looking smaller than before, judge it from what's visible now: a field showing the value they were asked to enter means it's done.

    judge only what's visible. never guess.
    """

    let lesson: FollowAlongLesson
    private let locateBrain: any Brain
    private let checkBrain: any Brain
    private let screenSource: any FollowAlongScreenSource
    private let presenter: any FollowAlongPresenter
    private let keyFrameDirectoryURL: URL
    private let onProgress: (FollowAlongRunProgress) -> Void
    private let onEvent: (String, [String: Any]) -> Void

    private(set) var ledger = FollowAlongCostLedger()
    private var lessonStartDate = Date()
    private var pendingVoiceCommands: [FollowAlongVoiceCommand] = []
    private var isUserTalking = false
    private var isPausedByUser = false
    private var isStopRequested = false
    private var adaptations: [FollowAlongAdaptationRecord] = []
    private var locationCache: [String: FollowAlongLocationCacheEntry] = [:]
    private var lessonConversationHistory: [BrainConversationExchange] = []
    private var highestStepIndexReached = 0
    private var currentStepTitle = ""
    private var currentStepNumber = 0
    private var currentStatusText = ""

    init(
        lesson: FollowAlongLesson,
        locateModelValue: String,
        checkModelValue: String,
        screenSource: any FollowAlongScreenSource,
        presenter: any FollowAlongPresenter,
        planWasBuiltDuringThisRun: Bool,
        onProgress: @escaping (FollowAlongRunProgress) -> Void,
        onEvent: @escaping (String, [String: Any]) -> Void
    ) {
        self.lesson = lesson
        self.locateBrain = BrainConfiguration.makeBrain(modelValue: locateModelValue)
        self.checkBrain = BrainConfiguration.makeBrain(modelValue: checkModelValue)
        self.screenSource = screenSource
        self.presenter = presenter
        self.keyFrameDirectoryURL = FollowAlongStorage.keyFrameDirectoryURL(videoIdentifier: lesson.source.videoIdentifier)
        self.onProgress = onProgress
        self.onEvent = onEvent

        if planWasBuiltDuringThisRun {
            ledger.recordFreshlyGeneratedPlan(lesson.generation)
        } else {
            ledger.isLessonPlanCached = true
            ledger.cachedPlanOriginalCostInUSD = lesson.generation.totalCostInUSD
        }
        loadLocationCache()
    }

    // MARK: Input From Push-To-Talk

    /// Called the moment the hotkey goes down, so the voice stops talking over
    /// the user and no screen judgement races their words.
    func userStartedTalking() {
        isUserTalking = true
        presenter.stopSpeaking()
    }

    /// Called with the final transcript, or nil when nothing was heard.
    func userFinishedTalking(transcript: String?) {
        isUserTalking = false
        guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let command = FollowAlongVoiceCommand.interpret(transcript: transcript)
        emit("voice_command", ["transcript": transcript, "command": String(describing: command)])
        pendingVoiceCommands.append(command)
    }

    func requestStop() {
        isStopRequested = true
        presenter.stopSpeaking()
    }

    // MARK: Running

    func publishInitialProgress() {
        currentStepNumber = 1
        currentStepTitle = lesson.steps.first?.title ?? ""
        updateStatus("getting ready")
    }

    func run() async -> FollowAlongRunSummary {
        lessonStartDate = Date()
        presenter.lessonDidBegin()
        emit("lesson_started", [
            "lessonTitle": lesson.lessonTitle,
            "videoURL": lesson.source.videoURL,
            "stepCount": lesson.steps.count,
            "planFromCache": ledger.isLessonPlanCached,
            "captureSource": screenSource.sourceDescription
        ])

        var stepIndex = 0
        var isRevisit = false
        var failureMessage: String?

        stepLoop: while stepIndex < lesson.steps.count {
            highestStepIndexReached = max(highestStepIndexReached, stepIndex)

            switch await teachStep(at: stepIndex, isRevisit: isRevisit) {
            case .passed, .skipped:
                stepIndex += 1
                isRevisit = false
            case .goBack:
                stepIndex = max(0, stepIndex - 1)
                isRevisit = true
            case .stopped:
                break stepLoop
            case .failed(let message):
                failureMessage = message
                break stepLoop
            }
        }

        await waitForSpeechToFinish()
        presenter.lessonDidEnd()

        let finishedEveryStep = stepIndex >= lesson.steps.count
        let finalSnapshot = ledger.snapshot(elapsedInSeconds: secondsSinceLessonStart)
        emit("lesson_finished", ["finishedEveryStep": finishedEveryStep, "stepsCompleted": stepIndex])

        return FollowAlongRunSummary(
            lessonTitle: lesson.lessonTitle,
            whatYouLearned: lesson.whatYouWillLearn,
            adaptations: adaptations,
            stepsCompleted: stepIndex,
            stepCount: lesson.steps.count,
            finishedEveryStep: finishedEveryStep,
            failureMessage: failureMessage,
            captureSourceDescription: screenSource.sourceDescription,
            costSnapshot: finalSnapshot,
            ledgerEntries: ledger.entries
        )
    }

    private var secondsSinceLessonStart: Double {
        Date().timeIntervalSince(lessonStartDate)
    }

    // MARK: One Step

    private func teachStep(at stepIndex: Int, isRevisit: Bool) async -> StepOutcome {
        let step = lesson.steps[stepIndex]
        currentStepNumber = stepIndex + 1
        currentStepTitle = step.title
        updateStatus("looking for it")
        emit("step_started", ["stepIdentifier": step.id, "title": step.title, "isRevisit": isRevisit])

        var capture: CompanionScreenCapture
        do {
            capture = try await captureSettledScreen()
        } catch {
            return await failLesson(because: error)
        }

        presenter.setThinking(true)
        var locatedTarget = await locateTarget(for: step, on: capture, allowsReuse: true)
        presenter.setThinking(false)

        if let navigationOutcome = await handlePendingVoiceCommands(step: step, successCheck: step.visualSuccessCheck, locatedTarget: locatedTarget) {
            return navigationOutcome
        }

        // A revisit always teaches the step again: its result is on screen
        // already, and that's exactly why the user went back to it.
        if let locatedTarget, locatedTarget.isAlreadyDone, !isRevisit {
            recordAdaptationIfNeeded(step: step, locatedTarget: locatedTarget)
            await waitForSpeechToFinish()
            // When the reason it's done is that the app changed, that reason is
            // the most useful thing the lesson can say here.
            await presenter.speak(locatedTarget.spokenAdaptation ?? "you've already got this one, nice.")
            emit("step_already_done", ["stepIdentifier": step.id, "spokenLine": locatedTarget.spokenAdaptation ?? ""])
            await waitForSpeechToFinish()
            return .passed
        }

        var successCheck = locatedTarget?.adaptedSuccessCheck ?? step.visualSuccessCheck
        recordAdaptationIfNeeded(step: step, locatedTarget: locatedTarget)

        await waitForSpeechToFinish()
        let spokenLine = openingLine(for: step, locatedTarget: locatedTarget, isRevisit: isRevisit)
        await announce(spokenLine, step: step, locatedTarget: locatedTarget, capture: capture)

        var isWaitingForPrerequisite = locatedTarget.map { !$0.isTargetFound } ?? true
        var relocateAttempts = 0
        var previousFingerprint = FollowAlongScreenFingerprint(imageData: capture.imageData)
        var lastJudgedFingerprint = previousFingerprint
        var lastCheckDate = Date.distantPast
        var lastNotYetDate: Date?
        var hasAskedForSecondOpinion = false

        func finishPassedStep(evidence: String?) async -> StepOutcome {
            emit("step_passed", ["stepIdentifier": step.id, "evidence": evidence ?? ""])
            // Fills the silence while the next step is being located.
            presenter.stopSpeaking()
            await presenter.speak(step.successLine)
            return .passed
        }

        /// The cheap model can only say they've left. Finding the way back takes
        /// the lesson's context and a stronger model, because bad directions
        /// here walk a beginner further away. Returns an outcome only if this
        /// ends the step.
        func recoverAfterLeavingTheStep(evidence: String?) async -> StepOutcome? {
            guard relocateAttempts < Self.maximumRelocateAttempts else { return nil }
            relocateAttempts += 1

            updateStatus("finding the way back")
            presenter.setThinking(true)
            locatedTarget = await locateTarget(for: step, on: capture, allowsReuse: false)
            presenter.setThinking(false)
            updateStatus("your turn")

            emit("off_track", [
                "stepIdentifier": step.id,
                "evidence": evidence ?? "",
                "recoveryLine": locatedTarget?.prerequisiteLine ?? ""
            ])

            guard let locatedTarget else { return nil }

            if locatedTarget.isAlreadyDone {
                return await finishPassedStep(evidence: "the locator saw the step already done, so the off track call was wrong")
            }

            isWaitingForPrerequisite = !locatedTarget.isTargetFound
            await waitForSpeechToFinish()
            await announce(openingLine(for: step, locatedTarget: locatedTarget, isRevisit: false), step: step, locatedTarget: locatedTarget, capture: capture)
            return nil
        }

        updateStatus("your turn")

        while true {
            if isStopRequested { return .stopped }

            if let navigationOutcome = await handlePendingVoiceCommands(step: step, successCheck: successCheck, locatedTarget: locatedTarget) {
                return navigationOutcome
            }

            try? await Task.sleep(nanoseconds: Self.pollIntervalInNanoseconds)

            if isUserTalking || isPausedByUser {
                publishProgress()
                continue
            }

            do {
                capture = try await screenSource.captureScreen()
            } catch {
                return await failLesson(because: error)
            }

            ledger.screensLookedAt += 1
            publishProgress()

            guard let currentFingerprint = FollowAlongScreenFingerprint(imageData: capture.imageData) else { continue }
            defer { previousFingerprint = currentFingerprint }

            let cellsChangedSinceLastPoll = previousFingerprint?.changedCellCount(comparedTo: currentFingerprint) ?? 0
            let cellsChangedSinceLastJudgement = lastJudgedFingerprint?.changedCellCount(comparedTo: currentFingerprint) ?? Int.max

            let hasSettled = cellsChangedSinceLastPoll < Self.settledChangeCellCount
            let hasMeaningfullyChanged = cellsChangedSinceLastJudgement >= Self.meaningfulChangeCellCount
            let hasCooledDown = Date().timeIntervalSince(lastCheckDate) >= Self.minimumSecondsBetweenChecks

            if let lastNotYetDate, !hasAskedForSecondOpinion, hasSettled, !hasMeaningfullyChanged, !isWaitingForPrerequisite,
               Date().timeIntervalSince(lastNotYetDate) >= Self.secondOpinionDelayInSeconds {
                hasAskedForSecondOpinion = true
                updateStatus("double checking")
                let secondOpinion = await checkStep(step, successCheck: successCheck, capture: capture, brain: locateBrain, purpose: .secondOpinion)
                updateStatus("your turn")
                if secondOpinion?.state == "passed" {
                    return await finishPassedStep(evidence: secondOpinion?.evidence)
                }
                // Models can misread a small screen, so a beginner who really
                // did it must never be left waiting in silence.
                emit("stuck_hint_spoken", ["stepIdentifier": step.id])
                await waitForSpeechToFinish()
                await presenter.speak("i can't quite tell if that worked. if it looks right to you, say skip and we'll keep going.")
                continue
            }

            guard hasSettled, hasMeaningfullyChanged, hasCooledDown else { continue }

            lastNotYetDate = nil
            hasAskedForSecondOpinion = false
            lastJudgedFingerprint = currentFingerprint
            lastCheckDate = Date()
            emit("screen_change_gated_through", ["stepIdentifier": step.id, "cellsChanged": cellsChangedSinceLastJudgement])

            if isWaitingForPrerequisite {
                guard relocateAttempts < Self.maximumRelocateAttempts else { continue }
                relocateAttempts += 1

                presenter.setThinking(true)
                locatedTarget = await locateTarget(for: step, on: capture, allowsReuse: false)
                presenter.setThinking(false)

                if let locatedTarget, locatedTarget.isAlreadyDone {
                    return await finishPassedStep(evidence: "the locator saw the step already done after the screen changed")
                }

                if let locatedTarget, locatedTarget.isTargetFound {
                    isWaitingForPrerequisite = false
                    successCheck = locatedTarget.adaptedSuccessCheck ?? successCheck
                    recordAdaptationIfNeeded(step: step, locatedTarget: locatedTarget)
                    await waitForSpeechToFinish()
                    await announce(openingLine(for: step, locatedTarget: locatedTarget, isRevisit: false), step: step, locatedTarget: locatedTarget, capture: capture)
                    continue
                }
                if let locatedTarget, locatedTarget.pointXInPixels != nil {
                    await waitForSpeechToFinish()
                    await announce(locatedTarget.prerequisiteLine ?? step.spokenLine, step: step, locatedTarget: locatedTarget, capture: capture)
                }
                continue
            }

            updateStatus("checking")
            let verdict = await checkStep(step, successCheck: successCheck, capture: capture)
            updateStatus("your turn")

            switch verdict?.state {
            case "passed":
                return await finishPassedStep(evidence: verdict?.evidence)

            case "not_yet":
                lastNotYetDate = Date()
                // A label from the cheap model is a judgement call, but this
                // count isn't. Most of the screen changing without the step
                // being done means they went somewhere, whatever the label says.
                if cellsChangedSinceLastJudgement >= Self.leftTheStepCellCount,
                   let recoveryOutcome = await recoverAfterLeavingTheStep(evidence: verdict?.evidence) {
                    return recoveryOutcome
                }

            case "off_track":
                if let recoveryOutcome = await recoverAfterLeavingTheStep(evidence: verdict?.evidence) {
                    return recoveryOutcome
                }

            default:
                continue
            }
        }
    }

    private func openingLine(for step: FollowAlongLessonStep, locatedTarget: FollowAlongLocatedTarget?, isRevisit: Bool) -> String {
        var line = step.spokenLine
        if let spokenAdaptation = locatedTarget?.spokenAdaptation, !spokenAdaptation.isEmpty {
            line = spokenAdaptation
        }
        if let locatedTarget, !locatedTarget.isTargetFound, let prerequisiteLine = locatedTarget.prerequisiteLine {
            line = prerequisiteLine
        }
        return isRevisit ? "okay, back to \(step.title). \(line)" : line
    }

    private func recordAdaptationIfNeeded(step: FollowAlongLessonStep, locatedTarget: FollowAlongLocatedTarget?) {
        // The locator leaves the spoken line empty when it has already told the
        // user about this change, so that's also what keeps the end card from
        // listing one change once per step it touched.
        guard let locatedTarget, !locatedTarget.interfaceMatchesVideo,
              let whatChanged = locatedTarget.whatChanged,
              let spokenAdaptation = locatedTarget.spokenAdaptation, !spokenAdaptation.isEmpty,
              !adaptations.contains(where: { $0.stepIdentifier == step.id }) else {
            return
        }
        adaptations.append(FollowAlongAdaptationRecord(stepIdentifier: step.id, stepTitle: step.title, whatChanged: whatChanged))
        emit("interface_adapted", [
            "stepIdentifier": step.id,
            "whatChanged": whatChanged,
            "spokenAdaptation": locatedTarget.spokenAdaptation ?? "",
            "adaptedSuccessCheck": locatedTarget.adaptedSuccessCheck ?? ""
        ])
    }

    // MARK: Pointing And Speaking

    private func announce(
        _ spokenLine: String,
        step: FollowAlongLessonStep,
        locatedTarget: FollowAlongLocatedTarget?,
        capture: CompanionScreenCapture
    ) async {
        await presenter.speak(spokenLine)

        guard let locatedTarget, let pointX = locatedTarget.pointXInPixels, let pointY = locatedTarget.pointYInPixels else {
            emit("step_announced", ["stepIdentifier": step.id, "spokenLine": spokenLine, "pointed": false])
            return
        }

        await fly(toPixelX: pointX, pixelY: pointY, capture: capture, bubbleText: locatedTarget.label)

        var eventFields = makePointEventFields(stepIdentifier: step.id, pixelX: pointX, pixelY: pointY, capture: capture)
        eventFields["spokenLine"] = spokenLine
        eventFields["label"] = locatedTarget.label ?? ""
        eventFields["isPrerequisite"] = !locatedTarget.isTargetFound
        eventFields["prerequisiteKey"] = locatedTarget.prerequisiteKeyToPress ?? ""
        let actionKind = locatedTarget.adaptedActionKind ?? step.actionKind
        eventFields["actionKind"] = actionKind.rawValue
        eventFields["keyToPress"] = locatedTarget.adaptedKeyToPress ?? step.keyToPress ?? ""
        eventFields["valueToType"] = locatedTarget.adaptedValueToType ?? step.valueToType ?? ""

        if locatedTarget.isTargetFound,
           let dragDestinationX = locatedTarget.dragDestinationXInPixels,
           let dragDestinationY = locatedTarget.dragDestinationYInPixels {
            // Shows where the drag ends after a beat on where it starts.
            try? await Task.sleep(nanoseconds: Self.flightHoldBeforeDragSeconds * 1_000_000_000)
            await fly(toPixelX: dragDestinationX, pixelY: dragDestinationY, capture: capture, bubbleText: "to here")
            let destinationPoint = mapToScreen(pixelX: dragDestinationX, pixelY: dragDestinationY, capture: capture)
            eventFields["dragDestinationDisplayPoint"] = ["x": destinationPoint.displayLocalPoint.x, "y": destinationPoint.displayLocalPoint.y]
        }

        emit("step_announced", eventFields)
    }

    private func makePointEventFields(stepIdentifier: String, pixelX: Double, pixelY: Double, capture: CompanionScreenCapture) -> [String: Any] {
        let mappedPoint = mapToScreen(pixelX: pixelX, pixelY: pixelY, capture: capture)
        return [
            "stepIdentifier": stepIdentifier,
            "pointInPixels": ["x": pixelX, "y": pixelY],
            "displayPoint": ["x": mappedPoint.displayLocalPoint.x, "y": mappedPoint.displayLocalPoint.y],
            "pointed": true
        ]
    }

    private func mapToScreen(pixelX: Double, pixelY: Double, capture: CompanionScreenCapture) -> MappedScreenPoint {
        ScreenshotCoordinateMapper.mapScreenshotPoint(
            CGPoint(x: pixelX, y: pixelY),
            screenshotWidthInPixels: capture.screenshotWidthInPixels,
            screenshotHeightInPixels: capture.screenshotHeightInPixels,
            displayFrame: capture.displayFrame
        )
    }

    private func fly(toPixelX pixelX: Double, pixelY: Double, capture: CompanionScreenCapture, bubbleText: String?) async {
        let mappedPoint = mapToScreen(pixelX: pixelX, pixelY: pixelY, capture: capture)
        _ = await presenter.flyPointer(
            toGlobalAppKitLocation: mappedPoint.globalAppKitPoint,
            displayFrame: capture.displayFrame,
            bubbleText: bubbleText
        )
    }

    private func waitForSpeechToFinish() async {
        while presenter.isSpeaking, !isStopRequested {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Voice Commands

    /// Runs everything the user said since the last look. Returns an outcome
    /// only when it ends the current step.
    private func handlePendingVoiceCommands(
        step: FollowAlongLessonStep,
        successCheck: String,
        locatedTarget: FollowAlongLocatedTarget?
    ) async -> StepOutcome? {
        while !pendingVoiceCommands.isEmpty {
            let command = pendingVoiceCommands.removeFirst()

            switch command {
            case .goBack:
                return .goBack

            case .stopLesson:
                presenter.stopSpeaking()
                await presenter.speak("okay, we'll stop here.")
                return .stopped

            case .skipStep:
                await presenter.speak("okay, skipping that one.")
                return .skipped

            case .pause:
                isPausedByUser = true
                updateStatus("paused")
                await presenter.speak("take your time. say keep going when you're ready.")

            case .resume:
                isPausedByUser = false
                updateStatus("your turn")
                await presenter.speak("okay, back to it.")

            case .repeatStep:
                isPausedByUser = false
                if let capture = try? await screenSource.captureScreen() {
                    await announce(openingLine(for: step, locatedTarget: locatedTarget, isRevisit: false), step: step, locatedTarget: locatedTarget, capture: capture)
                }

            case .markDone:
                isPausedByUser = false
                guard let capture = try? await screenSource.captureScreen() else { continue }
                let verdict = await checkStep(step, successCheck: successCheck, capture: capture)
                if verdict?.state == "passed" {
                    emit("step_passed", ["stepIdentifier": step.id, "evidence": verdict?.evidence ?? "", "triggeredByVoice": true])
                    await presenter.speak(step.successLine)
                    return .passed
                }
                await presenter.speak("i don't see it yet. say skip if you want to move on anyway.")

            case .question(let questionText):
                await answer(question: questionText, step: step, locatedTarget: locatedTarget)
            }
        }
        return nil
    }

    /// Answers using the same voice prompt as normal Clicky, so the lesson
    /// doesn't turn it into a different character, then returns the cursor to
    /// the step once the answer has been spoken.
    private func answer(question: String, step: FollowAlongLessonStep, locatedTarget: FollowAlongLocatedTarget?) async {
        updateStatus("thinking about that")
        presenter.setThinking(true)
        defer { presenter.setThinking(false) }

        do {
            let capture = try await screenSource.captureScreen()

            let lessonContextPrompt = """
            we're in the middle of a lesson, "\(lesson.lessonTitle)", built from the video "\(lesson.source.title)".
            the current step is "\(step.title)". the goal is: \(step.goal).
            they may be on a newer version of the app than the video, so go by what's on their screen.
            answer what they ask in one or two short sentences, then stop. they'll carry on with the step afterwards.

            they said: \(question)
            """

            let brainResponse = try await locateBrain.respond(
                to: BrainRequest(
                    systemPrompt: CompanionManager.companionVoiceResponseSystemPrompt,
                    conversationHistory: lessonConversationHistory,
                    userPrompt: lessonContextPrompt,
                    images: CompanionManager.makeBrainImages(from: [capture])
                ),
                onTextDelta: { _ in }
            )
            record(.answerQuestion, stepIdentifier: step.id, usage: brainResponse.usage)

            let parseResult = CompanionManager.parsePointingCoordinates(from: brainResponse.text)
            lessonConversationHistory.append(BrainConversationExchange(userTranscript: question, assistantResponse: parseResult.spokenText))
            if lessonConversationHistory.count > 6 {
                lessonConversationHistory.removeFirst()
            }

            presenter.setThinking(false)
            await presenter.speak(parseResult.spokenText)

            var eventFields: [String: Any] = ["stepIdentifier": step.id, "question": question, "answer": parseResult.spokenText]
            if let pointCoordinate = parseResult.coordinate {
                await fly(toPixelX: pointCoordinate.x, pixelY: pointCoordinate.y, capture: capture, bubbleText: parseResult.elementLabel)
                eventFields["answerPointLabel"] = parseResult.elementLabel ?? ""
                eventFields["answerPointInPixels"] = ["x": pointCoordinate.x, "y": pointCoordinate.y]
            }
            emit("question_answered", eventFields)

            await waitForSpeechToFinish()

            if parseResult.coordinate != nil,
               let pointX = locatedTarget?.pointXInPixels,
               let pointY = locatedTarget?.pointYInPixels {
                await fly(toPixelX: pointX, pixelY: pointY, capture: capture, bubbleText: locatedTarget?.label)
            }
        } catch is CancellationError {
            return
        } catch {
            emit("question_failed", ["stepIdentifier": step.id, "error": error.localizedDescription])
            await presenter.speak("i couldn't get an answer for that one. let's keep going.")
        }

        updateStatus("your turn")
    }

    // MARK: Asking Models

    /// Waits for two matching screens, so a menu that's still animating open
    /// never gets located.
    private func captureSettledScreen() async throws -> CompanionScreenCapture {
        var capture = try await screenSource.captureScreen()
        ledger.screensLookedAt += 1
        var previousFingerprint = FollowAlongScreenFingerprint(imageData: capture.imageData)
        let maximumSettleAttempts = 4

        for _ in 0..<maximumSettleAttempts {
            try await Task.sleep(nanoseconds: Self.pollIntervalInNanoseconds / 2)
            capture = try await screenSource.captureScreen()
            ledger.screensLookedAt += 1
            let currentFingerprint = FollowAlongScreenFingerprint(imageData: capture.imageData)

            if let previousFingerprint, let currentFingerprint,
               previousFingerprint.changedCellCount(comparedTo: currentFingerprint) < Self.settledChangeCellCount {
                break
            }
            previousFingerprint = currentFingerprint
        }
        return capture
    }

    private func locateTarget(
        for step: FollowAlongLessonStep,
        on capture: CompanionScreenCapture,
        allowsReuse: Bool
    ) async -> FollowAlongLocatedTarget? {
        let currentFingerprint = FollowAlongScreenFingerprint(imageData: capture.imageData)

        if allowsReuse, let currentFingerprint, let cacheEntry = locationCache[step.id],
           cacheEntry.locatedTarget.screenshotWidthInPixels == capture.screenshotWidthInPixels,
           cacheEntry.locatedTarget.screenshotHeightInPixels == capture.screenshotHeightInPixels,
           cacheEntry.screenFingerprint.changedCellCount(comparedTo: currentFingerprint) <= Self.locationReuseCellCount {
            ledger.cachedStepsReused += 1
            publishProgress()
            emit("location_reused", ["stepIdentifier": step.id, "label": cacheEntry.locatedTarget.label ?? ""])
            return cacheEntry.locatedTarget
        }

        var images: [BrainImage] = []
        if let keyFrameFileName = step.keyFrameFileName,
           let keyFrameData = try? Data(contentsOf: keyFrameDirectoryURL.appendingPathComponent(keyFrameFileName)) {
            images.append(BrainImage(imageData: keyFrameData, label: "video frame, from \(lesson.applicationName) \(lesson.applicationVersionInVideo). not the user's screen."))
        }
        images.append(contentsOf: CompanionManager.makeBrainImages(from: [capture]))

        var promptLines = [
            "step: \(step.title)",
            "goal: \(step.goal)",
            "the video's control: \(step.targetDescription)",
            "what the video shows here: \(step.videoInterfaceDescription)",
            "success check: \(step.visualSuccessCheck)",
            "action: \(step.actionKind.rawValue)"
        ]
        if let dragDestinationDescription = step.dragDestinationDescription {
            promptLines.append("drag ends at: \(dragDestinationDescription)")
        }
        promptLines.append("the voice line for this step, if nothing changed: \(step.spokenLine)")

        if let stepIndex = lesson.steps.firstIndex(where: { $0.id == step.id }), stepIndex + 1 < lesson.steps.count {
            let followingStep = lesson.steps[stepIndex + 1]
            promptLines.append("the step after this one: \(followingStep.title). its goal: \(followingStep.goal). its result: \(followingStep.visualSuccessCheck)")
        }
        if let stepIndex = lesson.steps.firstIndex(where: { $0.id == step.id }), stepIndex > 0 {
            let earlierSteps = lesson.steps[..<stepIndex].map { "\($0.title) (\($0.targetDescription))" }
            promptLines.append("lesson so far: \(earlierSteps.joined(separator: "; "))")
        }
        if !adaptations.isEmpty {
            promptLines.append("already told them: \(adaptations.map(\.whatChanged).joined(separator: " "))")
        }

        let brainRequest = BrainRequest(
            systemPrompt: Self.locateSystemPrompt,
            conversationHistory: [],
            userPrompt: promptLines.joined(separator: "\n"),
            images: images
        )

        let maximumAttempts = 2
        for _ in 1...maximumAttempts {
            do {
                let brainResponse = try await locateBrain.respond(to: brainRequest, onTextDelta: { _ in })
                record(.locateTarget, stepIdentifier: step.id, usage: brainResponse.usage)

                guard let jsonData = FollowAlongJSONExtraction.jsonObjectData(from: brainResponse.text) else { continue }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard let modelReply = try? decoder.decode(FollowAlongLocateModelReply.self, from: jsonData) else { continue }

                let locatedTarget = FollowAlongLocatedTarget(
                    isAlreadyDone: modelReply.alreadyDone ?? false,
                    isTargetFound: modelReply.targetFound ?? (modelReply.x != nil),
                    pointXInPixels: modelReply.x,
                    pointYInPixels: modelReply.y,
                    label: modelReply.label,
                    dragDestinationXInPixels: modelReply.dragToX,
                    dragDestinationYInPixels: modelReply.dragToY,
                    interfaceMatchesVideo: modelReply.interfaceMatchesVideo ?? true,
                    whatChanged: modelReply.whatChanged,
                    spokenAdaptation: modelReply.spokenAdaptation,
                    adaptedSuccessCheck: modelReply.adaptedSuccessCheck,
                    adaptedActionKind: modelReply.adaptedActionKind,
                    adaptedKeyToPress: modelReply.adaptedKeyToPress,
                    adaptedValueToType: modelReply.adaptedValueToType,
                    prerequisiteLine: modelReply.prerequisiteLine,
                    prerequisiteKeyToPress: modelReply.prerequisiteKey,
                    screenshotWidthInPixels: capture.screenshotWidthInPixels,
                    screenshotHeightInPixels: capture.screenshotHeightInPixels
                )

                emit("target_located", [
                    "stepIdentifier": step.id,
                    "rawReply": String(decoding: jsonData, as: UTF8.self),
                    "usage": Self.usageFields(brainResponse.usage)
                ])

                if let currentFingerprint, locatedTarget.isTargetFound {
                    locationCache[step.id] = FollowAlongLocationCacheEntry(
                        stepIdentifier: step.id,
                        screenFingerprint: currentFingerprint,
                        locatedTarget: locatedTarget
                    )
                    saveLocationCache()
                }
                return locatedTarget
            } catch is CancellationError {
                return nil
            } catch {
                emit("locate_failed", ["stepIdentifier": step.id, "error": error.localizedDescription])
            }
        }
        return nil
    }

    private func checkStep(
        _ step: FollowAlongLessonStep,
        successCheck: String,
        capture: CompanionScreenCapture,
        brain: (any Brain)? = nil,
        purpose: FollowAlongBrainCallPurpose = .checkSuccess
    ) async -> FollowAlongCheckModelReply? {
        var userPrompt = """
        step: \(step.title)
        goal: \(step.goal)
        success check: \(successCheck)
        """
        if let valueToType = step.valueToType {
            userPrompt += "\nthey were asked to enter: \(valueToType)"
        }

        do {
            let brainResponse = try await (brain ?? checkBrain).respond(
                to: BrainRequest(
                    systemPrompt: Self.checkSystemPrompt,
                    conversationHistory: [],
                    userPrompt: userPrompt,
                    images: CompanionManager.makeBrainImages(from: [capture])
                ),
                onTextDelta: { _ in }
            )
            record(purpose, stepIdentifier: step.id, usage: brainResponse.usage)

            guard let jsonData = FollowAlongJSONExtraction.jsonObjectData(from: brainResponse.text) else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let modelReply = try? decoder.decode(FollowAlongCheckModelReply.self, from: jsonData)

            emit("success_checked", [
                "stepIdentifier": step.id,
                "purpose": purpose.rawValue,
                "state": modelReply?.state ?? "unparseable",
                "evidence": modelReply?.evidence ?? "",
                "usage": Self.usageFields(brainResponse.usage)
            ])
            return modelReply
        } catch {
            emit("check_failed", ["stepIdentifier": step.id, "error": error.localizedDescription])
            return nil
        }
    }

    private func record(_ purpose: FollowAlongBrainCallPurpose, stepIdentifier: String, usage: BrainUsage) {
        ledger.record(purpose: purpose, stepIdentifier: stepIdentifier, usage: usage)
        publishProgress()
    }

    private static func usageFields(_ usage: BrainUsage) -> [String: Any] {
        [
            "model": usage.modelIdentifier,
            "costInUSD": usage.costInUSD ?? NSNull(),
            "isCostEstimated": usage.isCostEstimated,
            "inputTokens": usage.inputTokens ?? NSNull(),
            "outputTokens": usage.outputTokens ?? NSNull(),
            "cacheReadInputTokens": usage.cacheReadInputTokens ?? NSNull(),
            "cacheCreationInputTokens": usage.cacheCreationInputTokens ?? NSNull(),
            "totalDurationInSeconds": usage.totalDurationInSeconds
        ]
    }

    // MARK: Failure

    private func failLesson(because error: Error) async -> StepOutcome {
        let spokenFailure: String
        if error is CompanionScreenCaptureError {
            spokenFailure = "i can't see your screen yet. give clicky screen recording permission in system settings, then relaunch me."
        } else {
            spokenFailure = "i lost sight of your screen, so i'm stopping the lesson here."
        }
        emit("lesson_failed", ["error": error.localizedDescription])
        await presenter.speak(spokenFailure)
        return .failed(error.localizedDescription)
    }

    // MARK: Status

    private func updateStatus(_ statusText: String) {
        currentStatusText = statusText
        publishProgress()
    }

    private func publishProgress() {
        onProgress(FollowAlongRunProgress(
            stepNumber: currentStepNumber,
            stepCount: lesson.steps.count,
            stepTitle: currentStepTitle,
            statusText: currentStatusText,
            costSnapshot: ledger.snapshot(elapsedInSeconds: secondsSinceLessonStart)
        ))
    }

    private func emit(_ eventName: String, _ fields: [String: Any]) {
        var eventFields = fields
        eventFields["secondsIntoLesson"] = (secondsSinceLessonStart * 10).rounded() / 10
        onEvent(eventName, eventFields)
    }

    // MARK: Location Cache

    private func loadLocationCache() {
        let cacheFileURL = FollowAlongStorage.locationCacheFileURL(videoIdentifier: lesson.source.videoIdentifier)
        guard let cacheData = try? Data(contentsOf: cacheFileURL),
              let cacheEntries = try? JSONDecoder().decode([FollowAlongLocationCacheEntry].self, from: cacheData) else {
            return
        }
        locationCache = Dictionary(uniqueKeysWithValues: cacheEntries.map { ($0.stepIdentifier, $0) })
    }

    private func saveLocationCache() {
        let cacheFileURL = FollowAlongStorage.locationCacheFileURL(videoIdentifier: lesson.source.videoIdentifier)
        guard let cacheData = try? JSONEncoder().encode(Array(locationCache.values)) else { return }
        try? cacheData.write(to: cacheFileURL, options: .atomic)
    }
}
