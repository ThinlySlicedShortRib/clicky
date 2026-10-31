//
//  StuckDetector.swift
//  leanring-buddy
//
//  The on-device "are you stuck?" model. It sees timing and counts only: an
//  event here has no text, no key identity, no window title and no pixels, and
//  a pointer position is only ever a 160pt tile. Everything it holds lives in
//  these arrays and is dropped 2 minutes after it happened.
//
//  The file is pure Foundation on purpose. stuck-harness/ compiles this exact
//  source against synthetic traces that are not part of the app target, so the
//  numbers it reports are about this code, and no trace can reach the app.
//
//  The score is a plain sum of named lines, shown on the receipt, so anyone can
//  read why an offer fired. See docs/STUCK.md for the table.
//

import Foundation

// MARK: - Events

/// One thing the user did, reduced to its category. Deliberately has no String
/// and no key code: what isn't stored can't leak.
enum StuckBehaviourEventKind: Equatable {
    case undo
    case redo
    case cancel
    case modeToggle
    /// Any other key. Which key is never kept.
    case anonymousKeyPress
    case click(coarseAreaIdentifier: Int)
    case dragFinished
    case scrollTick
    case pointerMovement(distanceInPoints: Double, coarseAreaIdentifier: Int)
    case leftForBrowser
    case returnedFromBrowser
}

struct StuckBehaviourEvent: Equatable {
    /// Seconds on a monotonic clock. Never a wall-clock time.
    let timestampInSeconds: Double
    let kind: StuckBehaviourEventKind
}

// MARK: - Scoring Model

/// Every tunable number in one place. Values are hand-set and tuned only on the
/// harness's training seeds; docs/STUCK.md explains each one.
struct StuckScoringModel {
    var baseOfferThreshold: Double = 100
    /// Two kinds of evidence must agree, so one habit alone can't fire.
    var minimumDistinctSignalsToOffer = 2

    var memoryRetentionInSeconds: Double = 120

    // Undo loop. An "episode" is an undo that follows a real attempt, so holding
    // undo to rewind, or tapping it quickly, counts once.
    var undoWindowInSeconds: Double = 60
    var undoMinimumEpisodeSpacingInSeconds: Double = 2.5
    /// A loop is continuous. Two undos with real work between them aren't one.
    var undoMaximumGapInLoopInSeconds: Double = 18
    var undoPointsPerEpisode: Double = 22
    var undoPointsCap: Double = 66

    var cancelWindowInSeconds: Double = 45
    var cancelMinimumEpisodeSpacingInSeconds: Double = 1.5
    var cancelPointsPerEpisode: Double = 18
    var cancelPointsCap: Double = 72

    var modeToggleWindowInSeconds: Double = 30
    var modeTogglesIgnored = 2
    var modeTogglePointsPerToggle: Double = 12
    var modeTogglePointsCap: Double = 48

    /// Coming back to a spot covers both menus opened over and over without
    /// choosing, and flipping the same control. The tap can't see menus inside
    /// apps like Blender, but it can see the same tile being clicked again.
    var revisitWindowInSeconds: Double = 45
    var revisitsIgnored = 1
    var revisitPointsPerReturn: Double = 14
    var revisitPointsCap: Double = 72

    var restlessWindowInSeconds: Double = 30
    var restlessMinimumDistancePerSecondInPoints: Double = 60
    var restlessMinimumSeconds = 5
    var restlessMaximumDistinctAreas = 6
    var restlessPointsPerSecond: Double = 2.5
    var restlessPointsCap: Double = 30

    var stillnessMinimumInSeconds: Double = 8
    /// Past this it reads as walking away, not as being stuck.
    var stillnessMaximumInSeconds: Double = 40
    var stillnessPrecedingWindowInSeconds: Double = 30
    var stillnessMinimumPrecedingActions = 6
    var stillnessBasePoints: Double = 15
    var stillnessPointsPerExtraSecond: Double = 1.25
    var stillnessPointsCap: Double = 30

    /// A quick look-up. A long stay in the browser is reading, not bouncing.
    var browserBounceMaximumAwayInSeconds: Double = 60
    var browserBouncePointsPerTrip: Double = 18
    var browserBouncePointsCap: Double = 36

