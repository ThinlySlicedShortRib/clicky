//
//  TeachInputCapture.swift
//  leanring-buddy
//
//  What teach mode is allowed to know about the teacher's input, and the code
//  that enforces it. Raw events go through TeachInputAccumulator, which has no
//  system dependencies, so the privacy rules can be tested without permissions:
//
//    - keys become counts per category, and characters are never stored
//    - nothing is kept while secure input is on, or for a click on a password
//      field, even if an app forgot to turn secure input on
//    - AXValue is never read, so field and cell contents can't leak this way
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// MARK: - Accessibility Reading

enum TeachAccessibilityReader {
    /// A toolbar button's label often lives on a parent, so a few levels are
    /// walked. Beyond that the name usually belongs to something else entirely.
    private static let maximumParentLevelsForName = 3

    static func string(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else {
            return nil
        }
        return attributeValue as? String
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &attributeValue) == .success,
              let parentValue = attributeValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(parentValue, to: AXUIElement.self)
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &attributeValue) == .success,
              let childrenArray = attributeValue as? [AnyObject] else {
            return []
        }
        return childrenArray.compactMap { childValue in
            guard CFGetTypeID(childValue) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(childValue, to: AXUIElement.self)
        }
    }

    /// Element bounds in global top-left points.
    static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        // CFGetTypeID has already proved these are AXValues.
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    static func element(atGlobalTopLeftPoint point: CGPoint) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &hitElement) == .success else {
            return nil
        }
        return hitElement
    }

    static func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &attributeValue) == .success,
              let focusedValue = attributeValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(focusedValue, to: AXUIElement.self)
    }

    static func isSecureField(_ element: AXUIElement) -> Bool {
        TeachInputPrivacyRules.isSecureField(
            role: string(kAXRoleAttribute, of: element),
            subrole: string(kAXSubroleAttribute, of: element)
        )
    }

    /// Reads names and role only. There's deliberately no AXValue here.
    static func snapshot(of element: AXUIElement, displayOriginInGlobalTopLeftPoints: CGPoint) -> TeachElementSnapshot {
        var nameSource = element
        var title = nonEmptyString(kAXTitleAttribute, of: nameSource)
        var accessibilityDescription = nonEmptyString(kAXDescriptionAttribute, of: nameSource)

        var parentLevel = 0
        while title == nil, accessibilityDescription == nil, parentLevel < maximumParentLevelsForName,
              let parentElement = parent(of: nameSource) {
            nameSource = parentElement
            parentLevel += 1
            title = nonEmptyString(kAXTitleAttribute, of: nameSource)
            accessibilityDescription = nonEmptyString(kAXDescriptionAttribute, of: nameSource)
        }

        let frameInDisplayPoints = frame(of: element).map { elementFrame in
            LessonRectangle(elementFrame.offsetBy(
                dx: -displayOriginInGlobalTopLeftPoints.x,
                dy: -displayOriginInGlobalTopLeftPoints.y
            ))
        }

        return TeachElementSnapshot(
            role: string(kAXRoleAttribute, of: element),
            subrole: string(kAXSubroleAttribute, of: element),
            title: title,
            accessibilityDescription: accessibilityDescription,
            helpText: nonEmptyString(kAXHelpAttribute, of: element),
            frameInDisplayPoints: frameInDisplayPoints
        )
    }

    private static func nonEmptyString(_ attributeName: String, of element: AXUIElement) -> String? {
        guard let value = string(attributeName, of: element),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

// MARK: - Privacy Rules

enum TeachInputPrivacyRules {
    private static let secureFieldRoleName = "AXSecureTextField"

    static func isSecureField(role: String?, subrole: String?) -> Bool {
        role == secureFieldRoleName || subrole == secureFieldRoleName
    }

    /// Any app showing a password box has it marked one of these two ways.
    /// Secure input also blocks event taps, but relying on that alone would
    /// trust every app to turn it on.
    static func isCaptureForbidden(isSecureInputEnabled: Bool, focusedRole: String?, focusedSubrole: String?) -> Bool {
        isSecureInputEnabled || isSecureField(role: focusedRole, subrole: focusedSubrole)
    }
}

// MARK: - Keystroke Categories

enum TeachKeystrokeCategory: Equatable {
    case letter
    case digit
    case punctuation
    case space
    case returnKey
    case tab
    case delete
    case arrow
    case escape
    case otherIgnored
    case shortcut(name: String)
}

enum TeachKeystrokeCategorizer {
    private static let letterNamesByKeyCode: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
        kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
        kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
        kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
        kVK_ANSI_Z: "z"
    ]

    private static let digitNamesByKeyCode: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9"
    ]

    private static let keypadDigitKeyCodes: Set<Int> = [
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9
    ]

    private static let punctuationKeyCodes: Set<Int> = [
        kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_RightBracket, kVK_ANSI_LeftBracket, kVK_ANSI_Quote,
        kVK_ANSI_Semicolon, kVK_ANSI_Backslash, kVK_ANSI_Comma, kVK_ANSI_Slash, kVK_ANSI_Period,
        kVK_ANSI_Grave, kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus,
        kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals
    ]

    static func category(forKeyCode keyCode: Int, isCommandHeld: Bool, isControlHeld: Bool) -> TeachKeystrokeCategory {
        if isCommandHeld || isControlHeld {
            // A shortcut's letter is the app's vocabulary, not the user's text,
            // so this is the one place a key's name is kept. Keys outside the
            // tables get no name, which means they're dropped.
            guard let keyName = letterNamesByKeyCode[keyCode] ?? digitNamesByKeyCode[keyCode] else {
                return .otherIgnored
            }
            return .shortcut(name: "\(isCommandHeld ? "command" : "control")+\(keyName)")
        }

        if letterNamesByKeyCode[keyCode] != nil { return .letter }
        if digitNamesByKeyCode[keyCode] != nil || keypadDigitKeyCodes.contains(keyCode) { return .digit }
        if punctuationKeyCodes.contains(keyCode) { return .punctuation }

        switch keyCode {
        case kVK_Space: return .space
        case kVK_Return, kVK_ANSI_KeypadEnter: return .returnKey
        case kVK_Tab: return .tab
        case kVK_Delete, kVK_ForwardDelete: return .delete
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow: return .arrow
        case kVK_Escape: return .escape
        default: return .otherIgnored
        }
    }

    static func add(_ category: TeachKeystrokeCategory, to keystrokeSummary: inout TeachKeystrokeSummary) {
        switch category {
        case .letter: keystrokeSummary.letterCount += 1
        case .digit: keystrokeSummary.digitCount += 1
        case .punctuation: keystrokeSummary.punctuationCount += 1
        case .space: keystrokeSummary.spaceCount += 1
        case .returnKey: keystrokeSummary.returnCount += 1
        case .tab: keystrokeSummary.tabCount += 1
        case .delete: keystrokeSummary.deleteCount += 1
        case .arrow: keystrokeSummary.arrowCount += 1
        case .escape: keystrokeSummary.escapeCount += 1
        case .shortcut(let name): keystrokeSummary.shortcutNames.append(name)
        case .otherIgnored: break
        }
    }
}

