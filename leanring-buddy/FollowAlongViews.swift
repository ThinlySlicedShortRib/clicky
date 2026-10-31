//
//  FollowAlongViews.swift
//  leanring-buddy
//
//  The three Follow Along surfaces: the paste pill next to the cursor, the
//  live meter during a lesson, and the end card. All of them are lowercase and
//  small on purpose, so the app being taught stays the main thing on screen.
//  Their windows belong to Clicky, so screenshots of the user's screen exclude
//  them and they can never trigger a success check.
//

import AppKit
import SwiftUI

// MARK: - Paste Surface

struct FollowAlongPasteSurfaceView: View {
    @ObservedObject var coordinator: FollowAlongCoordinator
    @FocusState private var isLinkFieldFocused: Bool

    static let surfaceWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Triangle()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(-35))
                    .shadow(color: DS.Colors.overlayCursorBlue, radius: 5)

                switch coordinator.phase {
                case .importing(let statusText):
                    Text(statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ProgressView()
                        .controlSize(.small)
                        .tint(DS.Colors.overlayCursorBlue)
                default:
                    TextField("paste a youtube tutorial", text: $coordinator.pastedLinkText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .focused($isLinkFieldFocused)
                        .onSubmit { coordinator.submitPastedLink() }
                }
            }

            if case .failed(let message) = coordinator.phase {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: Self.surfaceWidth, alignment: .leading)
        .background(FollowAlongSurfaceBackground(cornerRadius: 14))
        .onAppear { isLinkFieldFocused = true }
    }
}

// MARK: - Live Meter

struct FollowAlongHUDView: View {
    @ObservedObject var coordinator: FollowAlongCoordinator

    static let surfaceWidth: CGFloat = 262

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let runProgress = coordinator.runProgress {
                HStack(spacing: 6) {
                    Circle()
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(width: 6, height: 6)
                        .shadow(color: DS.Colors.overlayCursorBlue, radius: 3)
                    Text("step \(runProgress.stepNumber) of \(runProgress.stepCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(runProgress.stepTitle)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                let snapshot = runProgress.costSnapshot

                HStack(alignment: .firstTextBaseline) {
                    Text(FollowAlongCostFormatting.costText(snapshot.totalCostInUSD, isEstimated: snapshot.isCostEstimated))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("this lesson")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer(minLength: 0)
                }

                meterRow(label: "model calls", value: "\(snapshot.modelCallCount)")
                meterRow(label: "screens looked at / sent", value: "\(snapshot.screensLookedAt) / \(snapshot.screensSentToModel)")
                meterRow(label: "cached steps reused", value: "\(snapshot.cachedStepsReused)")
                meterRow(
                    label: "looking every second",
                    value: FollowAlongCostFormatting.costText(snapshot.naiveEstimatedCostInUSD, isEstimated: true)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.surfaceWidth, alignment: .leading)
        .background(FollowAlongSurfaceBackground(cornerRadius: 12))
    }

    private func meterRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(DS.Colors.textSecondary)
        }
    }
}

// MARK: - End Card

struct FollowAlongEndCardView: View {
    @ObservedObject var coordinator: FollowAlongCoordinator

    static let surfaceWidth: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .finished(let summary) = coordinator.phase {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.finishedEveryStep ? "you did it." : "good place to stop.")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(summary.lessonTitle)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                if let failureMessage = summary.failureMessage {
                    Text(failureMessage)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                bulletSection(title: "what you learned", lines: summary.whatYouLearned)

                if !summary.adaptations.isEmpty {
                    bulletSection(
                        title: "what changed since the video",
                        lines: summary.adaptations.map(\.whatChanged)
                    )
                }

                costSection(summary: summary)

                Button(action: { coordinator.dismissEndCard() }) {
                    Text("done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(18)
        .frame(width: Self.surfaceWidth, alignment: .leading)
        .background(FollowAlongSurfaceBackground(cornerRadius: 16))
    }

    private func bulletSection(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(width: 4, height: 4)
                        .alignmentGuide(.firstTextBaseline) { _ in 6 }
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func costSection(summary: FollowAlongRunSummary) -> some View {
        let snapshot = summary.costSnapshot

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                statBlock(value: FollowAlongCostFormatting.durationText(seconds: snapshot.elapsedInSeconds), label: "time")
                statBlock(
                    value: FollowAlongCostFormatting.costText(snapshot.totalCostInUSD, isEstimated: snapshot.isCostEstimated),
                    label: "total cost"
                )
                statBlock(value: "\(snapshot.modelCallCount)", label: "model calls")
            }

            Text(naiveComparisonText(snapshot: snapshot))
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(DS.Colors.textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private func naiveComparisonText(snapshot: FollowAlongCostSnapshot) -> String {
        let reuseNote = snapshot.isLessonPlanCached ? "lesson plan reused from cache." : "includes building the lesson once."
        guard let naiveEstimatedCostInUSD = snapshot.naiveEstimatedCostInUSD else {
            return "\(reuseNote) no reported cost to compare against."
        }
        let naiveCostText = FollowAlongCostFormatting.costText(naiveEstimatedCostInUSD, isEstimated: true)
        let floorCostText = FollowAlongCostFormatting.costText(snapshot.naiveFloorEstimatedCostInUSD, isEstimated: true)
        return "\(reuseNote) looking every second would be about \(naiveCostText) for \(snapshot.naiveCallCount) calls at this lesson's real per-look cost, or \(floorCostText) even on the cheapest model."
    }
}

// MARK: - Shared Background

private struct FollowAlongSurfaceBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(DS.Colors.background)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 8)
    }
}

// MARK: - Windows

/// Non-activating so the app being taught keeps focus, but able to become key
/// so the link field can take typing.
final class FollowAlongKeyablePanel: NSPanel {
    var onPasteRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// A menu bar-only app has no Edit menu to route Command+V through, so a
    /// paste has to be caught here or it would do nothing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCommandV = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
        if isCommandV, let onPasteRequested {
            onPasteRequested()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancelRequested?()
    }
}

@MainActor
final class FollowAlongSurfaceManager {
    private unowned let coordinator: FollowAlongCoordinator

