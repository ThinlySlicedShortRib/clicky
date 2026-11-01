//
//  StuckReceiptView.swift
//  leanring-buddy
//
//  The privacy receipt: exactly what Clicky holds right now, printed on a
//  little strip of thermal paper. It's built only from the detector's memory,
//  so it can't show less than Clicky knows, and the measured numbers come from
//  the kernel via StuckProcessProbe rather than from anything Clicky promises.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Panel

/// Floats above everything without taking focus, and stays until closed.
@MainActor
final class StuckReceiptPanelManager {
    private var panel: NSPanel?
    private unowned let stuckCompanion: StuckCompanion

    private var contentChangeCancellable: AnyCancellable?

    private let panelWidth: CGFloat = 318

    init(stuckCompanion: StuckCompanion) {
        self.stuckCompanion = stuckCompanion
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let receiptPanel = panel ?? makePanel()
        panel = receiptPanel

        if let screen = NSScreen.main {
            let fittingHeight = receiptPanel.contentView?.fittingSize.height ?? 520
            let edgeMargin: CGFloat = 16
            receiptPanel.setFrame(
                NSRect(
                    x: screen.visibleFrame.maxX - panelWidth - edgeMargin,
                    y: screen.visibleFrame.maxY - fittingHeight - edgeMargin,
                    width: panelWidth,
                    height: fittingHeight
                ),
                display: true
            )
        }

        receiptPanel.orderFrontRegardless()

        // Lines come and go as memory changes, so the paper has to follow.
        contentChangeCancellable = stuckCompanion.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.fitPanelToContent()
            }
    }

    func hide() {
        contentChangeCancellable = nil
        panel?.orderOut(nil)
    }

    /// Keeps the top edge still, so it reads as paper feeding out of the top.
    private func fitPanelToContent() {
        guard let panel, let fittingHeight = panel.contentView?.fittingSize.height,
              abs(fittingHeight - panel.frame.height) >= 1 else { return }

        panel.setFrame(
            NSRect(
                x: panel.frame.minX,
                y: panel.frame.maxY - fittingHeight,
                width: panelWidth,
                height: fittingHeight
            ),
            display: true
        )
    }

    private func makePanel() -> NSPanel {
        let receiptPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        receiptPanel.isFloatingPanel = true
        receiptPanel.level = .floating
        receiptPanel.isOpaque = false
        receiptPanel.backgroundColor = .clear
        receiptPanel.hasShadow = true
        receiptPanel.hidesOnDeactivate = false
        receiptPanel.isExcludedFromWindowsMenu = true
        receiptPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        receiptPanel.isMovableByWindowBackground = true

        let hostingView = NSHostingView(rootView: StuckReceiptView(
            stuckCompanion: stuckCompanion,
            onClose: { [weak self] in self?.hide() }
        ).frame(width: panelWidth))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        receiptPanel.contentView = hostingView
        return receiptPanel
    }
}

// MARK: - Receipt

/// Paper colours rather than the app's dark theme, because this should look
/// like something handed to you, not another settings screen.
private enum ReceiptPalette {
    static let paper = Color(hex: "#F5F2EA")
    static let ink = Color(hex: "#1C1B19")
    static let fadedInk = Color(hex: "#1C1B19").opacity(0.58)
    static let faintInk = Color(hex: "#1C1B19").opacity(0.2)
    static let reassuringGreen = Color(hex: "#2C7A4B")
    static let warningRed = Color(hex: "#B23A2E")
}