    // Signs of flow, which pull the score down.
    var flowWindowInSeconds: Double = 30
    var typingKeysIgnored = 12
    var typingPenaltyPerKey: Double = 1.5
    var typingPenaltyCap: Double = 80
    var freshAreasIgnored = 4
    var freshAreaPenaltyPerArea: Double = 8
    var freshAreaPenaltyCap: Double = 40
    var dragsIgnored = 3
    var dragPenaltyPerDrag: Double = 6
    var dragPenaltyCap: Double = 36
    var scrollTicksForReadingPenalty = 20
    var readingPenalty: Double = 12
    var redoPenaltyPerRedo: Double = 15
    var redoPenaltyCap: Double = 30

    /// Never interrupts mid-action.
    var handsQuietMinimumInSeconds: Double = 1.2
    /// Readings are taken once a second. The case must hold on this many in a
    /// row, and then the offer waits for quiet hands.
    var consecutiveReadingsRequiredToOffer = 2

    var cooldownAfterOfferInSeconds: Double = 120
    var cooldownAfterDeclineInSeconds: Double = 300

    // Learning. A decline multiplies the threshold, so four declines put it
    // above the highest score the signals can add up to and offers stop.
    var thresholdMultiplierAfterDecline: Double = 1.4
    var thresholdMultiplierAfterIgnoring: Double = 1.12
    var thresholdDividerAfterAccepting: Double = 1.2
    var maximumThresholdMultiplier: Double = 4
}

// MARK: - Assessment

enum StuckSignalKind: String, CaseIterable {
    case undoLoop = "undo loop"
    case cancelLoop = "cancel loop"
    case modeFlipping = "flipping back and forth"
    case revisitingSpot = "returning to one spot"
    case restlessCursor = "restless cursor"
    case stillness = "stillness after activity"
    case browserBounce = "browser and back"

    /// Reading a page, thinking and looking things up all look like these, so
    /// on their own they never justify an offer.
    var isStrongEvidence: Bool {
        switch self {
        case .undoLoop, .cancelLoop, .modeFlipping, .revisitingSpot:
            return true
        case .restlessCursor, .stillness, .browserBounce:
            return false
        }
    }
}

struct StuckSignalReading: Equatable {
    let kind: StuckSignalKind
    let points: Double
    /// Plain English shown on the receipt, for example "4 undos in 30s".
    let humanReadableDescription: String
}

struct StuckFlowPenaltyReading: Equatable {
    let points: Double
    let humanReadableDescription: String
}

struct StuckAssessment: Equatable {
    let signals: [StuckSignalReading]
    let flowPenalties: [StuckFlowPenaltyReading]
    let score: Double
    let hasEnoughDistinctSignals: Bool
    let hasStrongEvidence: Bool
    let hasQuietHands: Bool
}

/// One line of the receipt. `secondsUntilWiped` belongs to the oldest thing the
/// line describes.
struct StuckReceiptLine: Equatable {
    let text: String
    let secondsUntilWiped: Double
    let itemCount: Int
}

// MARK: - Detector

/// Holds the last 2 minutes of behaviour and scores it. All times are passed
/// in, so a replay and the live app run the same code.
struct StuckDetector {
    let scoringModel: StuckScoringModel

    /// Everything except pointer movement, oldest first.
    private var retainedEvents: [StuckBehaviourEvent] = []
    /// Pointer movement is summed per whole second rather than kept as a path.
    private var retainedPointerSeconds: [PointerSecond] = []

    private struct PointerSecond {
        let wholeSecond: Int
        var distanceInPoints: Double
        var coarseAreaIdentifiers: Set<Int>
    }

    init(scoringModel: StuckScoringModel = StuckScoringModel()) {
        self.scoringModel = scoringModel
    }

    // MARK: Input

    mutating func ingest(_ event: StuckBehaviourEvent) {
        if case .pointerMovement(let distanceInPoints, let coarseAreaIdentifier) = event.kind {
            let wholeSecond = Int(event.timestampInSeconds)
            if let lastIndex = retainedPointerSeconds.indices.last,
               retainedPointerSeconds[lastIndex].wholeSecond == wholeSecond {
                retainedPointerSeconds[lastIndex].distanceInPoints += distanceInPoints
                retainedPointerSeconds[lastIndex].coarseAreaIdentifiers.insert(coarseAreaIdentifier)
            } else {
                retainedPointerSeconds.append(PointerSecond(
                    wholeSecond: wholeSecond,
                    distanceInPoints: distanceInPoints,
                    coarseAreaIdentifiers: [coarseAreaIdentifier]
                ))
            }
        } else {
            retainedEvents.append(event)
        }
    }

