//
//  main.swift
//  stuck-harness
//
//  Replays synthetic behaviour traces through the real StuckDetector and
//  StuckEventClassifier sources and reports what happened. Run it through
//  scripts/stuck-harness.sh. Every number it prints is about synthetic traces.
//
//    stuck-harness evaluate [--json /abs/out.json]   tuning and held-out scores
//    stuck-harness tune                              tuning set only
//    stuck-harness checks                            privacy and behaviour checks
//    stuck-harness live-replay <seconds>             paced replay for the proof
//

import CoreGraphics
import Foundation

// MARK: - Replay

struct ReplayOutcome {
    /// When offers fired, in trace seconds.
    let offerTimes: [Double]
    let peakScore: Double
}

/// Drives the detector exactly as the live monitor does: events as they
/// happen, and one reading a second.
func replay(_ trace: BehaviourTrace, scoringModel: StuckScoringModel, thresholdMultiplier: Double = 1) -> ReplayOutcome {
    var detector = StuckDetector(scoringModel: scoringModel)
    var offerPolicy = StuckOfferPolicy(scoringModel: scoringModel, thresholdMultiplier: thresholdMultiplier)
    var nextEventIndex = 0
    var offerTimes: [Double] = []
    var peakScore: Double = 0

    var readingTime: Double = 1
    while readingTime <= trace.durationInSeconds {
        while nextEventIndex < trace.events.count, trace.events[nextEventIndex].timestampInSeconds <= readingTime {
            detector.ingest(trace.events[nextEventIndex])
            nextEventIndex += 1
        }
        detector.wipeExpiredMemory(atTime: readingTime)
        let assessment = detector.assess(atTime: readingTime)
        peakScore = max(peakScore, assessment.score)
        if offerPolicy.shouldOffer(for: assessment, atTime: readingTime, isCompanionBusy: false) {
            offerTimes.append(readingTime)
        }
        readingTime += 1
    }

    return ReplayOutcome(offerTimes: offerTimes, peakScore: peakScore)
}

// MARK: - Evaluation

struct ScenarioResult {
    let name: String
    let isStuck: Bool
    let isDeliberatelyHard: Bool
    let traceCount: Int
    /// For stuck scenarios, traces that got an offer after onset. For busy
    /// scenarios, traces that got any offer, each of which is a false offer.
    let tracesWithOffer: Int
    let falseOffersBeforeOnset: Int
    let secondsToOffer: [Double]
    let peakScores: [Double]

    var rate: Double {
        Double(tracesWithOffer) / Double(traceCount)
    }
}

struct EvaluationSummary {
    let truePositives: Int
    let falseNegatives: Int
    let falsePositives: Int
    let trueNegatives: Int

    var precision: Double {
        truePositives + falsePositives == 0 ? 1 : Double(truePositives) / Double(truePositives + falsePositives)
    }

    var recall: Double {
        Double(truePositives) / Double(truePositives + falseNegatives)
    }
}

func evaluate(
    scenario: TraceScenario,
    seeds: [UInt64],
    timingNoise: Double,
    scoringModel: StuckScoringModel
) -> ScenarioResult {
    var tracesWithOffer = 0
    var falseOffersBeforeOnset = 0
    var secondsToOffer: [Double] = []
    var peakScores: [Double] = []

    for seed in seeds {
        let trace = scenario.makeTrace(seed: seed, timingNoise: timingNoise)
        let outcome = replay(trace, scoringModel: scoringModel)
        peakScores.append(outcome.peakScore)

        if let stuckOnset = trace.stuckOnsetInSeconds {
            let offersAfterOnset = outcome.offerTimes.filter { $0 >= stuckOnset }
            falseOffersBeforeOnset += outcome.offerTimes.count - offersAfterOnset.count
            if let firstOffer = offersAfterOnset.first {
                tracesWithOffer += 1
                secondsToOffer.append(firstOffer - stuckOnset)
            }
        } else if !outcome.offerTimes.isEmpty {
            tracesWithOffer += 1
        }
    }

    return ScenarioResult(
        name: scenario.name,
        isStuck: scenario.isStuck,
        isDeliberatelyHard: scenario.isDeliberatelyHard,
        traceCount: seeds.count,
        tracesWithOffer: tracesWithOffer,
        falseOffersBeforeOnset: falseOffersBeforeOnset,
        secondsToOffer: secondsToOffer,
        peakScores: peakScores
    )
}

