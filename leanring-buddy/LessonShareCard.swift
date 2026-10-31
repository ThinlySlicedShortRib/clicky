//
//  LessonShareCard.swift
//  leanring-buddy
//
//  The card a teacher gets once a lesson exists. Every number on it comes from
//  the lesson file: the size is the real `.clicky` file, and the cost is built
//  only from BrainUsage values from real calls. A figure nobody reported is
//  shown as not measured, never as zero.
//

import AppKit
import SwiftUI

// MARK: - Cost Estimate

struct LessonReplayCostEstimate: Equatable {
    /// Nil when no real call has reported a cost.
    let estimatedCostInUSD: Double?
    /// Used in place of a cost for backends that only report tokens.
    let estimatedTokenCount: Int?
    /// What the figure rests on, in plain language.
    let basisDescription: String

    /// Always says "estimated": the figures are the CLI's own list-price
    /// calculation, which isn't what anybody is billed.
    var displayText: String {
        if let estimatedCostInUSD {
            return "about \(Self.formatDollars(estimatedCostInUSD)) to replay (estimated)"
        }
        if let estimatedTokenCount {
            return "about \(estimatedTokenCount) tokens to replay (estimated)"
        }
        return "replay cost not measured yet"
    }

    static func formatDollars(_ amountInUSD: Double) -> String {
        amountInUSD >= 0.1
            ? String(format: "$%.2f", amountInUSD)
            : String(format: "$%.3f", amountInUSD)
    }
}

enum LessonReplayCostEstimator {
    static func estimate(for lesson: ClickyLesson) -> LessonReplayCostEstimate {
        let replayRuns = lesson.costEvidence.replayRuns

        if !replayRuns.isEmpty {
            return estimateFromReplayRuns(replayRuns)
        }

        return estimateFromRehearsal(
            rehearsalCalls: lesson.costEvidence.rehearsalCalls,
            stepCount: lesson.steps.count
        )
    }

    /// A whole recorded run is the best evidence, because it already reflects
    /// which steps needed the model and which were free.
    private static func estimateFromReplayRuns(_ replayRuns: [LessonReplayRun]) -> LessonReplayCostEstimate {
        let allCalls = replayRuns.flatMap(\.calls)
        let runCountText = replayRuns.count == 1 ? "1 real run" : "\(replayRuns.count) real runs"
        let basisDescription = "average of \(runCountText), \(allCalls.count) model calls, from \(costSourceText(of: allCalls))"

        if allCalls.contains(where: { $0.usage.costInUSD == nil }) {
            return tokenEstimate(calls: allCalls, divisor: replayRuns.count, basisDescription: basisDescription)
        }

        let totalCostInUSD = allCalls.compactMap(\.usage.costInUSD).reduce(0, +)
        return LessonReplayCostEstimate(
            estimatedCostInUSD: totalCostInUSD / Double(replayRuns.count),
            estimatedTokenCount: nil,
            basisDescription: basisDescription
        )
    }

    /// Before any full run exists, one measured locate and one measured check
    /// are scaled to the lesson's length, assuming every step pays for both.
    private static func estimateFromRehearsal(rehearsalCalls: [LessonCostSample], stepCount: Int) -> LessonReplayCostEstimate {
        guard let locateCall = rehearsalCalls.first(where: { $0.purpose == "locate" }),
              let checkCall = rehearsalCalls.first(where: { $0.purpose == "check" }) else {
            return LessonReplayCostEstimate(
                estimatedCostInUSD: nil,
                estimatedTokenCount: nil,
                basisDescription: "no model calls measured for this lesson yet"
            )
        }

        let basisDescription = "1 real locate and 1 real check scaled to \(stepCount) steps, from \(costSourceText(of: rehearsalCalls))"

        guard let locateCostInUSD = locateCall.usage.costInUSD,
              let checkCostInUSD = checkCall.usage.costInUSD else {
            return tokenEstimate(calls: rehearsalCalls, multiplier: stepCount, basisDescription: basisDescription)
        }

        return LessonReplayCostEstimate(
            estimatedCostInUSD: (locateCostInUSD + checkCostInUSD) * Double(stepCount),
            estimatedTokenCount: nil,
            basisDescription: basisDescription
        )
    }

    private static func tokenEstimate(
        calls: [LessonCostSample],
        multiplier: Int = 1,
        divisor: Int = 1,
        basisDescription: String
    ) -> LessonReplayCostEstimate {
        let reportedTokenCounts = calls.compactMap { call -> Int? in
            guard let inputTokens = call.usage.inputTokens, let outputTokens = call.usage.outputTokens else { return nil }
            return inputTokens + outputTokens
        }
        return LessonReplayCostEstimate(
            estimatedCostInUSD: nil,
            estimatedTokenCount: reportedTokenCounts.isEmpty ? nil : reportedTokenCounts.reduce(0, +) * multiplier / max(divisor, 1),
            basisDescription: basisDescription
        )
    }

    private static func costSourceText(of calls: [LessonCostSample]) -> String {
        calls.first?.usage.costSourceDescription ?? "no reported figures"
    }
}