    /// Drops everything older than the retention window. The whole 2 minute
    /// promise rests on this running on every reading, which StuckOfferPolicy
    /// and the live monitor both do.
    mutating func wipeExpiredMemory(atTime currentTime: Double) {
        let oldestTimeKept = currentTime - scoringModel.memoryRetentionInSeconds
        retainedEvents.removeAll { $0.timestampInSeconds < oldestTimeKept }
        retainedPointerSeconds.removeAll { Double($0.wholeSecond) < oldestTimeKept }
    }

    mutating func forgetEverything() {
        retainedEvents.removeAll()
        retainedPointerSeconds.removeAll()
    }

    /// How many facts are in memory. Exposed so tests and the proof script can
    /// check wiping without being able to read the facts themselves.
    var retainedItemCount: Int {
        retainedEvents.count + retainedPointerSeconds.count
    }

    var oldestRetainedTimestamp: Double? {
        [retainedEvents.first?.timestampInSeconds, retainedPointerSeconds.first.map { Double($0.wholeSecond) }]
            .compactMap { $0 }
            .min()
    }

    // MARK: Scoring

    func assess(atTime currentTime: Double) -> StuckAssessment {
        let readings = [
            readUndoLoop(atTime: currentTime),
            readCancelLoop(atTime: currentTime),
            readModeFlipping(atTime: currentTime),
            readRevisitingSpot(atTime: currentTime),
            readRestlessCursor(atTime: currentTime),
            readStillness(atTime: currentTime),
            readBrowserBounce(atTime: currentTime)
        ].compactMap { $0 }

        let flowPenalties = readFlowPenalties(atTime: currentTime)

        let signalPoints = readings.reduce(0) { $0 + $1.points }
        let penaltyPoints = flowPenalties.reduce(0) { $0 + $1.points }

        let lastKeyOrClickTime = retainedEvents.last { Self.isKeyOrClick($0.kind) }?.timestampInSeconds
        let hasQuietHands = lastKeyOrClickTime.map {
            currentTime - $0 >= scoringModel.handsQuietMinimumInSeconds
        } ?? true

        return StuckAssessment(
            signals: readings,
            flowPenalties: flowPenalties,
            score: max(0, signalPoints - penaltyPoints),
            hasEnoughDistinctSignals: readings.count >= scoringModel.minimumDistinctSignalsToOffer,
            hasStrongEvidence: readings.contains { $0.kind.isStrongEvidence },
            hasQuietHands: hasQuietHands
        )
    }

    private func events(
        matching isMatch: (StuckBehaviourEventKind) -> Bool,
        withinSeconds windowInSeconds: Double,
        ofTime currentTime: Double
    ) -> [StuckBehaviourEvent] {
        retainedEvents.filter {
            $0.timestampInSeconds >= currentTime - windowInSeconds
                && $0.timestampInSeconds <= currentTime
                && isMatch($0.kind)
        }
    }

    private static func isKeyOrClick(_ kind: StuckBehaviourEventKind) -> Bool {
        switch kind {
        case .undo, .redo, .cancel, .modeToggle, .anonymousKeyPress, .click, .dragFinished:
            return true
        case .scrollTick, .pointerMovement, .leftForBrowser, .returnedFromBrowser:
            return false
        }
    }

    /// True if the user did something other than undo between two moments.
    private func userAttemptedSomething(from startTime: Double, to endTime: Double) -> Bool {
        let didKeyOrClick = retainedEvents.contains { event in
            guard event.timestampInSeconds > startTime, event.timestampInSeconds < endTime else { return false }
            switch event.kind {
            case .anonymousKeyPress, .click, .dragFinished, .modeToggle:
                return true
            default:
                return false
            }
        }
        if didKeyOrClick {
            return true
        }
        return retainedPointerSeconds.contains {
            Double($0.wholeSecond) > startTime
                && Double($0.wholeSecond) < endTime
                && $0.distanceInPoints >= scoringModel.restlessMinimumDistancePerSecondInPoints
        }
    }

