//
//  StuckOfferViews.swift
//  leanring-buddy
//
//  The two surfaces of an offer. The pill is the only part of Stuck that takes
//  clicks: the overlay is click-through, so it gets its own panel. That panel
//  is non-activating and can never become key, because an offer that moved
//  keyboard focus away from Blender would be the very interruption it's trying
//  not to be. The flash is the visible receipt for the one screenshot.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Offer Panel

/// Accepts the first click without the app activating. Blender stays frontmost.
private final class StuckOfferHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class StuckNonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StuckOfferPillModel: ObservableObject {
    enum Stage {
        case hidden
        case asking
        case acknowledgingDecline
    }

    @Published var stage: Stage = .hidden
    @Published var remainingFraction: Double = 1
    @Published var isPointerInside = false
    var growsFromLeadingEdge = true
    var screenshotDestinationName = "the model provider"
    var onAccept: () -> Void = {}
    var onDecline: () -> Void = {}
}

@MainActor
final class StuckOfferPanelManager {
    static let pillPanelSize = CGSize(width: 272, height: 62)

    private(set) var panel: NSPanel?
    private let pillModel = StuckOfferPillModel()
    private var hideOrderOutTask: Task<Void, Never>?

    var isPointerOverOffer: Bool {
        pillModel.isPointerInside
    }

    func setRemainingFraction(_ remainingFraction: Double) {
        pillModel.remainingFraction = remainingFraction
    }

    func showOffer(
        pillOrigin: CGPoint,
        growsFromLeadingEdge: Bool,
        screenshotDestinationName: String,
        onAccept: @escaping () -> Void,
        onDecline: @escaping () -> Void
    ) {
        hideOrderOutTask?.cancel()

        pillModel.growsFromLeadingEdge = growsFromLeadingEdge
        pillModel.screenshotDestinationName = screenshotDestinationName
        pillModel.onAccept = onAccept
        pillModel.onDecline = onDecline
        pillModel.remainingFraction = 1
        pillModel.isPointerInside = false

        let offerPanel = panel ?? makePanel()
        panel = offerPanel
        offerPanel.setFrameOrigin(pillOrigin)
        offerPanel.orderFrontRegardless()

        // A tick later, so the view mounts hidden and has something to animate from.
        DispatchQueue.main.async { [pillModel] in
            pillModel.stage = .asking
        }
    }

    func showDeclineAcknowledgement() {
        pillModel.stage = .acknowledgingDecline
    }

    func hideOffer() {
        pillModel.stage = .hidden
        pillModel.isPointerInside = false

        hideOrderOutTask?.cancel()
        hideOrderOutTask = Task { [weak self] in
            // Long enough for the fade below to finish.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let offerPanel = StuckNonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        offerPanel.isFloatingPanel = true
        // Same level as the overlay, so the pill can't end up behind the buddy.
        offerPanel.level = .screenSaver
        offerPanel.isOpaque = false
        offerPanel.backgroundColor = .clear
        offerPanel.hasShadow = false
        offerPanel.hidesOnDeactivate = false
        offerPanel.isExcludedFromWindowsMenu = true
        offerPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        offerPanel.isMovable = false
        offerPanel.becomesKeyOnlyIfNeeded = true

        let hostingView = StuckOfferHostingView(rootView: StuckOfferPillView(pillModel: pillModel))
        hostingView.frame = NSRect(origin: .zero, size: Self.pillPanelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        offerPanel.contentView = hostingView
        return offerPanel
    }
}

// MARK: - Offer Pill

/// "want a hand?", arriving one letter at a time like a thought, and quietly
/// leaving by itself. A hairline along the bottom shows how long it'll stay.
struct StuckOfferPillView: View {
    @ObservedObject var pillModel: StuckOfferPillModel

    private let offerText = "want a hand?"
    private let declineAcknowledgementText = "ok, i'll back off"

    private var isVisible: Bool {
        pillModel.stage != .hidden
    }

    private var isAsking: Bool {
        pillModel.stage == .asking
    }

    private var growthAnchor: UnitPoint {
        pillModel.growsFromLeadingEdge ? .leading : .trailing
    }

    var body: some View {
        ZStack(alignment: pillModel.growsFromLeadingEdge ? .leading : .trailing) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    ZStack(alignment: .leading) {
                        StuckLetterRevealText(text: offerText, isRevealed: isAsking)
                        StuckLetterRevealText(text: declineAcknowledgementText, isRevealed: pillModel.stage == .acknowledgingDecline)
                    }

                    Text(disclosureText)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.46))
                        .opacity(isAsking ? 1 : 0)
                        .animation(.easeOut(duration: 0.4).delay(isAsking ? 0.42 : 0), value: isAsking)
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    pillButton(title: "nah", isPrimary: false, action: pillModel.onDecline)
                    pillButton(title: "yes", isPrimary: true, action: pillModel.onAccept)
                }
                .opacity(isAsking ? 1 : 0)
                .offset(x: isAsking ? 0 : 6)
                .animation(.easeOut(duration: 0.36).delay(isAsking ? 0.34 : 0), value: isAsking)
                .allowsHitTesting(isAsking)
            }
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .padding(.vertical, 9)
            .frame(width: StuckOfferPanelManager.pillPanelSize.width - 12)
            .background(pillBackground)
            .overlay(alignment: .bottom) { remainingTimeHairline }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS.Colors.overlayCursorBlue.opacity(pillModel.isPointerInside ? 0.75 : 0.34), lineWidth: 1)
                    .animation(.easeOut(duration: 0.18), value: pillModel.isPointerInside)
            )
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(pillModel.isPointerInside ? 0.36 : 0.18), radius: 14)
            .onHover { isPointerInside in
                pillModel.isPointerInside = isPointerInside
            }
        }
        .frame(width: StuckOfferPanelManager.pillPanelSize.width, height: StuckOfferPanelManager.pillPanelSize.height)
        .scaleEffect(isVisible ? 1 : 0.9, anchor: growthAnchor)
        .opacity(isVisible ? 1 : 0)
        .blur(radius: isVisible ? 0 : 5)
        .animation(isVisible ? .spring(response: 0.5, dampingFraction: 0.82) : .easeIn(duration: 0.28), value: isVisible)
    }

    private var disclosureText: String {
        pillModel.screenshotDestinationName == "this mac"
            ? "yes takes 1 screenshot, stays on this mac"
            : "yes sends 1 screenshot to \(pillModel.screenshotDestinationName)"
    }

    private var pillBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(hex: "#14171C").opacity(0.96))
    }

    private var remainingTimeHairline: some View {
        GeometryReader { hairlineGeometry in
            Capsule()
                .fill(DS.Colors.overlayCursorBlue.opacity(0.75))
                .frame(width: hairlineGeometry.size.width * pillModel.remainingFraction, height: 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 1.5)
        .opacity(isAsking ? 1 : 0)
    }

    private func pillButton(title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        StuckPillButton(title: title, isPrimary: isPrimary, action: action)
    }
}

