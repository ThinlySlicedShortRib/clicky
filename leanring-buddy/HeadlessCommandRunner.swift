//
//  HeadlessCommandRunner.swift
//  leanring-buddy
//
//  Scripted entry points that exercise the real app code without the hotkey,
//  so agents can verify a build with no human present. Each command prints one
//  JSON object on stdout and exits. Run them through scripts/headless.sh, which
//  launches via `open` so macOS applies Clicky's own permissions rather than
//  those of whatever shell started it. See docs/FOUNDATION.md.
//
//  Exit codes: 0 success, 1 check failed, 2 bad arguments, 3 permission missing.
//

import AppKit
import AVFoundation
import Foundation
import Speech
import Vision

// MARK: - Commands

struct HeadlessPointOptions {
    var userPrompt = "where is the most important thing on my screen? point at it."
    var modelValue = BrainConfiguration.configuredModelValue
    /// Image standing in for a real capture. Used when capture is blocked, or
    /// always when `skipRealCapture` is set.
    var fixtureImagePath: String?
    /// Where the fixture sits on the primary display, in top-left-origin
    /// display points. Defaults to covering the whole display.
    var fixtureImageRectInDisplayPoints: CGRect?
    var skipRealCapture = false
    var maximumScreenshotDimension = CompanionScreenCaptureUtility.maximumScreenshotDimension
    /// OCR ground truth: the text the point must land on.
    var verifyText: String?
    /// Rectangle ground truth, in top-left-origin display points.
    var verifyRectInDisplayPoints: CGRect?
    var shouldFlyOverlayToPoint = false
    /// Saves the exact image sent to the model.
    var sentImageOutputPath: String?
    /// Adds a second fixture as a simulated display right of the primary, to
    /// check that a multi-screen request produces a usable screenN tag. Only
    /// meaningful with `skipRealCapture`.
    var secondScreenImagePath: String?
    /// One earlier exchange, to check context reaches the model.
    var priorUserTranscript: String?
    var priorAssistantResponse: String?
    /// Cancels the Brain call after this long, the way a new hotkey press does.
    var cancelBrainAfterSeconds: Double?
}

enum HeadlessCommand {
    case permissions
    case selfTest
    case point(HeadlessPointOptions)
    case flyTo(displayLocalPoint: CGPoint, screenNumber: Int, bubbleText: String?)
    case say(text: String, interruptAfterSeconds: Double?)
    case transcribe(audioFilePath: String)
    case windowBounds(owningApplicationName: String)
    case ask(transcript: String)
    case lesson(HeadlessLessonCommand)

    /// Returns nil when no headless flag is present and the app should launch
    /// normally. Bad arguments exit immediately so a script can't mistake a
    /// typo for a passing run.
    static func parse(arguments: [String]) -> HeadlessCommand? {
        func value(after flag: String) -> String? {
            guard let flagIndex = arguments.firstIndex(of: flag), flagIndex + 1 < arguments.count else { return nil }
            return arguments[flagIndex + 1]
        }

        func exitWithUsageError(_ message: String) -> Never {
            HeadlessOutput.finish(["status": "usage_error", "error": message], exitCode: 2)
        }

        func parseRect(after flag: String) -> CGRect? {
            guard let rawValue = value(after: flag) else { return nil }
            let components = rawValue.split(separator: ",").compactMap { Double($0) }
            guard components.count == 4 else {
                exitWithUsageError("\(flag) expects x,y,width,height, got \(rawValue)")
            }
            return CGRect(x: components[0], y: components[1], width: components[2], height: components[3])
        }

        if let lessonCommand = HeadlessLessonCommand.parse(arguments: arguments, onUsageError: exitWithUsageError) {
            return .lesson(lessonCommand)
        }

        if arguments.contains("--headless-permissions") {
            return .permissions
        }

        if arguments.contains("--headless-self-test") {
            return .selfTest
        }

        if arguments.contains("--headless-point") {
            var options = HeadlessPointOptions()
            options.userPrompt = value(after: "--prompt") ?? options.userPrompt
            options.modelValue = value(after: "--model") ?? options.modelValue
            options.fixtureImagePath = value(after: "--image")
            options.fixtureImageRectInDisplayPoints = parseRect(after: "--image-rect")
            options.skipRealCapture = arguments.contains("--image-only")
            options.verifyText = value(after: "--verify-text")
            options.verifyRectInDisplayPoints = parseRect(after: "--verify-rect")
            options.shouldFlyOverlayToPoint = arguments.contains("--fly")
            options.sentImageOutputPath = value(after: "--save-sent-image")
            options.secondScreenImagePath = value(after: "--second-screen-image")
            options.priorUserTranscript = value(after: "--prior-user")
            options.priorAssistantResponse = value(after: "--prior-assistant")
            options.cancelBrainAfterSeconds = value(after: "--cancel-after").flatMap { Double($0) }
            if let rawMaximumDimension = value(after: "--max-dimension") {
                guard let maximumDimension = Int(rawMaximumDimension) else {
                    exitWithUsageError("--max-dimension expects an integer, got \(rawMaximumDimension)")
                }
                options.maximumScreenshotDimension = maximumDimension
            }
            if options.skipRealCapture && options.fixtureImagePath == nil {
                exitWithUsageError("--image-only requires --image")
            }
            return .point(options)
        }

        if let rawPoint = value(after: "--headless-fly-to") {
            let components = rawPoint.split(separator: ",").compactMap { Double($0) }
            guard components.count == 2 else {
                exitWithUsageError("--headless-fly-to expects x,y in display points, got \(rawPoint)")
            }
            return .flyTo(
                displayLocalPoint: CGPoint(x: components[0], y: components[1]),
                screenNumber: value(after: "--screen").flatMap { Int($0) } ?? 1,
                bubbleText: value(after: "--label")
            )
        }

        if let text = value(after: "--headless-say") {
            return .say(text: text, interruptAfterSeconds: value(after: "--interrupt-after").flatMap { Double($0) })
        }

        if let audioFilePath = value(after: "--headless-transcribe") {
            return .transcribe(audioFilePath: audioFilePath)
        }

        if let owningApplicationName = value(after: "--headless-window-bounds") {
            return .windowBounds(owningApplicationName: owningApplicationName)
        }

        if let transcript = value(after: "--headless-ask") {
            return .ask(transcript: transcript)
        }

        let headlessFlagWasMistyped = arguments.contains { $0.hasPrefix("--headless") }
        if headlessFlagWasMistyped {
            exitWithUsageError("unknown or incomplete headless command: \(arguments.dropFirst().joined(separator: " "))")
        }
        return nil
    }
}

