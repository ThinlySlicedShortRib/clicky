//
//  HeadlessLessonCommands.swift
//  leanring-buddy
//
//  Scripted checks for Show Me Once. Replay is the only code that feeds saved
//  images into lesson logic, and it can only be reached through a --headless-*
//  flag, which never starts the menu bar app. A live lesson has no route here:
//  LessonFollowController always captures with ScreenCaptureKit.
//
//  Each result reports its `captureSource`, and synthetic lessons stay labelled,
//  so nobody can mistake one of these runs for a real lesson on a real screen.
//

import AppKit
import AVFoundation
import Foundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Commands

enum HeadlessLessonCommand {
    case selfTest
    case preflight(shouldRequestPermissions: Bool)
    case compileRecording(recordingDirectoryPath: String, lessonOutputPath: String, modelValue: String)
    case followReplay(lessonPath: String, manifestPath: String, modelValue: String, shouldFlyOverlay: Bool, shouldSaveReplayCost: Bool)
    case question(lessonPath: String, questionText: String, imagePath: String, stepIndex: Int, modelValue: String)
    case shareCard(lessonPath: String, pngOutputPath: String)
    case indicatorImage(pngOutputPath: String, isPausedForSecureInput: Bool)
    case findText(imagePath: String, text: String)
    case presenter(lessonPath: String)
    case narrationFile(audioFilePath: String)
    case panelSection(pngOutputPath: String)
    case changedRows(beforeImagePath: String, afterImagePath: String, columnStartInPixels: Int, columnEndInPixels: Int)

    static func parse(arguments: [String], onUsageError: (String) -> Never) -> HeadlessLessonCommand? {
        func value(after flag: String) -> String? {
            guard let flagIndex = arguments.firstIndex(of: flag), flagIndex + 1 < arguments.count else { return nil }
            return arguments[flagIndex + 1]
        }

        func requiredValue(after flag: String) -> String {
            guard let flagValue = value(after: flag) else {
                onUsageError("\(flag) is required for this command")
            }
            return flagValue
        }

        let modelValue = value(after: "--model") ?? BrainConfiguration.configuredModelValue

        if arguments.contains("--headless-lesson-self-test") {
            return .selfTest
        }
        if arguments.contains("--headless-lesson-preflight") {
            return .preflight(shouldRequestPermissions: arguments.contains("--request-permissions"))
        }
        if let recordingDirectoryPath = value(after: "--headless-compile-recording") {
            return .compileRecording(
                recordingDirectoryPath: recordingDirectoryPath,
                lessonOutputPath: requiredValue(after: "--lesson-output"),
                modelValue: modelValue
            )
        }
        if let lessonPath = value(after: "--headless-follow-replay") {
            return .followReplay(
                lessonPath: lessonPath,
                manifestPath: requiredValue(after: "--replay-manifest"),
                modelValue: modelValue,
                shouldFlyOverlay: arguments.contains("--fly"),
                shouldSaveReplayCost: arguments.contains("--save-replay-cost")
            )
        }
        if let lessonPath = value(after: "--headless-lesson-question") {
            return .question(
                lessonPath: lessonPath,
                questionText: requiredValue(after: "--question"),
                imagePath: requiredValue(after: "--image"),
                stepIndex: value(after: "--step").flatMap { Int($0) } ?? 0,
                modelValue: modelValue
            )
        }
        if let lessonPath = value(after: "--headless-share-card") {
            return .shareCard(lessonPath: lessonPath, pngOutputPath: requiredValue(after: "--card-output"))
        }
        if let pngOutputPath = value(after: "--headless-teach-indicator") {
            return .indicatorImage(pngOutputPath: pngOutputPath, isPausedForSecureInput: arguments.contains("--secure"))
        }
        if let imagePath = value(after: "--headless-find-text") {
            return .findText(imagePath: imagePath, text: requiredValue(after: "--text"))
        }
        if let lessonPath = value(after: "--headless-lesson-presenter") {
            return .presenter(lessonPath: lessonPath)
        }
        if let audioFilePath = value(after: "--headless-narration-file") {
            return .narrationFile(audioFilePath: audioFilePath)
        }
        if let pngOutputPath = value(after: "--headless-panel-section") {
            return .panelSection(pngOutputPath: pngOutputPath)
        }
        if let beforeImagePath = value(after: "--headless-changed-rows") {
            guard let columnStartInPixels = Int(requiredValue(after: "--column-start")),
                  let columnEndInPixels = Int(requiredValue(after: "--column-end")) else {
                onUsageError("--column-start and --column-end expect pixel columns")
            }
            return .changedRows(
                beforeImagePath: beforeImagePath,
                afterImagePath: requiredValue(after: "--after"),
                columnStartInPixels: columnStartInPixels,
                columnEndInPixels: columnEndInPixels
            )
        }
        return nil
    }
}

// MARK: - Replay Manifest

/// Saved screens standing in for a follower's setup, one before/after pair per
/// step. Written by scripts/make-synthetic-lesson.py.
private struct LessonReplayManifest: Decodable {
    struct ManifestRectangle: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    struct ManifestStep: Decodable {
        let beforeImagePath: String
        let afterImagePath: String
        /// Where the window sits on the display, in top-left points.
        let imageRectInDisplayPoints: ManifestRectangle?
        /// Ground truth that doesn't come from the model.
        let groundTruthText: String?
        let groundTruthRectInDisplayPoints: ManifestRectangle?
        /// A screen where something else changed instead, to prove that a
        /// change alone can't pass the step.
        let wrongChangeImagePath: String
    }

    let setupDescription: String
    let steps: [ManifestStep]
}

// MARK: - Runner

@MainActor
struct HeadlessLessonCommandRunner {
    let companionManager: CompanionManager

    func run(_ command: HeadlessLessonCommand) async {
        switch command {
        case .selfTest:
            LessonSelfTest.run()
        case .preflight(let shouldRequestPermissions):
            await runPreflight(shouldRequestPermissions: shouldRequestPermissions)
        case .compileRecording(let recordingDirectoryPath, let lessonOutputPath, let modelValue):
            await runCompile(recordingDirectoryPath: recordingDirectoryPath, lessonOutputPath: lessonOutputPath, modelValue: modelValue)
        case .followReplay(let lessonPath, let manifestPath, let modelValue, let shouldFlyOverlay, let shouldSaveReplayCost):
            await runFollowReplay(
                lessonPath: lessonPath,
                manifestPath: manifestPath,
                modelValue: modelValue,
                shouldFlyOverlay: shouldFlyOverlay,
                shouldSaveReplayCost: shouldSaveReplayCost
            )
        case .question(let lessonPath, let questionText, let imagePath, let stepIndex, let modelValue):
            await runQuestion(lessonPath: lessonPath, questionText: questionText, imagePath: imagePath, stepIndex: stepIndex, modelValue: modelValue)
        case .shareCard(let lessonPath, let pngOutputPath):
            runShareCard(lessonPath: lessonPath, pngOutputPath: pngOutputPath)
        case .indicatorImage(let pngOutputPath, let isPausedForSecureInput):
            runIndicatorImage(pngOutputPath: pngOutputPath, isPausedForSecureInput: isPausedForSecureInput)
        case .findText(let imagePath, let text):
            runFindText(imagePath: imagePath, text: text)
        case .presenter(let lessonPath):
            await runPresenterCheck(lessonPath: lessonPath)
        case .narrationFile(let audioFilePath):
            await runNarrationFile(audioFilePath: audioFilePath)
        case .panelSection(let pngOutputPath):
            runPanelSection(pngOutputPath: pngOutputPath)
        case .changedRows(let beforeImagePath, let afterImagePath, let columnStartInPixels, let columnEndInPixels):
            runChangedRows(
                beforeImagePath: beforeImagePath,
                afterImagePath: afterImagePath,
                columnStartInPixels: columnStartInPixels,
                columnEndInPixels: columnEndInPixels
            )
        }
    }

    private func openLessonOrExit(at lessonPath: String) -> LessonPackage {
        do {
            return try LessonPackageArchiver.openArchive(at: URL(fileURLWithPath: lessonPath))
        } catch {
            HeadlessOutput.finish(["status": "failed", "error": error.localizedDescription], exitCode: 1)
        }
    }

    // MARK: Preflight