    private func readUndoLoop(atTime currentTime: Double) -> StuckSignalReading? {
        let undoEvents = events(
            matching: { $0 == .undo },
            withinSeconds: scoringModel.undoWindowInSeconds,
            ofTime: currentTime
        )
        guard let firstUndo = undoEvents.first, let lastUndo = undoEvents.last else { return nil }

        // Walks forward keeping the length of the current unbroken loop, so a
        // long gap starts a new loop instead of adding to the old one.
        var longestLoopEpisodeCount = 1
        var currentLoopEpisodeCount = 1
        var lastEpisodeTime = firstUndo.timestampInSeconds
        for undoEvent in undoEvents.dropFirst() {
            let secondsSinceLastEpisode = undoEvent.timestampInSeconds - lastEpisodeTime
            // Time in a browser doesn't break a loop: looking something up
            // between attempts is part of being stuck, not a sign of progress.
            let secondsOutsideBrowser = secondsSinceLastEpisode - secondsInBrowser(from: lastEpisodeTime, to: undoEvent.timestampInSeconds)
            if secondsOutsideBrowser > scoringModel.undoMaximumGapInLoopInSeconds {
                currentLoopEpisodeCount = 1
                lastEpisodeTime = undoEvent.timestampInSeconds
            } else if secondsSinceLastEpisode >= scoringModel.undoMinimumEpisodeSpacingInSeconds,
                      userAttemptedSomething(from: lastEpisodeTime, to: undoEvent.timestampInSeconds) {
                currentLoopEpisodeCount += 1
                lastEpisodeTime = undoEvent.timestampInSeconds
            }
            longestLoopEpisodeCount = max(longestLoopEpisodeCount, currentLoopEpisodeCount)
        }

        let points = min(scoringModel.undoPointsCap, Double(longestLoopEpisodeCount - 1) * scoringModel.undoPointsPerEpisode)
        guard points > 0 else { return nil }

        let spanInSeconds = Int((lastUndo.timestampInSeconds - firstUndo.timestampInSeconds).rounded())
        return StuckSignalReading(
            kind: .undoLoop,
            points: points,
            humanReadableDescription: "\(undoEvents.count) undos in \(spanInSeconds)s"
        )
    }

    private func secondsInBrowser(from startTime: Double, to endTime: Double) -> Double {
        var totalSeconds: Double = 0
        var browserLeftTime: Double?
        for event in retainedEvents {
            if event.kind == .leftForBrowser {
                browserLeftTime = event.timestampInSeconds
            } else if event.kind == .returnedFromBrowser, let leftTime = browserLeftTime {
                let overlapStart = max(leftTime, startTime)
                let overlapEnd = min(event.timestampInSeconds, endTime)
                totalSeconds += max(0, overlapEnd - overlapStart)
                browserLeftTime = nil
            }
        }
        return totalSeconds
    }

    private func readCancelLoop(atTime currentTime: Double) -> StuckSignalReading? {
        let cancelEvents = events(
            matching: { $0 == .cancel },
            withinSeconds: scoringModel.cancelWindowInSeconds,
            ofTime: currentTime
        )
        guard let firstCancel = cancelEvents.first, let lastCancel = cancelEvents.last else { return nil }

        var episodeCount = 1
        var lastEpisodeTime = firstCancel.timestampInSeconds
        for cancelEvent in cancelEvents.dropFirst()
        where cancelEvent.timestampInSeconds - lastEpisodeTime >= scoringModel.cancelMinimumEpisodeSpacingInSeconds {
            episodeCount += 1
            lastEpisodeTime = cancelEvent.timestampInSeconds
        }

        let points = min(scoringModel.cancelPointsCap, Double(episodeCount - 1) * scoringModel.cancelPointsPerEpisode)
        guard points > 0 else { return nil }

        let spanInSeconds = Int((lastCancel.timestampInSeconds - firstCancel.timestampInSeconds).rounded())
        return StuckSignalReading(
            kind: .cancelLoop,
            points: points,
            humanReadableDescription: "\(cancelEvents.count) cancels in \(spanInSeconds)s"
        )
    }