// MARK: - Output

enum HeadlessOutput {
    static var outputPath: String? {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--output"), flagIndex + 1 < arguments.count else { return nil }
        return arguments[flagIndex + 1]
    }

    static func emit(_ result: [String: Any], outputPath: String?) {
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            print("{\"status\":\"failed\",\"error\":\"result was not JSON serializable\"}")
            return
        }
        print(String(decoding: jsonData, as: UTF8.self))
        fflush(stdout)
        if let outputPath {
            try? jsonData.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    static func finish(_ result: [String: Any], exitCode: Int32) -> Never {
        emit(result, outputPath: outputPath)
        exit(exitCode)
    }

    static func json(_ point: CGPoint) -> [String: Double] {
        ["x": round(point.x * 100) / 100, "y": round(point.y * 100) / 100]
    }

    static func json(_ rect: CGRect) -> [String: Double] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
    }

    static func json(_ usage: BrainUsage) -> Any {
        guard let usageData = try? JSONEncoder().encode(usage),
              let usageObject = try? JSONSerialization.jsonObject(with: usageData) else {
            return NSNull()
        }
        return usageObject
    }
}

// MARK: - Runner

@MainActor
struct HeadlessCommandRunner {
    let companionManager: CompanionManager

    /// Long enough for a compile followed by its rehearsal calls.
    private static let wholeCommandTimeoutInSeconds: TimeInterval = 600
    private static let speechAuthorizationPromptWaitInSeconds: TimeInterval = 20

    func run(_ command: HeadlessCommand) async {
        scheduleWatchdog()

        switch command {
        case .permissions:
            await runPermissionReport()
        case .selfTest:
            runSelfTest()
        case .point(let options):
            await runPointCheck(options)
        case .flyTo(let displayLocalPoint, let screenNumber, let bubbleText):
            await runFlyTo(displayLocalPoint: displayLocalPoint, screenNumber: screenNumber, bubbleText: bubbleText)
        case .say(let text, let interruptAfterSeconds):
            await runSay(text: text, interruptAfterSeconds: interruptAfterSeconds)
        case .transcribe(let audioFilePath):
            await runTranscribe(audioFilePath: audioFilePath)
        case .windowBounds(let owningApplicationName):
            runWindowBounds(owningApplicationName: owningApplicationName)
        case .ask(let transcript):
            await runAsk(transcript: transcript)
        case .lesson(let lessonCommand):
            await HeadlessLessonCommandRunner(companionManager: companionManager).run(lessonCommand)
        }
    }

