//
//  LessonFollowController.swift
//  leanring-buddy
//
//  Runs a lesson live: for each step it finds the target on the follower's real
//  screen, points, speaks in the teacher's words, and waits. It watches for the
//  screen to change, and only then spends a check on whether the step is done.
//
//  Capture here is always real ScreenCaptureKit. There's no way to hand this
//  controller a saved image. Headless replay drives LessonFollowEngine directly.
//

import AppKit
import AVFoundation
import Combine
import Foundation

/// What follow mode needs from the app's voice and cursor.
@MainActor
protocol LessonFollowPresenter: AnyObject {
    func pointBuddyAtLessonTarget(globalAppKitLocation: CGPoint, displayFrame: CGRect, bubbleText: String) async
    func releaseLessonPoint()
    func speakLessonLine(_ line: String) async
    func stopLessonSpeech()
    var isSpeakingLessonLine: Bool { get }
    /// True from push-to-talk press until its answer has finished speaking.
    var isAnsweringFollowerQuestion: Bool { get }
    func prepareForNewLesson()
}

enum LessonFollowState: Equatable {
    case idle
    case gettingReady
    case findingStep(stepNumber: Int)
    case waitingForFollower(stepNumber: Int)
    case checkingStep(stepNumber: Int)
    case answeringQuestion(stepNumber: Int)
    case finished
    case failed(message: String)
}

@MainActor
final class LessonFollowController: ObservableObject {
    @Published private(set) var state: LessonFollowState = .idle
    @Published private(set) var activeLessonPackage: LessonPackage?
    /// Every model call in this run, for the share card's replay figure.
    @Published private(set) var costSamples: [LessonCostSample] = []

    private static let screenWatchIntervalInSeconds: TimeInterval = 1.0
    private static let minimumSecondsBetweenChecks: TimeInterval = 3.0
    /// A single changed tile is usually the menu bar clock.
    private static let minimumChangedTilesToCheck = 2
    /// A change this large means the window moved or a panel opened, so the
    /// cursor's target may have moved with it.
    private static let changedTilesThatMoveTheTarget = 60
    private static let secondsBeforeRepeatingTheLine: TimeInterval = 40
    /// A follower who keeps clicking around shouldn't run up an open-ended
    /// bill, so past this a step waits on them without asking the model.
    private static let maximumModelCallsPerStep = 12
    private static let secondsToWaitForApplication: TimeInterval = 120

    private weak var presenter: (any LessonFollowPresenter)?
    private var brain: any Brain = BrainConfiguration.makeBrain(modelValue: BrainConfiguration.configuredModelValue)
    private var runTask: Task<Void, Never>?
    private var voiceClipPlayer: AVAudioPlayer?

    private var currentStepIndex = 0
    private var isPausedForQuestion = false
    private var currentTargetLocation: LessonTargetLocation?

    var isFollowing: Bool {
        activeLessonPackage != nil
    }

    func attach(presenter: any LessonFollowPresenter) {
        self.presenter = presenter
    }

    func setBrain(_ newBrain: any Brain) {
        brain = newBrain
    }

