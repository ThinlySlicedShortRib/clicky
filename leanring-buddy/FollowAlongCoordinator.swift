//
//  FollowAlongCoordinator.swift
//  leanring-buddy
//
//  Owns one Follow Along session from paste to end card. It connects the
//  importer, the lesson runner, the on-screen surfaces and push-to-talk, and
//  chooses which models do which job.
//

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

enum FollowAlongPhase {
    case idle
    case pasting
    case importing(statusText: String)
    case running
    case finished(FollowAlongRunSummary)
    case failed(message: String)
}

enum FollowAlongModelChoice {
    private static let checkModelEnvironmentVariableName = "CLICKY_FOLLOW_ALONG_CHECK_MODEL"
    private static let cheapClaudeModelValue = "claude-haiku-5-5"

    /// "Did the thing happen" is a much easier question than "where is this
    /// control and what replaced it", and it gets asked far more often, so it
    /// goes to the cheapest model that answers it well.
    static func checkModelValue(forConfiguredModelValue configuredModelValue: String) -> String {
        if let environmentValue = ProcessInfo.processInfo.environment[checkModelEnvironmentVariableName],
           !environmentValue.isEmpty {
            return environmentValue
        }
        return configuredModelValue.hasPrefix("claude-") ? cheapClaudeModelValue : configuredModelValue
    }
}

// MARK: - Real Screen

/// The demo path's only screen source: ScreenCaptureKit, nothing else. With
/// Screen Recording missing it throws, and the lesson stops and says so.
@MainActor
final class FollowAlongScreenCaptureSource: FollowAlongScreenSource {
    let sourceDescription = "screencapturekit"

    func captureScreen() async throws -> CompanionScreenCapture {
        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(includesMouseCursor: false)
        guard let cursorScreenCapture = ScreenshotCoordinateMapper.targetCapture(forScreenNumber: nil, in: screenCaptures) else {
            throw CompanionScreenCaptureError.screenRecordingPermissionMissing
        }
        return cursorScreenCapture
    }
}

// MARK: - Presenter

/// Performs a lesson through the same overlay and voice as normal Clicky.
@MainActor
final class CompanionFollowAlongPresenter: FollowAlongPresenter {
    private unowned let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    var isSpeaking: Bool { companionManager.isSpeakingForLesson }

    func lessonDidBegin() {
        companionManager.prepareOverlayForLesson()
    }

    func lessonDidEnd() {
        companionManager.releaseOverlayAfterLesson()
    }

    func setThinking(_ isThinking: Bool) {
        companionManager.setThinkingForLesson(isThinking)
    }

    func flyPointer(toGlobalAppKitLocation globalLocation: CGPoint, displayFrame: CGRect, bubbleText: String?) async -> CGPoint? {
        await companionManager.flyBuddyForLesson(
            toGlobalAppKitLocation: globalLocation,
            displayFrame: displayFrame,
            bubbleText: bubbleText
        )
    }

    func speak(_ text: String) async {
        await companionManager.speakForLesson(text)
    }

    func stopSpeaking() {
        companionManager.stopSpeakingForLesson()
    }
}

// MARK: - Run Log

/// Writes what a lesson did to disk as it happens, one JSON object per line,
/// so an interrupted run still leaves a usable transcript.
@MainActor
final class FollowAlongRunLog {
    let directoryURL: URL
    private let eventFileHandle: FileHandle?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        let eventFileURL = directoryURL.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: eventFileURL.path, contents: nil)
        eventFileHandle = try? FileHandle(forWritingTo: eventFileURL)
    }

    func appendEvent(named eventName: String, fields: [String: Any]) {
        var eventObject = fields
        eventObject["event"] = eventName
        guard var eventData = try? JSONSerialization.data(withJSONObject: eventObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return
        }
        eventData.append(0x0A)
        try? eventFileHandle?.write(contentsOf: eventData)
        print("📘 \(String(decoding: eventData, as: UTF8.self))", terminator: "")
    }

    func saveSummary(_ summary: FollowAlongRunSummary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let summaryData = try? encoder.encode(summary) else { return }
        try? summaryData.write(to: directoryURL.appendingPathComponent("summary.json"), options: .atomic)
    }
}

// MARK: - Coordinator

@MainActor
final class FollowAlongCoordinator: ObservableObject {
    @Published private(set) var phase: FollowAlongPhase = .idle
    @Published var pastedLinkText = ""
    @Published private(set) var runProgress: FollowAlongRunProgress?

    private unowned let companionManager: CompanionManager
    private lazy var surfaceManager = FollowAlongSurfaceManager(coordinator: self)
    private var hotKey: FollowAlongGlobalHotKey?
    private var sessionTask: Task<Void, Never>?
    private(set) var activeRunner: FollowAlongLessonRunner?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    var isLessonRunning: Bool {
        activeRunner != nil
    }

    /// Registers the shortcut that opens the paste surface. It works with no
    /// permissions at all, unlike the push-to-talk monitor.
    func installHotKey() {
        hotKey = FollowAlongGlobalHotKey { [weak self] in
            self?.showPasteSurface()
        }
    }

    // MARK: Paste

    func showPasteSurface() {
        // While a lesson runs, the shortcut must not start a second one.
        guard !isLessonRunning else { return }

        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        surfaceManager.hideEndCard()
        pastedLinkText = ""
        phase = .pasting
        surfaceManager.showPasteSurface()
    }