private enum ReceiptFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct StuckReceiptView: View {
    @ObservedObject var stuckCompanion: StuckCompanion
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            dashedRule
            knowledgeSection
            dashedRule
            offerProgressSection
            dashedRule
            measuredSection
            dashedRule
            cannotSeeSection
            forgetButton
                .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 26)
        .background(ReceiptPaperShape().fill(ReceiptPalette.paper))
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 5)
        .padding(8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("clicky's receipt")
                    .font(ReceiptFont.mono(14, weight: .bold))
                    .foregroundColor(ReceiptPalette.ink)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(ReceiptPalette.fadedInk)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(ReceiptFont.mono(10.5))
                    .foregroundColor(ReceiptPalette.fadedInk)
            }
        }
        .padding(.bottom, 10)
    }

    private var statusColor: Color {
        switch stuckCompanion.watchingStatus {
        case .watching: return ReceiptPalette.reassuringGreen
        case .tapWithheldByMacOS, .needsPermission: return ReceiptPalette.warningRed
        case .off: return ReceiptPalette.faintInk
        }
    }

    private var statusText: String {
        switch stuckCompanion.watchingStatus {
        case .watching: return "noticing timing, nothing else"
        case .tapWithheldByMacOS: return "can't see undos yet, needs input monitoring"
        case .needsPermission: return "off until input monitoring is granted"
        case .off: return "off. not listening to anything."
        }
    }

    private var dashedRule: some View {
        Line()
            .stroke(ReceiptPalette.faintInk, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(ReceiptFont.mono(9.5, weight: .semibold))
            .foregroundColor(ReceiptPalette.fadedInk)
            .padding(.bottom, 5)
    }

    // MARK: Knowledge

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("WHAT I KNOW RIGHT NOW")
                Spacer()
                sectionTitle("WIPED IN")
            }

            if stuckCompanion.receiptLines.isEmpty {
                Text("nothing. my memory is empty.")
                    .font(ReceiptFont.mono(11.5))
                    .foregroundColor(ReceiptPalette.fadedInk)
                    .transition(.opacity)
            } else {
                ForEach(stuckCompanion.receiptLines, id: \.text) { receiptLine in
                    knowledgeRow(receiptLine)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .trailing))))
                }
            }

            Text("in memory only. 2 minutes, then gone.")
                .font(ReceiptFont.mono(9.5))
                .foregroundColor(ReceiptPalette.fadedInk)
                .padding(.top, 3)
        }
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.25), value: stuckCompanion.receiptLines.map(\.text))
    }

    private func knowledgeRow(_ receiptLine: StuckReceiptLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(receiptLine.text)
                .font(ReceiptFont.mono(11.5, weight: .medium))
                .foregroundColor(ReceiptPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Text(Self.formatRemainingTime(receiptLine.secondsUntilWiped))
                .font(ReceiptFont.mono(10.5))
                .foregroundColor(ReceiptPalette.fadedInk)
                .monospacedDigit()
        }
    }

    private static func formatRemainingTime(_ seconds: Double) -> String {
        let wholeSeconds = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }

    // MARK: Progress Towards An Offer

    private var offerProgressSection: some View {
        let score = stuckCompanion.currentAssessment?.score ?? 0
        let threshold = stuckCompanion.effectiveOfferThreshold
        let progress = min(score / threshold, 1)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("HOW CLOSE I AM TO OFFERING")
                Spacer()
                sectionTitle("\(Int(score)) / \(Int(threshold))")
            }

            GeometryReader { barGeometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(ReceiptPalette.faintInk)
                    Capsule()
                        .fill(ReceiptPalette.ink)
                        .frame(width: barGeometry.size.width * progress)
                        .animation(.easeOut(duration: 0.5), value: progress)
                }
            }
            .frame(height: 4)
            .padding(.bottom, 3)

            ForEach(stuckCompanion.currentAssessment?.signals ?? [], id: \.kind) { signalReading in
                scoreLine(signalReading.humanReadableDescription, points: "+\(Int(signalReading.points))")
            }
            ForEach(stuckCompanion.currentAssessment?.flowPenalties ?? [], id: \.humanReadableDescription) { penaltyReading in
                scoreLine(penaltyReading.humanReadableDescription, points: "-\(Int(penaltyReading.points))")
            }

            if stuckCompanion.thresholdMultiplier > 1 {
                HStack(spacing: 6) {
                    Text("you've told me to back off (\(String(format: "%.1f", stuckCompanion.thresholdMultiplier))x)")
                        .font(ReceiptFont.mono(9.5))
                        .foregroundColor(ReceiptPalette.fadedInk)
                    Button("reset") {
                        stuckCompanion.resetLearning()
                    }
                    .buttonStyle(.plain)
                    .font(ReceiptFont.mono(9.5, weight: .semibold))
                    .foregroundColor(ReceiptPalette.ink)
                    .pointerCursor()
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
    }

    private func scoreLine(_ description: String, points: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(description)
                .font(ReceiptFont.mono(10))
                .foregroundColor(ReceiptPalette.fadedInk)
            Spacer(minLength: 4)
            Text(points)
                .font(ReceiptFont.mono(10, weight: .medium))
                .foregroundColor(ReceiptPalette.ink)
        }
    }

    // MARK: Measured

    private var measuredSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("MEASURED FROM THE KERNEL, JUST NOW")
            measuredRow("network sockets", value: "\(stuckCompanion.measuredInternetSocketCount)")
            measuredRow(
                "bytes written",
                value: stuckCompanion.measuredBytesWrittenSinceEnabled.map(String.init) ?? "-"
            )
            measuredRow("screenshots taken", value: "\(stuckCompanion.screenshotsTakenCount)")
        }
        .padding(.vertical, 10)
    }

    private func measuredRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(ReceiptFont.mono(11))
                .foregroundColor(ReceiptPalette.ink)
            Line()
                .stroke(ReceiptPalette.faintInk, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                .frame(height: 1)
            Text(value)
                .font(ReceiptFont.mono(11.5, weight: .bold))
                .foregroundColor(ReceiptPalette.ink)
                .monospacedDigit()
        }
    }

    // MARK: Can't See

    private var cannotSeeSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionTitle("WHAT I NEVER KEEP")
            Text("your screen, text, which keys you press, window titles, app names.")
                .font(ReceiptFont.mono(10))
                .foregroundColor(ReceiptPalette.fadedInk)
                .fixedSize(horizontal: false, vertical: true)
            Text("saying yes is the only way a screenshot happens. that one goes to \(helpDestinationText).")
                .font(ReceiptFont.mono(10))
                .foregroundColor(ReceiptPalette.fadedInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(.top, 10)
    }

    private var helpDestinationText: String {
        stuckCompanion.usesLocalBrain ? "a model on this mac" : "the model provider, with this list"
    }

    private var forgetButton: some View {
        StuckForgetNowButton {
            withAnimation(.easeOut(duration: 0.3)) {
                stuckCompanion.forgetNow()
            }
        }
    }
}

private struct StuckForgetNowButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("forget now")
                .font(ReceiptFont.mono(12, weight: .bold))
                .foregroundColor(ReceiptPalette.paper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ReceiptPalette.ink.opacity(isHovering ? 0.82 : 1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A rectangle with a torn zigzag bottom, like the end of a till roll.
private struct ReceiptPaperShape: Shape {
    private let toothWidth: CGFloat = 12
    private let toothHeight: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - toothHeight))

        var currentX = rect.maxX
        var isOnPeak = false
        while currentX > rect.minX {
            currentX = max(rect.minX, currentX - toothWidth / 2)
            path.addLine(to: CGPoint(x: currentX, y: isOnPeak ? rect.maxY - toothHeight : rect.maxY))
            isOnPeak.toggle()
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
