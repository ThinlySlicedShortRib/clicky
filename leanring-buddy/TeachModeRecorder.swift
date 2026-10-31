//
//  TeachModeRecorder.swift
//  leanring-buddy
//
//  Records a live demonstration: what the teacher said, what they clicked, and
//  how the screen looked around each action. It only runs between the teacher
//  starting and stopping it, and the indicator is up the whole time.
//
//  Full screenshots and the audio stay in the recording directory, which the
//  compiler deletes once a lesson exists.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

struct TeachModeRecorderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

// MARK: - Narration

/// Continuous speech capture for the length of a recording. The push-to-talk
/// pipeline is built around a held key and one final transcript, while this
/// needs phrases with timestamps, so that they can be matched to actions.
final class TeachNarrationCapture {
    /// Recognition requests degrade on long audio, so a fresh one takes over
    /// at this point in a recording, and timestamps carry across the handover.
    private static let recognitionRequestLifetimeInSeconds: TimeInterval = 50
    /// A pause this long ends a phrase.
    private static let phraseGapInSeconds = 0.7

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer: SFSpeechRecognizer?
    private let narrationAudioFileURL: URL
    private let audioQueue = DispatchQueue(label: "clicky.teach.narration")

    private var narrationAudioFile: AVAudioFile?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRolloverTimer: Timer?

    /// Audio time written so far. Recognition timestamps are relative to their
    /// own request, so this anchors each request back onto the recording.
    private var framesWrittenSoFar: AVAudioFramePosition = 0
    private var audioSampleRate: Double = 44_100
    private var currentRequestStartSeconds: Double = 0

    private var completedSegments: [TeachNarrationSegment] = []
    private var latestRequestSegments: [TeachNarrationSegment] = []

    init(narrationAudioFileURL: URL) {
        self.narrationAudioFileURL = narrationAudioFileURL
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    static func requestPermissions() async -> Bool {
        let hasMicrophone = await AVCaptureDevice.requestAccess(for: .audio)
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return hasMicrophone && speechStatus == .authorized
    }

    func start() throws {
        guard speechRecognizer != nil else {
            throw TeachModeRecorderError(message: "speech recognition isn't available on this mac.")
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw TeachModeRecorderError(message: "clicky can't hear a microphone. check your input device.")
        }
        audioSampleRate = inputFormat.sampleRate

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000
        ]
        narrationAudioFile = try AVAudioFile(
            forWriting: narrationAudioFileURL,
            settings: fileSettings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )

        startRecognitionRequest()

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] audioBuffer, _ in
            self?.receive(audioBuffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionRolloverTimer = Timer.scheduledTimer(
            withTimeInterval: Self.recognitionRequestLifetimeInSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.rollOverRecognitionRequest()
        }
    }

    /// Stops listening and waits briefly for the last words to resolve.
    func stop() async -> [TeachNarrationSegment] {
        recognitionRolloverTimer?.invalidate()
        recognitionRolloverTimer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()

        try? await Task.sleep(nanoseconds: 1_200_000_000)

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        narrationAudioFile = nil

        return (completedSegments + latestRequestSegments)
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    private func receive(_ audioBuffer: AVAudioPCMBuffer) {
        audioQueue.sync {
            recognitionRequest?.append(audioBuffer)
            do {
                try narrationAudioFile?.write(from: audioBuffer)
                framesWrittenSoFar += AVAudioFramePosition(audioBuffer.frameLength)
            } catch {
                print("⚠️ Show Me Once: narration audio write failed: \(error.localizedDescription)")
            }
        }
    }

    private func startRecognitionRequest() {
        guard let speechRecognizer else { return }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        newRequest.addsPunctuation = true
        // On-device keeps the teacher's voice on their Mac when that's possible.
        newRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition

        currentRequestStartSeconds = Double(framesWrittenSoFar) / audioSampleRate
        latestRequestSegments = []

        let requestStartSeconds = currentRequestStartSeconds
        recognitionRequest = newRequest
        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] recognitionResult, recognitionError in
            guard let self else { return }
            if let recognitionResult {
                let phraseSegments = Self.groupIntoPhrases(
                    recognitionResult.bestTranscription.segments,
                    requestStartSeconds: requestStartSeconds
                )
                DispatchQueue.main.async {
                    // Results from a request that's already been replaced
                    // arrive here too, and they have to stay with that request.
                    if requestStartSeconds == self.currentRequestStartSeconds {
                        self.latestRequestSegments = phraseSegments
                    }
                }
            }
            if let recognitionError {
                print("⚠️ Show Me Once: speech recognition stopped: \(recognitionError.localizedDescription)")
            }
        }
    }

    private func rollOverRecognitionRequest() {
        completedSegments += latestRequestSegments
        let finishedRequest = recognitionRequest
        startRecognitionRequest()
        finishedRequest?.endAudio()
    }

    /// Recognition reports words. Teach mode wants phrases, split where the
    /// speaker paused, so a phrase can be matched to the click it went with.
    private static func groupIntoPhrases(
        _ transcriptionSegments: [SFTranscriptionSegment],
        requestStartSeconds: Double
    ) -> [TeachNarrationSegment] {
        var phrases: [TeachNarrationSegment] = []
        var phraseWords: [String] = []
        var phraseStartSeconds = 0.0
        var phraseEndSeconds = 0.0

        func finishPhrase() {
            guard !phraseWords.isEmpty else { return }
            phrases.append(TeachNarrationSegment(
                text: phraseWords.joined(separator: " "),
                startSeconds: requestStartSeconds + phraseStartSeconds,
                endSeconds: requestStartSeconds + phraseEndSeconds
            ))
            phraseWords = []
        }

        for transcriptionSegment in transcriptionSegments {
            if !phraseWords.isEmpty, transcriptionSegment.timestamp - phraseEndSeconds >= phraseGapInSeconds {
                finishPhrase()
            }
            if phraseWords.isEmpty {
                phraseStartSeconds = transcriptionSegment.timestamp
            }
            phraseWords.append(transcriptionSegment.substring)
            phraseEndSeconds = transcriptionSegment.timestamp + transcriptionSegment.duration
        }
        finishPhrase()
        return phrases
    }
}