    /// Everything the live demo needs, as one report. Nothing here is faked if
    /// missing: each line says what's wrong and what would fix it.
    private func runPreflight(shouldRequestPermissions: Bool) async {
        // Only a person can answer these prompts, so this puts them all up at
        // once for whoever is setting up the Mac. Nothing here can grant them.
        if shouldRequestPermissions {
            _ = await TeachNarrationCapture.requestPermissions()
            _ = CGRequestScreenCaptureAccess()
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }

        let hasAccessibility = AXIsProcessTrusted()
        let microphoneStatus = HeadlessCommandRunner.describe(AVCaptureDevice.authorizationStatus(for: .audio))
        let speechStatus = HeadlessCommandRunner.describe(SFSpeechRecognizer.authorizationStatus())
        let speechRecognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

        var screenCaptureResult = "ok"
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            screenCaptureResult = "ok: \(screenCaptures.count) display(s)"
        } catch {
            screenCaptureResult = "failed: \(error.localizedDescription)"
        }
        let hasScreenCapture = screenCaptureResult.hasPrefix("ok")

        let lessonFileHandlerPath = LessonFileType.contentTypes.first
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }?
            .path
        let isHandledByThisBuild = lessonFileHandlerPath == Bundle.main.bundlePath

        var missingForTeaching: [String] = []
        if !hasScreenCapture { missingForTeaching.append("Screen & System Audio Recording") }
        if !hasAccessibility { missingForTeaching.append("Accessibility") }
        if microphoneStatus != "authorized" { missingForTeaching.append("Microphone") }
        if speechStatus != "authorized" { missingForTeaching.append("Speech Recognition") }

        var missingForFollowing: [String] = []
        if !hasScreenCapture { missingForFollowing.append("Screen & System Audio Recording") }

        var missingForQuestions = missingForFollowing
        if !hasAccessibility { missingForQuestions.append("Accessibility") }
        if microphoneStatus != "authorized" { missingForQuestions.append("Microphone") }
        if speechStatus != "authorized" { missingForQuestions.append("Speech Recognition") }

        let isEverythingReady = missingForTeaching.isEmpty && missingForQuestions.isEmpty

        HeadlessOutput.finish([
            "status": isEverythingReady ? "ok" : "permissions_missing",
            "bundlePath": Bundle.main.bundlePath,
            "screenCapture": screenCaptureResult,
            "accessibilityTrusted": hasAccessibility,
            "microphone": microphoneStatus,
            "speechRecognition": speechStatus,
            "speechOnDeviceSupported": speechRecognizer?.supportsOnDeviceRecognition ?? false,
            "brainModel": BrainConfiguration.configuredModelValue,
            "lessonFileHandler": lessonFileHandlerPath ?? NSNull(),
            "lessonFilesOpenInThisBuild": isHandledByThisBuild,
            "missingForTeaching": missingForTeaching,
            "missingForFollowing": missingForFollowing,
            "missingForQuestions": missingForQuestions
        ], exitCode: isEverythingReady ? 0 : 3)
    }

    // MARK: Compile

    private func runCompile(recordingDirectoryPath: String, lessonOutputPath: String, modelValue: String) async {
        let compileStartDate = Date()
        let compiler = LessonCompiler(brain: BrainConfiguration.makeBrain(modelValue: modelValue))

        do {
            let compilationResult = try await compiler.compile(
                recordingDirectoryURL: URL(fileURLWithPath: recordingDirectoryPath, isDirectory: true),
                archiveURL: URL(fileURLWithPath: lessonOutputPath),
                deleteRecordingAfterwards: false
            )

            let lesson = compilationResult.lesson
            let compileCostSamples = lesson.costEvidence.compileCalls
            HeadlessOutput.finish([
                "status": "ok",
                "model": modelValue,
                "provenance": lesson.provenance.kind.rawValue,
                "lessonPath": compilationResult.archiveURL.path,
                "lessonTitle": lesson.title,
                "stepCount": lesson.steps.count,
                "archiveSizeInBytes": compilationResult.archiveSizeInBytes,
                "compileSeconds": round(Date().timeIntervalSince(compileStartDate) * 10) / 10,
                "compileCalls": compileCostSamples.map { HeadlessOutput.json($0.usage) },
                "rehearsalCalls": lesson.costEvidence.rehearsalCalls.map { HeadlessOutput.json($0.usage) },
                "spokenLineSources": lesson.steps.map(\.spokenLineSource.rawValue),
                "teacherWordOverlap": lesson.steps.map(\.teacherWordOverlap),
                "voiceClips": lesson.steps.map { $0.voiceClipFileName ?? NSNull() as Any }
            ], exitCode: 0)
        } catch {
            HeadlessOutput.finish(["status": "failed", "error": error.localizedDescription], exitCode: 1)
        }
    }

    // MARK: Follow Replay

    private func runFollowReplay(
        lessonPath: String,
        manifestPath: String,
        modelValue: String,
        shouldFlyOverlay: Bool,
        shouldSaveReplayCost: Bool
    ) async {
        let lessonPackage = openLessonOrExit(at: lessonPath)
        let lesson = lessonPackage.lesson

        guard let manifestData = FileManager.default.contents(atPath: manifestPath),
              let replayManifest = try? JSONDecoder().decode(LessonReplayManifest.self, from: manifestData) else {
            HeadlessOutput.finish(["status": "failed", "error": "could not read replay manifest at \(manifestPath)"], exitCode: 1)
        }
        guard replayManifest.steps.count == lesson.steps.count else {
            HeadlessOutput.finish([
                "status": "failed",
                "error": "manifest has \(replayManifest.steps.count) steps but the lesson has \(lesson.steps.count)"
            ], exitCode: 1)
        }

        let followEngine = LessonFollowEngine(
            brain: BrainConfiguration.makeBrain(modelValue: modelValue),
            accessibilityFinder: nil
        )
        let primaryDisplayFrame = NSScreen.screens.first?.frame ?? .zero

        var stepResults: [[String: Any]] = []
        /// What a follower would pay for: locating, and judging the real result.
        var costSamples: [LessonCostSample] = []
        /// Calls that only exist to test the check. They're reported, but they
        /// stay out of the lesson's cost, which they'd otherwise inflate.
        var controlCostSamples: [LessonCostSample] = []
        var failedStepCount = 0
        var unverifiedStepCount = 0

        for (stepIndex, step) in lesson.steps.enumerated() {
            let manifestStep = replayManifest.steps[stepIndex]
            var stepResult: [String: Any] = ["stepNumber": step.stepNumber, "intent": step.intent]

            do {
                let imageRect = manifestStep.imageRectInDisplayPoints?.cgRect

                func makeFixture(imagePath: String) throws -> (screenCapture: CompanionScreenCapture, groundTruthImage: GroundTruthImage) {
                    try FixtureScreenCapture.make(
                        imagePath: imagePath,
                        imageRectInDisplayPoints: imageRect,
                        displayFrame: primaryDisplayFrame,
                        label: "user's screen (cursor is here)",
                        screenNumber: 1,
                        isCursorScreen: true,
                        maximumScreenshotDimension: CompanionScreenCaptureUtility.maximumScreenshotDimension
                    )
                }

                let beforeFixture = try makeFixture(imagePath: manifestStep.beforeImagePath)
                let afterFixture = try makeFixture(imagePath: manifestStep.afterImagePath)

                if let beforeFingerprint = LessonScreenFingerprint(imageData: beforeFixture.screenCapture.imageData),
                   let afterFingerprint = LessonScreenFingerprint(imageData: afterFixture.screenCapture.imageData) {
                    stepResult["changedTilesBeforeToAfter"] = beforeFingerprint.changedTileCount(comparedTo: afterFingerprint)
                }

                // Locate, against the step's "before" screen.
                let targetLocation = try await followEngine.locateTarget(
                    of: step,
                    lessonApplicationBundleIdentifier: lesson.applicationBundleIdentifier,
                    referenceImageData: lessonPackage.imageData(forFileName: step.element.referenceImageFileName),
                    in: [beforeFixture.screenCapture]
                )
                if let usage = targetLocation.usage {
                    costSamples.append(LessonCostSample(purpose: "locate", usage: usage))
                    stepResult["locateCostInUSD"] = usage.costInUSD ?? NSNull()
                }
                stepResult["locateMethod"] = targetLocation.method.rawValue
                stepResult["rawLocateResponse"] = targetLocation.rawModelResponse ?? NSNull()
                stepResult["adaptedLine"] = targetLocation.adaptedSpokenLine ?? NSNull()

                var didLandOnTarget: Bool?
                if let mappedPoint = targetLocation.mappedPoint {
                    stepResult["pointInDisplayPoints"] = HeadlessOutput.json(mappedPoint.displayLocalPoint)

                    if let groundTruthText = manifestStep.groundTruthText {
                        let textVerification = OCRGroundTruth.verify(
                            pointInDisplayPoints: mappedPoint.displayLocalPoint,
                            landsOnText: groundTruthText,
                            in: beforeFixture.groundTruthImage
                        )
                        stepResult["textVerification"] = textVerification
                        didLandOnTarget = textVerification["error"] == nil ? (textVerification["hit"] as? Bool) : nil
                    } else if let groundTruthRect = manifestStep.groundTruthRectInDisplayPoints?.cgRect {
                        let isInsideRect = groundTruthRect.contains(mappedPoint.displayLocalPoint)
                        stepResult["rectVerification"] = [
                            "rectInDisplayPoints": HeadlessOutput.json(groundTruthRect),
                            "hit": isInsideRect
                        ]
                        didLandOnTarget = isInsideRect
                    }

                    if shouldFlyOverlay, let displayFrame = targetLocation.displayFrame {
                        let tipLocation = await companionManager.flyBuddyForScriptedCheck(
                            toGlobalAppKitLocation: mappedPoint.globalAppKitPoint,
                            displayFrame: displayFrame,
                            bubbleText: step.bubbleText
                        )
                        stepResult["overlayLandingErrorInPoints"] = round(hypot(
                            tipLocation.x - mappedPoint.globalAppKitPoint.x,
                            tipLocation.y - mappedPoint.globalAppKitPoint.y
                        ) * 100) / 100
                    }
                } else {
                    didLandOnTarget = false
                    stepResult["notFoundExplanation"] = targetLocation.notFoundExplanation ?? NSNull()
                }

                // Negative control: the check has to say no before the action,
                // or a pass after it would mean nothing.
                let baselineTextLines = await LessonFollowEngine.recognizedTextLines(in: [beforeFixture.screenCapture])
                let verdictBeforeAction = try await followEngine.checkSuccess(
                    of: step,
                    currentScreenCaptures: [beforeFixture.screenCapture],
                    baselineScreenCaptures: [beforeFixture.screenCapture],
                    baselineTextLines: baselineTextLines
                )
                if let usage = verdictBeforeAction.usage {
                    controlCostSamples.append(LessonCostSample(purpose: "check", usage: usage))
                }

                // A second control: the screen did change, but not in the way
                // this step asks for, so it still has to say no.
                let wrongChangeFixture = try makeFixture(imagePath: manifestStep.wrongChangeImagePath)
                let verdictAfterWrongChange = try await followEngine.checkSuccess(
                    of: step,
                    currentScreenCaptures: [wrongChangeFixture.screenCapture],
                    baselineScreenCaptures: [beforeFixture.screenCapture],
                    baselineTextLines: baselineTextLines
                )
                if let usage = verdictAfterWrongChange.usage {
                    controlCostSamples.append(LessonCostSample(purpose: "check", usage: usage))
                }

                let verdictAfterAction = try await followEngine.checkSuccess(
                    of: step,
                    currentScreenCaptures: [afterFixture.screenCapture],
                    baselineScreenCaptures: [beforeFixture.screenCapture],
                    baselineTextLines: baselineTextLines
                )
                if let usage = verdictAfterAction.usage {
                    costSamples.append(LessonCostSample(purpose: "check", usage: usage))
                }

                stepResult["checkBeforeAction"] = [
                    "passed": verdictBeforeAction.didSucceed,
                    "method": verdictBeforeAction.method.rawValue,
                    "explanation": verdictBeforeAction.explanation
                ]
                stepResult["checkAfterWrongChange"] = [
                    "passed": verdictAfterWrongChange.didSucceed,
                    "method": verdictAfterWrongChange.method.rawValue,
                    "explanation": verdictAfterWrongChange.explanation
                ]
                stepResult["checkAfterAction"] = [
                    "passed": verdictAfterAction.didSucceed,
                    "method": verdictAfterAction.method.rawValue,
                    "explanation": verdictAfterAction.explanation
                ]

                let checksAreCorrect = !verdictBeforeAction.didSucceed
                    && !verdictAfterWrongChange.didSucceed
                    && verdictAfterAction.didSucceed
                stepResult["checksCorrect"] = checksAreCorrect
                stepResult["landedOnTarget"] = didLandOnTarget ?? NSNull()

                if didLandOnTarget == nil {
                    unverifiedStepCount += 1
                }
                if didLandOnTarget == false || !checksAreCorrect {
                    failedStepCount += 1
                }
            } catch {
                stepResult["error"] = error.localizedDescription
                failedStepCount += 1
            }

            stepResults.append(stepResult)
        }

        let reportedCosts = costSamples.compactMap(\.usage.costInUSD)
        let reportedControlCosts = controlCostSamples.compactMap(\.usage.costInUSD)

        if shouldSaveReplayCost {
            var updatedLesson = lesson
            updatedLesson.costEvidence.replayRuns.append(LessonReplayRun(
                finishedAt: Date(),
                captureSource: "fixture",
                calls: costSamples
            ))
            try? LessonPackageArchiver.rewriteLesson(updatedLesson, in: lessonPackage)
        }

        HeadlessOutput.finish([
            "status": failedStepCount == 0 ? (unverifiedStepCount == 0 ? "ok" : "unverified") : "verification_failed",
            "captureSource": "fixture",
            "capturePathNote": "saved window exports placed where the window server says the window is: ScreenCaptureKit was not exercised by this run",
            "lessonProvenance": lesson.provenance.kind.rawValue,
            "setup": replayManifest.setupDescription,
            "model": modelValue,
            "stepCount": lesson.steps.count,
            "failedStepCount": failedStepCount,
            "unverifiedStepCount": unverifiedStepCount,
            "modelCallCount": costSamples.count,
            "totalCostInUSDEstimated": reportedCosts.reduce(0, +),
            "controlCallCount": controlCostSamples.count,
            "controlCostInUSDEstimatedExcludedFromTotal": reportedControlCosts.reduce(0, +),
            "costIsEstimated": costSamples.contains { $0.usage.isCostEstimated },
            "costSource": costSamples.first?.usage.costSourceDescription ?? NSNull(),
            "steps": stepResults
        ], exitCode: failedStepCount == 0 && unverifiedStepCount == 0 ? 0 : 1)
    }

    // MARK: Question

    private func runQuestion(lessonPath: String, questionText: String, imagePath: String, stepIndex: Int, modelValue: String) async {
        let lessonPackage = openLessonOrExit(at: lessonPath)
        let brain = BrainConfiguration.makeBrain(modelValue: modelValue)

        do {
            let fixture = try FixtureScreenCapture.make(
                imagePath: imagePath,
                imageRectInDisplayPoints: nil,
                displayFrame: NSScreen.screens.first?.frame ?? .zero,
                label: "user's screen (cursor is here)",
                screenNumber: 1,
                isCursorScreen: true,
                maximumScreenshotDimension: CompanionScreenCaptureUtility.maximumScreenshotDimension
            )

            let brainResponse = try await brain.respond(
                to: BrainRequest(
                    systemPrompt: LessonQuestionPrompt.makeSystemPrompt(lesson: lessonPackage.lesson, currentStepIndex: stepIndex),
                    conversationHistory: [],
                    userPrompt: questionText,
                    images: CompanionManager.makeBrainImages(from: [fixture.screenCapture])
                ),
                onTextDelta: { _ in }
            )

            let parseResult = CompanionManager.parsePointingCoordinates(from: brainResponse.text)
            HeadlessOutput.finish([
                "status": "ok",
                "captureSource": "fixture",
                "question": questionText,
                "spokenAnswer": parseResult.spokenText,
                "usage": HeadlessOutput.json(brainResponse.usage)
            ], exitCode: 0)
        } catch {
            HeadlessOutput.finish(["status": "failed", "error": error.localizedDescription], exitCode: 1)
        }
    }

    // MARK: Images

    private func runShareCard(lessonPath: String, pngOutputPath: String) {
        let lessonPackage = openLessonOrExit(at: lessonPath)
        let cardContent = LessonShareCardContent(lessonPackage: lessonPackage)

        guard let pngData = LessonShareCardRenderer.pngData(for: cardContent),
              (try? pngData.write(to: URL(fileURLWithPath: pngOutputPath))) != nil else {
            HeadlessOutput.finish(["status": "failed", "error": "could not render the share card"], exitCode: 1)
        }

        HeadlessOutput.finish([
            "status": "ok",
            "cardPath": pngOutputPath,
            "title": cardContent.title,
            "teacherName": cardContent.teacherName,
            "stepCount": cardContent.stepCount,
            "size": cardContent.sizeText,
            "replayCost": cardContent.replayCostText,
            "costFootnote": cardContent.costFootnote,
            "provenanceWarning": cardContent.provenanceWarning ?? NSNull()
        ], exitCode: 0)
    }

    private func runIndicatorImage(pngOutputPath: String, isPausedForSecureInput: Bool) {
        let imageRenderer = ImageRenderer(content:
            TeachModeIndicatorView(isPausedForSecureInput: isPausedForSecureInput, actionCount: 3, elapsedSeconds: 42)
                .padding(20)
                .background(Color(white: 0.85))
        )
        imageRenderer.scale = 2

        guard let renderedImage = imageRenderer.cgImage,
              let pngData = NSBitmapImageRep(cgImage: renderedImage).representation(using: .png, properties: [:]),
              (try? pngData.write(to: URL(fileURLWithPath: pngOutputPath))) != nil else {
            HeadlessOutput.finish(["status": "failed", "error": "could not render the indicator"], exitCode: 1)
        }
        HeadlessOutput.finish(["status": "ok", "indicatorPath": pngOutputPath], exitCode: 0)
    }

    /// Drives the real cursor through what a lesson does to it: fly, stay for
    /// longer than a normal point would, then let go. Also loads every voice
    /// clip through the player live follow mode uses. Needs no permissions.
    private func runPresenterCheck(lessonPath: String) async {
        let lessonPackage = openLessonOrExit(at: lessonPath)
        guard let displayFrame = NSScreen.screens.first?.frame else {
            HeadlessOutput.finish(["status": "failed", "error": "no display"], exitCode: 1)
        }

        /// A normal point flies home about 3.5 seconds after landing.
        let holdSecondsLongerThanANormalPoint: UInt64 = 7
        let target = CGPoint(x: displayFrame.midX + 200, y: displayFrame.midY + 100)
        let flightStartDate = Date()

        await companionManager.pointBuddyAtLessonTarget(
            globalAppKitLocation: target,
            displayFrame: displayFrame,
            bubbleText: lessonPackage.lesson.steps[0].bubbleText
        )
        let flightSeconds = Date().timeIntervalSince(flightStartDate)
        let wasHoldingAfterLanding = companionManager.detectedElementScreenLocation != nil

        try? await Task.sleep(nanoseconds: holdSecondsLongerThanANormalPoint * 1_000_000_000)
        let wasStillHolding = companionManager.detectedElementScreenLocation == target

        // A second point at the same spot is what follows a question.
        await companionManager.pointBuddyAtLessonTarget(
            globalAppKitLocation: target,
            displayFrame: displayFrame,
            bubbleText: lessonPackage.lesson.steps[0].bubbleText
        )
        let didRepeatAtSameSpot = companionManager.detectedElementScreenLocation == target

        companionManager.releaseLessonPoint()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let wasReleased = companionManager.detectedElementScreenLocation == nil

        var clipDurationsInSeconds: [String: Double] = [:]
        var unplayableClips: [String] = []
        for step in lessonPackage.lesson.steps {
            guard let clipURL = lessonPackage.voiceClipURL(forFileName: step.voiceClipFileName) else { continue }
            if let clipPlayer = try? AVAudioPlayer(contentsOf: clipURL), clipPlayer.prepareToPlay(), clipPlayer.duration > 0 {
                clipDurationsInSeconds[clipURL.lastPathComponent] = round(clipPlayer.duration * 100) / 100
            } else {
                unplayableClips.append(clipURL.lastPathComponent)
            }
        }

        let didPass = wasHoldingAfterLanding && wasStillHolding && didRepeatAtSameSpot && wasReleased && unplayableClips.isEmpty
        HeadlessOutput.finish([
            "status": didPass ? "ok" : "failed",
            "flightSeconds": round(flightSeconds * 100) / 100,
            "heldAfterLanding": wasHoldingAfterLanding,
            "stillHoldingAfterSeconds": holdSecondsLongerThanANormalPoint,
            "stillHolding": wasStillHolding,
            "repeatPointAtSameSpotWorked": didRepeatAtSameSpot,
            "releasedWhenAsked": wasReleased,
            "voiceClipDurationsInSeconds": clipDurationsInSeconds,
            "unplayableClips": unplayableClips,
            "note": "the audio files were loaded, not played aloud, and no pixels were captured"
        ], exitCode: didPass ? 0 : 1)
    }

    /// Teach mode's own recognition code on a spoken file. Needs Speech
    /// Recognition, and proves nothing about the microphone itself.
    private func runNarrationFile(audioFilePath: String) async {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        guard speechStatus == .authorized else {
            HeadlessOutput.finish([
                "status": "permission_missing",
                "speechRecognition": HeadlessCommandRunner.describe(speechStatus)
            ], exitCode: 3)
        }

        let narrationCapture = TeachNarrationCapture(
            narrationAudioFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).m4a")
        )
        let startDate = Date()

        do {
            let narrationSegments = try await narrationCapture.transcribeFileForCheck(at: URL(fileURLWithPath: audioFilePath))
            HeadlessOutput.finish([
                "status": narrationSegments.isEmpty ? "failed" : "ok",
                "seconds": round(Date().timeIntervalSince(startDate) * 10) / 10,
                "recognizerLocale": narrationCapture.recognizerLocaleIdentifier,
                "onDeviceSupported": narrationCapture.supportsOnDeviceRecognition,
                "recognitionError": narrationCapture.lastRecognitionErrorDescription ?? NSNull(),
                "segments": narrationSegments.map { segment in
                    ["text": segment.text, "startSeconds": segment.startSeconds, "endSeconds": segment.endSeconds] as [String: Any]
                }
            ], exitCode: narrationSegments.isEmpty ? 1 : 0)
        } catch {
            HeadlessOutput.finish(["status": "failed", "error": error.localizedDescription], exitCode: 1)
        }
    }

    private func runPanelSection(pngOutputPath: String) {
        // ImageRenderer draws a placeholder for buttons and drop targets, which
        // are AppKit underneath, so this goes through a real hosting view.
        let hostingView = NSHostingView(rootView:
            ShowMeOncePanelSection(coordinator: ShowMeOnceCoordinator())
                .frame(width: 288)
                .padding(16)
                .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        )
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            HeadlessOutput.finish(["status": "failed", "error": "could not render the panel section"], exitCode: 1)
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]),
              (try? pngData.write(to: URL(fileURLWithPath: pngOutputPath))) != nil else {
            HeadlessOutput.finish(["status": "failed", "error": "could not write the panel section"], exitCode: 1)
        }
        HeadlessOutput.finish(["status": "ok", "panelSectionPath": pngOutputPath], exitCode: 0)
    }

    /// Which rows differ between two images, within a band of columns. A tab
    /// strip's active highlight moves when a tab is chosen, so this finds a
    /// wordless tab from the app's own pixels, with no help from the model.
    private func runChangedRows(beforeImagePath: String, afterImagePath: String, columnStartInPixels: Int, columnEndInPixels: Int) {
        func readPixels(_ imagePath: String) -> NSBitmapImageRep? {
            FileManager.default.contents(atPath: imagePath).flatMap { NSBitmapImageRep(data: $0) }
        }

        guard let beforeBitmap = readPixels(beforeImagePath),
              let afterBitmap = readPixels(afterImagePath),
              beforeBitmap.pixelsHigh == afterBitmap.pixelsHigh,
              beforeBitmap.pixelsWide == afterBitmap.pixelsWide else {
            HeadlessOutput.finish(["status": "failed", "error": "could not read two images of the same size"], exitCode: 1)
        }

        var changedBands: [[String: Int]] = []
        var openBandStartRow: Int?

        for rowIndex in 0..<beforeBitmap.pixelsHigh {
            var rowDiffers = false
            for columnIndex in columnStartInPixels..<min(columnEndInPixels, beforeBitmap.pixelsWide) {
                guard let beforeColor = beforeBitmap.colorAt(x: columnIndex, y: rowIndex),
                      let afterColor = afterBitmap.colorAt(x: columnIndex, y: rowIndex) else { continue }
                if abs(beforeColor.brightnessComponent - afterColor.brightnessComponent) > 0.04 {
                    rowDiffers = true
                    break
                }
            }

            if rowDiffers, openBandStartRow == nil {
                openBandStartRow = rowIndex
            } else if !rowDiffers, let bandStartRow = openBandStartRow {
                changedBands.append(["startRow": bandStartRow, "endRow": rowIndex])
                openBandStartRow = nil
            }
        }

        HeadlessOutput.finish(["status": "ok", "changedBandsInPixels": changedBands], exitCode: 0)
    }

    /// Where OCR sees a word in an image, in that image's pixels. It lets test
    /// scripts place synthetic clicks using ground truth rather than guesses.
    private func runFindText(imagePath: String, text: String) {
        guard let imageData = FileManager.default.contents(atPath: imagePath),
              let sourceBitmap = NSBitmapImageRep(data: imageData),
              let sourceImage = sourceBitmap.cgImage else {
            HeadlessOutput.finish(["status": "failed", "error": "could not read \(imagePath)"], exitCode: 1)
        }

        let boxes = OCRGroundTruth.findWholeWordBoxes(
            of: text,
            in: sourceImage,
            displayRect: CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        )
        HeadlessOutput.finish([
            "status": boxes.isEmpty ? "failed" : "ok",
            "imageSizeInPixels": ["width": sourceImage.width, "height": sourceImage.height],
            "boxesInPixels": boxes.map { HeadlessOutput.json($0) }
        ], exitCode: boxes.isEmpty ? 1 : 0)
    }
}