    func dismissPasteSurface() {
        guard case .pasting = phase else {
            if case .failed = phase {
                surfaceManager.hidePasteSurface()
                phase = .idle
            }
            return
        }
        surfaceManager.hidePasteSurface()
        phase = .idle
    }

    func submitPastedLink() {
        guard let videoIdentifier = FollowAlongYouTubeLink.videoIdentifier(from: pastedLinkText) else {
            phase = .failed(message: "that doesn't look like a youtube link")
            surfaceManager.refitPasteSurface()
            return
        }
        startLesson(videoIdentifier: videoIdentifier)
    }

    // MARK: Starting

    /// The one way a lesson starts in the real app. It always uses real screen
    /// capture and the real voice. Rehearsals go through `performLesson`
    /// directly and can only be reached from a `--headless` command.
    func startLesson(videoIdentifier: String) {
        guard !isLessonRunning, sessionTask == nil else { return }

        phase = .importing(statusText: "checking for a saved lesson")
        surfaceManager.showPasteSurface()

        sessionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.sessionTask = nil }

            do {
                let (lesson, wasBuiltNow) = try await self.loadOrBuildLesson(videoIdentifier: videoIdentifier)
                guard !Task.isCancelled else { return }

                let runLog = FollowAlongRunLog(directoryURL: try FollowAlongStorage.makeRunDirectoryURL())
                _ = await self.performLesson(
                    lesson: lesson,
                    planWasBuiltDuringThisRun: wasBuiltNow,
                    screenSource: FollowAlongScreenCaptureSource(),
                    presenter: CompanionFollowAlongPresenter(companionManager: self.companionManager),
                    runLog: runLog
                )
            } catch is CancellationError {
                self.phase = .idle
                self.surfaceManager.hidePasteSurface()
            } catch {
                self.phase = .failed(message: error.localizedDescription)
                self.surfaceManager.refitPasteSurface()
                print("⚠️ Follow Along: \(error.localizedDescription)")
            }
        }
    }

    func loadOrBuildLesson(videoIdentifier: String) async throws -> (lesson: FollowAlongLesson, wasBuiltNow: Bool) {
        let importer = FollowAlongTutorialImporter(modelValue: companionManager.selectedModel) { [weak self] importProgress in
            self?.phase = .importing(statusText: importProgress.statusText)
        }
        return try await importer.loadOrBuildLesson(videoIdentifier: videoIdentifier)
    }

    /// Runs a lesson to the end card. The screen source and presenter are
    /// passed in so a rehearsal runs this same code rather than a copy of it.
    func performLesson(
        lesson: FollowAlongLesson,
        planWasBuiltDuringThisRun: Bool,
        screenSource: any FollowAlongScreenSource,
        presenter: any FollowAlongPresenter,
        runLog: FollowAlongRunLog
    ) async -> FollowAlongRunSummary {
        let locateModelValue = companionManager.selectedModel
        let checkModelValue = FollowAlongModelChoice.checkModelValue(forConfiguredModelValue: locateModelValue)

        let runner = FollowAlongLessonRunner(
            lesson: lesson,
            locateModelValue: locateModelValue,
            checkModelValue: checkModelValue,
            screenSource: screenSource,
            presenter: presenter,
            planWasBuiltDuringThisRun: planWasBuiltDuringThisRun,
            onProgress: { [weak self] runProgress in
                self?.runProgress = runProgress
            },
            onEvent: { eventName, eventFields in
                runLog.appendEvent(named: eventName, fields: eventFields)
            }
        )

        activeRunner = runner
        phase = .running
        // The meter measures itself when it opens, so it needs content first.
        runner.publishInitialProgress()
        surfaceManager.hidePasteSurface()
        surfaceManager.showHUD()

        let summary = await runner.run()

        activeRunner = nil
        runLog.saveSummary(summary)
        surfaceManager.hideHUD()
        phase = .finished(summary)
        surfaceManager.showEndCard()
        return summary
    }

    func stopActiveLesson() {
        activeRunner?.requestStop()
    }

    func dismissEndCard() {
        surfaceManager.hideEndCard()
        phase = .idle
        runProgress = nil
    }

    // MARK: Push-To-Talk

    func userStartedTalking() {
        activeRunner?.userStartedTalking()
    }

    func userFinishedTalking(transcript: String?) {
        activeRunner?.userFinishedTalking(transcript: transcript)
    }

    // MARK: Rendering For Evidence

    /// Lets a headless check produce images of the real SwiftUI surfaces.
    func applyStateForRendering(phase renderedPhase: FollowAlongPhase, runProgress renderedProgress: FollowAlongRunProgress?) {
        phase = renderedPhase
        runProgress = renderedProgress
    }
}

// MARK: - Global Shortcut

/// Command+Shift+Y, as in YouTube. A Carbon hot key is used because it needs no
/// permission, so the paste surface opens even before Accessibility is granted.
/// Control+Option is taken: holding those two already means push-to-talk.
final class FollowAlongGlobalHotKey {
    private static var onPressedHandler: (@MainActor () -> Void)?

    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?

    init(onPressed: @escaping @MainActor () -> Void) {
        Self.onPressedHandler = onPressed

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    FollowAlongGlobalHotKey.onPressedHandler?()
                }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerReference)

        // "CLFA" only has to be unique within this app.
        let hotKeyIdentifier = EventHotKeyID(signature: OSType(0x434C4641), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Y),
            UInt32(cmdKey | shiftKey),
            hotKeyIdentifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
    }

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }
}