// MARK: - Input Accumulator

/// A low-level input event, already stripped of anything teach mode may not
/// keep. A keystroke arrives as a category, so characters never reach here.
enum TeachRawInputEvent {
    case mouseDown(locationInDisplayPoints: CGPoint, clickCount: Int, isRightButton: Bool, secondsFromStart: Double, context: TeachActionContext)
    case mouseUp(locationInDisplayPoints: CGPoint, secondsFromStart: Double)
    case keystroke(category: TeachKeystrokeCategory, secondsFromStart: Double, context: TeachActionContext)
    case secureInputChanged(isActive: Bool, secondsFromStart: Double)
}

/// What was under an event, read at the moment it happened.
struct TeachActionContext: Equatable {
    let applicationName: String?
    let applicationBundleIdentifier: String?
    let element: TeachElementSnapshot?
    let windowFrameInDisplayPoints: LessonRectangle?
    let isOverSecureField: Bool

    static let empty = TeachActionContext(
        applicationName: nil,
        applicationBundleIdentifier: nil,
        element: nil,
        windowFrameInDisplayPoints: nil,
        isOverSecureField: false
    )
}

/// Turns the event stream into recorded actions: a press and release become a
/// click or a drag, and runs of keys collapse into one typing action.
struct TeachInputAccumulator {
    /// Further than this between press and release counts as a drag. Below it,
    /// a slightly shaky hand is still a click.
    private static let minimumDragDistanceInPoints: CGFloat = 8
    /// A pause this long means the teacher finished typing that bit.
    private static let typingRunGapInSeconds = 1.5