// MARK: - Self Test

/// Checks the rules that have to hold without a model or any permission: what
/// teach mode may keep, how a lesson file is opened, and how costs are shown.
@MainActor
enum LessonSelfTest {
    static func run() {
        var failures: [String] = []
        var checkCount = 0

        func expect(_ condition: Bool, _ description: String) {
            checkCount += 1
            if !condition {
                failures.append(description)
            }
        }

        checkKeystrokePrivacy(expect)
        checkClicksAndDrags(expect)
        checkSecureInput(expect)
        checkNarrationAlignment(expect)
        checkTeacherWords(expect)
        checkModelReplyParsing(expect)
        checkOnDeviceTextRule(expect)
        checkCostRules(expect)
        checkPackageSafety(expect)
        checkScreenFingerprint(expect)
        checkNarrationSinkOnAudioThread(expect)
        let accessibilityReport = checkAccessibilityReaderOnOwnWindow(expect)

        HeadlessOutput.finish([
            "status": failures.isEmpty ? "ok" : "failed",
            "checks": checkCount,
            "failures": failures,
            "ownWindowAccessibility": accessibilityReport
        ], exitCode: failures.isEmpty ? 0 : 1)
    }

    private typealias Expectation = (Bool, String) -> Void

    private static func makeContext(isOverSecureField: Bool = false) -> TeachActionContext {
        TeachActionContext(
            applicationName: "Numbers",
            applicationBundleIdentifier: "com.apple.Numbers",
            element: TeachElementSnapshot(role: "AXButton", subrole: nil, title: "Chart", accessibilityDescription: nil, helpText: nil, frameInDisplayPoints: nil),
            windowFrameInDisplayPoints: nil,
            isOverSecureField: isOverSecureField
        )
    }