    private func readModeFlipping(atTime currentTime: Double) -> StuckSignalReading? {
        let toggleCount = events(
            matching: { $0 == .modeToggle },
            withinSeconds: scoringModel.modeToggleWindowInSeconds,
            ofTime: currentTime
        ).count

        let countedToggles = toggleCount - scoringModel.modeTogglesIgnored
        guard countedToggles > 0 else { return nil }

        return StuckSignalReading(
            kind: .modeFlipping,
            points: min(scoringModel.modeTogglePointsCap, Double(countedToggles) * scoringModel.modeTogglePointsPerToggle),
            humanReadableDescription: "flipped back and forth \(toggleCount) times"
        )
    }

    private func readRevisitingSpot(atTime currentTime: Double) -> StuckSignalReading? {
        let clickEvents = events(
            matching: { if case .click = $0 { return true } else { return false } },
            withinSeconds: scoringModel.revisitWindowInSeconds,
            ofTime: currentTime
        )

        // Counted per tile, because "the same spot" has to be one spot. Clicks
        // that merely land on any earlier tile are normal work.
        var returnCountByArea: [Int: Int] = [:]
        var previousClick: (time: Double, area: Int)?
        var visitedAreas = Set<Int>()

        for clickEvent in clickEvents {
            guard case .click(let coarseAreaIdentifier) = clickEvent.kind else { continue }

            if let previousClick {
                let cameBackFromAnotherClick = previousClick.area != coarseAreaIdentifier
                    && visitedAreas.contains(coarseAreaIdentifier)
                let leftAndCameBackWithoutClicking = previousClick.area == coarseAreaIdentifier
                    && pointerLeftArea(
                        coarseAreaIdentifier,
                        from: previousClick.time,
                        to: clickEvent.timestampInSeconds
                    )
                if cameBackFromAnotherClick || leftAndCameBackWithoutClicking {
                    returnCountByArea[coarseAreaIdentifier, default: 0] += 1
                }
            }

            visitedAreas.insert(coarseAreaIdentifier)
            previousClick = (clickEvent.timestampInSeconds, coarseAreaIdentifier)
        }

        let returnCount = returnCountByArea.values.max() ?? 0
        let countedReturns = returnCount - scoringModel.revisitsIgnored
        guard countedReturns > 0 else { return nil }

        return StuckSignalReading(
            kind: .revisitingSpot,
            points: min(scoringModel.revisitPointsCap, Double(countedReturns) * scoringModel.revisitPointsPerReturn),
            humanReadableDescription: "came back to the same spot \(returnCount) times"
        )
    }

    private func pointerLeftArea(_ coarseAreaIdentifier: Int, from startTime: Double, to endTime: Double) -> Bool {
        retainedPointerSeconds.contains { pointerSecond in
            Double(pointerSecond.wholeSecond) >= startTime
                && Double(pointerSecond.wholeSecond) <= endTime
                && pointerSecond.coarseAreaIdentifiers.contains { $0 != coarseAreaIdentifier }
        }
    }

    private func readRestlessCursor(atTime currentTime: Double) -> StuckSignalReading? {
        let oldestSecond = Int(currentTime - scoringModel.restlessWindowInSeconds)
        let recentPointerSeconds = retainedPointerSeconds.filter { $0.wholeSecond >= oldestSecond }

        // Seconds when the mouse moved but nothing was clicked or pressed.
        let secondsWithKeyOrClick = Set(retainedEvents
            .filter { Self.isKeyOrClick($0.kind) }
            .map { Int($0.timestampInSeconds) })
        let restlessSeconds = recentPointerSeconds.filter {
            $0.distanceInPoints >= scoringModel.restlessMinimumDistancePerSecondInPoints
                && !secondsWithKeyOrClick.contains($0.wholeSecond)
        }

        guard restlessSeconds.count >= scoringModel.restlessMinimumSeconds else { return nil }

        let distinctAreas = restlessSeconds.reduce(into: Set<Int>()) { $0.formUnion($1.coarseAreaIdentifiers) }
        guard distinctAreas.count <= scoringModel.restlessMaximumDistinctAreas else { return nil }

        return StuckSignalReading(
            kind: .restlessCursor,
            points: min(scoringModel.restlessPointsCap, Double(restlessSeconds.count) * scoringModel.restlessPointsPerSecond),
            humanReadableDescription: "cursor circling the same area for \(restlessSeconds.count)s"
        )
    }