func summarize(_ results: [ScenarioResult]) -> EvaluationSummary {
    let stuckResults = results.filter(\.isStuck)
    let busyResults = results.filter { !$0.isStuck }

    let truePositives = stuckResults.reduce(0) { $0 + $1.tracesWithOffer }
    let stuckTraceCount = stuckResults.reduce(0) { $0 + $1.traceCount }
    let earlyFalseOffers = stuckResults.reduce(0) { $0 + $1.falseOffersBeforeOnset }
    let busyFalsePositives = busyResults.reduce(0) { $0 + $1.tracesWithOffer }
    let busyTraceCount = busyResults.reduce(0) { $0 + $1.traceCount }

    return EvaluationSummary(
        truePositives: truePositives,
        falseNegatives: stuckTraceCount - truePositives,
        falsePositives: busyFalsePositives + earlyFalseOffers,
        trueNegatives: busyTraceCount - busyFalsePositives
    )
}

/// How uncertain a rate is given how few traces it came from.
func wilsonInterval(successes: Int, total: Int) -> (lower: Double, upper: Double) {
    guard total > 0 else { return (0, 1) }
    let criticalValue = 1.96
    let observedRate = Double(successes) / Double(total)
    let totalAsDouble = Double(total)
    let denominator = 1 + criticalValue * criticalValue / totalAsDouble
    let center = (observedRate + criticalValue * criticalValue / (2 * totalAsDouble)) / denominator
    let margin = criticalValue * (observedRate * (1 - observedRate) / totalAsDouble + criticalValue * criticalValue / (4 * totalAsDouble * totalAsDouble)).squareRoot() / denominator
    return (max(0, center - margin), min(1, center + margin))
}

/// Precision depends on how many stuck traces happen to be in the set, so this
/// is the fairer number: run only busy work, for hours, and count interruptions.
func falseOffersOverSimulatedBusyHours(hours: Int, seedBase: UInt64, timingNoise: Double, scoringModel: StuckScoringModel) -> (offers: Int, simulatedHours: Double) {
    var generator = SeededGenerator(seed: seedBase)
    var detector = StuckDetector(scoringModel: scoringModel)
    var offerPolicy = StuckOfferPolicy(scoringModel: scoringModel)
    var clockOffset: Double = 0
    var offerCount = 0
    var traceIndex: UInt64 = 0
    let targetSeconds = Double(hours) * 3_600

    while clockOffset < targetSeconds {
        let scenario = TraceLibrary.busyScenarios.randomElement(using: &generator)!
        let trace = scenario.makeTrace(seed: seedBase &+ traceIndex, timingNoise: timingNoise)
        traceIndex += 1

        var nextEventIndex = 0
        var readingTime: Double = 1
        while readingTime <= trace.durationInSeconds {
            while nextEventIndex < trace.events.count, trace.events[nextEventIndex].timestampInSeconds <= readingTime {
                let event = trace.events[nextEventIndex]
                detector.ingest(StuckBehaviourEvent(timestampInSeconds: event.timestampInSeconds + clockOffset, kind: event.kind))
                nextEventIndex += 1
            }
            let absoluteTime = readingTime + clockOffset
            detector.wipeExpiredMemory(atTime: absoluteTime)
            if offerPolicy.shouldOffer(for: detector.assess(atTime: absoluteTime), atTime: absoluteTime, isCompanionBusy: false) {
                offerCount += 1
            }
            readingTime += 1
        }
        clockOffset += trace.durationInSeconds
    }

    return (offerCount, clockOffset / 3_600)
}

// MARK: - Reporting

func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
}

func printSection(title: String, results: [ScenarioResult]) -> EvaluationSummary {
    print("\n\(title)")
    print("  scenario".padding(toLength: 58, withPad: " ", startingAt: 0) + "offers/traces   median s to offer")
    for result in results {
        let offerColumn = "\(result.tracesWithOffer)/\(result.traceCount)".padding(toLength: 16, withPad: " ", startingAt: 0)
        let latencyColumn = median(result.secondsToOffer).map { String(format: "%.0f", $0) } ?? "-"
        print("  " + result.name.padding(toLength: 56, withPad: " ", startingAt: 0) + offerColumn + latencyColumn)
    }

    let summary = summarize(results)
    let precisionTotal = summary.truePositives + summary.falsePositives
    let recallTotal = summary.truePositives + summary.falseNegatives
    let precisionInterval = wilsonInterval(successes: summary.truePositives, total: precisionTotal)
    let recallInterval = wilsonInterval(successes: summary.truePositives, total: recallTotal)

    print("  TP \(summary.truePositives)  FP \(summary.falsePositives)  FN \(summary.falseNegatives)  TN \(summary.trueNegatives)")
    print("  precision \(percent(summary.precision)) (95% CI \(percent(precisionInterval.lower)) to \(percent(precisionInterval.upper)))")
    print("  recall    \(percent(summary.recall)) (95% CI \(percent(recallInterval.lower)) to \(percent(recallInterval.upper)))")
    return summary
}