    /// A hung subprocess or an overlay that never lands must fail the check
    /// rather than leave a script waiting forever.
    private func scheduleWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wholeCommandTimeoutInSeconds) {
            HeadlessOutput.finish(["status": "failed", "error": "timed out after \(Self.wholeCommandTimeoutInSeconds)s"], exitCode: 1)
        }
    }

    // MARK: Permissions

    private func runPermissionReport() async {
        let screenRecordingPreflight = CGPreflightScreenCaptureAccess()
        let accessibilityTrusted = AXIsProcessTrusted()
        let microphoneStatus = Self.describe(AVCaptureDevice.authorizationStatus(for: .audio))
        let speechRecognitionStatus = Self.describe(SFSpeechRecognizer.authorizationStatus())

        // The preflight can be stale, so an actual capture is the real answer.
        var realCaptureResult = "ok"
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            realCaptureResult = "ok: \(screenCaptures.count) display(s), \(screenCaptures[0].screenshotWidthInPixels)x\(screenCaptures[0].screenshotHeightInPixels)"
        } catch {
            realCaptureResult = "failed: \(error.localizedDescription)"
        }

        var missingPermissions: [String] = []
        if !realCaptureResult.hasPrefix("ok") {
            missingPermissions.append("Screen & System Audio Recording")
        }
        if !accessibilityTrusted {
            missingPermissions.append("Accessibility")
        }
        if microphoneStatus != "authorized" {
            missingPermissions.append("Microphone")
        }
        if speechRecognitionStatus != "authorized" {
            missingPermissions.append("Speech Recognition")
        }

        HeadlessOutput.finish([
            "status": missingPermissions.isEmpty ? "ok" : "permissions_missing",
            "bundlePath": Bundle.main.bundlePath,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "screenRecordingPreflight": screenRecordingPreflight,
            "realCapture": realCaptureResult,
            "accessibilityTrusted": accessibilityTrusted,
            "microphone": microphoneStatus,
            "speechRecognition": speechRecognitionStatus,
            "missingPermissions": missingPermissions
        ], exitCode: missingPermissions.isEmpty ? 0 : 3)
    }

    static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    // MARK: Point Check

    private func runPointCheck(_ options: HeadlessPointOptions) async {
        var result: [String: Any] = [
            "prompt": options.userPrompt,
            "model": options.modelValue
        ]

        let screenCaptures: [CompanionScreenCapture]
        var groundTruthImage: GroundTruthImage?

        if options.skipRealCapture {
            result["captureSource"] = "fixture"
        }

        do {
            if options.skipRealCapture {
                throw CompanionScreenCaptureError.screenRecordingPermissionMissing
            }
            screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            result["captureSource"] = "screencapturekit"
            result["capturePathNote"] = "real capture path"
            groundTruthImage = GroundTruthImage(
                imageData: screenCaptures[0].imageData,
                displayRectInPoints: CGRect(origin: .zero, size: screenCaptures[0].displayFrame.size)
            )
        } catch let captureError {
            guard let fixtureImagePath = options.fixtureImagePath else {
                let isPermissionFailure = captureError is CompanionScreenCaptureError
                HeadlessOutput.finish([
                    "status": isPermissionFailure ? "permission_missing" : "failed",
                    "error": captureError.localizedDescription,
                    "hint": "pass --image <file> to run the rest of the path on a saved screenshot"
                ], exitCode: isPermissionFailure ? 3 : 1)
            }

            if !options.skipRealCapture {
                result["captureSource"] = "fixture"
                result["captureFallbackReason"] = captureError.localizedDescription
            }
            result["capturePathNote"] = "fixture image: ScreenCaptureKit was not exercised by this run"

            do {
                let primaryDisplayFrame = NSScreen.screens.first?.frame ?? .zero
                let fixture = try FixtureScreenCapture.make(
                    imagePath: fixtureImagePath,
                    imageRectInDisplayPoints: options.fixtureImageRectInDisplayPoints,
                    displayFrame: primaryDisplayFrame,
                    label: options.secondScreenImagePath == nil
                        ? "user's screen (cursor is here)"
                        : "screen 1 of 2 — cursor is on this screen (primary focus)",
                    screenNumber: 1,
                    isCursorScreen: true,
                    maximumScreenshotDimension: options.maximumScreenshotDimension
                )
                var fixtureCaptures = [fixture.screenCapture]

                if let secondScreenImagePath = options.secondScreenImagePath {
                    let secondFixture = try FixtureScreenCapture.make(
                        imagePath: secondScreenImagePath,
                        imageRectInDisplayPoints: nil,
                        displayFrame: CGRect(x: primaryDisplayFrame.maxX, y: 0, width: 1920, height: 1080),
                        label: "screen 2 of 2 — secondary screen",
                        screenNumber: 2,
                        isCursorScreen: false,
                        maximumScreenshotDimension: options.maximumScreenshotDimension
                    )
                    fixtureCaptures.append(secondFixture.screenCapture)
                }

                screenCaptures = fixtureCaptures
                groundTruthImage = fixture.groundTruthImage
            } catch {
                HeadlessOutput.finish(["status": "failed", "error": error.localizedDescription], exitCode: 1)
            }
        }

        if let sentImageOutputPath = options.sentImageOutputPath {
            try? screenCaptures[0].imageData.write(to: URL(fileURLWithPath: sentImageOutputPath))
        }

        let brain = BrainConfiguration.makeBrain(modelValue: options.modelValue)
        result["brain"] = brain.displayName

        var conversationHistory: [BrainConversationExchange] = []
        if let priorUserTranscript = options.priorUserTranscript {
            conversationHistory.append(BrainConversationExchange(
                userTranscript: priorUserTranscript,
                assistantResponse: options.priorAssistantResponse ?? ""
            ))
        }

        let brainRequest = BrainRequest(
            systemPrompt: CompanionManager.companionVoiceResponseSystemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: options.userPrompt,
            images: CompanionManager.makeBrainImages(from: screenCaptures)
        )

        let brainStartDate = Date()
        let brainTask = Task {
            try await brain.respond(to: brainRequest, onTextDelta: { _ in })
        }

        if let cancelBrainAfterSeconds = options.cancelBrainAfterSeconds {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(cancelBrainAfterSeconds * 1_000_000_000))
                brainTask.cancel()
            }
        }

        let brainResponse: BrainResponse
        do {
            brainResponse = try await brainTask.value
        } catch is CancellationError {
            result["status"] = "ok"
            result["brainCancelledAfterSeconds"] = Date().timeIntervalSince(brainStartDate)
            HeadlessOutput.finish(result, exitCode: 0)
        } catch {
            result["status"] = "failed"
            result["error"] = error.localizedDescription
            HeadlessOutput.finish(result, exitCode: 1)
        }

        result["rawResponse"] = brainResponse.text
        result["usage"] = HeadlessOutput.json(brainResponse.usage)

        let parseResult = CompanionManager.parsePointingCoordinates(from: brainResponse.text)
        result["spokenText"] = parseResult.spokenText
        result["elementLabel"] = parseResult.elementLabel ?? NSNull()
        result["screenNumber"] = parseResult.screenNumber ?? NSNull()

        guard let pointCoordinate = parseResult.coordinate,
              let targetScreenCapture = ScreenshotCoordinateMapper.targetCapture(
                forScreenNumber: parseResult.screenNumber,
                in: screenCaptures
              ) else {
            result["status"] = "no_point"
            HeadlessOutput.finish(result, exitCode: options.verifyText == nil && options.verifyRectInDisplayPoints == nil ? 0 : 1)
        }

        let mappedPoint = ScreenshotCoordinateMapper.mapScreenshotPoint(
            pointCoordinate,
            screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
            displayFrame: targetScreenCapture.displayFrame
        )

        result["screenshotSizeInPixels"] = ["width": targetScreenCapture.screenshotWidthInPixels, "height": targetScreenCapture.screenshotHeightInPixels]
        result["displayFrameAppKit"] = HeadlessOutput.json(targetScreenCapture.displayFrame)
        result["pointInScreenshotPixels"] = HeadlessOutput.json(mappedPoint.clampedScreenshotPoint)
        result["pointInDisplayPoints"] = HeadlessOutput.json(mappedPoint.displayLocalPoint)
        result["pointGlobalAppKit"] = HeadlessOutput.json(mappedPoint.globalAppKitPoint)

        var allVerificationsPassed = true
        var couldNotVerify = false

        if let verifyRectInDisplayPoints = options.verifyRectInDisplayPoints {
            let isInsideRect = verifyRectInDisplayPoints.contains(mappedPoint.displayLocalPoint)
            allVerificationsPassed = allVerificationsPassed && isInsideRect
            result["rectVerification"] = [
                "rectInDisplayPoints": HeadlessOutput.json(verifyRectInDisplayPoints),
                "hit": isInsideRect
            ]
        }

        if let verifyText = options.verifyText {
            let textVerification = OCRGroundTruth.verify(
                pointInDisplayPoints: mappedPoint.displayLocalPoint,
                landsOnText: verifyText,
                in: groundTruthImage
            )
            // No OCR match says nothing about the point, so it can't count as
            // a hit or a miss. Short words and scrolled-off text both cause it.
            couldNotVerify = textVerification["error"] != nil
            allVerificationsPassed = allVerificationsPassed && (textVerification["hit"] as? Bool ?? false)
            result["textVerification"] = textVerification
        }

        if options.shouldFlyOverlayToPoint {
            let tipLocation = await companionManager.flyBuddyForScriptedCheck(
                toGlobalAppKitLocation: mappedPoint.globalAppKitPoint,
                displayFrame: targetScreenCapture.displayFrame,
                bubbleText: parseResult.elementLabel
            )
            let landingErrorInPoints = hypot(
                tipLocation.x - mappedPoint.globalAppKitPoint.x,
                tipLocation.y - mappedPoint.globalAppKitPoint.y
            )
            result["overlayTipLandedGlobalAppKit"] = HeadlessOutput.json(tipLocation)
            result["overlayLandingErrorInPoints"] = round(landingErrorInPoints * 100) / 100
        }

        if couldNotVerify {
            result["status"] = "unverified"
        } else {
            result["status"] = allVerificationsPassed ? "ok" : "verification_failed"
        }
        HeadlessOutput.finish(result, exitCode: allVerificationsPassed && !couldNotVerify ? 0 : 1)
    }

    // MARK: Ask

    /// Runs the same pipeline a hotkey press runs after transcription: real
    /// capture, Brain, parsing, overlay state, and speech. Unlike the point
    /// check it has no fixture fallback, so it also shows what a user hears
    /// when a permission is missing.
    private func runAsk(transcript: String) async {
        await companionManager.answerTranscriptForScriptedCheck(transcript: transcript)

        let textToSpeechClientWasSpeaking = companionManager.isSpeakingForScriptedCheck
        while companionManager.isSpeakingForScriptedCheck {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let failureMessage = companionManager.lastResponseFailureMessage
        HeadlessOutput.finish([
            "status": failureMessage == nil ? "ok" : "failed",
            "transcript": transcript,
            "failureMessage": failureMessage ?? NSNull(),
            "spokeAloud": textToSpeechClientWasSpeaking,
            "usage": companionManager.lastBrainUsage.map { HeadlessOutput.json($0) } ?? NSNull()
        ], exitCode: failureMessage == nil ? 0 : 1)
    }

    // MARK: Fly To

    private func runFlyTo(displayLocalPoint: CGPoint, screenNumber: Int, bubbleText: String?) async {
        let screens = NSScreen.screens
        guard screenNumber >= 1, screenNumber <= screens.count else {
            HeadlessOutput.finish(["status": "failed", "error": "--screen \(screenNumber) is out of range, \(screens.count) screen(s) attached"], exitCode: 1)
        }

        let displayFrame = screens[screenNumber - 1].frame

        // Already in display points, so the screenshot is the size of the display.
        let mappedPoint = ScreenshotCoordinateMapper.mapScreenshotPoint(
            displayLocalPoint,
            screenshotWidthInPixels: Int(displayFrame.width),
            screenshotHeightInPixels: Int(displayFrame.height),
            displayFrame: displayFrame
        )

        let tipLocation = await companionManager.flyBuddyForScriptedCheck(
            toGlobalAppKitLocation: mappedPoint.globalAppKitPoint,
            displayFrame: displayFrame,
            bubbleText: bubbleText
        )

        // Leaves the buddy on screen long enough for a human or recording to see.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let landingErrorInPoints = hypot(
            tipLocation.x - mappedPoint.globalAppKitPoint.x,
            tipLocation.y - mappedPoint.globalAppKitPoint.y
        )

        // Target closer to an edge than clamping allows can't land exactly.
        let maximumAcceptableLandingErrorInPoints: CGFloat = 2
        let didLandOnTarget = landingErrorInPoints <= maximumAcceptableLandingErrorInPoints

        HeadlessOutput.finish([
            "status": didLandOnTarget ? "ok" : "failed",
            "requestedDisplayPoint": HeadlessOutput.json(displayLocalPoint),
            "targetGlobalAppKit": HeadlessOutput.json(mappedPoint.globalAppKitPoint),
            "tipLandedGlobalAppKit": HeadlessOutput.json(tipLocation),
            "landingErrorInPoints": round(landingErrorInPoints * 100) / 100,
            "displayFrameAppKit": HeadlessOutput.json(displayFrame),
            "overlayWindowFramesAppKit": companionManager.overlayWindowManager.overlayWindowFrames.map { HeadlessOutput.json($0) }
        ], exitCode: didLandOnTarget ? 0 : 1)
    }

    // MARK: Say

    private func runSay(text: String, interruptAfterSeconds: Double?) async {
        let textToSpeechClient = SayTTSClient()
        let startDate = Date()

        do {
            try await textToSpeechClient.speakText(text)
        } catch {
            HeadlessOutput.finish(["status": "failed", "error": error.localizedDescription], exitCode: 1)
        }

        let timeToProcessStartInSeconds = Date().timeIntervalSince(startDate)
        let wasPlayingAfterStart = textToSpeechClient.isPlaying

        if let interruptAfterSeconds {
            try? await Task.sleep(nanoseconds: UInt64(interruptAfterSeconds * 1_000_000_000))
            textToSpeechClient.stopPlayback()
        } else {
            while textToSpeechClient.isPlaying {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        HeadlessOutput.finish([
            "status": wasPlayingAfterStart ? "ok" : "failed",
            "voice": textToSpeechClient.lastUsedVoiceName ?? "system default",
            "timeToProcessStartInSeconds": timeToProcessStartInSeconds,
            "wasPlayingAfterStart": wasPlayingAfterStart,
            "totalSeconds": Date().timeIntervalSince(startDate),
            "wasInterrupted": interruptAfterSeconds != nil
        ], exitCode: wasPlayingAfterStart ? 0 : 1)
    }

    // MARK: Transcribe

    /// Sends a speech file through the same provider the mic uses, so voice
    /// input can be checked with no human speaking.
    private func runTranscribe(audioFilePath: String) async {
        let speechRecognitionStatus = await Self.requestSpeechRecognitionAuthorization()
        guard speechRecognitionStatus == .authorized else {
            HeadlessOutput.finish([
                "status": "permission_missing",
                "speechRecognition": Self.describe(speechRecognitionStatus),
                "error": "Speech Recognition permission is missing for Clicky. Grant it in System Settings > Privacy & Security > Speech Recognition."
            ], exitCode: 3)
        }

        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()

        do {
            let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioFilePath))
            let finalTranscript: String = try await withCheckedThrowingContinuation { continuation in
                let continuationGuard = SingleResumeGuard(continuation: continuation)

                Task { @MainActor in
                    do {
                        let streamingSession = try await transcriptionProvider.startStreamingSession(
                            keyterms: [],
                            onTranscriptUpdate: { _ in },
                            onFinalTranscriptReady: { finalTranscript in continuationGuard.resume(returning: finalTranscript) },
                            onError: { error in continuationGuard.resume(throwing: error) }
                        )

                        let framesPerBuffer: AVAudioFrameCount = 4_096
                        while audioFile.framePosition < audioFile.length {
                            guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: framesPerBuffer) else { break }
                            try audioFile.read(into: audioBuffer)
                            streamingSession.appendAudioBuffer(audioBuffer)
                        }
                        streamingSession.requestFinalTranscript()
                    } catch {
                        continuationGuard.resume(throwing: error)
                    }
                }
            }

            HeadlessOutput.finish([
                "status": "ok",
                "provider": transcriptionProvider.displayName,
                "transcript": finalTranscript
            ], exitCode: 0)
        } catch {
            HeadlessOutput.finish([
                "status": "failed",
                "provider": transcriptionProvider.displayName,
                "error": error.localizedDescription
            ], exitCode: 1)
        }
    }

    private static func requestSpeechRecognitionAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentStatus == .notDetermined else { return currentStatus }

        // The request can't finish until a human answers the system prompt, so
        // a machine nobody is watching has to report that rather than hang.
        DispatchQueue.main.asyncAfter(deadline: .now() + speechAuthorizationPromptWaitInSeconds) {
            HeadlessOutput.finish([
                "status": "permission_missing",
                "speechRecognition": "not_determined",
                "error": "Speech Recognition has not been answered. Allow the system prompt, or grant Clicky in System Settings > Privacy & Security > Speech Recognition, then run this again."
            ], exitCode: 3)
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { requestedStatus in
                continuation.resume(returning: requestedStatus)
            }
        }
    }

    // MARK: Window Bounds

    /// Reports where the window server says an app's windows are. Bounds and
    /// owner names don't need Screen Recording, which makes this a ground
    /// truth for window position that works on an ungranted machine.
    private func runWindowBounds(owningApplicationName: String) {
        let onScreenWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        let matchingWindowBounds: [[String: Double]] = onScreenWindows.compactMap { windowInfo in
            guard windowInfo[kCGWindowOwnerName as String] as? String == owningApplicationName,
                  windowInfo[kCGWindowLayer as String] as? Int == 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let windowBounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return nil
            }
            return HeadlessOutput.json(windowBounds)
        }

        HeadlessOutput.finish([
            "status": matchingWindowBounds.isEmpty ? "failed" : "ok",
            "owningApplicationName": owningApplicationName,
            "windowBoundsTopLeftOrigin": matchingWindowBounds
        ], exitCode: matchingWindowBounds.isEmpty ? 1 : 0)
    }

    // MARK: Self Test

    /// Checks the pure coordinate and parsing logic. These cases simulate
    /// display layouts, so they also cover multi-display arrangements on a
    /// machine with one monitor.
    private func runSelfTest() {
        var failures: [String] = []
        var checkCount = 0

        func expect(_ condition: Bool, _ description: String) {
            checkCount += 1
            if !condition {
                failures.append(description)
            }
        }

        func isClose(_ first: CGPoint, _ second: CGPoint) -> Bool {
            hypot(first.x - second.x, first.y - second.y) < 0.75
        }

        // Retina MacBook: 1512x982 points, sent to the model at 1280x831.
        let builtInDisplayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let builtInImageSize = ScreenshotCoordinateMapper.screenshotPixelSize(forDisplayWidth: 1512, displayHeight: 982, maximumDimension: 1280)
        expect(builtInImageSize.width == 1280 && builtInImageSize.height == 831, "built-in display downscales to 1280x831")

        let centerPoint = ScreenshotCoordinateMapper.mapScreenshotPoint(
            CGPoint(x: 640, y: 415.5), screenshotWidthInPixels: 1280, screenshotHeightInPixels: 831, displayFrame: builtInDisplayFrame)
        expect(isClose(centerPoint.displayLocalPoint, CGPoint(x: 756, y: 491)), "image center maps to display center")
        expect(isClose(centerPoint.globalAppKitPoint, CGPoint(x: 756, y: 491)), "display center maps to itself in AppKit")

        let topLeftPoint = ScreenshotCoordinateMapper.mapScreenshotPoint(
            .zero, screenshotWidthInPixels: 1280, screenshotHeightInPixels: 831, displayFrame: builtInDisplayFrame)
        expect(isClose(topLeftPoint.globalAppKitPoint, CGPoint(x: 0, y: 982)), "image top-left maps to AppKit top of display")

        let clampedPoint = ScreenshotCoordinateMapper.mapScreenshotPoint(
            CGPoint(x: 5000, y: -40), screenshotWidthInPixels: 1280, screenshotHeightInPixels: 831, displayFrame: builtInDisplayFrame)
        expect(isClose(clampedPoint.globalAppKitPoint, CGPoint(x: 1512, y: 982)), "out-of-image coordinates clamp to the display")

        // External display to the right, 1920x1080, bottom-aligned.
        let rightDisplayFrame = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let rightDisplayPoint = ScreenshotCoordinateMapper.mapScreenshotPoint(
            CGPoint(x: 640, y: 360), screenshotWidthInPixels: 1280, screenshotHeightInPixels: 720, displayFrame: rightDisplayFrame)
        expect(isClose(rightDisplayPoint.globalAppKitPoint, CGPoint(x: 2472, y: 540)), "right display adds its x origin")

        // External display to the left, so global x is negative.
        let leftDisplayFrame = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let leftDisplayPoint = ScreenshotCoordinateMapper.mapScreenshotPoint(
            CGPoint(x: 0, y: 720), screenshotWidthInPixels: 1280, screenshotHeightInPixels: 720, displayFrame: leftDisplayFrame)
        expect(isClose(leftDisplayPoint.globalAppKitPoint, CGPoint(x: -1920, y: 100)), "left display keeps negative x and offset y")

        // External display above the built-in one.
        let aboveDisplayFrame = CGRect(x: -200, y: 982, width: 2560, height: 1440)
        let aboveDisplayPoint = ScreenshotCoordinateMapper.mapScreenshotPoint(
            CGPoint(x: 1280, y: 0), screenshotWidthInPixels: 1280, screenshotHeightInPixels: 720, displayFrame: aboveDisplayFrame)
        expect(isClose(aboveDisplayPoint.globalAppKitPoint, CGPoint(x: 2360, y: 2422)), "above display stacks on the primary's height")

        // Core Graphics to AppKit frame conversion for the same display.
        let convertedFrame = ScreenshotCoordinateMapper.appKitFrame(
            fromCoreGraphicsFrame: CGRect(x: -200, y: -1440, width: 2560, height: 1440),
            primaryDisplayHeight: 982
        )
        expect(convertedFrame == aboveDisplayFrame, "Core Graphics frame converts to AppKit")

        // Screen selection.
        let makeCapture = { (screenNumber: Int, isCursorScreen: Bool) in
            CompanionScreenCapture(
                imageData: Data(), label: "", screenNumber: screenNumber, isCursorScreen: isCursorScreen,
                displayWidthInPoints: 1, displayHeightInPoints: 1, displayFrame: .zero,
                screenshotWidthInPixels: 1, screenshotHeightInPixels: 1
            )
        }
        let twoCaptures = [makeCapture(1, true), makeCapture(2, false)]
        expect(ScreenshotCoordinateMapper.targetCapture(forScreenNumber: 2, in: twoCaptures)?.screenNumber == 2, "screen2 selects capture 2")
        expect(ScreenshotCoordinateMapper.targetCapture(forScreenNumber: nil, in: twoCaptures)?.screenNumber == 1, "no screen selects the cursor screen")
        expect(ScreenshotCoordinateMapper.targetCapture(forScreenNumber: 9, in: twoCaptures)?.screenNumber == 1, "bad screen falls back to the cursor screen")
        let capturesWithNoCursor = [makeCapture(1, false)]
        expect(ScreenshotCoordinateMapper.targetCapture(forScreenNumber: nil, in: capturesWithNoCursor)?.screenNumber == 1, "cursor on a top edge still gets a screen")

        // Tag parsing.
        let plainTag = CompanionManager.parsePointingCoordinates(from: "look here. [POINT:100,200:save button]")
        expect(plainTag.coordinate == CGPoint(x: 100, y: 200), "plain tag coordinate")
        expect(plainTag.elementLabel == "save button", "plain tag label")
        expect(plainTag.spokenText == "look here.", "plain tag removed from speech")

        let screenTag = CompanionManager.parsePointingCoordinates(from: "over there [POINT:400,300:terminal:screen2]")
        expect(screenTag.screenNumber == 2 && screenTag.elementLabel == "terminal", "label plus screen")

        let screenOnlyTag = CompanionManager.parsePointingCoordinates(from: "over there [POINT:400,300:screen2]")
        expect(screenOnlyTag.screenNumber == 2 && screenOnlyTag.elementLabel == nil, "screen with no label")

        let noneTag = CompanionManager.parsePointingCoordinates(from: "html is markup. [POINT:none]")
        expect(noneTag.coordinate == nil && noneTag.elementLabel == "none" && noneTag.spokenText == "html is markup.", "none tag")

        let trailingPunctuationTag = CompanionManager.parsePointingCoordinates(from: "there [POINT:10,20:tab].")
        expect(trailingPunctuationTag.coordinate == CGPoint(x: 10, y: 20) && !trailingPunctuationTag.spokenText.contains("POINT"), "tag before trailing period")

        let decimalTag = CompanionManager.parsePointingCoordinates(from: "there [POINT:10.5, 20.25:tab]")
        expect(decimalTag.coordinate == CGPoint(x: 10.5, y: 20.25), "decimal coordinates")

        let twoTags = CompanionManager.parsePointingCoordinates(from: "first [POINT:1,2:a] then [POINT:3,4:b]")
        expect(twoTags.coordinate == CGPoint(x: 3, y: 4) && !twoTags.spokenText.contains("POINT"), "last of several tags wins")

        let noTag = CompanionManager.parsePointingCoordinates(from: "no tag here")
        expect(noTag.coordinate == nil && noTag.spokenText == "no tag here", "response with no tag")

        // Voice selection.
        let voiceList = """
        Albert              en_US    # Hello! My name is Albert.
        Eddy (English (US)) en_US    # Hello! My name is Eddy.
        Samantha            en_US    # Hello! My name is Samantha.
        Thomas              fr_FR    # Bonjour, je m'appelle Thomas.
        """
        expect(SayTTSClient.chooseBestVoiceName(fromVoiceListOutput: voiceList) == "Samantha", "falls back to Samantha")
        expect(SayTTSClient.chooseBestVoiceName(fromVoiceListOutput: voiceList + "\nAva (Premium)       en_US    # Hello!") == "Ava (Premium)", "prefers a Premium voice")

        HeadlessOutput.finish([
            "status": failures.isEmpty ? "ok" : "failed",
            "checks": checkCount,
            "failures": failures
        ], exitCode: failures.isEmpty ? 0 : 1)
    }
}