    private func readStillness(atTime currentTime: Double) -> StuckSignalReading? {
        let lastEventTime = retainedEvents.last { $0.kind != .leftForBrowser && $0.kind != .returnedFromBrowser }?.timestampInSeconds
        let lastPointerTime = retainedPointerSeconds.last.map { Double($0.wholeSecond) + 1 }
        guard let lastActivityTime = [lastEventTime, lastPointerTime].compactMap({ $0 }).max() else { return nil }

        let stillnessInSeconds = currentTime - lastActivityTime
        guard stillnessInSeconds >= scoringModel.stillnessMinimumInSeconds,
              stillnessInSeconds <= scoringModel.stillnessMaximumInSeconds else {
            return nil
        }

        let windowStart = lastActivityTime - scoringModel.stillnessPrecedingWindowInSeconds
        let precedingActions = retainedEvents.filter {
            $0.timestampInSeconds >= windowStart
                && $0.timestampInSeconds <= lastActivityTime
                && Self.isKeyOrClick($0.kind)
        }.count
        guard precedingActions >= scoringModel.stillnessMinimumPrecedingActions else { return nil }

        let extraSeconds = stillnessInSeconds - scoringModel.stillnessMinimumInSeconds
        let points = min(
            scoringModel.stillnessPointsCap,
            scoringModel.stillnessBasePoints + extraSeconds * scoringModel.stillnessPointsPerExtraSecond
        )
        return StuckSignalReading(
            kind: .stillness,
            points: points,
            humanReadableDescription: "\(Int(stillnessInSeconds))s of stillness after a busy stretch"
        )
    }

    private func completedBrowserTripCount() -> Int {
        var completedTrips = 0
        var browserLeftTime: Double?

        for event in retainedEvents {
            switch event.kind {
            case .leftForBrowser:
                browserLeftTime = event.timestampInSeconds
            case .returnedFromBrowser:
                if let leftTime = browserLeftTime,
                   event.timestampInSeconds - leftTime <= scoringModel.browserBounceMaximumAwayInSeconds {
                    completedTrips += 1
                }
                browserLeftTime = nil
            default:
                break
            }
        }
        return completedTrips
    }

    private func readBrowserBounce(atTime currentTime: Double) -> StuckSignalReading? {
        let tripCount = completedBrowserTripCount()
        guard tripCount > 0 else { return nil }

        return StuckSignalReading(
            kind: .browserBounce,
            points: min(scoringModel.browserBouncePointsCap, Double(tripCount) * scoringModel.browserBouncePointsPerTrip),
            humanReadableDescription: "went to a browser and back \(tripCount) \(tripCount == 1 ? "time" : "times")"
        )
    }

