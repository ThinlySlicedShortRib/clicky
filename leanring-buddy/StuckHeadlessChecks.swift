//
//  StuckHeadlessChecks.swift
//  leanring-buddy
//
//  Scripted checks for Stuck, reached only through `--headless-*` flags, each
//  of which exits the app when it's done. None of them can run during a normal
//  launch, so nothing here is on the demo path, and any result that didn't come
//  from real detection says `"scripted": true`.
//
//  Frames come from the app's own views drawing themselves, which needs no
//  Screen Recording. They show what the code renders, not what reached a real
//  display.
//

import AppKit
import ApplicationServices
import Foundation
import SwiftUI

struct HeadlessStuckOfferOptions {
    enum Answer: String {
        case yes
        case no
        case none
    }

    var answer: Answer = .none
    var fixtureImagePath: String?
    var fixtureImageRectInDisplayPoints: CGRect?
    var framesDirectoryPath: String?
    var useLocalBrain = false
    var receiptLines: [String] = []
}

extension HeadlessCommandRunner {
    // MARK: Status

    /// Asks an already running Clicky how detection is going. Counts only.
    func runStuckStatus() async {
        let replyWaitInSeconds = 2.5

        let reply: [AnyHashable: Any]? = await withCheckedContinuation { continuation in
            let distributedCenter = DistributedNotificationCenter.default()
            var replyObserver: NSObjectProtocol?
            var hasResumed = false

            func finish(_ userInfo: [AnyHashable: Any]?) {
                guard !hasResumed else { return }
                hasResumed = true
                if let replyObserver {
                    distributedCenter.removeObserver(replyObserver)
                }
                continuation.resume(returning: userInfo)
            }

            replyObserver = distributedCenter.addObserver(
                forName: StuckCompanion.distributedStatusReplyName,
                object: nil,
                queue: .main
            ) { notification in
                finish(notification.userInfo)
            }

            distributedCenter.postNotificationName(
                StuckCompanion.distributedStatusRequestName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + replyWaitInSeconds) {
                finish(nil)
            }
        }

        guard let reply else {
            HeadlessOutput.finish([
                "status": "failed",
                "error": "no running Clicky replied within \(replyWaitInSeconds)s"
            ], exitCode: 1)
        }

        var result: [String: Any] = ["status": "ok"]
        for (key, value) in reply {
            if let stringKey = key as? String {
                result[stringKey] = value
            }
        }
        HeadlessOutput.finish(result, exitCode: 0)
    }

    // MARK: Shadow Run

    /// Runs the real tap and detector on whatever is really happening on this
    /// Mac, with no UI, so nothing can interrupt anyone. Unlike every other
    /// check here this isn't scripted: the point is to see how often a real
    /// offer would have fired. It keeps totals only and writes nothing until
    /// it prints them at the end. The input is unlabelled, so a would-be offer
    /// is a count to look at, not a measured false positive.
    func runStuckShadow(seconds: Double) async {
        let scoringModel = StuckScoringModel()
        var detector = StuckDetector(scoringModel: scoringModel)
        var offerPolicy = StuckOfferPolicy(scoringModel: scoringModel)
        var offersThatWouldHaveFired = 0
        var peakScore: Double = 0
        var readingsPerSignal: [String: Int] = [:]
        var eventCountsByCategory: [String: Int] = [:]

        let tapMonitor = StuckEventTapMonitor()
        tapMonitor.onBehaviourEvent = { behaviourEventKind, timestampInSeconds in
            MainActor.assumeIsolated {
                detector.ingest(StuckBehaviourEvent(timestampInSeconds: timestampInSeconds, kind: behaviourEventKind))
                eventCountsByCategory[Self.categoryName(of: behaviourEventKind), default: 0] += 1
            }
        }

        guard tapMonitor.start() else {
            HeadlessOutput.finish(["status": "permission_missing", "error": "macOS refused the tap"], exitCode: 3)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let isReceivingKeyboardEvents = tapMonitor.isReceivingKeyboardEvents

        let startDate = Date()
        while Date().timeIntervalSince(startDate) < seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            let currentTime = ProcessInfo.processInfo.systemUptime
            detector.wipeExpiredMemory(atTime: currentTime)
            let assessment = detector.assess(atTime: currentTime)
            peakScore = max(peakScore, assessment.score)
            for signalReading in assessment.signals {
                readingsPerSignal[signalReading.kind.rawValue, default: 0] += 1
            }
            if offerPolicy.shouldOffer(for: assessment, atTime: currentTime, isCompanionBusy: false) {
                offersThatWouldHaveFired += 1
            }
        }

        tapMonitor.stop()

        HeadlessOutput.finish([
            "status": isReceivingKeyboardEvents ? "ok" : "permission_missing",
            "scripted": false,
            "inputIsUnlabelled": true,
            "seconds": seconds,
            "isReceivingKeyboardEvents": isReceivingKeyboardEvents,
            "eventCountsByCategory": eventCountsByCategory,
            "peakScore": peakScore,
            "secondsEachSignalWasActive": readingsPerSignal,
            "offersThatWouldHaveFired": offersThatWouldHaveFired
        ], exitCode: isReceivingKeyboardEvents ? 0 : 3)
    }