/// CheckedContinuation traps on a second resume, and a transcription session
/// can report both a final transcript and a late error.
private final class SingleResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    private func takeContinuation() -> CheckedContinuation<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let currentContinuation = continuation
        continuation = nil
        return currentContinuation
    }

    func resume(returning value: String) {
        takeContinuation()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        takeContinuation()?.resume(throwing: error)
    }
}

// MARK: - Fixture Capture

/// An image plus where it sits on the display, used to check where text
/// really is, independent of the model.
struct GroundTruthImage {
    let imageData: Data
    let displayRectInPoints: CGRect
}

/// Builds a capture from a saved image, shaped exactly like a real one: a
/// full-display frame at the same downscaled size. Everything after capture
/// then runs unchanged, including the scaling that real captures go through.
enum FixtureScreenCapture {
    struct FixtureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func make(
        imagePath: String,
        imageRectInDisplayPoints: CGRect?,
        displayFrame: CGRect,
        label: String,
        screenNumber: Int,
        isCursorScreen: Bool,
        maximumScreenshotDimension: Int
    ) throws -> (screenCapture: CompanionScreenCapture, groundTruthImage: GroundTruthImage) {
        guard let sourceImageData = FileManager.default.contents(atPath: imagePath),
              let sourceBitmap = NSBitmapImageRep(data: sourceImageData),
              let sourceImage = sourceBitmap.cgImage else {
            throw FixtureError(message: "could not read image at \(imagePath)")
        }

        let placementRect = imageRectInDisplayPoints ?? CGRect(origin: .zero, size: displayFrame.size)

        let canvasSize = ScreenshotCoordinateMapper.screenshotPixelSize(
            forDisplayWidth: Int(displayFrame.width),
            displayHeight: Int(displayFrame.height),
            maximumDimension: maximumScreenshotDimension
        )

        guard let canvas = CGContext(
            data: nil,
            width: canvasSize.width,
            height: canvasSize.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FixtureError(message: "could not create a \(canvasSize.width)x\(canvasSize.height) canvas")
        }

        let pixelsPerPointX = CGFloat(canvasSize.width) / displayFrame.width
        let pixelsPerPointY = CGFloat(canvasSize.height) / displayFrame.height

        // A plain background where the desktop would show around a window.
        canvas.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height))
        canvas.interpolationQuality = .high
        canvas.draw(sourceImage, in: CGRect(
            x: placementRect.origin.x * pixelsPerPointX,
            y: (displayFrame.height - placementRect.maxY) * pixelsPerPointY,
            width: placementRect.width * pixelsPerPointX,
            height: placementRect.height * pixelsPerPointY
        ))

        guard let canvasImage = canvas.makeImage(),
              let jpegData = NSBitmapImageRep(cgImage: canvasImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw FixtureError(message: "could not encode the fixture as JPEG")
        }

        let screenCapture = CompanionScreenCapture(
            imageData: jpegData,
            label: label,
            screenNumber: screenNumber,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: canvasSize.width,
            screenshotHeightInPixels: canvasSize.height
        )

        // OCR runs on the full-resolution source, not the downscaled canvas.
        return (screenCapture, GroundTruthImage(imageData: sourceImageData, displayRectInPoints: placementRect))
    }
}