    private func readFlowPenalties(atTime currentTime: Double) -> [StuckFlowPenaltyReading] {
        var penalties: [StuckFlowPenaltyReading] = []
        let flowWindow = scoringModel.flowWindowInSeconds

        let keyCount = events(
            matching: { $0 == .anonymousKeyPress },
            withinSeconds: flowWindow,
            ofTime: currentTime
        ).count
        if keyCount > scoringModel.typingKeysIgnored {
            let countedKeys = keyCount - scoringModel.typingKeysIgnored
            penalties.append(StuckFlowPenaltyReading(
                points: min(scoringModel.typingPenaltyCap, Double(countedKeys) * scoringModel.typingPenaltyPerKey),
                humanReadableDescription: "typing steadily"
            ))
        }

        var clickedAreas = Set<Int>()
        for clickEvent in events(
            matching: { if case .click = $0 { return true } else { return false } },
            withinSeconds: flowWindow,
            ofTime: currentTime
        ) {
            if case .click(let coarseAreaIdentifier) = clickEvent.kind {
                clickedAreas.insert(coarseAreaIdentifier)
            }
        }
        if clickedAreas.count > scoringModel.freshAreasIgnored {
            let countedAreas = clickedAreas.count - scoringModel.freshAreasIgnored
            penalties.append(StuckFlowPenaltyReading(
                points: min(scoringModel.freshAreaPenaltyCap, Double(countedAreas) * scoringModel.freshAreaPenaltyPerArea),
                humanReadableDescription: "moving through new areas"
            ))
        }

        let dragCount = events(
            matching: { $0 == .dragFinished },
            withinSeconds: flowWindow,
            ofTime: currentTime
        ).count
        if dragCount > scoringModel.dragsIgnored {
            let countedDrags = dragCount - scoringModel.dragsIgnored
            penalties.append(StuckFlowPenaltyReading(
                points: min(scoringModel.dragPenaltyCap, Double(countedDrags) * scoringModel.dragPenaltyPerDrag),
                humanReadableDescription: "steady drag work"
            ))
        }

        let scrollCount = events(
            matching: { $0 == .scrollTick },
            withinSeconds: flowWindow,
            ofTime: currentTime
        ).count
        if scrollCount >= scoringModel.scrollTicksForReadingPenalty {
            penalties.append(StuckFlowPenaltyReading(
                points: scoringModel.readingPenalty,
                humanReadableDescription: "scrolling, probably reading"
            ))
        }

        let redoCount = events(
            matching: { $0 == .redo },
            withinSeconds: scoringModel.undoWindowInSeconds,
            ofTime: currentTime
        ).count
        if redoCount > 0 {
            penalties.append(StuckFlowPenaltyReading(
                points: min(scoringModel.redoPenaltyCap, Double(redoCount) * scoringModel.redoPenaltyPerRedo),
                humanReadableDescription: "comparing with redo"
            ))
        }

        return penalties
    }

    // MARK: Receipt

    /// The complete, human-readable contents of memory. Every retained fact is
    /// covered by exactly one line, which the harness checks, so the receipt
    /// can't quietly omit something the detector knows.
    func receiptLines(atTime currentTime: Double) -> [StuckReceiptLine] {
        var lines: [StuckReceiptLine] = []

        func addEventLine(matching isMatch: (StuckBehaviourEventKind) -> Bool, describe: ([StuckBehaviourEvent]) -> String) {
            let matchingEvents = retainedEvents.filter { isMatch($0.kind) }
            guard let oldestEvent = matchingEvents.first else { return }
            lines.append(StuckReceiptLine(
                text: describe(matchingEvents),
                secondsUntilWiped: secondsUntilWiped(timestamp: oldestEvent.timestampInSeconds, currentTime: currentTime),
                itemCount: matchingEvents.count
            ))
        }

        func span(of matchingEvents: [StuckBehaviourEvent]) -> Int {
            guard let firstEvent = matchingEvents.first, let lastEvent = matchingEvents.last else { return 0 }
            return Int((lastEvent.timestampInSeconds - firstEvent.timestampInSeconds).rounded())
        }

        func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
            "\(count) \(count == 1 ? singular : (pluralForm ?? singular + "s"))"
        }

        addEventLine(matching: { $0 == .undo }) { "\(plural($0.count, "undo")) in \(span(of: $0))s" }
        addEventLine(matching: { $0 == .redo }) { "\(plural($0.count, "redo")) in \(span(of: $0))s" }
        addEventLine(matching: { $0 == .cancel }) { "\(plural($0.count, "cancel")) in \(span(of: $0))s" }
        addEventLine(matching: { $0 == .modeToggle }) { "\(plural($0.count, "tab press", "tab presses")) in \(span(of: $0))s" }
        addEventLine(matching: { $0 == .anonymousKeyPress }) { "\(plural($0.count, "other key press", "other key presses")), not which keys" }
        addEventLine(matching: { if case .click = $0 { return true } else { return false } }) { clickEvents in
            let distinctAreas = clickEvents.reduce(into: Set<Int>()) { areas, clickEvent in
                if case .click(let coarseAreaIdentifier) = clickEvent.kind {
                    areas.insert(coarseAreaIdentifier)
                }
            }
            return "\(plural(clickEvents.count, "click")) across \(plural(distinctAreas.count, "screen area"))"
        }
        addEventLine(matching: { $0 == .dragFinished }) { plural($0.count, "drag") }
        addEventLine(matching: { $0 == .scrollTick }) { "\(plural($0.count, "scroll tick")) in \(span(of: $0))s" }
        addEventLine(matching: { $0 == .leftForBrowser || $0 == .returnedFromBrowser }) { browserEvents in
            let tripCount = completedBrowserTripCount()
            return tripCount > 0
                ? "went to a browser and back \(tripCount) \(tripCount == 1 ? "time" : "times")"
                : "\(plural(browserEvents.count, "switch", "switches")) to or from a browser"
        }