    /// Categories only. Coarse areas and distances are deliberately left out.
    private static func categoryName(of behaviourEventKind: StuckBehaviourEventKind) -> String {
        switch behaviourEventKind {
        case .undo: return "undo"
        case .redo: return "redo"
        case .cancel: return "cancel"
        case .modeToggle: return "modeToggle"
        case .anonymousKeyPress: return "anonymousKeyPress"
        case .click: return "click"
        case .dragFinished: return "drag"
        case .scrollTick: return "scroll"
        case .pointerMovement: return "pointerMovement"
        case .leftForBrowser, .returnedFromBrowser: return "browserSwitch"
        }
    }

    // MARK: Tap Check

    /// Installs the real tap, then reads it back from the system list. That
    /// list is the only honest answer: a tap can install and still be denied
    /// key presses. Removes the tap straight away.
    func runStuckTapCheck() async {
        let tapMonitor = StuckEventTapMonitor()
        let didInstallTap = tapMonitor.start()

        // Enabled state settles once the run loop has had a turn.
        try? await Task.sleep(nanoseconds: 400_000_000)

        let systemTaps = SystemEventTapReport.tapsOwnedByThisProcess()
        let isReceivingKeyboardEvents = tapMonitor.isReceivingKeyboardEvents
        tapMonitor.stop()
        let tapsAfterStopping = SystemEventTapReport.tapsOwnedByThisProcess()

        HeadlessOutput.finish([
            "status": isReceivingKeyboardEvents ? "ok" : "permission_missing",
            "tapInstalled": didInstallTap,
            "isReceivingKeyboardEvents": isReceivingKeyboardEvents,
            "inputMonitoringPreflight": CGPreflightListenEventAccess(),
            "accessibilityTrusted": AXIsProcessTrusted(),
            "requestedEventMask": StuckEventTapMonitor.monitoredEventMask,
            "systemReportedTaps": systemTaps.map {
                ["isListenOnly": $0.isListenOnly, "eventMask": $0.eventMask, "isEnabled": $0.isEnabled]
            },
            "tapsLeftAfterStopping": tapsAfterStopping.count,
            "hint": isReceivingKeyboardEvents
                ? "keyboard and mouse events are both reaching the tap"
                : "macOS is withholding key presses from the tap, so undos go unseen. Grant Clicky Input Monitoring in System Settings > Privacy & Security, then quit and relaunch it."
        ], exitCode: isReceivingKeyboardEvents ? 0 : 3)
    }

    // MARK: Offer