private struct StuckPillButton: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isPrimary ? .white : Color.white.opacity(isHovering ? 0.92 : 0.58))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isPrimary
                              ? DS.Colors.overlayCursorBlue.opacity(isHovering ? 1 : 0.86)
                              : Color.white.opacity(isHovering ? 0.12 : 0))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

/// Each letter fades and rises a little after the one before it.
private struct StuckLetterRevealText: View {
    let text: String
    let isRevealed: Bool

    private let delayPerLetterInSeconds = 0.022

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { letterIndex, letter in
                Text(String(letter))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .opacity(isRevealed ? 1 : 0)
                    .offset(y: isRevealed ? 0 : 4)
                    .animation(
                        isRevealed
                            ? .easeOut(duration: 0.3).delay(Double(letterIndex) * delayPerLetterInSeconds)
                            : .easeIn(duration: 0.14),
                        value: isRevealed
                    )
            }
        }
    }
}

// MARK: - Capture Flash

@MainActor
final class StuckCaptureFlashModel: ObservableObject {
    @Published var edgeGlowOpacity: Double = 0
    @Published var isChipVisible = false
    var screenshotDestinationName = "the model provider"
}

/// A blue breath around the edges of the screen, and a chip saying what was
/// just taken and where it's going. Own windows are excluded from capture, so
/// the flash can't end up in the screenshot.
@MainActor
final class StuckCaptureFlashManager {
    private(set) var panel: NSPanel?
    private let flashModel = StuckCaptureFlashModel()
    private var flashSequenceTask: Task<Void, Never>?

    private static let edgeGlowFadeInSeconds = 0.12
    private static let edgeGlowHoldSeconds = 0.34
    private static let edgeGlowFadeOutSeconds = 0.6
    /// Long enough to actually read the destination.
    private static let chipVisibleSeconds = 3.4

    func showFlash(on screen: NSScreen, screenshotDestinationName: String) {
        flashModel.screenshotDestinationName = screenshotDestinationName

        let flashPanel = panel ?? makePanel()
        panel = flashPanel
        flashPanel.setFrame(screen.frame, display: false)
        flashPanel.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
        flashPanel.orderFrontRegardless()

        flashSequenceTask?.cancel()
        flashSequenceTask = Task { [flashModel] in
            withAnimation(.easeOut(duration: Self.edgeGlowFadeInSeconds)) {
                flashModel.edgeGlowOpacity = 1
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                flashModel.isChipVisible = true
            }

            try? await Task.sleep(nanoseconds: UInt64((Self.edgeGlowFadeInSeconds + Self.edgeGlowHoldSeconds) * 1_000_000_000))
            withAnimation(.easeIn(duration: Self.edgeGlowFadeOutSeconds)) {
                flashModel.edgeGlowOpacity = 0
            }

            try? await Task.sleep(nanoseconds: UInt64(Self.chipVisibleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) {
                flashModel.isChipVisible = false
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let flashPanel = StuckNonActivatingPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        flashPanel.level = .screenSaver
        flashPanel.isOpaque = false
        flashPanel.backgroundColor = .clear
        flashPanel.hasShadow = false
        flashPanel.ignoresMouseEvents = true
        flashPanel.hidesOnDeactivate = false
        flashPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        flashPanel.contentView = NSHostingView(rootView: StuckCaptureFlashView(flashModel: flashModel))
        return flashPanel
    }
}

struct StuckCaptureFlashView: View {
    @ObservedObject var flashModel: StuckCaptureFlashModel

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DS.Colors.overlayCursorBlue, lineWidth: 14)
                .blur(radius: 16)
                .opacity(flashModel.edgeGlowOpacity)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                .opacity(flashModel.edgeGlowOpacity)

            chip
                .padding(.top, 44)
                .opacity(flashModel.isChipVisible ? 1 : 0)
                .offset(y: flashModel.isChipVisible ? 0 : -10)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var chipText: String {
        flashModel.screenshotDestinationName == "this mac"
            ? "1 screenshot, staying on this mac"
            : "1 screenshot, just this once, going to \(flashModel.screenshotDestinationName)"
    }

    private var chip: some View {
        HStack(spacing: 7) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.overlayCursorBlue)

            Text(chipText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(hex: "#14171C").opacity(0.96))
        )
        .overlay(
            Capsule()
                .stroke(DS.Colors.overlayCursorBlue.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.3), radius: 12)
    }
}
