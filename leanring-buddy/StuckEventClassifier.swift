//
//  StuckEventClassifier.swift
//  leanring-buddy
//
//  Turns a raw event from the listen-only tap into a StuckBehaviourEventKind,
//  and this is where the privacy promise is enforced: a key press becomes one
//  of four categories and the key code is never stored or passed on. Pointer
//  positions become a 160pt tile. The tap's raw CGEvent goes no further.
//
//  Only CoreGraphics, so stuck-harness/ can check it with real CGEvent objects.
//

import CoreGraphics

/// Stateful only for what it takes to tell a click from a drag and measure
/// movement. It holds the last pointer position for that and nothing else.
struct StuckEventClassifier {
    /// Key codes are read to recognise exactly these three keys. Every other
    /// key takes the anonymous path without its code going anywhere.
    private static let zKeyCode: Int64 = 6
    private static let tabKeyCode: Int64 = 48
    private static let escapeKeyCode: Int64 = 53

    /// Coarse enough that an area says "somewhere in the middle of the
    /// screen", not what's under the cursor.
    static let coarseAreaSizeInPoints: Double = 160

    /// A press that travels less than this is a click.
    private static let minimumDragDistanceInPoints: Double = 20

    private var lastPointerLocation: CGPoint?
    private var distanceTravelledWhileButtonDown: Double = 0
    private var isButtonDown = false
    private var buttonDownCoarseAreaIdentifier: Int?

    /// Identifies a screen tile as one integer, so nothing downstream can
    /// recover a position any finer than that tile.
    static func coarseAreaIdentifier(for location: CGPoint) -> Int {
        let tileColumn = Int((Double(location.x) / coarseAreaSizeInPoints).rounded(.down))
        let tileRow = Int((Double(location.y) / coarseAreaSizeInPoints).rounded(.down))
        return tileColumn * 1_000 + tileRow
    }

    mutating func classify(
        eventType: CGEventType,
        keyCode: Int64,
        modifierFlags: CGEventFlags,
        isAutorepeat: Bool,
        pointerLocation: CGPoint
    ) -> StuckBehaviourEventKind? {
        switch eventType {
        case .keyDown:
            return Self.classifyKeyDown(keyCode: keyCode, modifierFlags: modifierFlags, isAutorepeat: isAutorepeat)

        case .leftMouseDown, .rightMouseDown:
            isButtonDown = true
            distanceTravelledWhileButtonDown = 0
            buttonDownCoarseAreaIdentifier = Self.coarseAreaIdentifier(for: pointerLocation)
            lastPointerLocation = pointerLocation
            return nil

        case .leftMouseUp, .rightMouseUp:
            defer {
                isButtonDown = false
                buttonDownCoarseAreaIdentifier = nil
            }
            guard isButtonDown else { return nil }
            if distanceTravelledWhileButtonDown >= Self.minimumDragDistanceInPoints {
                return .dragFinished
            }
            return .click(coarseAreaIdentifier: buttonDownCoarseAreaIdentifier ?? Self.coarseAreaIdentifier(for: pointerLocation))

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let previousPointerLocation = lastPointerLocation ?? pointerLocation
            let deltaX = Double(pointerLocation.x - previousPointerLocation.x)
            let deltaY = Double(pointerLocation.y - previousPointerLocation.y)
            let distanceInPoints = (deltaX * deltaX + deltaY * deltaY).squareRoot()
            lastPointerLocation = pointerLocation
            if isButtonDown {
                distanceTravelledWhileButtonDown += distanceInPoints
            }
            return .pointerMovement(
                distanceInPoints: distanceInPoints,
                coarseAreaIdentifier: Self.coarseAreaIdentifier(for: pointerLocation)
            )

        case .scrollWheel:
            return .scrollTick

        default:
            return nil
        }
    }

    /// Autorepeat is dropped entirely: holding a key isn't a repeated attempt.
    private static func classifyKeyDown(
        keyCode: Int64,
        modifierFlags: CGEventFlags,
        isAutorepeat: Bool
    ) -> StuckBehaviourEventKind? {
        guard !isAutorepeat else { return nil }

        let hasCommandOrControl = modifierFlags.contains(.maskCommand) || modifierFlags.contains(.maskControl)
        let hasShift = modifierFlags.contains(.maskShift)

        if keyCode == zKeyCode && hasCommandOrControl {
            return hasShift ? .redo : .undo
        }
        if keyCode == escapeKeyCode {
            return .cancel
        }
        if keyCode == tabKeyCode && !hasCommandOrControl {
            return .modeToggle
        }
        return .anonymousKeyPress
    }
}