func runTuningOnly() {
    let scoringModel = StuckScoringModel()
    let allScenarios = TraceLibrary.stuckScenarios + TraceLibrary.busyScenarios
    let tuningSeeds = (1...100).map { UInt64($0) }
    let tuningResults = allScenarios.map { evaluate(scenario: $0, seeds: tuningSeeds, timingNoise: 0.20, scoringModel: scoringModel) }
    _ = printSection(title: "TUNING SET ONLY (synthetic)", results: tuningResults)
    print("\n  peak score per scenario: median  p95  max")
    for result in tuningResults {
        let sortedPeaks = result.peakScores.sorted()
        print("  " + result.name.padding(toLength: 56, withPad: " ", startingAt: 0) + String(format: "%4.0f %4.0f %4.0f", sortedPeaks[sortedPeaks.count / 2], sortedPeaks[sortedPeaks.count * 95 / 100], sortedPeaks.last ?? 0))
    }
}

func runEvaluation(jsonOutputPath: String?) {
    let scoringModel = StuckScoringModel()
    let allScenarios = TraceLibrary.stuckScenarios + TraceLibrary.busyScenarios

    // Tuning traces are the only ones looked at while choosing the numbers.
    // Held-out traces use seeds and noise levels the tuning never saw.
    let tuningSeeds = (1...100).map { UInt64($0) }
    let tuningTimingNoise = 0.20
    let heldOutSeeds = (0..<300).map { UInt64(900_000 + $0 * 7) }
    let heldOutTimingNoise = 0.35

    print("All traces below are SYNTHETIC, generated by stuck-harness/TraceGenerators.swift.")
    print("They are models of behaviour, not recordings of people.")

    let tuningResults = allScenarios.map { evaluate(scenario: $0, seeds: tuningSeeds, timingNoise: tuningTimingNoise, scoringModel: scoringModel) }
    let tuningSummary = printSection(title: "TUNING SET (100 seeds each, timing noise \(tuningTimingNoise))", results: tuningResults)

    let heldOutResults = allScenarios.map { evaluate(scenario: $0, seeds: heldOutSeeds, timingNoise: heldOutTimingNoise, scoringModel: scoringModel) }
    let heldOutSummary = printSection(title: "HELD-OUT SET (300 seeds each, timing noise \(heldOutTimingNoise))", results: heldOutResults)

    let obviousHeldOutResults = heldOutResults.filter { !($0.isStuck && $0.isDeliberatelyHard) }
    let obviousRecall = summarize(obviousHeldOutResults).recall
    print("\n  recall excluding the two deliberately hard stuck scenarios: \(percent(obviousRecall))")

    print("\nFALSE OFFERS PER BUSY HOUR (held-out noise, random busy scenarios back to back)")
    let busyHours = falseOffersOverSimulatedBusyHours(hours: 200, seedBase: 5_000_000, timingNoise: heldOutTimingNoise, scoringModel: scoringModel)
    print(String(format: "  %d false offers in %.0f simulated hours: %.3f per hour", busyHours.offers, busyHours.simulatedHours, Double(busyHours.offers) / busyHours.simulatedHours))

    print("\nTHRESHOLD SWEEP (held-out traces, score threshold only)")
    print("  threshold  precision  recall    TP   FP   FN")
    var sweepRows: [[String: Any]] = []
    for threshold in stride(from: 40.0, through: 200.0, by: 20.0) {
        var sweptModel = scoringModel
        sweptModel.baseOfferThreshold = threshold
        let sweptResults = allScenarios.map { evaluate(scenario: $0, seeds: heldOutSeeds, timingNoise: heldOutTimingNoise, scoringModel: sweptModel) }
        let sweptSummary = summarize(sweptResults)
        print(String(format: "  %9.0f  %8.1f%%  %5.1f%%  %4d %4d %4d", threshold, sweptSummary.precision * 100, sweptSummary.recall * 100, sweptSummary.truePositives, sweptSummary.falsePositives, sweptSummary.falseNegatives))
        sweepRows.append([
            "threshold": threshold,
            "precision": sweptSummary.precision,
            "recall": sweptSummary.recall,
            "truePositives": sweptSummary.truePositives,
            "falsePositives": sweptSummary.falsePositives,
            "falseNegatives": sweptSummary.falseNegatives
        ])
    }

    print("\nDECLINING (held-out stuck traces, excluding the hard ones)")
    print("  declines  threshold  traces that still get an offer")
    var multiplier: Double = 1
    let obviousStuckScenarios = TraceLibrary.stuckScenarios.filter { !$0.isDeliberatelyHard }
    var declineRows: [[String: Any]] = []
    for declineCount in 0...4 {
        var offered = 0
        var total = 0
        for scenario in obviousStuckScenarios {
            for seed in heldOutSeeds {
                let trace = scenario.makeTrace(seed: seed, timingNoise: heldOutTimingNoise)
                total += 1
                if !replay(trace, scoringModel: scoringModel, thresholdMultiplier: multiplier).offerTimes.isEmpty {
                    offered += 1
                }
            }
        }
        let threshold = scoringModel.baseOfferThreshold * multiplier
        print(String(format: "  %8d  %9.0f  %d/%d (%.1f%%)", declineCount, threshold, offered, total, Double(offered) / Double(total) * 100))
        declineRows.append(["declines": declineCount, "threshold": threshold, "offered": offered, "total": total])
        multiplier = min(scoringModel.maximumThresholdMultiplier, multiplier * scoringModel.thresholdMultiplierAfterDecline)
    }

    if let jsonOutputPath {
        func scenarioRows(_ results: [ScenarioResult]) -> [[String: Any]] {
            results.map { result in
                [
                    "scenario": result.name,
                    "isStuck": result.isStuck,
                    "isDeliberatelyHard": result.isDeliberatelyHard,
                    "traces": result.traceCount,
                    "tracesWithOffer": result.tracesWithOffer,
                    "falseOffersBeforeOnset": result.falseOffersBeforeOnset,
                    "medianSecondsToOffer": median(result.secondsToOffer) ?? NSNull()
                ]
            }
        }
        func summaryRow(_ summary: EvaluationSummary) -> [String: Any] {
            [
                "truePositives": summary.truePositives,
                "falsePositives": summary.falsePositives,
                "falseNegatives": summary.falseNegatives,
                "trueNegatives": summary.trueNegatives,
                "precision": summary.precision,
                "recall": summary.recall
            ]
        }
        let document: [String: Any] = [
            "dataIsSynthetic": true,
            "tuning": ["summary": summaryRow(tuningSummary), "scenarios": scenarioRows(tuningResults)],
            "heldOut": ["summary": summaryRow(heldOutSummary), "scenarios": scenarioRows(heldOutResults)],
            "heldOutRecallExcludingHardScenarios": obviousRecall,
            "falseOffersInSimulatedBusyHours": ["offers": busyHours.offers, "hours": busyHours.simulatedHours],
            "thresholdSweep": sweepRows,
            "declining": declineRows
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: jsonOutputPath, contents: jsonData)
        }
    }
}