// MARK: - Recorder

@MainActor
final class TeachModeRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recordedActionCount = 0
    @Published private(set) var elapsedSeconds: Double = 0
    /// True during a password field, so the indicator can say it looked away.
    @Published private(set) var isPausedForSecureInput = false

    /// Frames this often give every action a "before" shot from just prior to
    /// the click. A click can't be screenshotted before it happens otherwise.
    private static let frameIntervalInSeconds: TimeInterval = 0.5
    private static let maximumAgeOfBeforeFrameInSeconds = 1.5
    /// How long after an action the screen is captured, so that menus and
    /// animations have finished by the time of the "after" shot.
    private static let afterFrameDelayInSeconds: TimeInterval = 0.8
    /// Enough to crop a sharp reference image from. The model sees it smaller.
    private static let frameMaximumDimension = 1920
    private static let accessibilityReadTimeoutInSeconds: Float = 0.3

    private var recordingDirectoryURL: URL?
    private var framesDirectoryURL: URL?
    private var recordingIdentifier = ""
    private var startDate = Date()
    private var teacherName = ""
    private var startingSetup: LessonSetupDescription?

    private var inputAccumulator = TeachInputAccumulator()
    private var narrationCapture: TeachNarrationCapture?
    private var frameLoopTask: Task<Void, Never>?
    private var clockTimer: Timer?
    private var pendingFrameTasks: [Task<Void, Never>] = []

    private var latestFrame: CompanionScreenCapture?
    private var latestFrameDate = Date.distantPast

    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    private var secondsSinceStart: Double {
        Date().timeIntervalSince(startDate)
    }

    // MARK: Start and Stop

    func startRecording(teacherName: String) async throws {
        guard !isRecording else { return }

        guard await TeachNarrationCapture.requestPermissions() else {
            throw TeachModeRecorderError(message: "clicky needs the microphone and speech recognition to hear you teach. grant both in system settings, under privacy and security.")
        }
        guard AXIsProcessTrusted() else {
            throw TeachModeRecorderError(message: "clicky needs accessibility access to see what you click. grant it in system settings, under privacy and security.")
        }

        // Proves Screen Recording works before the teacher starts talking,
        // rather than letting them finish a take that captured nothing.
        let firstCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
            maximumDimension: Self.frameMaximumDimension,
            onlyCursorScreen: true
        )
        guard let firstCapture = firstCaptures.first else {
            throw TeachModeRecorderError(message: "clicky couldn't see your screen.")
        }

        let newRecordingIdentifier = UUID().uuidString
        let newRecordingDirectoryURL = try Self.recordingsDirectoryURL()
            .appendingPathComponent(newRecordingIdentifier, isDirectory: true)
        let newFramesDirectoryURL = newRecordingDirectoryURL
            .appendingPathComponent(TeachRecording.framesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: newFramesDirectoryURL, withIntermediateDirectories: true)

        let newNarrationCapture = TeachNarrationCapture(
            narrationAudioFileURL: newRecordingDirectoryURL.appendingPathComponent(Self.narrationAudioFileName)
        )
        try newNarrationCapture.start()

        recordingIdentifier = newRecordingIdentifier
        recordingDirectoryURL = newRecordingDirectoryURL
        framesDirectoryURL = newFramesDirectoryURL
        narrationCapture = newNarrationCapture
        self.teacherName = teacherName
        startDate = Date()
        inputAccumulator = TeachInputAccumulator()
        pendingFrameTasks = []
        recordedActionCount = 0
        elapsedSeconds = 0
        latestFrame = firstCapture
        latestFrameDate = Date()
        startingSetup = LessonSetupDescription(
            displaySizeInPoints: LessonRectangle(CGRect(origin: .zero, size: firstCapture.displayFrame.size)),
            windowSizeInPoints: nil,
            appearanceName: Self.currentAppearanceName()
        )

        // These reads happen inside the event tap, on the main thread, so an
        // app that has hung can't be allowed to hold them up for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.accessibilityReadTimeoutInSeconds)

        try startEventTap()
        startFrameLoop()

        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsedSeconds = self.secondsSinceStart
            }
        }

        isRecording = true
        print("🎓 Show Me Once: teach mode recording to \(newRecordingDirectoryURL.path)")
    }

    /// Stops everything, writes the manifest, and returns the recording's
    /// directory for the compiler.
    func stopRecording() async throws -> URL {
        guard isRecording, let recordingDirectoryURL, let startingSetup else {
            throw TeachModeRecorderError(message: "teach mode wasn't recording.")
        }

        let durationInSeconds = secondsSinceStart
        isRecording = false

        stopEventTap()
        frameLoopTask?.cancel()
        frameLoopTask = nil
        clockTimer?.invalidate()
        clockTimer = nil
        latestFrame = nil

        if inputAccumulator.finish(atSecondsFromStart: durationInSeconds) {
            captureFramesForLatestAction(beforeFrameData: pendingKeystrokeBeforeFrameData)
        }
        pendingClickBeforeFrameData = nil
        pendingKeystrokeBeforeFrameData = nil

        // A trailing action's "after" shot may still be waiting on its delay.
        for pendingFrameTask in pendingFrameTasks {
            await pendingFrameTask.value
        }
        pendingFrameTasks = []

        let narrationSegments = await narrationCapture?.stop() ?? []
        narrationCapture = nil

        let recording = TeachRecording(
            recordingIdentifier: recordingIdentifier,
            provenance: .liveRecording,
            teacherName: teacherName,
            startedAt: startDate,
            durationInSeconds: durationInSeconds,
            setup: startingSetup,
            actions: inputAccumulator.actions,
            narrationSegments: narrationSegments,
            secureGaps: inputAccumulator.secureGaps,
            narrationAudioFileName: Self.narrationAudioFileName
        )

        let manifestData = try LessonPackageArchiver.makeEncoder().encode(recording)
        try manifestData.write(to: recordingDirectoryURL.appendingPathComponent(TeachRecording.manifestFileName))
        print("🎓 Show Me Once: recorded \(recording.actions.count) actions, \(narrationSegments.count) phrases, \(recording.secureGaps.count) secure gaps")
        return recordingDirectoryURL
    }

    private static let narrationAudioFileName = "narration.m4a"

    static func recordingsDirectoryURL() throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupportURL.appendingPathComponent("Clicky/Recordings", isDirectory: true)
    }

    private static func currentAppearanceName() -> String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    // MARK: Frames

    private func startFrameLoop() {
        frameLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureRollingFrame()
                try? await Task.sleep(nanoseconds: UInt64(Self.frameIntervalInSeconds * 1_000_000_000))
            }
        }
    }

    private func captureRollingFrame() async {
        guard !isCaptureForbiddenRightNow() else {
            // A frame from just before the password box may already show it.
            latestFrame = nil
            noteSecureInput(isActive: true)
            return
        }
        noteSecureInput(isActive: false)

        guard let screenCapture = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
            maximumDimension: Self.frameMaximumDimension,
            onlyCursorScreen: true
        ).first else {
            return
        }

        // The capture takes a moment, and a password box may have opened
        // during it. Checking again means that frame is thrown away.
        guard !isCaptureForbiddenRightNow() else {
            latestFrame = nil
            return
        }
        latestFrame = screenCapture
        latestFrameDate = Date()
    }

    private func isCaptureForbiddenRightNow() -> Bool {
        let focusedElement = TeachAccessibilityReader.focusedElement()
        return TeachInputPrivacyRules.isCaptureForbidden(
            isSecureInputEnabled: TeachSecureInputMonitor.isSecureInputEnabled,
            focusedRole: focusedElement.flatMap { TeachAccessibilityReader.string(kAXRoleAttribute, of: $0) },
            focusedSubrole: focusedElement.flatMap { TeachAccessibilityReader.string(kAXSubroleAttribute, of: $0) }
        )
    }

    private func noteSecureInput(isActive: Bool) {
        guard isActive != inputAccumulator.isInsideSecureGap else { return }
        inputAccumulator.ingest(.secureInputChanged(isActive: isActive, secondsFromStart: secondsSinceStart))
        isPausedForSecureInput = isActive
    }

    private func recentBeforeFrameData() -> Data? {
        guard Date().timeIntervalSince(latestFrameDate) <= Self.maximumAgeOfBeforeFrameInSeconds else { return nil }
        return latestFrame?.imageData
    }

    /// Saves the screen on either side of a finished action. The "before" shot
    /// is taken from the rolling frame now, so a later frame can't replace it.
    private func captureFramesForLatestAction(beforeFrameData: Data?) {
        let actionIndex = inputAccumulator.actions.count - 1
        guard actionIndex >= 0, let framesDirectoryURL else { return }

        recordedActionCount = inputAccumulator.actions.count

        let beforeFrameFileName = beforeFrameData.flatMap { frameData -> String? in
            let fileName = "action-\(actionIndex)-before.jpg"
            let frameURL = framesDirectoryURL.appendingPathComponent(fileName)
            return (try? frameData.write(to: frameURL)) == nil ? nil : fileName
        }
        inputAccumulator.attachFrames(toActionAtIndex: actionIndex, beforeFrameFileName: beforeFrameFileName, afterFrameFileName: nil)

        let afterFrameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.afterFrameDelayInSeconds * 1_000_000_000))
            await self?.saveAfterFrame(forActionAtIndex: actionIndex, beforeFrameFileName: beforeFrameFileName)
        }
        pendingFrameTasks.append(afterFrameTask)
    }

    private func saveAfterFrame(forActionAtIndex actionIndex: Int, beforeFrameFileName: String?) async {
        guard !isCaptureForbiddenRightNow(), let framesDirectoryURL else { return }
        guard let screenCapture = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
            maximumDimension: Self.frameMaximumDimension,
            onlyCursorScreen: true
        ).first else {
            return
        }

        let fileName = "action-\(actionIndex)-after.jpg"
        guard !isCaptureForbiddenRightNow(),
              (try? screenCapture.imageData.write(to: framesDirectoryURL.appendingPathComponent(fileName))) != nil else {
            return
        }
        inputAccumulator.attachFrames(toActionAtIndex: actionIndex, beforeFrameFileName: beforeFrameFileName, afterFrameFileName: fileName)
    }

    // MARK: Input Events

    private func startEventTap() throws {
        let monitoredEventTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<TeachModeRecorder>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap's run loop source is on the main run loop.
            MainActor.assumeIsolated {
                recorder.handleEventTap(eventType: eventType, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let newEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let newRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newEventTap, 0) else {
            throw TeachModeRecorderError(message: "clicky couldn't start watching clicks. check its accessibility permission.")
        }

        eventTap = newEventTap
        eventTapRunLoopSource = newRunLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newEventTap, enable: true)
    }

    private func stopEventTap() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handleEventTap(eventType: CGEventType, event: CGEvent) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        guard isRecording else { return }

        let isCaptureForbidden = isCaptureForbiddenRightNow()
        noteSecureInput(isActive: isCaptureForbidden)
        guard !isCaptureForbidden else { return }

        let secondsFromStart = secondsSinceStart
        let globalTopLeftLocation = event.location
        let displayOrigin = Self.displayOriginInGlobalTopLeftPoints(containing: globalTopLeftLocation)
        let locationInDisplayPoints = CGPoint(
            x: globalTopLeftLocation.x - displayOrigin.x,
            y: globalTopLeftLocation.y - displayOrigin.y
        )

        // The rolling frame is grabbed before the action finishes, so the
        // shot really does show the screen from before the click landed.
        let beforeFrameData = recentBeforeFrameData()
        var didFinishAction = false

        switch eventType {
        case .leftMouseDown, .rightMouseDown:
            let context = makeActionContext(atGlobalTopLeftPoint: globalTopLeftLocation, displayOrigin: displayOrigin)
            guard !isOwnApplication(context) else { return }
            pendingClickBeforeFrameData = beforeFrameData
            didFinishAction = inputAccumulator.ingest(.mouseDown(
                locationInDisplayPoints: locationInDisplayPoints,
                clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                isRightButton: eventType == .rightMouseDown,
                secondsFromStart: secondsFromStart,
                context: context
            ))

        case .leftMouseUp, .rightMouseUp:
            didFinishAction = inputAccumulator.ingest(.mouseUp(
                locationInDisplayPoints: locationInDisplayPoints,
                secondsFromStart: secondsFromStart
            ))

        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let eventFlags = event.flags
            let keystrokeCategory = TeachKeystrokeCategorizer.category(
                forKeyCode: keyCode,
                isCommandHeld: eventFlags.contains(.maskCommand),
                isControlHeld: eventFlags.contains(.maskControl)
            )

            // The teach hotkey itself isn't part of the lesson.
            guard keystrokeCategory != .shortcut(name: "control+t") else { return }

            let context = makeFocusedActionContext(displayOrigin: displayOrigin)
            guard !isOwnApplication(context) else { return }
            pendingKeystrokeBeforeFrameData = pendingKeystrokeBeforeFrameData ?? beforeFrameData
            didFinishAction = inputAccumulator.ingest(.keystroke(
                category: keystrokeCategory,
                secondsFromStart: secondsFromStart,
                context: context
            ))

        default:
            return
        }

        if didFinishAction {
            let wasKeystrokeAction = inputAccumulator.actions.last?.keystrokeSummary != nil
            if wasKeystrokeAction {
                captureFramesForLatestAction(beforeFrameData: pendingKeystrokeBeforeFrameData)
                // This key may have ended one typing run and begun the next.
                pendingKeystrokeBeforeFrameData = eventType == .keyDown ? beforeFrameData : nil
            } else {
                captureFramesForLatestAction(beforeFrameData: pendingClickBeforeFrameData)
                pendingClickBeforeFrameData = nil
            }
        }
    }

    /// Actions finish after they begin: a click on release, and typing when
    /// the run ends. These hold the "before" frame from the moment each began,
    /// because by the time they finish the rolling frame shows the result.
    private var pendingClickBeforeFrameData: Data?
    private var pendingKeystrokeBeforeFrameData: Data?

    private func isOwnApplication(_ context: TeachActionContext) -> Bool {
        context.applicationBundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func makeActionContext(atGlobalTopLeftPoint globalTopLeftLocation: CGPoint, displayOrigin: CGPoint) -> TeachActionContext {
        guard let hitElement = TeachAccessibilityReader.element(atGlobalTopLeftPoint: globalTopLeftLocation) else {
            return .empty
        }
        return makeActionContext(for: hitElement, displayOrigin: displayOrigin)
    }

    private func makeFocusedActionContext(displayOrigin: CGPoint) -> TeachActionContext {
        guard let focusedElement = TeachAccessibilityReader.focusedElement() else {
            return .empty
        }
        return makeActionContext(for: focusedElement, displayOrigin: displayOrigin)
    }

    private func makeActionContext(for element: AXUIElement, displayOrigin: CGPoint) -> TeachActionContext {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        let owningApplication = NSRunningApplication(processIdentifier: processIdentifier)

        let isOverSecureField = TeachAccessibilityReader.isSecureField(element)

        var windowFrame: LessonRectangle?
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
           let windowValue,
           CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
           let frameInGlobalPoints = TeachAccessibilityReader.frame(of: unsafeBitCast(windowValue, to: AXUIElement.self)) {
            windowFrame = LessonRectangle(frameInGlobalPoints.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y))
        }

        return TeachActionContext(
            applicationName: owningApplication?.localizedName,
            applicationBundleIdentifier: owningApplication?.bundleIdentifier,
            // Nothing about a password box helps a lesson, so none of it is kept.
            element: isOverSecureField ? nil : TeachAccessibilityReader.snapshot(of: element, displayOriginInGlobalTopLeftPoints: displayOrigin),
            windowFrameInDisplayPoints: windowFrame,
            isOverSecureField: isOverSecureField
        )
    }

    /// Event locations are global, while frames and lesson data use the
    /// display's own coordinates.
    private static func displayOriginInGlobalTopLeftPoints(containing globalTopLeftLocation: CGPoint) -> CGPoint {
        guard let primaryDisplayHeight = NSScreen.screens.first?.frame.height else { return .zero }

        let appKitLocation = CGPoint(x: globalTopLeftLocation.x, y: primaryDisplayHeight - globalTopLeftLocation.y)
        let containingScreen = NSScreen.screens.first { $0.frame.contains(appKitLocation) } ?? NSScreen.screens.first
        guard let containingScreen else { return .zero }

        return CGPoint(
            x: containingScreen.frame.origin.x,
            y: primaryDisplayHeight - containingScreen.frame.maxY
        )
    }
}
