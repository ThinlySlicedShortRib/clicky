//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    /// The N in the [POINT:...:screenN] tag. 1 is always the cursor screen.
    let screenNumber: Int
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

enum CompanionScreenCaptureError: LocalizedError {
    case screenRecordingPermissionMissing

    /// Includes the exact path because this is shown to whoever is setting up
    /// the machine, and only a human can flip this switch.
    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionMissing:
            let bundlePath = Bundle.main.bundlePath
            return "Screen Recording permission is missing for Clicky. Grant it in System Settings > Privacy & Security > Screen & System Audio Recording (add \(bundlePath) if it isn't listed), then quit and relaunch Clicky."
        }
    }
}

@MainActor
enum CompanionScreenCaptureUtility {
    /// Longest edge of the image sent to the model, in pixels.
    static let maximumScreenshotDimension = 1280

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors. With `onlyCursorScreen`, takes
    /// exactly one image, which is what a Stuck yes promises.
    static func captureAllScreensAsJPEG(onlyCursorScreen: Bool = false) async throws -> [CompanionScreenCapture] {
        // The preflight alone can lag a fresh grant, so a failed preflight only
        // counts as "denied" once a real capture has also failed. Without it,
        // the capture failure would surface as a generic ScreenCaptureKit error.
        let hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !hasScreenRecordingPermission {
                throw CompanionScreenCaptureError.screenRecordingPermissionMissing
            }
            throw error
        }

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        let displaysToCapture = onlyCursorScreen ? Array(sortedDisplays.prefix(1)) : sortedDisplays

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in displaysToCapture.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? display.frame.height
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? ScreenshotCoordinateMapper.appKitFrame(fromCoreGraphicsFrame: display.frame, primaryDisplayHeight: primaryDisplayHeight)
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let screenshotPixelSize = ScreenshotCoordinateMapper.screenshotPixelSize(
                forDisplayWidth: display.width,
                displayHeight: display.height,
                maximumDimension: maximumScreenshotDimension
            )
            configuration.width = screenshotPixelSize.width
            configuration.height = screenshotPixelSize.height

            let cgImage: CGImage
            do {
                cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            } catch {
                if !hasScreenRecordingPermission {
                    throw CompanionScreenCaptureError.screenRecordingPermissionMissing
                }
                throw error
            }

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if displaysToCapture.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                screenNumber: displayIndex + 1,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                // The delivered image, not the requested size, is the
                // coordinate space the model reads off.
                screenshotWidthInPixels: cgImage.width,
                screenshotHeightInPixels: cgImage.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
