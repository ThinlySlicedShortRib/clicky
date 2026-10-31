//
//  FollowAlongRehearsal.swift
//  leanring-buddy
//
//  TEST ONLY. Runs the real lesson runner against a real Blender window on a
//  machine where Screen Recording hasn't been granted. It is only constructed
//  by the `--headless-follow-along-rehearsal` command. The demo path,
//  FollowAlongCoordinator.startLesson, always uses
//  FollowAlongScreenCaptureSource and cannot reach anything in this file.
//
//  What is real here: Blender 5.2, its UI, every model call, the planner's
//  lesson, the parsing, mapping, gating, checks and cost figures. What stands
//  in: Blender exports its own window instead of ScreenCaptureKit capturing it,
//  and scripts/rehearse_follow_along.py plays the student by clicking exactly
//  where the runner pointed, so a wrong point really does fail the step.
//
//  The two sides talk through files in a shared directory, because Blender,
//  the app and the student are three separate processes:
//
//    capture-N.request   this file asks Blender for a frame
//    capture-N.png       Blender's export of its own window
//    capture-N.done      written after the PNG is complete
//    say-N.txt           words for the "student" to say, as a final transcript
//

import AppKit
import Foundation

@MainActor
final class FollowAlongBlenderBridgeScreenSource: FollowAlongScreenSource {
    let sourceDescription = "rehearsal: Blender's own window export over a file bridge, not ScreenCaptureKit"

    private let bridgeDirectoryURL: URL
    /// Where Blender's content sits on the display, in top-left display points.
    private let contentRectInDisplayPoints: CGRect
    private var nextCaptureNumber = 1

    private static let captureTimeoutInSeconds: TimeInterval = 20

    init(bridgeDirectoryURL: URL, contentRectInDisplayPoints: CGRect) {
        self.bridgeDirectoryURL = bridgeDirectoryURL
        self.contentRectInDisplayPoints = contentRectInDisplayPoints
    }

    func captureScreen() async throws -> CompanionScreenCapture {
        let captureNumber = nextCaptureNumber
        nextCaptureNumber += 1

        let requestURL = bridgeDirectoryURL.appendingPathComponent("capture-\(captureNumber).request")
        let doneURL = bridgeDirectoryURL.appendingPathComponent("capture-\(captureNumber).done")
        let imageURL = bridgeDirectoryURL.appendingPathComponent("capture-\(captureNumber).png")

        FileManager.default.createFile(atPath: requestURL.path, contents: nil)

        let deadline = Date().addingTimeInterval(Self.captureTimeoutInSeconds)
        while !FileManager.default.fileExists(atPath: doneURL.path) {
            guard Date() < deadline else {
                throw BrainError(message: "Blender didn't export capture \(captureNumber) in time")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Each full-resolution frame is a few megabytes and a lesson takes
        // hundreds, so only the most recent ones are kept.
        let framesKept = 6
        let staleImageURL = bridgeDirectoryURL.appendingPathComponent("capture-\(captureNumber - framesKept).png")
        try? FileManager.default.removeItem(at: staleImageURL)

        let primaryDisplayFrame = NSScreen.screens.first?.frame ?? .zero
        return try FixtureScreenCapture.make(
            imagePath: imageURL.path,
            imageRectInDisplayPoints: contentRectInDisplayPoints,
            displayFrame: primaryDisplayFrame,
            label: "user's screen (cursor is here)",
            screenNumber: 1,
            isCursorScreen: true,
            maximumScreenshotDimension: CompanionScreenCaptureUtility.maximumScreenshotDimension
        ).screenCapture
    }
}

/// Keeps a repeated rehearsal from reading aloud through the Mac's speakers.
/// It waits as long as the line would take to say, so timing stays realistic.
@MainActor
final class FollowAlongMutedPresenter: FollowAlongPresenter {
    private let wrappedPresenter: any FollowAlongPresenter
    private var speechEndDate = Date.distantPast
    private static let wordsPerSecond = 2.8

    init(wrapping wrappedPresenter: any FollowAlongPresenter) {
        self.wrappedPresenter = wrappedPresenter
    }

    var isSpeaking: Bool { Date() < speechEndDate }

    func lessonDidBegin() { wrappedPresenter.lessonDidBegin() }
    func lessonDidEnd() { wrappedPresenter.lessonDidEnd() }
    func setThinking(_ isThinking: Bool) { wrappedPresenter.setThinking(isThinking) }

    func flyPointer(toGlobalAppKitLocation globalLocation: CGPoint, displayFrame: CGRect, bubbleText: String?) async -> CGPoint? {
        await wrappedPresenter.flyPointer(toGlobalAppKitLocation: globalLocation, displayFrame: displayFrame, bubbleText: bubbleText)
    }

    func speak(_ text: String) async {
        let wordCount = text.split(separator: " ").count
        speechEndDate = Date().addingTimeInterval(Double(wordCount) / Self.wordsPerSecond)
    }

    func stopSpeaking() {
        speechEndDate = .distantPast
    }
}

/// Feeds scripted words into the runner through the same calls push-to-talk
/// uses. The hotkey, microphone and Apple Speech are all skipped, so this
/// covers what happens after a transcript exists and nothing before it.
@MainActor
final class FollowAlongRehearsalVoiceFeed {
    private let bridgeDirectoryURL: URL
    private let coordinator: FollowAlongCoordinator
    private var nextUtteranceNumber = 1
    private var pollingTask: Task<Void, Never>?

    init(bridgeDirectoryURL: URL, coordinator: FollowAlongCoordinator) {
        self.bridgeDirectoryURL = bridgeDirectoryURL
        self.coordinator = coordinator
    }

    func start() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.deliverNextUtteranceIfPresent()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
    }

    private func deliverNextUtteranceIfPresent() {
        let utteranceURL = bridgeDirectoryURL.appendingPathComponent("say-\(nextUtteranceNumber).txt")
        guard let transcript = try? String(contentsOf: utteranceURL, encoding: .utf8) else { return }
        nextUtteranceNumber += 1
        coordinator.userStartedTalking()
        coordinator.userFinishedTalking(transcript: transcript)
    }
}
