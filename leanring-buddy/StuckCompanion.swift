//
//  StuckCompanion.swift
//  leanring-buddy
//
//  Runs Stuck: it owns the tap, feeds the detector, takes a reading once a
//  second, and walks an offer through its phases. Nothing in this class can
//  capture the screen. The only route to a screenshot is acceptOffer(), which
//  is only called from the user pressing yes.
//
//  Deliberately never prints or logs an event, and holds no file handles.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class StuckCompanion: ObservableObject {
    enum WatchingStatus {
        case off
        /// macOS refused the tap outright.
        case needsPermission
        /// The tap runs but macOS withholds key presses, so undos go unseen.
        case watchingMouseOnly
        case watching
    }

    enum OfferPhase: Equatable {
        case none
        /// The buddy is wandering over. Nothing is on screen to answer yet.
        case drifting
        case asking
        case acknowledgingDecline
        /// The user said yes. One screenshot, then normal Clicky help.
        case helping
    }

    /// The consent, as one sentence, shown before Stuck can be turned on.
    static let consentSentence = "let clicky notice when you seem stuck, using only the timing of your mouse and keys, never what's on your screen, kept in memory on this mac for 2 minutes."

    static let distributedStatusRequestName = Notification.Name("clicky.stuck.statusRequest")
    static let distributedStatusReplyName = Notification.Name("clicky.stuck.statusReply")

    private static let isEnabledDefaultsKey = "isStuckCompanionEnabled"
    private static let thresholdMultiplierDefaultsKey = "stuckThresholdMultiplier"
    private static let usesLocalBrainDefaultsKey = "stuckUsesLocalBrain"
    private static let localBrainModelEnvironmentVariableName = "CLICKY_STUCK_LOCAL_BRAIN"
    private static let fallbackLocalBrainModelValue = "ollama:qwen3.6:35b-a3b"

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "app.zen-browser.zen"
    ]

    private static let offerVisibleDurationInSeconds: Double = 7
    private static let declineAcknowledgementDurationInSeconds: Double = 1.1

    @Published private(set) var isEnabled: Bool
    @Published private(set) var watchingStatus: WatchingStatus = .off
    @Published private(set) var offerPhase: OfferPhase = .none
    @Published private(set) var receiptLines: [StuckReceiptLine] = []
    @Published private(set) var currentAssessment: StuckAssessment?
    @Published private(set) var thresholdMultiplier: Double
    @Published private(set) var screenshotsTakenCount = 0
    @Published private(set) var usesLocalBrain: Bool

    // Measured, not claimed. See StuckProcessProbe.
    @Published private(set) var measuredInternetSocketCount = 0
    @Published private(set) var measuredBytesWrittenSinceEnabled: UInt64?

    /// How much the detector has processed since launch, as a bare count. Lets
    /// the proof show detection was live without exposing anything it saw.
    private(set) var processedEventCount = 0

    /// Off for scripted checks, so a test run can't change a real user's learning.
    var persistsLearning = true

    private let scoringModel = StuckScoringModel()
    private var detector: StuckDetector
    private var offerPolicy: StuckOfferPolicy
    private let eventTapMonitor = StuckEventTapMonitor()
    private let offerPanelManager = StuckOfferPanelManager()
    private let captureFlashManager = StuckCaptureFlashManager()
    private var readingTimer: Timer?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var statusRequestObserver: NSObjectProtocol?
    private var isBrowserFrontmost = false
    private var bytesWrittenWhenEnabled: UInt64?
    private var offerExpiryTask: Task<Void, Never>?
    private var offerPlacement: StuckOfferPlacement.Placement?

    private weak var companionManager: CompanionManager?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        isEnabled = UserDefaults.standard.bool(forKey: Self.isEnabledDefaultsKey)
        usesLocalBrain = UserDefaults.standard.bool(forKey: Self.usesLocalBrainDefaultsKey)

        let savedMultiplier = UserDefaults.standard.double(forKey: Self.thresholdMultiplierDefaultsKey)
        let startingMultiplier = savedMultiplier >= 1 ? savedMultiplier : 1
        detector = StuckDetector(scoringModel: scoringModel)
        offerPolicy = StuckOfferPolicy(scoringModel: scoringModel, thresholdMultiplier: startingMultiplier)
        thresholdMultiplier = offerPolicy.thresholdMultiplier

        eventTapMonitor.onBehaviourEvent = { [weak self] behaviourEventKind, timestampInSeconds in
            MainActor.assumeIsolated {
                self?.receive(behaviourEventKind, timestampInSeconds: timestampInSeconds)
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        installStatusRequestObserver()
        if isEnabled {
            startWatching()
        }
    }

    func stop() {
        stopWatching()
        if let statusRequestObserver {
            DistributedNotificationCenter.default().removeObserver(statusRequestObserver)
            self.statusRequestObserver = nil
        }
    }

    /// Turning it off stops the tap and drops everything immediately.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.isEnabledDefaultsKey)
        if enabled {
            startWatching()
        } else {
            stopWatching()
        }
    }

    func setUsesLocalBrain(_ shouldUseLocalBrain: Bool) {
        usesLocalBrain = shouldUseLocalBrain
        UserDefaults.standard.set(shouldUseLocalBrain, forKey: Self.usesLocalBrainDefaultsKey)
    }

    private func startWatching() {
        bytesWrittenWhenEnabled = StuckProcessProbe.logicalBytesWrittenSinceLaunch()
        refreshTapStatus()
        installWorkspaceObserver()

        readingTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.takeReading()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        readingTimer = timer
        takeReading()
    }

    private func stopWatching() {
        readingTimer?.invalidate()
        readingTimer = nil
        eventTapMonitor.stop()
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
        cancelOfferSilently()
        forgetNow()
        watchingStatus = .off
    }

    private func installWorkspaceObserver() {
        guard workspaceActivationObserver == nil else { return }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // The bundle ID is compared here and dropped. Only "was it a
            // browser" survives this closure, never which app it was.
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isActivatedAppBrowser = activatedApplication?.bundleIdentifier.map(Self.browserBundleIdentifiers.contains) ?? false
            let isActivatedAppClicky = activatedApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            MainActor.assumeIsolated {
                self?.frontmostApplicationChanged(isBrowser: isActivatedAppBrowser, isClicky: isActivatedAppClicky)
            }
        }
    }

    private func frontmostApplicationChanged(isBrowser: Bool, isClicky: Bool) {
        guard !isClicky, isBrowser != isBrowserFrontmost else { return }
        isBrowserFrontmost = isBrowser
        receive(isBrowser ? .leftForBrowser : .returnedFromBrowser, timestampInSeconds: ProcessInfo.processInfo.systemUptime)
    }

    private func receive(_ behaviourEventKind: StuckBehaviourEventKind, timestampInSeconds: Double) {
        processedEventCount += 1
        detector.ingest(StuckBehaviourEvent(timestampInSeconds: timestampInSeconds, kind: behaviourEventKind))
    }

    // MARK: - Readings

    /// Runs once a second. Everything downstream of the detector, including
    /// the receipt, is rebuilt from what's still in memory.
    private func takeReading() {
        let currentTime = ProcessInfo.processInfo.systemUptime

        if isEnabled {
            refreshTapStatus()
        }

        detector.wipeExpiredMemory(atTime: currentTime)

        let assessment = detector.assess(atTime: currentTime)
        currentAssessment = assessment
        receiptLines = detector.receiptLines(atTime: currentTime)
        refreshProcessMeasurements()

        guard offerPhase == .none, let companionManager else { return }

        let isCompanionBusy = companionManager.voiceState != .idle
            || companionManager.isSpeakingForScriptedCheck
            || companionManager.buddyDictationManager.isDictationInProgress

        if offerPolicy.shouldOffer(for: assessment, atTime: currentTime, isCompanionBusy: isCompanionBusy) {
            beginOffer()
        }
    }

    /// macOS doesn't upgrade an existing tap when a permission arrives, so a
    /// mouse-only tap is rebuilt as soon as keyboard access might be there.
    private func refreshTapStatus() {
        let hasKeyboardPermission = CGPreflightListenEventAccess() || AXIsProcessTrusted()

        if eventTapMonitor.isRunning && !eventTapMonitor.isReceivingKeyboardEvents && hasKeyboardPermission {
            eventTapMonitor.stop()
        }

        guard eventTapMonitor.start() else {
            watchingStatus = .needsPermission
            return
        }
        watchingStatus = eventTapMonitor.isReceivingKeyboardEvents ? .watching : .watchingMouseOnly
    }

    private func refreshProcessMeasurements() {
        measuredInternetSocketCount = StuckProcessProbe.openSocketCount().internetSockets
        if let bytesWrittenWhenEnabled, let currentBytesWritten = StuckProcessProbe.logicalBytesWrittenSinceLaunch() {
            measuredBytesWrittenSinceEnabled = currentBytesWritten - bytesWrittenWhenEnabled
        }
    }

    /// What the threshold is right now, including what declining has done to it.
    var effectiveOfferThreshold: Double {
        offerPolicy.effectiveThreshold
    }

    func forgetNow() {
        detector.forgetEverything()
        receiptLines = []
        currentAssessment = nil
    }

    func resetLearning() {
        offerPolicy.resetLearning()
        saveThresholdMultiplier()
    }

    private func saveThresholdMultiplier() {
        thresholdMultiplier = offerPolicy.thresholdMultiplier
        if persistsLearning {
            UserDefaults.standard.set(thresholdMultiplier, forKey: Self.thresholdMultiplierDefaultsKey)
        }
    }

    // MARK: - The Offer

    private var screenshotDestinationName: String {
        makeHelpBrain()?.screenshotDestinationName ?? "the model provider"
    }

    private func makeHelpBrain() -> (any Brain)? {
        guard let companionManager else { return nil }
        return BrainConfiguration.makeBrain(modelValue: usesLocalBrain ? localBrainModelValue : companionManager.selectedModel)
    }

    var localBrainModelValue: String {
        if let environmentValue = ProcessInfo.processInfo.environment[Self.localBrainModelEnvironmentVariableName],
           !environmentValue.isEmpty {
            return environmentValue
        }
        return AppBundleConfiguration.stringValue(forKey: "StuckLocalBrainModel") ?? Self.fallbackLocalBrainModelValue
    }

    private func beginOffer() {
        guard let companionManager else { return }

        let pointerLocation = NSEvent.mouseLocation
        let displayFrame = NSScreen.screens.first { $0.frame.contains(pointerLocation) }?.frame
            ?? NSScreen.main?.frame
            ?? .zero

        let placement = StuckOfferPlacement.makePlacement(
            pointerLocation: pointerLocation,
            displayFrame: displayFrame,
            pillSize: StuckOfferPanelManager.pillPanelSize
        )
        offerPlacement = placement
        offerPhase = .drifting

        companionManager.presentBuddyForStuckOffer(
            StuckBuddyDriftTarget(restingLocation: placement.buddyLocation, displayFrame: displayFrame)
        ) { [weak self] in
            self?.buddyArrivedAtOffer()
        }
    }

    /// The pill only appears once the buddy has settled, so the first thing
    /// noticed is something arriving, not a popup.
    private func buddyArrivedAtOffer() {
        guard offerPhase == .drifting, let offerPlacement else { return }
        offerPhase = .asking

        offerPanelManager.showOffer(
            pillOrigin: offerPlacement.pillOrigin,
            growsFromLeadingEdge: offerPlacement.pillOrigin.x > offerPlacement.buddyLocation.x,
            screenshotDestinationName: screenshotDestinationName,
            onAccept: { [weak self] in self?.acceptOffer() },
            onDecline: { [weak self] in self?.declineOffer() }
        )

        startOfferExpiryCountdown()
    }

    /// Counts down in small steps so hovering can pause it: reaching for the
    /// pill must never race its disappearance.
    private func startOfferExpiryCountdown() {
        offerExpiryTask?.cancel()
        offerExpiryTask = Task { [weak self] in
            var remainingSeconds = Self.offerVisibleDurationInSeconds
            let stepInSeconds = 0.05

            while remainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(stepInSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if !self.offerPanelManager.isPointerOverOffer {
                    remainingSeconds -= stepInSeconds
                }
                self.offerPanelManager.setRemainingFraction(remainingSeconds / Self.offerVisibleDurationInSeconds)
            }

            guard let self else { return }
            self.offerExpired()
        }
    }

    private func offerExpired() {
        guard offerPhase == .asking else { return }
        offerPolicy.recordIgnored()
        saveThresholdMultiplier()
        finishOffer()
    }

    func declineOffer() {
        guard offerPhase == .asking else { return }
        offerExpiryTask?.cancel()
        offerPhase = .acknowledgingDecline

        offerPolicy.recordDeclined(atTime: ProcessInfo.processInfo.systemUptime)
        saveThresholdMultiplier()

        companionManager?.nodBuddyAfterStuckDecline()
        offerPanelManager.showDeclineAcknowledgement()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.declineAcknowledgementDurationInSeconds * 1_000_000_000))
            guard let self, self.offerPhase == .acknowledgingDecline else { return }
            self.finishOffer()
        }
    }

    /// The one and only path from Stuck to a screenshot.
    func acceptOffer() {
        guard offerPhase == .asking, let companionManager, let helpBrain = makeHelpBrain() else { return }
        offerExpiryTask?.cancel()
        offerPhase = .helping

        offerPolicy.recordAccepted()
        saveThresholdMultiplier()

        let receiptLinesAtYes = receiptLines.map(\.text)
        // Its job is done, so it doesn't sit around for the full 2 minutes.
        forgetNow()

        offerPanelManager.hideOffer()

        let targetScreen = NSScreen.screens.first { $0.frame == offerPlacement?.displayFrame } ?? NSScreen.main

        companionManager.runStuckHelp(
            receiptLinesAtYes: receiptLinesAtYes,
            brain: helpBrain,
            onCaptureStarting: { [weak self] in
                guard let self, let targetScreen else { return }
                self.captureFlashManager.showFlash(
                    on: targetScreen,
                    screenshotDestinationName: helpBrain.screenshotDestinationName
                )
            },
            onScreenshotTaken: { [weak self] in
                self?.screenshotsTakenCount += 1
            },
            onFinished: { [weak self] in
                self?.finishOffer()
            }
        )
    }

    private func finishOffer() {
        offerExpiryTask?.cancel()
        offerPanelManager.hideOffer()
        offerPlacement = nil
        offerPhase = .none
        companionManager?.releaseBuddyAfterStuckOffer()
    }

    private func cancelOfferSilently() {
        guard offerPhase != .none else { return }
        finishOffer()
    }

    /// Holding the hotkey during an offer is a clear intent to talk. It isn't
    /// a no, so it doesn't count against the offer.
    func dismissOfferForPushToTalk() {
        guard offerPhase == .drifting || offerPhase == .asking else { return }
        finishOffer()
    }

    // MARK: - Status For The Proof

    /// Lets scripts/prove-privacy.sh confirm detection was really running. The
    /// reply is counts only, and goes over Mach IPC rather than a socket or a
    /// file, so asking doesn't disturb what's being measured.
    private func installStatusRequestObserver() {
        statusRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.distributedStatusRequestName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.replyWithStatus()
            }
        }
    }

    private func replyWithStatus() {
        let systemTaps = SystemEventTapReport.tapsOwnedByThisProcess()
        let stuckTaps = systemTaps.filter(\.isStuckTap)

        let status: [String: Any] = [
            "processIdentifier": Int(getpid()),
            "isEnabled": isEnabled,
            "isWatching": watchingStatus == .watching || watchingStatus == .watchingMouseOnly,
            "isReceivingKeyboardEvents": watchingStatus == .watching,
            "processedEventCount": processedEventCount,
            "retainedItemCount": detector.retainedItemCount,
            "screenshotsTakenCount": screenshotsTakenCount,
            "stuckTapCount": stuckTaps.count,
            "stuckTapIsListenOnly": stuckTaps.allSatisfy(\.isListenOnly)
        ]

        DistributedNotificationCenter.default().postNotificationName(
            Self.distributedStatusReplyName,
            object: nil,
            userInfo: status,
            deliverImmediately: true
        )
    }

    // MARK: - Scripted Checks

    /// Runs a real offer with no detection behind it. Only `--headless-stuck-offer`
    /// calls this, and that command exits the app when it's done, so it can't
    /// be part of the demo path. Results it produces are always marked scripted.
    func presentOfferForScriptedCheck() {
        persistsLearning = false
        beginOffer()
    }

    /// Fills the receipt's memory for a scripted render. The same restriction
    /// as above applies.
    func ingestForScriptedRender(_ behaviourEventKind: StuckBehaviourEventKind, timestampInSeconds: Double) {
        receive(behaviourEventKind, timestampInSeconds: timestampInSeconds)
    }

    func refreshReceiptForScriptedRender() {
        let currentTime = ProcessInfo.processInfo.systemUptime
        currentAssessment = detector.assess(atTime: currentTime)
        receiptLines = detector.receiptLines(atTime: currentTime)
        refreshProcessMeasurements()
    }

    var offerPanelForScriptedChecks: NSPanel? {
        offerPanelManager.panel
    }

    var offerPanelHostingViewForScriptedChecks: NSView? {
        offerPanelManager.panel?.contentView
    }

    var flashPanelForScriptedChecks: NSPanel? {
        captureFlashManager.panel
    }

    func acceptOfferForScriptedCheck() {
        acceptOffer()
    }
}

// MARK: - Help Prompt

enum StuckHelpPrompt {
    /// Kept in conversation history instead of the real prompt, so the
    /// behaviour summary can't outlive the 2 minutes in memory.
    static let conversationHistoryLabel = "(i said yes when you offered to help)"

    static func makeUserPrompt(receiptLines: [String]) -> String {
        let behaviourSummary = receiptLines.isEmpty
            ? "no details."
            : receiptLines.joined(separator: ", ")

        return """
        i didn't ask a question. you noticed i seemed stuck and offered to help, and i said yes. here's what you saw of my behaviour in the last two minutes, which is only timing and counts: \(behaviourSummary).

        look at my screen and work out what i'm most likely trying to do. if the screen shows a goal, a reference or instructions, compare them with what i've got and notice what's different. then say what's going wrong in one short sentence and give me the single next step. point at the exact thing i should click or look at. don't mention the counts or that you were watching.
        """
    }
}