    private var pastePanel: FollowAlongKeyablePanel?
    private var hudPanel: NSPanel?
    private var endCardPanel: NSPanel?

    private static let distanceFromMouse: CGFloat = 26
    private static let hudMarginFromScreenEdge: CGFloat = 16

    init(coordinator: FollowAlongCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: Paste

    func showPasteSurface() {
        if pastePanel == nil {
            let panel = FollowAlongKeyablePanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            configure(panel: panel)
            panel.level = .statusBar
            panel.contentView = makeHostingView(FollowAlongPasteSurfaceView(coordinator: coordinator))
            panel.onPasteRequested = { [weak self] in self?.pasteClipboardIntoLinkField() }
            panel.onCancelRequested = { [weak self] in self?.coordinator.dismissPasteSurface() }
            pastePanel = panel
        }

        guard let pastePanel else { return }
        fitToContent(pastePanel)
        pastePanel.setFrameOrigin(originNextToMouse(panelSize: pastePanel.frame.size))
        pastePanel.makeKeyAndOrderFront(nil)
        pastePanel.orderFrontRegardless()
    }

    func hidePasteSurface() {
        pastePanel?.orderOut(nil)
    }

    /// An error line makes the pill taller after it opened. Waits a turn so
    /// SwiftUI has laid the new content out, and keeps the top edge in place.
    func refitPasteSurface() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let pastePanel = self.pastePanel, let fittingSize = pastePanel.contentView?.fittingSize else { return }
            let topEdge = pastePanel.frame.maxY
            pastePanel.setContentSize(fittingSize)
            pastePanel.setFrameOrigin(CGPoint(x: pastePanel.frame.minX, y: topEdge - fittingSize.height))
        }
    }

    func pasteClipboardIntoLinkField(from pasteboard: NSPasteboard = .general) {
        guard let clipboardText = pasteboard.string(forType: .string) else { return }
        coordinator.pastedLinkText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func originNextToMouse(panelSize: CGSize) -> CGPoint {
        let mouseLocation = NSEvent.mouseLocation
        let visibleFrame = NSScreen.screens.first { $0.frame.contains(mouseLocation) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero

        let preferredOrigin = CGPoint(
            x: mouseLocation.x + Self.distanceFromMouse,
            y: mouseLocation.y - panelSize.height - Self.distanceFromMouse
        )
        return CGPoint(
            x: max(visibleFrame.minX, min(preferredOrigin.x, visibleFrame.maxX - panelSize.width)),
            y: max(visibleFrame.minY, min(preferredOrigin.y, visibleFrame.maxY - panelSize.height))
        )
    }

    // MARK: Live Meter

    func showHUD() {
        if hudPanel == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            configure(panel: panel)
            panel.level = .statusBar
            // It's a readout. A click on it should reach the app underneath.
            panel.ignoresMouseEvents = true
            panel.contentView = makeHostingView(FollowAlongHUDView(coordinator: coordinator))
            hudPanel = panel
        }

        guard let hudPanel, let visibleFrame = NSScreen.main?.visibleFrame else { return }
        fitToContent(hudPanel)
        hudPanel.setFrameOrigin(CGPoint(
            x: visibleFrame.minX + Self.hudMarginFromScreenEdge,
            y: visibleFrame.minY + Self.hudMarginFromScreenEdge
        ))
        hudPanel.orderFrontRegardless()
    }

    func hideHUD() {
        hudPanel?.orderOut(nil)
    }

    // MARK: End Card

    func showEndCard() {
        let panel = endCardPanel ?? {
            let newPanel = FollowAlongKeyablePanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            configure(panel: newPanel)
            newPanel.level = .statusBar
            newPanel.onCancelRequested = { [weak self] in self?.coordinator.dismissEndCard() }
            return newPanel
        }()
        endCardPanel = panel

        // Rebuilt each time: the card's height depends on this run's content.
        panel.contentView = makeHostingView(FollowAlongEndCardView(coordinator: coordinator))
        fitToContent(panel)

        if let visibleFrame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: visibleFrame.midX - panel.frame.width / 2,
                y: visibleFrame.midY - panel.frame.height / 2
            ))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hideEndCard() {
        endCardPanel?.orderOut(nil)
    }

    // MARK: Shared

    private func configure(panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private func makeHostingView<Content: View>(_ rootView: Content) -> NSView {
        // Padding leaves room for the shadow inside the transparent window.
        let hostingView = NSHostingView(rootView: rootView.padding(20))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        return hostingView
    }

    private func fitToContent(_ panel: NSPanel) {
        guard let fittingSize = panel.contentView?.fittingSize else { return }
        panel.setContentSize(fittingSize)
    }
}