// MARK: - OCR Ground Truth

/// Finds where a piece of text really is using Vision, which shares nothing
/// with the model, so a passing check can't be the model agreeing with itself.
enum OCRGroundTruth {
    /// A click-sized tolerance around the text box: small targets like tabs
    /// have padding beyond the glyphs that OCR measures.
    private static let hitMarginInPoints: CGFloat = 10

    static func verify(
        pointInDisplayPoints: CGPoint,
        landsOnText targetText: String,
        in groundTruthImage: GroundTruthImage?
    ) -> [String: Any] {
        guard let groundTruthImage,
              let sourceImage = NSBitmapImageRep(data: groundTruthImage.imageData)?.cgImage else {
            return ["text": targetText, "hit": false, "error": "no image available for OCR"]
        }

        let textBoxesInDisplayPoints = findWholeWordBoxes(
            of: targetText,
            in: sourceImage,
            displayRect: groundTruthImage.displayRectInPoints
        )

        guard !textBoxesInDisplayPoints.isEmpty else {
            return ["text": targetText, "hit": false, "error": "OCR did not find the text"]
        }

        func distanceFromPoint(to box: CGRect) -> CGFloat {
            hypot(pointInDisplayPoints.x - box.midX, pointInDisplayPoints.y - box.midY)
        }

        // Judged against the nearest occurrence: pointing at any instance of
        // the text is correct.
        let nearestBox = textBoxesInDisplayPoints.min { distanceFromPoint(to: $0) < distanceFromPoint(to: $1) }!
        let isHit = nearestBox
            .insetBy(dx: -hitMarginInPoints, dy: -hitMarginInPoints)
            .contains(pointInDisplayPoints)

        return [
            "text": targetText,
            "hit": isHit,
            "ocrBoxInDisplayPoints": HeadlessOutput.json(nearestBox),
            "distanceToBoxCenterInPoints": round(distanceFromPoint(to: nearestBox) * 100) / 100,
            "occurrencesFound": textBoxesInDisplayPoints.count
        ]
    }