    /// Runs a real offer through the real overlay and panel. There's no
    /// detection behind it, so the result is marked scripted.
    func runStuckOffer(_ options: HeadlessStuckOfferOptions) async {
        let stuckCompanion = companionManager.stuckCompanion
        let startingMultiplier = stuckCompanion.thresholdMultiplier
        let frontmostApplicationBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        var result: [String: Any] = [
            "scripted": true,
            "answer": options.answer.rawValue,
            "frontmostApplicationBefore": frontmostApplicationBefore ?? NSNull()
        ]

        if options.useLocalBrain {
            stuckCompanion.setUsesLocalBrain(true)
        }

        var frameRecorder: StuckFrameRecorder?
        if let framesDirectoryPath = options.framesDirectoryPath {
            frameRecorder = StuckFrameRecorder(
                outputDirectoryPath: framesDirectoryPath,
                companionManager: companionManager,
                backgroundImagePath: options.fixtureImagePath,
                backgroundRectInDisplayPoints: options.fixtureImageRectInDisplayPoints
            )
            frameRecorder?.start()
        }

        stuckCompanion.forgetNow()
        let scriptedEventBaseTime = ProcessInfo.processInfo.systemUptime
        for scriptedEvent in Self.scriptedBehaviourEvents() {
            stuckCompanion.ingestForScriptedRender(scriptedEvent.kind, timestampInSeconds: scriptedEventBaseTime - scriptedEvent.secondsAgo)
        }
        stuckCompanion.refreshReceiptForScriptedRender()

        // Gives the recorder an opening beat with the buddy at the pointer.
        await companionManager.showOverlayForScriptedStuckCheck()
        try? await Task.sleep(nanoseconds: 700_000_000)

        let offerStartDate = Date()
        stuckCompanion.presentOfferForScriptedCheck()

        guard await waitUntil(timeoutInSeconds: 8, { stuckCompanion.offerPhase == .asking }) else {
            frameRecorder?.stop()
            HeadlessOutput.finish(["status": "failed", "error": "the buddy never arrived at the offer"], exitCode: 1)
        }

        result["secondsFromOfferToPillAppearing"] = Date().timeIntervalSince(offerStartDate)
        try? await Task.sleep(nanoseconds: 800_000_000)

        guard let offerPanel = stuckCompanion.offerPanelForScriptedChecks else {
            frameRecorder?.stop()
            HeadlessOutput.finish(["status": "failed", "error": "no offer panel exists"], exitCode: 1)
        }

        if let framesDirectoryPath = options.framesDirectoryPath, let pillView = offerPanel.contentView,
           let pillBitmap = pillView.bitmapImageRepForCachingDisplay(in: pillView.bounds) {
            pillView.cacheDisplay(in: pillView.bounds, to: pillBitmap)
            try? pillBitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: framesDirectoryPath).appendingPathComponent("offer-pill-2x.png"))
        }

        let frontmostApplicationDuringOffer = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let focusSafety: [String: Any] = [
            "frontmostApplicationDuringOffer": frontmostApplicationDuringOffer ?? NSNull(),
            "frontmostApplicationUnchanged": frontmostApplicationDuringOffer == frontmostApplicationBefore,
            "clickyIsActiveApplication": NSApp.isActive,
            "panelIsKeyWindow": offerPanel.isKeyWindow,
            "panelCanBecomeKey": offerPanel.canBecomeKey,
            "panelCanBecomeMain": offerPanel.canBecomeMain,
            "panelIsNonActivating": offerPanel.styleMask.contains(.nonactivatingPanel),
            "panelReceivesClicks": !offerPanel.ignoresMouseEvents,
            "panelFrameAppKit": HeadlessOutput.json(offerPanel.frame)
        ]
        result["focusSafety"] = focusSafety

        let didKeepFocusSafe = frontmostApplicationDuringOffer == frontmostApplicationBefore
            && !NSApp.isActive
            && !offerPanel.isKeyWindow
            && !offerPanel.canBecomeKey

        let answerStartDate = Date()

        switch options.answer {
        case .none:
            break

        case .no:
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            stuckCompanion.declineOffer()

        case .yes:
            guard let fixtureImagePath = options.fixtureImagePath else { return }
            companionManager.stuckCaptureOverrideForScriptedCheck = {
                try MainActor.assumeIsolated {
                    let primaryDisplayFrame = NSScreen.screens.first?.frame ?? .zero
                    return [try FixtureScreenCapture.make(
                        imagePath: fixtureImagePath,
                        imageRectInDisplayPoints: options.fixtureImageRectInDisplayPoints,
                        displayFrame: primaryDisplayFrame,
                        label: "user's screen (cursor is here)",
                        screenNumber: 1,
                        isCursorScreen: true,
                        maximumScreenshotDimension: CompanionScreenCaptureUtility.maximumScreenshotDimension
                    ).screenCapture]
                }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            stuckCompanion.acceptOfferForScriptedCheck()
        }

        let answerTimeoutInSeconds: Double = options.answer == .yes ? 280 : 12
        let didFinish = await waitUntil(timeoutInSeconds: answerTimeoutInSeconds, { stuckCompanion.offerPhase == .none })

        result["secondsUntilOfferFinished"] = Date().timeIntervalSince(answerStartDate)
        result["thresholdMultiplierBefore"] = startingMultiplier
        result["thresholdMultiplierAfter"] = stuckCompanion.thresholdMultiplier
        result["screenshotsTaken"] = stuckCompanion.screenshotsTakenCount
        result["retainedItemsAfterAnswer"] = stuckCompanion.receiptLines.count
        result["clickyActivatedDuringRun"] = NSApp.isActive

        if options.answer == .yes {
            result["failureMessage"] = companionManager.lastResponseFailureMessage ?? NSNull()
            result["usage"] = companionManager.lastBrainUsage.map { HeadlessOutput.json($0) } ?? NSNull()
        }

        // Lets the buddy drift home on camera.
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        result["frameCount"] = frameRecorder?.stop() ?? 0

        let learnedCorrectly: Bool
        switch options.answer {
        case .no: learnedCorrectly = stuckCompanion.thresholdMultiplier > startingMultiplier
        case .none: learnedCorrectly = stuckCompanion.thresholdMultiplier > startingMultiplier
        case .yes: learnedCorrectly = true
        }

        let succeeded = didFinish
            && didKeepFocusSafe
            && learnedCorrectly
            && companionManager.lastResponseFailureMessage == nil
        result["status"] = succeeded ? "ok" : "failed"
        HeadlessOutput.finish(result, exitCode: succeeded ? 0 : 1)
    }

    private func waitUntil(timeoutInSeconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutInSeconds)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }

    /// A believable half minute, used only to fill the receipt in renders.
    /// Offsets are seconds before now.
    private static func scriptedBehaviourEvents() -> [(secondsAgo: Double, kind: StuckBehaviourEventKind)] {
        var events: [(secondsAgo: Double, kind: StuckBehaviourEventKind)] = []
        let objectArea = 4_003
        let nearbyArea = 5_003

        for attemptIndex in 0..<5 {
            let attemptStart = 44 - Double(attemptIndex) * 8
            events.append((attemptStart, .click(coarseAreaIdentifier: objectArea)))
            events.append((attemptStart - 0.8, .anonymousKeyPress))
            for movementIndex in 0..<30 {
                events.append((
                    attemptStart - 1 - Double(movementIndex) * 0.1,
                    .pointerMovement(distanceInPoints: 13, coarseAreaIdentifier: movementIndex % 7 == 0 ? nearbyArea : objectArea)
                ))
            }
            events.append((attemptStart - 4.2, .click(coarseAreaIdentifier: objectArea)))
            if attemptIndex > 0 {
                events.append((attemptStart - 6.4, .undo))
            }
        }
        return events.sorted { $0.secondsAgo > $1.secondsAgo }
    }

    // MARK: Receipt Render

    /// Asks the real receipt view to draw itself to a PNG.
    func runStuckReceiptRender(outputPath: String, isEmpty: Bool) async {
        let stuckCompanion = companionManager.stuckCompanion
        stuckCompanion.persistsLearning = false
        stuckCompanion.setEnabled(true)

        if !isEmpty {
            let baseTime = ProcessInfo.processInfo.systemUptime
            for scriptedEvent in Self.scriptedBehaviourEvents() {
                stuckCompanion.ingestForScriptedRender(scriptedEvent.kind, timestampInSeconds: baseTime - scriptedEvent.secondsAgo)
            }
        }
        stuckCompanion.refreshReceiptForScriptedRender()

        let receiptView = StuckReceiptView(stuckCompanion: stuckCompanion, onClose: {})
            .frame(width: 318)
        let pixelSize = await renderToPNG(receiptView, outputPath: outputPath)

        // Wipes the switch back to how a user would have left it.
        stuckCompanion.setEnabled(false)

        HeadlessOutput.finish([
            "status": "ok",
            "scripted": true,
            "outputPath": outputPath,
            "pixelSize": ["width": pixelSize.width, "height": pixelSize.height]
        ], exitCode: 0)
    }

    // MARK: Consent Render

    /// Draws the real menu bar panel with Stuck off, which is where the
    /// one-sentence consent lives.
    func runStuckConsentRender(outputPath: String) async {
        let panelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: 320)
        let pixelSize = await renderToPNG(panelView, outputPath: outputPath)

        HeadlessOutput.finish([
            "status": "ok",
            "scripted": true,
            "outputPath": outputPath,
            "pixelSize": ["width": pixelSize.width, "height": pixelSize.height]
        ], exitCode: 0)
    }

    /// Asks a view to draw itself to a PNG, hosted off screen because a
    /// windowless view can't lay out. Exits the app if it can't.
    private func renderToPNG<Content: View>(_ view: Content, outputPath: String) async -> (width: Int, height: Int) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)

        let offscreenWindow = NSWindow(
            contentRect: NSRect(x: -5_000, y: -5_000, width: hostingView.frame.width, height: hostingView.frame.height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        offscreenWindow.isOpaque = false
        offscreenWindow.backgroundColor = .clear
        offscreenWindow.contentView = hostingView
        offscreenWindow.orderBack(nil)

        try? await Task.sleep(nanoseconds: 500_000_000)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            HeadlessOutput.finish(["status": "failed", "error": "could not create a bitmap"], exitCode: 1)
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]),
              (try? pngData.write(to: URL(fileURLWithPath: outputPath))) != nil else {
            HeadlessOutput.finish(["status": "failed", "error": "could not write \(outputPath)"], exitCode: 1)
        }

        return (bitmap.pixelsWide, bitmap.pixelsHigh)
    }
}