    private static func checkKeystrokePrivacy(_ expect: Expectation) {
        let letter = TeachKeystrokeCategorizer.category(forKeyCode: 0, isCommandHeld: false, isControlHeld: false)
        expect(letter == .letter, "a plain key is only ever a letter category")

        let digit = TeachKeystrokeCategorizer.category(forKeyCode: 18, isCommandHeld: false, isControlHeld: false)
        expect(digit == .digit, "a number key is only ever a digit category")

        let shortcut = TeachKeystrokeCategorizer.category(forKeyCode: 8, isCommandHeld: true, isControlHeld: false)
        expect(shortcut == .shortcut(name: "command+c"), "command+c keeps its name")

        var accumulator = TeachInputAccumulator()
        for keyOffset in 0..<5 {
            accumulator.ingest(.keystroke(category: .letter, secondsFromStart: 1 + Double(keyOffset) * 0.1, context: makeContext()))
        }
        accumulator.finish(atSecondsFromStart: 3)
        expect(accumulator.actions.count == 1, "keys in quick succession are one typing action")
        expect(accumulator.actions.first?.keystrokeSummary?.letterCount == 5, "typing is stored as a count")

        let encodedActions = (try? JSONEncoder().encode(accumulator.actions)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        expect(!encodedActions.contains("characters") && encodedActions.contains("letterCount"), "a typing action's json holds counts and no characters field")

        var pausedAccumulator = TeachInputAccumulator()
        pausedAccumulator.ingest(.keystroke(category: .letter, secondsFromStart: 1, context: makeContext()))
        pausedAccumulator.ingest(.keystroke(category: .letter, secondsFromStart: 4, context: makeContext()))
        pausedAccumulator.finish(atSecondsFromStart: 5)
        expect(pausedAccumulator.actions.count == 2, "a long pause splits typing into two actions")
    }

    private static func checkClicksAndDrags(_ expect: Expectation) {
        func actionKind(from startPoint: CGPoint, to endPoint: CGPoint, clickCount: Int = 1, isRightButton: Bool = false) -> TeachActionKind? {
            var accumulator = TeachInputAccumulator()
            accumulator.ingest(.mouseDown(locationInDisplayPoints: startPoint, clickCount: clickCount, isRightButton: isRightButton, secondsFromStart: 1, context: makeContext()))
            accumulator.ingest(.mouseUp(locationInDisplayPoints: endPoint, secondsFromStart: 1.1))
            return accumulator.actions.last?.kind
        }

        expect(actionKind(from: .zero, to: CGPoint(x: 3, y: 2)) == .click, "a shaky click stays a click")
        expect(actionKind(from: .zero, to: CGPoint(x: 100, y: 0)) == .drag, "a long press and move is a drag")
        expect(actionKind(from: .zero, to: .zero, isRightButton: true) == .rightClick, "right button is a right click")

        var doubleClickAccumulator = TeachInputAccumulator()
        doubleClickAccumulator.ingest(.mouseDown(locationInDisplayPoints: .zero, clickCount: 1, isRightButton: false, secondsFromStart: 1, context: makeContext()))
        expect(doubleClickAccumulator.ingest(.mouseUp(locationInDisplayPoints: .zero, secondsFromStart: 1.05)), "the first click finishes an action")
        doubleClickAccumulator.ingest(.mouseDown(locationInDisplayPoints: .zero, clickCount: 2, isRightButton: false, secondsFromStart: 1.2, context: makeContext()))
        expect(doubleClickAccumulator.ingest(.mouseUp(locationInDisplayPoints: .zero, secondsFromStart: 1.25)), "the second click still reports a finished action")
        expect(doubleClickAccumulator.actions.count == 1 && doubleClickAccumulator.actions[0].kind == .doubleClick, "a double click replaces its first click")

        var typingThenClick = TeachInputAccumulator()
        typingThenClick.ingest(.keystroke(category: .digit, secondsFromStart: 1, context: makeContext()))
        expect(typingThenClick.ingest(.mouseDown(locationInDisplayPoints: .zero, clickCount: 1, isRightButton: false, secondsFromStart: 1.2, context: makeContext())), "a click ends a typing run")
        typingThenClick.ingest(.mouseUp(locationInDisplayPoints: .zero, secondsFromStart: 1.3))
        expect(typingThenClick.actions.map(\.kind) == [.typing, .click], "typing then click stays in order")
    }

    private static func checkSecureInput(_ expect: Expectation) {
        expect(TeachInputPrivacyRules.isSecureField(role: "AXSecureTextField", subrole: nil), "secure role is a secure field")
        expect(TeachInputPrivacyRules.isSecureField(role: "AXTextField", subrole: "AXSecureTextField"), "secure subrole is a secure field")
        expect(!TeachInputPrivacyRules.isSecureField(role: "AXTextField", subrole: nil), "an ordinary field is not secure")
        expect(TeachInputPrivacyRules.isCaptureForbidden(isSecureInputEnabled: true, focusedRole: nil, focusedSubrole: nil), "secure input alone stops capture")
        expect(TeachInputPrivacyRules.isCaptureForbidden(isSecureInputEnabled: false, focusedRole: "AXSecureTextField", focusedSubrole: nil), "a focused password box stops capture even with secure input off")
        expect(!TeachInputPrivacyRules.isCaptureForbidden(isSecureInputEnabled: false, focusedRole: "AXButton", focusedSubrole: nil), "a button doesn't stop capture")

        var accumulator = TeachInputAccumulator()
        accumulator.ingest(.keystroke(category: .letter, secondsFromStart: 1, context: makeContext()))
        accumulator.ingest(.secureInputChanged(isActive: true, secondsFromStart: 1.2))
        expect(accumulator.isInsideSecureGap, "the secure gap opens")
        accumulator.ingest(.keystroke(category: .letter, secondsFromStart: 1.3, context: makeContext()))
        accumulator.ingest(.mouseDown(locationInDisplayPoints: .zero, clickCount: 1, isRightButton: false, secondsFromStart: 1.4, context: makeContext()))
        accumulator.ingest(.mouseUp(locationInDisplayPoints: .zero, secondsFromStart: 1.5))
        accumulator.ingest(.secureInputChanged(isActive: false, secondsFromStart: 2))
        accumulator.finish(atSecondsFromStart: 3)
        expect(accumulator.actions.isEmpty, "nothing during a secure gap, or the typing just before it, is kept")
        expect(accumulator.secureGaps == [TeachSecureGap(startSeconds: 1.2, endSeconds: 2)], "the gap's times are recorded")

        var clickOnPassword = TeachInputAccumulator()
        clickOnPassword.ingest(.mouseDown(locationInDisplayPoints: .zero, clickCount: 1, isRightButton: false, secondsFromStart: 1, context: makeContext(isOverSecureField: true)))
        clickOnPassword.ingest(.mouseUp(locationInDisplayPoints: .zero, secondsFromStart: 1.1))
        clickOnPassword.ingest(.keystroke(category: .letter, secondsFromStart: 1.2, context: makeContext(isOverSecureField: true)))
        clickOnPassword.finish(atSecondsFromStart: 2)
        expect(clickOnPassword.actions.isEmpty, "a click or key on a password box is dropped even with secure input off")

        let unfinishedGap = { () -> [TeachSecureGap] in
            var accumulator = TeachInputAccumulator()
            accumulator.ingest(.secureInputChanged(isActive: true, secondsFromStart: 5))
            accumulator.finish(atSecondsFromStart: 9)
            return accumulator.secureGaps
        }()
        expect(unfinishedGap == [TeachSecureGap(startSeconds: 5, endSeconds: 9)], "stopping mid-password still closes the gap")
    }

    private static func makeRecording(actionTimes: [Double], segments: [TeachNarrationSegment], secureGaps: [TeachSecureGap] = []) -> TeachRecording {
        TeachRecording(
            recordingIdentifier: "test",
            provenance: .liveRecording,
            teacherName: "sam",
            startedAt: Date(),
            durationInSeconds: 30,
            setup: LessonSetupDescription(displaySizeInPoints: LessonRectangle(CGRect(x: 0, y: 0, width: 100, height: 100)), windowSizeInPoints: nil, appearanceName: "dark"),
            actions: actionTimes.map { actionTime in
                TeachRecordedAction(
                    secondsFromStart: actionTime, kind: .click, applicationName: "Numbers", applicationBundleIdentifier: nil,
                    element: nil, locationInDisplayPoints: nil, dragEndLocationInDisplayPoints: nil,
                    windowFrameInDisplayPoints: nil, keystrokeSummary: nil, beforeFrameFileName: nil, afterFrameFileName: nil
                )
            },
            narrationSegments: segments,
            secureGaps: secureGaps,
            narrationAudioFileName: nil
        )
    }

    private static func checkNarrationAlignment(_ expect: Expectation) {
        let alignment = TeachNarrationAligner.align(makeRecording(
            actionTimes: [5, 10],
            segments: [
                TeachNarrationSegment(text: "click the chart button", startSeconds: 2, endSeconds: 4),
                TeachNarrationSegment(text: "there it is", startSeconds: 5, endSeconds: 6),
                TeachNarrationSegment(text: "then pick this one", startSeconds: 8, endSeconds: 9.5),
                TeachNarrationSegment(text: "and we're done", startSeconds: 14, endSeconds: 15)
            ]
        ))
        expect(alignment.actionNarrations[0].narrationText == "click the chart button there it is", "speech before and just after a click belongs to it")
        expect(alignment.actionNarrations[1].narrationText == "then pick this one", "the next phrase goes to the next action")
        expect(alignment.trailingNarrationText == "and we're done", "speech after the last action is the sign-off")
        expect(alignment.fullTranscript.hasPrefix("click the chart button"), "the transcript keeps its order")

        let introduction = TeachNarrationSegment(text: "okay this took me ages to find", startSeconds: 0, endSeconds: 2)
        let instruction = TeachNarrationSegment(text: "click the chart button up top", startSeconds: 3, endSeconds: 5)
        let clipSegments = TeacherWordOverlap.segmentsSpokenInLine("click the chart button", from: [introduction, instruction])
        expect(clipSegments == [instruction], "a voice clip holds only the phrases its line came from")

        let secureAlignment = TeachNarrationAligner.align(makeRecording(
            actionTimes: [5],
            segments: [
                TeachNarrationSegment(text: "my password is hunter2", startSeconds: 2, endSeconds: 4),
                TeachNarrationSegment(text: "okay click this", startSeconds: 4.5, endSeconds: 5)
            ],
            secureGaps: [TeachSecureGap(startSeconds: 1, endSeconds: 3)]
        ))
        expect(!secureAlignment.fullTranscript.contains("hunter2"), "anything said during secure input is dropped")
        expect(secureAlignment.fullTranscript == "okay click this", "speech outside the gap survives")
    }

    private static func checkTeacherWords(_ expect: Expectation) {
        let narration = "okay so you wanna click the chart button up top, trust me"
        expect(TeacherWordOverlap.overlap(ofLine: "click the chart button", withNarration: narration) == 1, "a line of their words scores 1")
        expect(TeacherWordOverlap.overlap(ofLine: "", withNarration: narration) == 0, "an empty line is not a match")

        let keptLine = TeacherWordOverlap.chooseSpokenLine(modelLine: "you wanna click the chart button", narrationForStep: narration, fullTranscript: narration)
        expect(keptLine.source == .teacherWords && keptLine.spokenLine == "you wanna click the chart button", "a close line is kept")

        let driftedLine = TeacherWordOverlap.chooseSpokenLine(modelLine: "great job, please select the insert graph control", narrationForStep: narration, fullTranscript: narration)
        expect(driftedLine.source == .teacherNarrationFallback && driftedLine.spokenLine == narration, "a drifted line gives way to their real narration")

        let silentStep = TeacherWordOverlap.chooseSpokenLine(modelLine: "select the insert graph control", narrationForStep: "  ", fullTranscript: narration)
        expect(silentStep.source == .generatedBecauseTeacherWasSilent, "a line with no narration behind it is labelled as generated")
    }

    private static func makeUsage(costInUSD: Double?, inputTokens: Int? = 100, outputTokens: Int? = 10) -> BrainUsage {
        BrainUsage(
            backendName: "test", modelIdentifier: "test", inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadInputTokens: nil, cacheCreationInputTokens: nil, costInUSD: costInUSD,
            isCostEstimated: true, costSourceDescription: "test source", timeToFirstTextInSeconds: nil, totalDurationInSeconds: 1
        )
    }

    private static func checkModelReplyParsing(_ expect: Expectation) {
        let usage = makeUsage(costInUSD: 0.001)
        let displayFrame = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let screenCapture = CompanionScreenCapture(
            imageData: Data(), label: "", screenNumber: 1, isCursorScreen: true, displayWidthInPoints: 1000,
            displayHeightInPoints: 500, displayFrame: displayFrame, screenshotWidthInPixels: 500, screenshotHeightInPixels: 250
        )

        let sameLine = LessonFollowEngine.parseLocateResponse(
            BrainResponse(text: "LINE: SAME\n[POINT:100,50:chart button]", usage: usage),
            screenCaptures: [screenCapture], bubbleText: "this one"
        )
        expect(sameLine.method == .modelVision && sameLine.adaptedSpokenLine == nil, "SAME keeps the teacher's line")
        expect(sameLine.mappedPoint?.displayLocalPoint == CGPoint(x: 200, y: 100), "the point maps from screenshot to display")

        let adaptedLine = LessonFollowEngine.parseLocateResponse(
            BrainResponse(text: "LINE: now click the first row\n[POINT:100,50:row]", usage: usage),
            screenCaptures: [screenCapture], bubbleText: "this one"
        )
        expect(adaptedLine.adaptedSpokenLine == "now click the first row", "a rewritten line is carried through")

        let notFound = LessonFollowEngine.parseLocateResponse(
            BrainResponse(text: "LINE: i can't see a table on screen\n[POINT:none]", usage: usage),
            screenCaptures: [screenCapture], bubbleText: "this one"
        )
        expect(notFound.method == .notFound && notFound.mappedPoint == nil, "no target means no point")
        expect(notFound.notFoundExplanation == "i can't see a table on screen", "not found says why")

        expect(LessonFollowEngine.parseCheckResponse(BrainResponse(text: "YES\na chart is there", usage: usage)).didSucceed, "yes passes")
        expect(!LessonFollowEngine.parseCheckResponse(BrainResponse(text: "NO\nnothing changed", usage: usage)).didSucceed, "no fails")
        expect(!LessonFollowEngine.parseCheckResponse(BrainResponse(text: "maybe, hard to tell", usage: usage)).didSucceed, "anything unclear doesn't advance the lesson")
        expect(!LessonFollowEngine.parseCheckResponse(BrainResponse(text: "yesterday's chart", usage: usage)).didSucceed, "a word starting with yes isn't a yes")

        expect(LessonDraftJSON.extractObjectText(from: "sure!\n```json\n{\"a\":1}\n```") == "{\"a\":1}", "json is found inside a code fence")
        expect(LessonDraftJSON.extractObjectText(from: "no json here") == nil, "no braces means no json")
    }

    private static func checkOnDeviceTextRule(_ expect: Expectation) {
        expect(
            LessonOnDeviceText.firstNewlyVisibleText(among: ["frame range"], currentLines: ["frame range"], baselineLines: []) == "frame range",
            "text that just appeared is evidence"
        )
        expect(
            LessonOnDeviceText.firstNewlyVisibleText(among: ["frame range"], currentLines: ["frame range"], baselineLines: ["frame range"]) == nil,
            "text that was already there proves nothing"
        )
        expect(
            LessonOnDeviceText.firstNewlyVisibleText(among: ["file"], currentLines: ["profile settings"], baselineLines: []) == nil,
            "a word inside another word isn't a match"
        )
    }

    private static func checkCostRules(_ expect: Expectation) {
        func makeLesson(rehearsalCalls: [LessonCostSample], replayRuns: [LessonReplayRun] = []) -> ClickyLesson {
            let minimalLesson = makeMinimalLesson()
            let fourStepLesson = ClickyLesson(
                lessonIdentifier: "x", title: "x", summary: "x", teacherName: "x", createdAt: Date(), provenance: .liveRecording,
                applicationName: "x", applicationBundleIdentifier: nil, openingLine: "", closingLine: "",
            openingVoiceClipFileName: nil, closingVoiceClipFileName: nil, teacherNarrationTranscript: "",
                taughtOnSetup: minimalLesson.taughtOnSetup,
                steps: Array(repeating: minimalLesson.steps[0], count: 4),
                costEvidence: LessonCostEvidence(compileCalls: [], rehearsalCalls: rehearsalCalls, replayRuns: replayRuns)
            )
            return fourStepLesson
        }

        let noEvidence = LessonReplayCostEstimator.estimate(for: makeLesson(rehearsalCalls: []))
        expect(noEvidence.estimatedCostInUSD == nil && noEvidence.displayText == "replay cost not measured yet", "no calls means no figure, never zero")

        let rehearsal = LessonReplayCostEstimator.estimate(for: makeLesson(rehearsalCalls: [
            LessonCostSample(purpose: "locate", usage: makeUsage(costInUSD: 0.002)),
            LessonCostSample(purpose: "check", usage: makeUsage(costInUSD: 0.001))
        ]))
        expect(abs((rehearsal.estimatedCostInUSD ?? 0) - 0.012) < 0.000001, "rehearsal scales to the lesson's length")
        expect(rehearsal.displayText.contains("estimated"), "a cost always says estimated")

        let tokensOnly = LessonReplayCostEstimator.estimate(for: makeLesson(rehearsalCalls: [
            LessonCostSample(purpose: "locate", usage: makeUsage(costInUSD: nil)),
            LessonCostSample(purpose: "check", usage: makeUsage(costInUSD: nil))
        ]))
        expect(tokensOnly.estimatedCostInUSD == nil && tokensOnly.estimatedTokenCount != nil, "a backend with no cost shows tokens, not $0")
        expect(tokensOnly.displayText.contains("tokens") && tokensOnly.displayText.contains("estimated"), "tokens are labelled as an estimate too")

        let replayRun = LessonReplayRun(finishedAt: Date(), captureSource: "screencapturekit", calls: [
            LessonCostSample(purpose: "locate", usage: makeUsage(costInUSD: 0.004))
        ])
        let replayed = LessonReplayCostEstimator.estimate(for: makeLesson(rehearsalCalls: [], replayRuns: [replayRun, replayRun]))
        expect(replayed.estimatedCostInUSD == 0.004, "real runs are averaged")
    }

    private static func checkPackageSafety(_ expect: Expectation) {
        expect(LessonPackageFiles.isPlainFileName("step-1.jpg"), "a plain file name is fine")
        expect(!LessonPackageFiles.isPlainFileName("../secrets.jpg"), "a parent path is refused")
        expect(!LessonPackageFiles.isPlainFileName("a/b.jpg"), "a nested path is refused")
        expect(!LessonPackageFiles.isPlainFileName(".."), "a bare parent is refused")

        let normalListing = """
        Archive:  x.clicky
          Length      Date    Time    Name
        ---------  ---------- -----   ----
             1024  11-01-2026 10:00   lesson.json
              500  11-01-2026 10:00   images/step 1.jpg
        ---------                     -------
             1524                     2 files
        """
        expect((try? LessonPackageArchiver.validateArchiveListing(normalListing)) != nil, "a normal archive passes")

        let traversalListing = """
             1024  11-01-2026 10:00   ../../.zshrc
        """
        expect((try? LessonPackageArchiver.validateArchiveListing(traversalListing)) == nil, "an archive writing outside its folder is refused")

        let absoluteListing = """
             1024  11-01-2026 10:00   /tmp/evil.json
        """
        expect((try? LessonPackageArchiver.validateArchiveListing(absoluteListing)) == nil, "an absolute path is refused")

        let bombListing = """
        999999999999  11-01-2026 10:00   images/huge.jpg
        """
        expect((try? LessonPackageArchiver.validateArchiveListing(bombListing)) == nil, "an enormous unpacked size is refused")

        // Real files, built the way an attacker would.
        let workingDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectoryURL) }

