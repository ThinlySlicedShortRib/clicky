//
//  StuckEventTapMonitor.swift
//  leanring-buddy
//
//  The one place raw input reaches Stuck. A listen-only tap, so it can't block,
//  change or inject anything, and it exists only while Stuck is switched on.
//  Each event is classified on the spot and the CGEvent is left behind.
//
//  This is separate from GlobalPushToTalkShortcutMonitor because that tap runs
//  whenever Accessibility is granted, and Stuck's must not.
//

import AppKit
import CoreGraphics

final class StuckEventTapMonitor {
    /// Runs on the main thread, because the tap's run loop source is on main.
    var onBehaviourEvent: ((StuckBehaviourEventKind, Double) -> Void)?

    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var classifier = StuckEventClassifier()

    /// Every category the tap can see, kept here so docs/STUCK.md and the proof
    /// script can state the exact mask. Notably absent: flagsChanged, keyUp.
    static let monitoredEventTypes: [CGEventType] = [
        .keyDown,
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged,
        .scrollWheel
    ]

    static var monitoredEventMask: CGEventMask {
        monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }
    }

    var isRunning: Bool {
        eventTap != nil
    }

    /// Whether macOS is really delivering to this tap. Creating a tap succeeds
    /// without Input Monitoring: the system quietly disables it and removes
    /// keyDown from its mask, so a tap that "worked" could be blind to
    /// everything. Only the system's own list can tell the two cases apart.
    var isReceivingKeyboardEvents: Bool {
        let keyDownBit = CGEventMask(1) << CGEventType.keyDown.rawValue
        return SystemEventTapReport.tapsOwnedByThisProcess().contains { systemTap in
            systemTap.isStuckTap && systemTap.isEnabled && systemTap.eventMask & keyDownBit != 0
        }
    }

    /// Returns false if macOS refused the tap, which means the permission is
    /// missing. Safe to call repeatedly.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let stuckEventTapMonitor = Unmanaged<StuckEventTapMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            stuckEventTapMonitor.handleTappedEvent(eventType: eventType, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.monitoredEventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let createdRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdEventTap, 0) else {
            CFMachPortInvalidate(createdEventTap)
            return false
        }

        eventTap = createdEventTap
        eventTapRunLoopSource = createdRunLoopSource
        classifier = StuckEventClassifier()

        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
        return true
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        classifier = StuckEventClassifier()
    }

    private func handleTappedEvent(eventType: CGEventType, event: CGEvent) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        guard let behaviourEventKind = classifier.classify(
            eventType: eventType,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            modifierFlags: event.flags,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            pointerLocation: event.location
        ) else {
            return
        }

        // systemUptime is monotonic: the detector never holds a real-world time.
        onBehaviourEvent?(behaviourEventKind, ProcessInfo.processInfo.systemUptime)
    }
}

/// What macOS itself says about event taps, for the proof. Reads the system
/// list rather than trusting this app's own description of itself.
enum SystemEventTapReport {
    struct TapDescription {
        let isListenOnly: Bool
        let eventMask: UInt64
        let isEnabled: Bool

        /// Stuck's tap is the only one here that asks for mouse movement. The
        /// keyboard bit can't be used to recognise it, as macOS may remove it.
        var isStuckTap: Bool {
            eventMask & (CGEventMask(1) << CGEventType.mouseMoved.rawValue) != 0
        }
    }

    static func tapsOwnedByThisProcess() -> [TapDescription] {
        var tapCount: UInt32 = 0
        guard CGGetEventTapList(0, nil, &tapCount) == .success, tapCount > 0 else { return [] }

        var tapList = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(tapCount))
        guard CGGetEventTapList(tapCount, &tapList, &tapCount) == .success else { return [] }

        return tapList.prefix(Int(tapCount))
            .filter { $0.tappingProcess == getpid() }
            .map { tapInformation in
                TapDescription(
                    isListenOnly: tapInformation.options == .listenOnly,
                    eventMask: tapInformation.eventsOfInterest,
                    isEnabled: tapInformation.enabled
                )
            }
    }
}