    private struct PendingMousePress {
        let locationInDisplayPoints: CGPoint
        let clickCount: Int
        let isRightButton: Bool
        let secondsFromStart: Double
        let context: TeachActionContext
    }

    private struct PendingTypingRun {
        var keystrokeSummary = TeachKeystrokeSummary()
        let firstKeySecondsFromStart: Double
        var lastKeySecondsFromStart: Double
        let context: TeachActionContext
    }

    private(set) var actions: [TeachRecordedAction] = []
    private(set) var secureGaps: [TeachSecureGap] = []
    /// Counts every action finished, unlike `actions.count`, which stays flat
    /// when a double click replaces the single click before it.
    private var finishedActionCount = 0

    private var pendingMousePress: PendingMousePress?
    private var pendingTypingRun: PendingTypingRun?
    private var secureGapStartSeconds: Double?

    var isInsideSecureGap: Bool {
        secureGapStartSeconds != nil
    }

    /// Feeds one event in. Returns true when it finished a new action, which
    /// is when the caller attaches screenshots to it.
    @discardableResult
    mutating func ingest(_ rawEvent: TeachRawInputEvent) -> Bool {
        let finishedActionCountBeforeEvent = finishedActionCount

        switch rawEvent {
        case .secureInputChanged(let isActive, let secondsFromStart):
            handleSecureInputChange(isActive: isActive, secondsFromStart: secondsFromStart)

        case .mouseDown(let locationInDisplayPoints, let clickCount, let isRightButton, let secondsFromStart, let context):
            guard !isInsideSecureGap else { break }
            flushTypingRun()
            // A click on a password field teaches nothing worth the risk of
            // keeping what's around it.
            guard !context.isOverSecureField else { break }
            pendingMousePress = PendingMousePress(
                locationInDisplayPoints: locationInDisplayPoints,
                clickCount: clickCount,
                isRightButton: isRightButton,
                secondsFromStart: secondsFromStart,
                context: context
            )

        case .mouseUp(let locationInDisplayPoints, _):
            guard !isInsideSecureGap else { break }
            finishMousePress(releasedAt: locationInDisplayPoints)

        case .keystroke(let category, let secondsFromStart, let context):
            guard !isInsideSecureGap, !context.isOverSecureField else { break }
            appendKeystroke(category, secondsFromStart: secondsFromStart, context: context)
        }

        return finishedActionCount > finishedActionCountBeforeEvent
    }

    /// Call when recording stops, so a trailing typing run isn't lost and an
    /// open secure gap still gets its end recorded.
    @discardableResult
    mutating func finish(atSecondsFromStart secondsFromStart: Double) -> Bool {
        let finishedActionCountBeforeFinish = finishedActionCount
        flushTypingRun()
        pendingMousePress = nil
        if isInsideSecureGap {
            handleSecureInputChange(isActive: false, secondsFromStart: secondsFromStart)
        }
        return finishedActionCount > finishedActionCountBeforeFinish
    }

    mutating func attachFrames(toActionAtIndex actionIndex: Int, beforeFrameFileName: String?, afterFrameFileName: String?) {
        guard actions.indices.contains(actionIndex) else { return }
        actions[actionIndex].beforeFrameFileName = beforeFrameFileName
        actions[actionIndex].afterFrameFileName = afterFrameFileName
    }

    private mutating func handleSecureInputChange(isActive: Bool, secondsFromStart: Double) {
        if isActive, secureGapStartSeconds == nil {
            // Typing that led up to the password box could be its label or the
            // password itself in a badly built form, so it goes too.
            pendingTypingRun = nil
            pendingMousePress = nil
            secureGapStartSeconds = secondsFromStart
        } else if !isActive, let startSeconds = secureGapStartSeconds {
            secureGaps.append(TeachSecureGap(startSeconds: startSeconds, endSeconds: secondsFromStart))
            secureGapStartSeconds = nil
        }
    }