        func makeArchive(named archiveName: String, populate: (URL) throws -> Void) -> URL? {
            let contentURL = workingDirectoryURL.appendingPathComponent(archiveName + "-content", isDirectory: true)
            let archiveURL = workingDirectoryURL.appendingPathComponent(archiveName + ".clicky")
            do {
                try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
                try populate(contentURL)
                let zipProcess = Process()
                zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                zipProcess.currentDirectoryURL = contentURL
                zipProcess.arguments = ["-q", "-r", "-y", archiveURL.path, "."]
                try zipProcess.run()
                zipProcess.waitUntilExit()
                return archiveURL
            } catch {
                return nil
            }
        }

        // A valid manifest, so a refusal can only come from the check under
        // test, and the clean archive proves a good lesson really does open.
        guard let validManifestData = try? LessonPackageArchiver.makeEncoder().encode(makeMinimalLesson()) else {
            expect(false, "could not encode the test lesson")
            return
        }

        func openingFailure(of archiveURL: URL?) -> String? {
            guard let archiveURL else { return "archive was not built" }
            do {
                let lessonPackage = try LessonPackageArchiver.openArchive(at: archiveURL)
                try? FileManager.default.removeItem(at: lessonPackage.unpackedDirectoryURL)
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        let cleanArchive = makeArchive(named: "clean") { contentURL in
            try validManifestData.write(to: contentURL.appendingPathComponent(ClickyLesson.manifestFileName))
        }
        expect(openingFailure(of: cleanArchive) == nil, "a clean lesson opens")

        let symlinkArchive = makeArchive(named: "symlink") { contentURL in
            try validManifestData.write(to: contentURL.appendingPathComponent(ClickyLesson.manifestFileName))
            try FileManager.default.createSymbolicLink(
                at: contentURL.appendingPathComponent("link.jpg"),
                withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
            )
        }
        expect(openingFailure(of: symlinkArchive)?.contains("link to somewhere else") == true, "an archive with a symlink is refused for that reason")

        let scriptArchive = makeArchive(named: "script") { contentURL in
            try validManifestData.write(to: contentURL.appendingPathComponent(ClickyLesson.manifestFileName))
            try Data("#!/bin/sh".utf8).write(to: contentURL.appendingPathComponent("run.sh"))
        }
        expect(openingFailure(of: scriptArchive)?.contains("isn't part of a lesson") == true, "an archive with a script is refused for that reason")

        let emptyArchive = makeArchive(named: "empty") { contentURL in
            try Data("hello".utf8).write(to: contentURL.appendingPathComponent("notes.json"))
        }
        expect(openingFailure(of: emptyArchive)?.contains("no lesson.json") == true, "an archive without lesson.json is refused for that reason")
    }

    private static func makeMinimalLesson() -> ClickyLesson {
        let element = LessonElementTarget(description: "x", kind: .documentContent, accessibilityRole: nil, accessibilityTitleHints: [], whereToLook: nil, referenceImageFileName: nil)
        let step = LessonStep(
            stepNumber: 1, intent: "x", spokenLine: "x", bubbleText: "x", action: .click, element: element,
            successCheck: LessonSuccessCheck(description: "x", newlyVisibleTextAnyOf: []),
            spokenLineSource: .teacherWords, teacherWordOverlap: 1, usesDocumentSpecificWords: false, voiceClipFileName: nil
        )
        return ClickyLesson(
            lessonIdentifier: "x", title: "x", summary: "x", teacherName: "x", createdAt: Date(), provenance: .liveRecording,
            applicationName: "x", applicationBundleIdentifier: nil, openingLine: "", closingLine: "",
            openingVoiceClipFileName: nil, closingVoiceClipFileName: nil, teacherNarrationTranscript: "",
            taughtOnSetup: LessonSetupDescription(displaySizeInPoints: LessonRectangle(.zero), windowSizeInPoints: nil, appearanceName: "dark"),
            steps: [step],
            costEvidence: LessonCostEvidence(compileCalls: [], rehearsalCalls: [], replayRuns: [])
        )
    }

    private static func checkScreenFingerprint(_ expect: Expectation) {
        func makeImageData(highlightRect: CGRect?) -> Data? {
            guard let context = CGContext(data: nil, width: 1200, height: 750, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return nil
            }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 750))
            if let highlightRect {
                context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
                context.fill(highlightRect)
            }
            return context.makeImage().flatMap { LessonImageTools.jpegData(from: $0) }
        }