// MARK: - Checks

/// Checks claims the receipt makes, against the real code.
func runChecks() -> Bool {
    var passedCount = 0
    var failures: [String] = []

    func expect(_ condition: Bool, _ description: String) {
        if condition {
            passedCount += 1
            print("  ok    \(description)")
        } else {
            failures.append(description)
            print("  FAIL  \(description)")
        }
    }

    print("Classifier, using real CGEvent objects:")
    let eventSource = CGEventSource(stateID: .privateState)

    func keyEvent(keyCode: CGKeyCode, flags: CGEventFlags, isAutorepeat: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isAutorepeat ? 1 : 0)
        return event
    }

    func classify(_ event: CGEvent, type: CGEventType, using classifier: inout StuckEventClassifier) -> StuckBehaviourEventKind? {
        classifier.classify(
            eventType: type,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            modifierFlags: event.flags,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            pointerLocation: event.location
        )
    }

    var classifier = StuckEventClassifier()
    let keyCodeForA: CGKeyCode = 0
    let keyCodeForZ: CGKeyCode = 6
    let keyCodeForTab: CGKeyCode = 48
    let keyCodeForEscape: CGKeyCode = 53

    expect(classify(keyEvent(keyCode: keyCodeForZ, flags: .maskCommand), type: .keyDown, using: &classifier) == .undo, "cmd-z is an undo")
    expect(classify(keyEvent(keyCode: keyCodeForZ, flags: .maskControl), type: .keyDown, using: &classifier) == .undo, "ctrl-z is an undo")
    expect(classify(keyEvent(keyCode: keyCodeForZ, flags: [.maskCommand, .maskShift]), type: .keyDown, using: &classifier) == .redo, "shift-cmd-z is a redo")
    expect(classify(keyEvent(keyCode: keyCodeForZ, flags: []), type: .keyDown, using: &classifier) == .anonymousKeyPress, "a plain z is anonymous")
    expect(classify(keyEvent(keyCode: keyCodeForA, flags: []), type: .keyDown, using: &classifier) == .anonymousKeyPress, "a plain a is anonymous")
    expect(classify(keyEvent(keyCode: keyCodeForA, flags: .maskCommand), type: .keyDown, using: &classifier) == .anonymousKeyPress, "cmd-a is anonymous")
    expect(classify(keyEvent(keyCode: keyCodeForTab, flags: []), type: .keyDown, using: &classifier) == .modeToggle, "tab is a mode toggle")
    expect(classify(keyEvent(keyCode: keyCodeForEscape, flags: []), type: .keyDown, using: &classifier) == .cancel, "escape is a cancel")
    expect(classify(keyEvent(keyCode: keyCodeForZ, flags: .maskCommand, isAutorepeat: true), type: .keyDown, using: &classifier) == nil, "held undo autorepeat is dropped")

    func mouseEvent(_ type: CGEventType, at location: CGPoint, button: CGMouseButton = .left) -> CGEvent {
        CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: location, mouseButton: button)!
    }

    var mouseClassifier = StuckEventClassifier()
    let clickLocation = CGPoint(x: 500, y: 330)
    expect(classify(mouseEvent(.leftMouseDown, at: clickLocation), type: .leftMouseDown, using: &mouseClassifier) == nil, "mouse down alone reports nothing")
    let clickResult = classify(mouseEvent(.leftMouseUp, at: clickLocation), type: .leftMouseUp, using: &mouseClassifier)
    let nearbyLocationInSameTile = CGPoint(x: 510, y: 335)
    expect(clickResult == .click(coarseAreaIdentifier: StuckEventClassifier.coarseAreaIdentifier(for: nearbyLocationInSameTile)), "a click reports a tile, and nearby clicks share it")

    _ = classify(mouseEvent(.leftMouseDown, at: clickLocation), type: .leftMouseDown, using: &mouseClassifier)
    _ = classify(mouseEvent(.leftMouseDragged, at: CGPoint(x: 560, y: 330)), type: .leftMouseDragged, using: &mouseClassifier)
    let dragResult = classify(mouseEvent(.leftMouseUp, at: CGPoint(x: 560, y: 330)), type: .leftMouseUp, using: &mouseClassifier)
    expect(dragResult == .dragFinished, "a press that travels is a drag")

    print("\nWhat an event can hold:")
    func allStoredValueTypes(of value: Any) -> Set<String> {
        var typeNames: Set<String> = []
        for child in Mirror(reflecting: value).children {
            typeNames.insert(String(describing: type(of: child.value)))
            typeNames.formUnion(allStoredValueTypes(of: child.value))
        }
        return typeNames
    }
    let sampleEvents = [
        StuckBehaviourEvent(timestampInSeconds: 1, kind: .undo),
        StuckBehaviourEvent(timestampInSeconds: 1, kind: .anonymousKeyPress),
        StuckBehaviourEvent(timestampInSeconds: 1, kind: .click(coarseAreaIdentifier: 3_002)),
        StuckBehaviourEvent(timestampInSeconds: 1, kind: .pointerMovement(distanceInPoints: 4, coarseAreaIdentifier: 3_002)),
        StuckBehaviourEvent(timestampInSeconds: 1, kind: .leftForBrowser)
    ]
    let storedTypes = sampleEvents.reduce(into: Set<String>()) { $0.formUnion(allStoredValueTypes(of: $1)) }
    print("  stored field types: \(storedTypes.sorted())")
    expect(!storedTypes.contains { $0.contains("String") || $0.contains("Data") || $0.contains("Character") }, "an event holds no text or bytes")

    print("\nMemory:")
    var detector = StuckDetector()
    var clock: Double = 0
    let sampleTrace = TraceLibrary.stuckScenarios[0].makeTrace(seed: 1, timingNoise: 0.2)
    for event in sampleTrace.events where event.timestampInSeconds <= 30 {
        detector.ingest(event)
        clock = event.timestampInSeconds
    }
    let filledCount = detector.retainedItemCount
    expect(filledCount > 0, "memory fills while events arrive (\(filledCount) items)")

    let receiptItemCount = detector.receiptLines(atTime: clock).reduce(0) { $0 + $1.itemCount }
    expect(receiptItemCount == filledCount, "the receipt accounts for every item in memory (\(receiptItemCount) of \(filledCount))")
    print("  receipt at \(Int(clock))s:")
    for line in detector.receiptLines(atTime: clock) {
        print("    \(line.text)  [wiped in \(Int(line.secondsUntilWiped))s]")
    }

    detector.wipeExpiredMemory(atTime: clock + 60)
    expect(detector.retainedItemCount == filledCount, "nothing is wiped before 2 minutes")
    detector.wipeExpiredMemory(atTime: clock + 120.5)
    expect(detector.retainedItemCount == 0, "everything is gone after 2 minutes")

    for event in sampleTrace.events where event.timestampInSeconds <= 30 {
        detector.ingest(event)
    }
    detector.forgetEverything()
    expect(detector.retainedItemCount == 0 && detector.receiptLines(atTime: clock).isEmpty, "forget now empties memory and the receipt")

    print("\nOffer policy:")
    var policy = StuckOfferPolicy()
    let baseThreshold = policy.effectiveThreshold
    policy.recordDeclined(atTime: 0)
    expect(policy.effectiveThreshold > baseThreshold, "declining raises the threshold (\(baseThreshold) to \(policy.effectiveThreshold))")
    for _ in 0..<3 {
        policy.recordDeclined(atTime: 0)
    }
    let scoringModel = StuckScoringModel()
    let highestPossibleScore = scoringModel.undoPointsCap + scoringModel.cancelPointsCap + scoringModel.modeTogglePointsCap
        + scoringModel.revisitPointsCap + scoringModel.restlessPointsCap + scoringModel.stillnessPointsCap
        + scoringModel.browserBouncePointsCap
    expect(policy.effectiveThreshold > highestPossibleScore, "four declines put the threshold (\(policy.effectiveThreshold)) above the highest possible score (\(highestPossibleScore))")
    policy.recordAccepted()
    expect(policy.effectiveThreshold < scoringModel.baseOfferThreshold * scoringModel.maximumThresholdMultiplier, "accepting lowers it again")
    policy.resetLearning()
    expect(policy.effectiveThreshold == baseThreshold, "reset returns to the default")

    func strongAssessment(hasQuietHands: Bool = true, signalCount: Int = 2, hasStrongEvidence: Bool = true) -> StuckAssessment {
        StuckAssessment(
            signals: Array(repeating: StuckSignalReading(kind: .undoLoop, points: 80, humanReadableDescription: ""), count: signalCount),
            flowPenalties: [],
            score: 160,
            hasEnoughDistinctSignals: signalCount >= scoringModel.minimumDistinctSignalsToOffer,
            hasStrongEvidence: hasStrongEvidence,
            hasQuietHands: hasQuietHands
        )
    }

    var gatePolicy = StuckOfferPolicy()
    expect(!gatePolicy.shouldOffer(for: strongAssessment(), atTime: 10, isCompanionBusy: false), "one reading over the line is not enough")
    expect(gatePolicy.shouldOffer(for: strongAssessment(), atTime: 11, isCompanionBusy: false), "two readings in a row make an offer")
    expect(!gatePolicy.shouldOffer(for: strongAssessment(), atTime: 12, isCompanionBusy: false) && !gatePolicy.shouldOffer(for: strongAssessment(), atTime: 13, isCompanionBusy: false), "a cooldown follows an offer")

    var quietPolicy = StuckOfferPolicy()
    _ = quietPolicy.shouldOffer(for: strongAssessment(), atTime: 10, isCompanionBusy: false)
    expect(!quietPolicy.shouldOffer(for: strongAssessment(hasQuietHands: false), atTime: 11, isCompanionBusy: false), "never mid-action")
    var singleSignalPolicy = StuckOfferPolicy()
    _ = singleSignalPolicy.shouldOffer(for: strongAssessment(signalCount: 1), atTime: 10, isCompanionBusy: false)
    expect(!singleSignalPolicy.shouldOffer(for: strongAssessment(signalCount: 1), atTime: 11, isCompanionBusy: false), "one signal alone never fires")
    var weakEvidencePolicy = StuckOfferPolicy()
    _ = weakEvidencePolicy.shouldOffer(for: strongAssessment(hasStrongEvidence: false), atTime: 10, isCompanionBusy: false)
    expect(!weakEvidencePolicy.shouldOffer(for: strongAssessment(hasStrongEvidence: false), atTime: 11, isCompanionBusy: false), "stillness and wandering alone never fire")
    var busyCompanionPolicy = StuckOfferPolicy()
    _ = busyCompanionPolicy.shouldOffer(for: strongAssessment(), atTime: 10, isCompanionBusy: true)
    expect(!busyCompanionPolicy.shouldOffer(for: strongAssessment(), atTime: 11, isCompanionBusy: true), "never while clicky is already talking")

    print("\n\(passedCount) passed, \(failures.count) failed")
    return failures.isEmpty
}