extension CompanionManager {
    /// Shows the overlay without a drift, for the opening of a recorded run.
    func showOverlayForScriptedStuckCheck() async {
        guard !isOverlayVisible else { return }
        setOverlayVisibleForScriptedCheck()
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}

// MARK: - Frame Recorder

/// Draws the app's real views onto a background once per timer tick. It's a
/// record of what the views render, composited by this process. No pixels here
/// came from the display, and no window of any other app is involved.
@MainActor
final class StuckFrameRecorder {
    private let outputDirectoryURL: URL
    private weak var companionManager: CompanionManager?
    private let backgroundImage: CGImage?
    private let backgroundRectInDisplayPoints: CGRect?
    private var recordingTimer: Timer?
    private var frameCount = 0
    private var frameDurationLines: [String] = []
    private var lastFrameDate: Date?
    private var pendingFrameFileName: String?

    private let framesPerSecond: Double = 20

    init(
        outputDirectoryPath: String,
        companionManager: CompanionManager,
        backgroundImagePath: String?,
        backgroundRectInDisplayPoints: CGRect?
    ) {
        outputDirectoryURL = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        self.companionManager = companionManager
        self.backgroundRectInDisplayPoints = backgroundRectInDisplayPoints
        backgroundImage = backgroundImagePath
            .flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap { NSBitmapImageRep(data: $0)?.cgImage }
        try? FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
    }