        if let oldestPointerSecond = retainedPointerSeconds.first {
            let totalDistance = retainedPointerSeconds.reduce(0) { $0 + $1.distanceInPoints }
            let distinctAreas = retainedPointerSeconds.reduce(into: Set<Int>()) { $0.formUnion($1.coarseAreaIdentifiers) }
            lines.append(StuckReceiptLine(
                text: "cursor moved for \(plural(retainedPointerSeconds.count, "second")) across \(plural(distinctAreas.count, "screen area")) (\(Int(totalDistance))pt)",
                secondsUntilWiped: secondsUntilWiped(timestamp: Double(oldestPointerSecond.wholeSecond), currentTime: currentTime),
                itemCount: retainedPointerSeconds.count
            ))
        }

        return lines
    }

    private func secondsUntilWiped(timestamp: Double, currentTime: Double) -> Double {
        max(0, scoringModel.memoryRetentionInSeconds - (currentTime - timestamp))
    }
}

// MARK: - Offer Policy

/// Decides when a score becomes an offer, and learns from the answer. Separate
/// from the detector because it's the only part that outlives the 2 minutes:
/// the threshold multiplier is one number, and it's the only thing saved.
struct StuckOfferPolicy {
    let scoringModel: StuckScoringModel

    private(set) var thresholdMultiplier: Double
    private var noOffersUntilTime: Double = -.infinity
    private var consecutiveReadingsOverThreshold = 0

    init(scoringModel: StuckScoringModel = StuckScoringModel(), thresholdMultiplier: Double = 1) {
        self.scoringModel = scoringModel
        self.thresholdMultiplier = max(1, min(thresholdMultiplier, scoringModel.maximumThresholdMultiplier))
    }

    var effectiveThreshold: Double {
        scoringModel.baseOfferThreshold * thresholdMultiplier
    }

    /// Call once a second. True means make an offer now. `isCompanionBusy` is
    /// true while Clicky is already listening or talking.
    mutating func shouldOffer(for assessment: StuckAssessment, atTime currentTime: Double, isCompanionBusy: Bool) -> Bool {
        guard !isCompanionBusy,
              currentTime >= noOffersUntilTime,
              assessment.score >= effectiveThreshold,
              assessment.hasEnoughDistinctSignals,
              assessment.hasStrongEvidence else {
            consecutiveReadingsOverThreshold = 0
            return false
        }

        consecutiveReadingsOverThreshold += 1

        // Quiet hands doesn't reset the count: the case is made, and the offer
        // is only waiting for a moment that won't interrupt.
        guard consecutiveReadingsOverThreshold >= scoringModel.consecutiveReadingsRequiredToOffer,
              assessment.hasQuietHands else {
            return false
        }

        consecutiveReadingsOverThreshold = 0
        noOffersUntilTime = currentTime + scoringModel.cooldownAfterOfferInSeconds
        return true
    }

    mutating func recordDeclined(atTime currentTime: Double) {
        thresholdMultiplier = min(
            scoringModel.maximumThresholdMultiplier,
            thresholdMultiplier * scoringModel.thresholdMultiplierAfterDecline
        )
        noOffersUntilTime = currentTime + scoringModel.cooldownAfterDeclineInSeconds
    }

    mutating func recordIgnored() {
        thresholdMultiplier = min(
            scoringModel.maximumThresholdMultiplier,
            thresholdMultiplier * scoringModel.thresholdMultiplierAfterIgnoring
        )
    }

    mutating func recordAccepted() {
        thresholdMultiplier = max(1, thresholdMultiplier / scoringModel.thresholdDividerAfterAccepting)
    }

    mutating func resetLearning() {
        thresholdMultiplier = 1
    }
}
