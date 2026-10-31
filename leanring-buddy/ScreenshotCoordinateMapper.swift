//
//  ScreenshotCoordinateMapper.swift
//  leanring-buddy
//
//  Maps a [POINT:x,y] coordinate from screenshot pixels to the global AppKit
//  point the overlay flies to. Every caller goes through here so the voice
//  pipeline, onboarding demo, and headless checks can never disagree.
//
//  Three coordinate spaces are involved:
//    screenshot pixels  top-left origin, downscaled image the model sees
//    display points     top-left origin, same size as NSScreen.frame
//    global AppKit      bottom-left origin at the primary display, shared by
//                       every screen, so a secondary display can have negative
//                       or offset values
//

import CoreGraphics
import Foundation

struct MappedScreenPoint {
    /// The model's coordinate after clamping to the image bounds.
    let clampedScreenshotPoint: CGPoint
    /// Top-left origin, relative to the target display.
    let displayLocalPoint: CGPoint
    /// Bottom-left origin, global. What the overlay consumes.
    let globalAppKitPoint: CGPoint
}

enum ScreenshotCoordinateMapper {
    static func mapScreenshotPoint(
        _ screenshotPoint: CGPoint,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        displayFrame: CGRect
    ) -> MappedScreenPoint {
        let screenshotWidth = CGFloat(screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenshotHeightInPixels)

        let clampedScreenshotPoint = CGPoint(
            x: max(0, min(screenshotPoint.x, screenshotWidth)),
            y: max(0, min(screenshotPoint.y, screenshotHeight))
        )

        // X and Y scale separately because rounding the image height to whole
        // pixels makes the two factors differ very slightly.
        let displayLocalPoint = CGPoint(
            x: clampedScreenshotPoint.x * (displayFrame.width / screenshotWidth),
            y: clampedScreenshotPoint.y * (displayFrame.height / screenshotHeight)
        )

        let globalAppKitPoint = CGPoint(
            x: displayFrame.origin.x + displayLocalPoint.x,
            y: displayFrame.origin.y + displayFrame.height - displayLocalPoint.y
        )

        return MappedScreenPoint(
            clampedScreenshotPoint: clampedScreenshotPoint,
            displayLocalPoint: displayLocalPoint,
            globalAppKitPoint: globalAppKitPoint
        )
    }

    /// Picks the capture a [POINT] refers to. Falls back to the cursor screen,
    /// then the first capture: NSRect.contains is false on a frame's top edge,
    /// so a mouse parked against the top of the screen is on no screen at all
    /// and the point would otherwise be silently dropped.
    static func targetCapture(
        forScreenNumber screenNumber: Int?,
        in screenCaptures: [CompanionScreenCapture]
    ) -> CompanionScreenCapture? {
        if let screenNumber, let namedCapture = screenCaptures.first(where: { $0.screenNumber == screenNumber }) {
            return namedCapture
        }
        return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
    }

    /// Converts a Core Graphics display frame (top-left origin at the primary
    /// display) to AppKit (bottom-left origin).
    static func appKitFrame(fromCoreGraphicsFrame coreGraphicsFrame: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: coreGraphicsFrame.origin.x,
            y: primaryDisplayHeight - coreGraphicsFrame.maxY,
            width: coreGraphicsFrame.width,
            height: coreGraphicsFrame.height
        )
    }

    /// Largest image dimensions that fit `maximumDimension` while keeping the
    /// display's aspect ratio.
    static func screenshotPixelSize(
        forDisplayWidth displayWidth: Int,
        displayHeight: Int,
        maximumDimension: Int
    ) -> (width: Int, height: Int) {
        let aspectRatio = CGFloat(displayWidth) / CGFloat(displayHeight)
        if displayWidth >= displayHeight {
            return (maximumDimension, Int((CGFloat(maximumDimension) / aspectRatio).rounded()))
        }
        return (Int((CGFloat(maximumDimension) * aspectRatio).rounded()), maximumDimension)
    }
}