        guard let plainData = makeImageData(highlightRect: nil),
              let highlightedData = makeImageData(highlightRect: CGRect(x: 300, y: 300, width: 80, height: 20)),
              let plainFingerprint = LessonScreenFingerprint(imageData: plainData),
              let highlightedFingerprint = LessonScreenFingerprint(imageData: highlightedData) else {
            expect(false, "could not build fingerprints")
            return
        }

        expect(plainFingerprint.changedTileCount(comparedTo: plainFingerprint) == 0, "an unchanged screen shows no change")
        expect(highlightedFingerprint.changedTileCount(comparedTo: plainFingerprint) >= 2, "one highlighted spreadsheet cell registers as a change")
    }

    /// A microphone tap fires on a real-time thread. A main-actor closure there
    /// traps at once, and no mic permission is needed to prove this path is
    /// safe, because it only depends on which thread calls in.
    private static func checkNarrationSinkOnAudioThread(_ expect: Expectation) {
        for (sampleRate, channelCount) in [(44_100.0, AVAudioChannelCount(1)), (48_000.0, 2), (48_000.0, 4)] {
            let audioFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-sink-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: audioFileURL) }

            let inputDescription = "\(channelCount) channels at \(Int(sampleRate))"

            // The standard initializer can't describe more than two channels.
            guard let channelLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)),
                  case let inputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    interleaved: false,
                    channelLayout: channelLayout
                  ),
                  let audioBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_410) else {
                expect(false, "could not build a test buffer for \(inputDescription)")
                continue
            }
            audioBuffer.frameLength = 4_410

            // Handed straight to the sink, because a file is only finalized
            // once its last reference goes.
            guard let audioSink = (try? AVAudioFile(
                forWriting: audioFileURL,
                settings: TeachNarrationAudioSink.makeNarrationFileSettings(sampleRate: sampleRate),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )).map({ TeachNarrationAudioSink(audioFile: $0) }) else {
                expect(false, "could not open a narration file for \(inputDescription)")
                continue
            }

            let writesFinished = DispatchSemaphore(value: 0)
            let audioThreadQueue = DispatchQueue(label: "clicky.selftest.audio", qos: .userInteractive)

            // Only this queue touches the buffer until the semaphore signals.
            nonisolated(unsafe) let bufferForAudioThread = audioBuffer
            audioThreadQueue.async {
                for _ in 0..<5 {
                    audioSink.receive(bufferForAudioThread)
                }
                writesFinished.signal()
            }

            expect(writesFinished.wait(timeout: .now() + 5) == .success, "the audio sink takes \(inputDescription) from a background thread")
            expect(audioSink.framesWrittenSoFar == 22_050, "\(inputDescription) reaches the narration file")

            audioSink.closeAudioFile()
            let writtenFrameCount = (try? AVAudioFile(forReading: audioFileURL))?.length ?? 0
            expect(writtenFrameCount > 0, "the narration file from \(inputDescription) can be read back")
        }
    }

    /// Reads a real window of ours through the same reader teach mode uses. An
    /// app can inspect its own tree without Accessibility permission on some
    /// systems, so this reports what happened rather than requiring it.
    private static func checkAccessibilityReaderOnOwnWindow(_ expect: Expectation) -> [String: Any] {
        let testWindow = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let chartButton = NSButton(title: "Chart", target: nil, action: nil)
        chartButton.frame = NSRect(x: 20, y: 70, width: 100, height: 30)
        let passwordField = NSSecureTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        passwordField.stringValue = "hunter2"
        testWindow.contentView?.addSubview(chartButton)
        testWindow.contentView?.addSubview(passwordField)
        testWindow.orderFrontRegardless()
        defer { testWindow.orderOut(nil) }

        // Hit-testing a real position needs the window server, so the tree is
        // walked from the application instead.
        let applicationElement = AXUIElementCreateApplication(getpid())
        var elementsToVisit = [applicationElement]
        var visitedElementCount = 0
        var foundButtonTitle: String?
        var foundSecureField = false
        var secureFieldValueWasRead = false

        while !elementsToVisit.isEmpty, visitedElementCount < 200 {
            let currentElement = elementsToVisit.removeFirst()
            visitedElementCount += 1

            let snapshot = TeachAccessibilityReader.snapshot(of: currentElement, displayOriginInGlobalTopLeftPoints: .zero)
            if snapshot.role == "AXButton", snapshot.title == "Chart" {
                foundButtonTitle = snapshot.title
            }
            if TeachAccessibilityReader.isSecureField(currentElement) {
                foundSecureField = true
                let encodedSnapshot = (try? JSONEncoder().encode(snapshot)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                secureFieldValueWasRead = encodedSnapshot.contains("hunter2")
            }
            elementsToVisit += TeachAccessibilityReader.children(of: currentElement)
        }

        if visitedElementCount <= 1 {
            return ["ran": false, "note": "the accessibility tree isn't readable without permission on this system"]
        }

        expect(foundButtonTitle == "Chart", "the reader finds a real button's title")
        expect(foundSecureField, "the reader recognises a real password field")
        expect(!secureFieldValueWasRead, "a real password field's contents never reach a snapshot")
        return ["ran": true, "visitedElements": visitedElementCount]
    }
}