    func start() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1 / framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordFrame()
            }
        }
    }

    @discardableResult
    func stop() -> Int {
        recordingTimer?.invalidate()
        recordingTimer = nil
        writeFrameDurations()
        return frameCount
    }

    private func writeFrameDurations() {
        if let pendingFrameFileName {
            frameDurationLines.append("file '\(pendingFrameFileName)'\nduration 0.05")
        }
        let concatenationList = "ffconcat version 1.0\n" + frameDurationLines.joined(separator: "\n") + "\n"
        try? concatenationList.write(
            to: outputDirectoryURL.appendingPathComponent("frames.ffconcat"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func recordFrame() {
        guard let companionManager, let displayFrame = NSScreen.screens.first?.frame else { return }

        let pixelsWide = Int(displayFrame.width)
        let pixelsHigh = Int(displayFrame.height)

        guard let canvas = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        canvas.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))

        if let backgroundImage {
            let placementRect = backgroundRectInDisplayPoints ?? CGRect(origin: .zero, size: displayFrame.size)
            canvas.interpolationQuality = .medium
            canvas.draw(backgroundImage, in: CGRect(
                x: placementRect.origin.x,
                y: displayFrame.height - placementRect.maxY,
                width: placementRect.width,
                height: placementRect.height
            ))
        }

        for (overlayView, windowFrame) in companionManager.overlayWindowManager.overlayContentViewsForScriptedChecks {
            draw(overlayView, windowFrame: windowFrame, onto: canvas)
        }

        let stuckCompanion = companionManager.stuckCompanion
        if let flashPanel = stuckCompanion.flashPanelForScriptedChecks, flashPanel.isVisible, let flashView = flashPanel.contentView {
            draw(flashView, windowFrame: flashPanel.frame, onto: canvas)
        }
        if let offerPanel = stuckCompanion.offerPanelForScriptedChecks, offerPanel.isVisible, let offerView = offerPanel.contentView {
            draw(offerView, windowFrame: offerPanel.frame, onto: canvas)
        }

        drawRealPointer(onto: canvas)

        guard let frameImage = canvas.makeImage(),
              let jpegData = NSBitmapImageRep(cgImage: frameImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
            return
        }

        let frameFileName = String(format: "frame-%05d.jpg", frameCount)
        try? jpegData.write(to: outputDirectoryURL.appendingPathComponent(frameFileName))
        frameCount += 1

        // Real elapsed time, so a slow frame doesn't speed the animation up.
        let currentDate = Date()
        if let lastFrameDate, let pendingFrameFileName {
            let frameDuration = currentDate.timeIntervalSince(lastFrameDate)
            frameDurationLines.append("file '\(pendingFrameFileName)'\nduration \(String(format: "%.4f", frameDuration))")
        }
        lastFrameDate = currentDate
        pendingFrameFileName = frameFileName
    }

    /// The system cursor isn't in any of these views, so it's drawn at the
    /// real pointer location to keep the buddy's position readable.
    private func drawRealPointer(onto canvas: CGContext) {
        let pointerLocation = NSEvent.mouseLocation
        let arrowPoints = [(0.0, 0.0), (0.0, -16.0), (4.0, -12.5), (6.8, -18.5), (9.2, -17.4), (6.4, -11.5), (11.5, -11.5)]

        let arrowPath = CGMutablePath()
        for (pointIndex, arrowPoint) in arrowPoints.enumerated() {
            let location = CGPoint(x: pointerLocation.x + arrowPoint.0, y: pointerLocation.y + arrowPoint.1)
            if pointIndex == 0 {
                arrowPath.move(to: location)
            } else {
                arrowPath.addLine(to: location)
            }
        }
        arrowPath.closeSubpath()

        canvas.addPath(arrowPath)
        canvas.setFillColor(CGColor(gray: 0, alpha: 1))
        canvas.fillPath()
        canvas.addPath(arrowPath)
        canvas.setStrokeColor(CGColor(gray: 1, alpha: 1))
        canvas.setLineWidth(1.2)
        canvas.strokePath()
    }

    private func draw(_ view: NSView, windowFrame: CGRect, onto canvas: CGContext) {
        guard let viewBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }

        view.cacheDisplay(in: view.bounds, to: viewBitmap)

        guard let viewImage = viewBitmap.cgImage else { return }
        canvas.draw(viewImage, in: windowFrame)
    }
}