    static func findWholeWordBoxes(of targetText: String, in sourceImage: CGImage, displayRect: CGRect) -> [CGRect] {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false

        guard (try? VNImageRequestHandler(cgImage: sourceImage).perform([textRequest])) != nil,
              let observations = textRequest.results else {
            return []
        }

        let escapedTarget = NSRegularExpression.escapedPattern(for: targetText)
        guard let wholeWordRegex = try? NSRegularExpression(pattern: "\\b\(escapedTarget)\\b", options: [.caseInsensitive]) else {
            return []
        }

        var boxesInDisplayPoints: [CGRect] = []

        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let recognizedText = topCandidate.string
            let fullRange = NSRange(recognizedText.startIndex..., in: recognizedText)

            for match in wholeWordRegex.matches(in: recognizedText, range: fullRange) {
                guard let textRange = Range(match.range, in: recognizedText),
                      let wordBox = try? topCandidate.boundingBox(for: textRange)?.boundingBox else {
                    continue
                }

                // Vision boxes are normalized with a bottom-left origin.
                boxesInDisplayPoints.append(CGRect(
                    x: displayRect.origin.x + wordBox.origin.x * displayRect.width,
                    y: displayRect.origin.y + (1 - wordBox.maxY) * displayRect.height,
                    width: wordBox.width * displayRect.width,
                    height: wordBox.height * displayRect.height
                ))
            }
        }

        return boxesInDisplayPoints
    }
}