    private mutating func finishMousePress(releasedAt releaseLocation: CGPoint) {
        guard let mousePress = pendingMousePress else { return }
        pendingMousePress = nil

        let travelDistance = hypot(
            releaseLocation.x - mousePress.locationInDisplayPoints.x,
            releaseLocation.y - mousePress.locationInDisplayPoints.y
        )
        let isDrag = travelDistance >= Self.minimumDragDistanceInPoints

        let actionKind: TeachActionKind
        if isDrag {
            actionKind = .drag
        } else if mousePress.isRightButton {
            actionKind = .rightClick
        } else if mousePress.clickCount >= 2 {
            actionKind = .doubleClick
        } else {
            actionKind = .click
        }

        // A double click reports twice: the second press replaces the click
        // the first press already recorded.
        if actionKind == .doubleClick, actions.last?.kind == .click {
            actions.removeLast()
        }

        actions.append(TeachRecordedAction(
            secondsFromStart: mousePress.secondsFromStart,
            kind: actionKind,
            applicationName: mousePress.context.applicationName,
            applicationBundleIdentifier: mousePress.context.applicationBundleIdentifier,
            element: mousePress.context.element,
            locationInDisplayPoints: LessonPoint(mousePress.locationInDisplayPoints),
            dragEndLocationInDisplayPoints: isDrag ? LessonPoint(releaseLocation) : nil,
            windowFrameInDisplayPoints: mousePress.context.windowFrameInDisplayPoints,
            keystrokeSummary: nil,
            beforeFrameFileName: nil,
            afterFrameFileName: nil
        ))
        finishedActionCount += 1
    }

    private mutating func appendKeystroke(_ category: TeachKeystrokeCategory, secondsFromStart: Double, context: TeachActionContext) {
        guard category != .otherIgnored else { return }

        if case .shortcut = category {
            flushTypingRun()
            var shortcutSummary = TeachKeystrokeSummary()
            TeachKeystrokeCategorizer.add(category, to: &shortcutSummary)
            actions.append(makeKeystrokeAction(kind: .shortcut, keystrokeSummary: shortcutSummary, secondsFromStart: secondsFromStart, context: context))
            finishedActionCount += 1
            return
        }

        if var typingRun = pendingTypingRun,
           secondsFromStart - typingRun.lastKeySecondsFromStart < Self.typingRunGapInSeconds {
            TeachKeystrokeCategorizer.add(category, to: &typingRun.keystrokeSummary)
            typingRun.lastKeySecondsFromStart = secondsFromStart
            pendingTypingRun = typingRun
            return
        }

        flushTypingRun()
        var newTypingRun = PendingTypingRun(
            firstKeySecondsFromStart: secondsFromStart,
            lastKeySecondsFromStart: secondsFromStart,
            context: context
        )
        TeachKeystrokeCategorizer.add(category, to: &newTypingRun.keystrokeSummary)
        pendingTypingRun = newTypingRun
    }

    private mutating func flushTypingRun() {
        guard let typingRun = pendingTypingRun else { return }
        pendingTypingRun = nil
        actions.append(makeKeystrokeAction(
            kind: .typing,
            keystrokeSummary: typingRun.keystrokeSummary,
            secondsFromStart: typingRun.firstKeySecondsFromStart,
            context: typingRun.context
        ))
        finishedActionCount += 1
    }

    private func makeKeystrokeAction(
        kind: TeachActionKind,
        keystrokeSummary: TeachKeystrokeSummary,
        secondsFromStart: Double,
        context: TeachActionContext
    ) -> TeachRecordedAction {
        TeachRecordedAction(
            secondsFromStart: secondsFromStart,
            kind: kind,
            applicationName: context.applicationName,
            applicationBundleIdentifier: context.applicationBundleIdentifier,
            element: context.element,
            locationInDisplayPoints: nil,
            dragEndLocationInDisplayPoints: nil,
            windowFrameInDisplayPoints: context.windowFrameInDisplayPoints,
            keystrokeSummary: keystrokeSummary,
            beforeFrameFileName: nil,
            afterFrameFileName: nil
        )
    }
}

// MARK: - Secure Input

enum TeachSecureInputMonitor {
    /// True whenever any app has secure keyboard entry on, which is what macOS
    /// password fields do while focused.
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}

// MARK: - Toggle Hotkey

/// The teach mode shortcut. Carbon hot keys are consumed before they reach the
/// frontmost app, so starting or stopping can't leak a keystroke into the
/// teacher's document. They need no Accessibility permission either.
final class TeachModeHotKey {
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private let onPressed: () -> Void

    static let displayText = "control + shift + t"

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
    }

    deinit {
        unregister()
    }

    func register() {
        guard hotKeyReference == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerCallback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<TeachModeHotKey>.fromOpaque(userData).takeUnretainedValue().onPressed()
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handlerCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )

        let hotKeyIdentifier = EventHotKeyID(signature: OSType(0x434C4B59), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(controlKey | shiftKey),
            hotKeyIdentifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
    }

    func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }
}