    func start(lessonPackage: LessonPackage) {
        stop()
        activeLessonPackage = lessonPackage
        costSamples = []
        currentStepIndex = 0
        isPausedForQuestion = false
        state = .gettingReady
        presenter?.prepareForNewLesson()

        runTask = Task { [weak self] in
            await self?.runLesson(lessonPackage)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        stopSpeaking()
        presenter?.releaseLessonPoint()
        activeLessonPackage = nil
        currentTargetLocation = nil
        isPausedForQuestion = false
        if state != .finished {
            state = .idle
        }
    }

    /// Push-to-talk was pressed. The lesson holds still until the answer ends.
    func pauseForQuestion() {
        guard isFollowing else { return }
        isPausedForQuestion = true
        stopSpeaking()
    }

    /// The prompt that makes a follower's question answer from the teacher's
    /// narration. Nil outside a lesson.
    var questionSystemPrompt: String? {
        guard let lesson = activeLessonPackage?.lesson else { return nil }
        return LessonQuestionPrompt.makeSystemPrompt(lesson: lesson, currentStepIndex: currentStepIndex)
    }

    // MARK: Lesson Loop

    private func runLesson(_ lessonPackage: LessonPackage) async {
        let lesson = lessonPackage.lesson

        do {
            await speak(line: lesson.openingLine, voiceClipURL: nil)
            try await waitForLessonApplication(lesson)

            for stepIndex in lesson.steps.indices {
                currentStepIndex = stepIndex
                try await run(step: lesson.steps[stepIndex], lessonPackage: lessonPackage)
                try Task.checkCancellation()
            }

            presenter?.releaseLessonPoint()
            state = .finished
            await speak(line: lesson.closingLine, voiceClipURL: nil)
            recordFinishedRun(lessonPackage)
            activeLessonPackage = nil
        } catch is CancellationError {
            // stop() has already cleaned up.
        } catch {
            print("⚠️ Show Me Once: lesson stopped: \(error.localizedDescription)")
            presenter?.releaseLessonPoint()
            state = .failed(message: error.localizedDescription)
            activeLessonPackage = nil
            await speak(line: Self.spokenMessage(for: error), voiceClipURL: nil)
        }
    }

    private static func spokenMessage(for error: Error) -> String {
        if error is CompanionScreenCaptureError {
            return "i can't see your screen yet. give clicky screen recording permission in system settings, then relaunch me."
        }
        return "something went wrong on my end, so i've stopped the lesson."
    }

    /// A step can't be found until the follower is in the app. Waiting has a
    /// limit so a lesson can't sit listening forever if it's left open.
    private func waitForLessonApplication(_ lesson: ClickyLesson) async throws {
        guard let bundleIdentifier = lesson.applicationBundleIdentifier else { return }

        func isLessonApplicationFrontmost() -> Bool {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
        }

        guard !isLessonApplicationFrontmost() else { return }
        await speak(line: "open \(lesson.applicationName) and bring it to the front, and we'll start.", voiceClipURL: nil)

        let deadline = Date().addingTimeInterval(Self.secondsToWaitForApplication)
        while !isLessonApplicationFrontmost(), Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func run(step: LessonStep, lessonPackage: LessonPackage) async throws {
        let followEngine = LessonFollowEngine(brain: brain, accessibilityFinder: LessonAccessibilityElementFinder())
        var modelCallsThisStep = 0

        state = .findingStep(stepNumber: step.stepNumber)
        let baselineCaptures = try await captureScreen()
        let baselineTextLines = await LessonFollowEngine.recognizedTextLines(in: baselineCaptures)

        let targetLocation = try await locateAndPoint(
            at: step,
            lessonPackage: lessonPackage,
            followEngine: followEngine,
            screenCaptures: baselineCaptures
        )
        modelCallsThisStep += targetLocation.usage == nil ? 0 : 1

        await speakStepLine(step, targetLocation: targetLocation, lessonPackage: lessonPackage)
        await waitForSpeechToFinish()

        state = .waitingForFollower(stepNumber: step.stepNumber)

        var comparisonFingerprints = Self.fingerprints(of: baselineCaptures)
        var previousTickFingerprints = comparisonFingerprints
        var lastCheckDate = Date.distantPast
        var lastGuidanceDate = Date()

        while true {
            try await Task.sleep(nanoseconds: UInt64(Self.screenWatchIntervalInSeconds * 1_000_000_000))

            if isPausedForQuestion {
                try await waitOutQuestion(step: step, lessonPackage: lessonPackage, followEngine: followEngine)
                let capturesAfterQuestion = try await captureScreen()
                comparisonFingerprints = Self.fingerprints(of: capturesAfterQuestion)
                previousTickFingerprints = comparisonFingerprints
                lastGuidanceDate = Date()
                continue
            }

            let currentCaptures = try await captureScreen()
            let currentFingerprints = Self.fingerprints(of: currentCaptures)

            let changedTilesSinceComparison = Self.changedTileCount(between: currentFingerprints, and: comparisonFingerprints)
            // Equal to the last tick means the screen has settled, which
            // avoids judging a menu halfway through opening.
            let hasSettled = Self.changedTileCount(between: currentFingerprints, and: previousTickFingerprints) == 0
            previousTickFingerprints = currentFingerprints

            let hasChanged = changedTilesSinceComparison >= Self.minimumChangedTilesToCheck
            let isCheckAllowed = Date().timeIntervalSince(lastCheckDate) >= Self.minimumSecondsBetweenChecks
            let hasModelBudget = modelCallsThisStep < Self.maximumModelCallsPerStep

            if hasChanged, hasSettled, isCheckAllowed, hasModelBudget {
                state = .checkingStep(stepNumber: step.stepNumber)
                lastCheckDate = Date()

                let verdict = try await followEngine.checkSuccess(
                    of: step,
                    currentScreenCaptures: currentCaptures,
                    baselineTextLines: baselineTextLines
                )
                record(verdict.usage, purpose: "check")
                modelCallsThisStep += verdict.usage == nil ? 0 : 1
                print("🎓 Show Me Once: step \(step.stepNumber) check \(verdict.didSucceed ? "passed" : "not yet") by \(verdict.method.rawValue): \(verdict.explanation)")

                if verdict.didSucceed {
                    return
                }

                comparisonFingerprints = currentFingerprints
                state = .waitingForFollower(stepNumber: step.stepNumber)

                if changedTilesSinceComparison >= Self.changedTilesThatMoveTheTarget, hasModelBudget {
                    let movedTarget = try await locateAndPoint(
                        at: step,
                        lessonPackage: lessonPackage,
                        followEngine: followEngine,
                        screenCaptures: currentCaptures
                    )
                    modelCallsThisStep += movedTarget.usage == nil ? 0 : 1
                }
            }

            if Date().timeIntervalSince(lastGuidanceDate) >= Self.secondsBeforeRepeatingTheLine {
                lastGuidanceDate = Date()
                await speakStepLine(step, targetLocation: currentTargetLocation, lessonPackage: lessonPackage)
            }
        }
    }

    private func locateAndPoint(
        at step: LessonStep,
        lessonPackage: LessonPackage,
        followEngine: LessonFollowEngine,
        screenCaptures: [CompanionScreenCapture]
    ) async throws -> LessonTargetLocation {
        let targetLocation = try await followEngine.locateTarget(
            of: step,
            lessonApplicationBundleIdentifier: lessonPackage.lesson.applicationBundleIdentifier,
            referenceImageData: lessonPackage.imageData(forFileName: step.element.referenceImageFileName),
            in: screenCaptures
        )
        record(targetLocation.usage, purpose: "locate")
        currentTargetLocation = targetLocation
        print("🎓 Show Me Once: step \(step.stepNumber) target by \(targetLocation.method.rawValue)")

        if let mappedPoint = targetLocation.mappedPoint, let displayFrame = targetLocation.displayFrame {
            await presenter?.pointBuddyAtLessonTarget(
                globalAppKitLocation: mappedPoint.globalAppKitPoint,
                displayFrame: displayFrame,
                bubbleText: step.bubbleText
            )
        }
        return targetLocation
    }

    /// Holds the lesson until the question is answered, then points back at
    /// the step, since the answer may have flown the cursor somewhere else.
    private func waitOutQuestion(step: LessonStep, lessonPackage: LessonPackage, followEngine: LessonFollowEngine) async throws {
        state = .answeringQuestion(stepNumber: step.stepNumber)

        // The press and the listening state are a beat apart. Without this the
        // gap would read as the question already being over.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        while presenter?.isAnsweringFollowerQuestion == true {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        isPausedForQuestion = false

        let capturesAfterQuestion = try await captureScreen()
        _ = try await locateAndPoint(
            at: step,
            lessonPackage: lessonPackage,
            followEngine: followEngine,
            screenCaptures: capturesAfterQuestion
        )
        state = .waitingForFollower(stepNumber: step.stepNumber)
    }

    private func captureScreen() async throws -> [CompanionScreenCapture] {
        // The pointer stays out of it, or merely moving the mouse would count
        // as the screen changing.
        try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(showsMousePointer: false)
    }

    private static func fingerprints(of screenCaptures: [CompanionScreenCapture]) -> [LessonScreenFingerprint] {
        screenCaptures.compactMap { LessonScreenFingerprint(imageData: $0.imageData) }
    }

    private static func changedTileCount(
        between firstFingerprints: [LessonScreenFingerprint],
        and secondFingerprints: [LessonScreenFingerprint]
    ) -> Int {
        zip(firstFingerprints, secondFingerprints).reduce(0) { changedTileTotal, fingerprintPair in
            changedTileTotal + fingerprintPair.0.changedTileCount(comparedTo: fingerprintPair.1)
        }
    }

    // MARK: Speech

    /// Plays the teacher's real voice when their line still fits this screen.
    /// A line that had to be reworded for this screen goes through `say`,
    /// because a recording can't change its words.
    private func speakStepLine(_ step: LessonStep, targetLocation: LessonTargetLocation?, lessonPackage: LessonPackage) async {
        let adaptedLine = targetLocation?.adaptedSpokenLine

        if let notFoundExplanation = targetLocation?.notFoundExplanation, targetLocation?.method == .notFound {
            await speak(line: "\(step.spokenLine) \(notFoundExplanation)", voiceClipURL: nil)
            return
        }

        await speak(
            line: adaptedLine ?? step.spokenLine,
            voiceClipURL: adaptedLine == nil ? lessonPackage.voiceClipURL(forFileName: step.voiceClipFileName) : nil
        )
    }

    private func speak(line: String, voiceClipURL: URL?) async {
        guard !line.isEmpty || voiceClipURL != nil else { return }

        if let voiceClipURL, let clipPlayer = try? AVAudioPlayer(contentsOf: voiceClipURL) {
            stopSpeaking()
            voiceClipPlayer = clipPlayer
            clipPlayer.play()
        } else {
            await presenter?.speakLessonLine(line)
        }
    }

    private var isSpeaking: Bool {
        (voiceClipPlayer?.isPlaying ?? false) || (presenter?.isSpeakingLessonLine ?? false)
    }

    private func waitForSpeechToFinish() async {
        while isSpeaking, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func stopSpeaking() {
        voiceClipPlayer?.stop()
        voiceClipPlayer = nil
        presenter?.stopLessonSpeech()
    }

    // MARK: Cost

    private func record(_ usage: BrainUsage?, purpose: String) {
        guard let usage else { return }
        costSamples.append(LessonCostSample(purpose: purpose, usage: usage))
    }

    /// Saves this run's real figures into the lesson, so the share card can
    /// show what a replay cost rather than an estimate from one rehearsal.
    private func recordFinishedRun(_ lessonPackage: LessonPackage) {
        var updatedLesson = lessonPackage.lesson
        updatedLesson.costEvidence.replayRuns.append(LessonReplayRun(
            finishedAt: Date(),
            captureSource: "screencapturekit",
            calls: costSamples
        ))

        do {
            try LessonPackageArchiver.rewriteLesson(updatedLesson, in: lessonPackage)
        } catch {
            print("⚠️ Show Me Once: couldn't save this run's cost figures: \(error.localizedDescription)")
        }
    }
}