// MARK: - Live Replay

/// Runs the detector in real time for scripts/prove-privacy.sh, so kernel
/// counters can be read while the same detector source does its normal work.
/// It writes nothing and prints nothing until it finishes.
func runLiveReplay(seconds: Double) {
    let scoringModel = StuckScoringModel()
    var detector = StuckDetector(scoringModel: scoringModel)
    var offerPolicy = StuckOfferPolicy(scoringModel: scoringModel)
    let startDate = Date()
    var traceClockOffset: Double = 0
    var traceSeed: UInt64 = 1
    var processedEventCount = 0
    var offerCount = 0

    while Date().timeIntervalSince(startDate) < seconds {
        let trace = TraceLibrary.stuckScenarios[0].makeTrace(seed: traceSeed, timingNoise: 0.2)
        traceSeed += 1
        for event in trace.events {
            let eventTime = event.timestampInSeconds + traceClockOffset
            while Date().timeIntervalSince(startDate) < eventTime {
                let currentTime = Date().timeIntervalSince(startDate)
                guard currentTime < seconds else { break }
                detector.wipeExpiredMemory(atTime: currentTime)
                if offerPolicy.shouldOffer(for: detector.assess(atTime: currentTime), atTime: currentTime, isCompanionBusy: false) {
                    offerCount += 1
                    offerPolicy = StuckOfferPolicy(scoringModel: scoringModel)
                }
                Thread.sleep(forTimeInterval: min(0.25, max(0.01, eventTime - currentTime)))
            }
            guard Date().timeIntervalSince(startDate) < seconds else { break }
            detector.ingest(StuckBehaviourEvent(timestampInSeconds: eventTime, kind: event.kind))
            processedEventCount += 1
        }
        traceClockOffset += trace.durationInSeconds
    }

    print("{\"eventsProcessed\": \(processedEventCount), \"offersThatWouldHaveFired\": \(offerCount), \"retainedItemsAtEnd\": \(detector.retainedItemCount)}")
}

// MARK: - Entry Point

let commandLineArguments = CommandLine.arguments

switch commandLineArguments.dropFirst().first {
case "evaluate":
    let jsonFlagIndex = commandLineArguments.firstIndex(of: "--json")
    let jsonOutputPath = jsonFlagIndex.flatMap { $0 + 1 < commandLineArguments.count ? commandLineArguments[$0 + 1] : nil }
    runEvaluation(jsonOutputPath: jsonOutputPath)
case "tune":
    runTuningOnly()
case "checks":
    exit(runChecks() ? 0 : 1)
case "live-replay":
    runLiveReplay(seconds: commandLineArguments.count > 2 ? Double(commandLineArguments[2]) ?? 30 : 30)
default:
    print("usage: stuck-harness evaluate [--json /abs/out.json] | tune | checks | live-replay <seconds>")
    exit(2)
}