// MARK: - Card Data

struct LessonShareCardContent: Equatable {
    let title: String
    let teacherName: String
    let stepTitles: [String]
    let stepCount: Int
    let applicationName: String
    let sizeText: String
    let replayCostText: String
    let costFootnote: String
    /// Set for synthetic lessons, so nobody takes one for a real teacher's.
    let provenanceWarning: String?

    private static let stepsShownOnCard = 6

    init(lessonPackage: LessonPackage) {
        let lesson = lessonPackage.lesson
        let replayCost = LessonReplayCostEstimator.estimate(for: lesson)

        title = lesson.title
        teacherName = lesson.teacherName
        stepTitles = Array(lesson.steps.prefix(Self.stepsShownOnCard).map(\.intent))
        stepCount = lesson.steps.count
        applicationName = lesson.applicationName
        sizeText = Self.formatFileSize(lessonPackage.archiveSizeInBytes)
        replayCostText = replayCost.displayText
        costFootnote = replayCost.basisDescription

        if lesson.provenance.kind == .syntheticRecording {
            provenanceWarning = "synthetic test lesson. \(lesson.provenance.note ?? "made by a script, not a real teacher.")"
        } else {
            provenanceWarning = nil
        }
    }

    static func formatFileSize(_ sizeInBytes: Int) -> String {
        let oneMegabyte = 1_000_000
        if sizeInBytes >= oneMegabyte {
            return String(format: "%.1f mb", Double(sizeInBytes) / Double(oneMegabyte))
        }
        return "\(max(1, sizeInBytes / 1_000)) kb"
    }
}

// MARK: - Card View

struct LessonShareCardView: View {
    let cardContent: LessonShareCardContent

    private let cardWidth: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Triangle()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 13, height: 13)
                    .rotationEffect(.degrees(-35))
                    .shadow(color: DS.Colors.overlayCursorBlue, radius: 5)
                Text("show me once")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.overlayCursorBlue)
                Spacer()
                Text(cardContent.applicationName.lowercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text(cardContent.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)

            Text("taught once by \(cardContent.teacherName)")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(cardContent.stepTitles.enumerated()), id: \.offset) { stepOffset, stepTitle in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(stepOffset + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(DS.Colors.overlayCursorBlue)
                            .frame(width: 14, alignment: .trailing)
                        Text(stepTitle)
                            .font(.system(size: 14))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                if cardContent.stepCount > cardContent.stepTitles.count {
                    Text("and \(cardContent.stepCount - cardContent.stepTitles.count) more")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.leading, 24)
                }
            }
            .padding(.top, 20)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.top, 20)

            HStack(spacing: 18) {
                cardStatistic(cardContent.stepCount == 1 ? "1 step" : "\(cardContent.stepCount) steps")
                cardStatistic(cardContent.sizeText)
                cardStatistic(cardContent.replayCostText)
            }
            .padding(.top, 14)

            Text(cardContent.costFootnote)
                .font(.system(size: 10.5))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if let provenanceWarning = cardContent.provenanceWarning {
                Text(provenanceWarning)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .padding(28)
        .frame(width: cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
        )
    }

    private func cardStatistic(_ statisticText: String) -> some View {
        Text(statisticText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
    }
}

enum LessonShareCardRenderer {
    /// Renders the card to a PNG, the same view the panel shows.
    static func pngData(for cardContent: LessonShareCardContent) -> Data? {
        let imageRenderer = ImageRenderer(content: LessonShareCardView(cardContent: cardContent))
        imageRenderer.scale = 2
        guard let renderedImage = imageRenderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: renderedImage).representation(using: .png, properties: [:])
    }
}

// MARK: - Card Window

/// Shows the share card centred on screen, with a way to find the file.
@MainActor
final class LessonShareCardWindowManager {
    private var cardPanel: NSPanel?

    func show(lessonPackage: LessonPackage) {
        hide()

        let cardContent = LessonShareCardContent(lessonPackage: lessonPackage)
        let archiveURL = lessonPackage.archiveURL

        let hostingView = NSHostingView(rootView: LessonShareCardPanelView(
            cardContent: cardContent,
            onRevealFile: {
                NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
            },
            onClose: { [weak self] in
                self?.hide()
            }
        ))
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.center()
        panel.orderFrontRegardless()
        cardPanel = panel
    }

    func hide() {
        cardPanel?.orderOut(nil)
        cardPanel = nil
    }
}

private struct LessonShareCardPanelView: View {
    let cardContent: LessonShareCardContent
    let onRevealFile: () -> Void
    let onClose: () -> Void

    @State private var isRevealButtonHovered = false
    @State private var isCloseButtonHovered = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            LessonShareCardView(cardContent: cardContent)

            HStack(spacing: 8) {
                Button(action: onRevealFile) {
                    Text("show file")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isRevealButtonHovered ? DS.Colors.accentHover : DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .onHover { isRevealButtonHovered = $0 }

                Button(action: onClose) {
                    Text("done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isCloseButtonHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .onHover { isCloseButtonHovered = $0 }
            }
        }
        .padding(16)
    }
}
