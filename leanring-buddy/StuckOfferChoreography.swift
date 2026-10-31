//
//  StuckOfferChoreography.swift
//  leanring-buddy
//
//  The motion of the offer, as plain functions of time, so the feel can be
//  tuned and rendered without a window. The offer should read as someone
//  wandering over and waiting, not as a notification, which is why everything
//  here is slow, curved and unhurried, in contrast to the pointing flight.
//

import CoreGraphics
import Foundation

/// Where the buddy should rest, in global AppKit coordinates, and the display
/// it's resting on.
struct StuckBuddyDriftTarget: Equatable {
    let restingLocation: CGPoint
    let displayFrame: CGRect
}

/// A lazy S-curve from wherever the buddy is to its resting spot.
struct StuckDriftPath {
    struct Sample {
        let position: CGPoint
        let rotationDegrees: Double
        /// 0 at either end of the drift, 1 in the middle. Drives a faint glow.
        let travelEnergy: Double
    }

    let startPosition: CGPoint
    let destination: CGPoint
    let durationInSeconds: Double

    private let firstControlPoint: CGPoint
    private let secondControlPoint: CGPoint

    /// The resting angle of the triangle, matching a real mouse pointer.
    static let restingRotationDegrees: Double = -35
    /// How far it may lean into its direction of travel. It tilts, not spins.
    private static let maximumLeanDegrees: Double = 16

    init(startPosition: CGPoint, destination: CGPoint) {
        self.startPosition = startPosition
        self.destination = destination

        let deltaX = destination.x - startPosition.x
        let deltaY = destination.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        durationInSeconds = min(max(distance / 170, 1.5), 2.6)

        // Control points pushed to opposite sides of the straight line make
        // the S. The bend grows with distance, but a short drift still curves.
        let perpendicularX = distance > 0 ? -deltaY / distance : 0
        let perpendicularY = distance > 0 ? deltaX / distance : 0
        let bendInPoints = min(max(distance * 0.28, 22), 90)

        firstControlPoint = CGPoint(
            x: startPosition.x + deltaX * 0.3 + perpendicularX * bendInPoints,
            y: startPosition.y + deltaY * 0.3 + perpendicularY * bendInPoints
        )
        secondControlPoint = CGPoint(
            x: startPosition.x + deltaX * 0.7 - perpendicularX * bendInPoints * 0.6,
            y: startPosition.y + deltaY * 0.7 - perpendicularY * bendInPoints * 0.6
        )
    }

    /// Sine ease in and out: no sudden start, and a long soft arrival.
    private static func easedProgress(_ linearProgress: Double) -> Double {
        (1 - cos(linearProgress * .pi)) / 2
    }

    func sample(atElapsedSeconds elapsedSeconds: Double) -> Sample {
        let linearProgress = min(max(elapsedSeconds / durationInSeconds, 0), 1)
        let progress = Self.easedProgress(linearProgress)
        let remaining = 1 - progress

        // Cubic bezier: B(t) = (1-t)³P0 + 3(1-t)²tP1 + 3(1-t)t²P2 + t³P3
        func bezierValue(_ start: CGFloat, _ first: CGFloat, _ second: CGFloat, _ end: CGFloat) -> CGFloat {
            let startWeight = remaining * remaining * remaining
            let firstWeight = 3 * remaining * remaining * progress
            let secondWeight = 3 * remaining * progress * progress
            let endWeight = progress * progress * progress
            return CGFloat(startWeight) * start
                + CGFloat(firstWeight) * first
                + CGFloat(secondWeight) * second
                + CGFloat(endWeight) * end
        }

        // Derivative of the same curve, for the direction of travel.
        func bezierSlope(_ start: CGFloat, _ first: CGFloat, _ second: CGFloat, _ end: CGFloat) -> Double {
            3 * remaining * remaining * Double(first - start)
                + 6 * remaining * progress * Double(second - first)
                + 3 * progress * progress * Double(end - second)
        }

        let position = CGPoint(
            x: bezierValue(startPosition.x, firstControlPoint.x, secondControlPoint.x, destination.x),
            y: bezierValue(startPosition.y, firstControlPoint.y, secondControlPoint.y, destination.y)
        )

        let slopeX = bezierSlope(startPosition.x, firstControlPoint.x, secondControlPoint.x, destination.x)
        let slopeY = bezierSlope(startPosition.y, firstControlPoint.y, secondControlPoint.y, destination.y)

        // The sine of the travel angle gives a lean that fades out as the
        // buddy slows, so it settles back to the resting angle by itself.
        let travelEnergy = sin(linearProgress * .pi)
        let travelAngle = atan2(slopeY, slopeX)
        let leanDegrees = sin(travelAngle) * Self.maximumLeanDegrees * travelEnergy

        return Sample(
            position: position,
            rotationDegrees: Self.restingRotationDegrees + leanDegrees,
            travelEnergy: travelEnergy
        )
    }
}

/// Where the buddy and the pill go, so they're near the user without covering
/// what the cursor is on.
enum StuckOfferPlacement {
    static let offsetFromPointerInPoints = CGPoint(x: 96, y: 74)
    static let gapBetweenBuddyAndPillInPoints: CGFloat = 16

    struct Placement: Equatable {
        /// Global AppKit coordinates of the buddy's centre.
        let buddyLocation: CGPoint
        /// Global AppKit origin of the pill's panel.
        let pillOrigin: CGPoint
        let displayFrame: CGRect
    }

    /// Prefers up and to the right of the pointer, flipping away from any
    /// screen edge the pill wouldn't fit against.
    static func makePlacement(pointerLocation: CGPoint, displayFrame: CGRect, pillSize: CGSize) -> Placement {
        let edgeMarginInPoints: CGFloat = 24
        let spaceNeededToTheRight = offsetFromPointerInPoints.x + gapBetweenBuddyAndPillInPoints + pillSize.width + edgeMarginInPoints
        let spaceNeededAbove = offsetFromPointerInPoints.y + pillSize.height / 2 + edgeMarginInPoints

        let placesPillToTheRight = pointerLocation.x + spaceNeededToTheRight <= displayFrame.maxX
        let placesBuddyAbove = pointerLocation.y + spaceNeededAbove <= displayFrame.maxY

        let buddyLocation = CGPoint(
            x: pointerLocation.x + (placesPillToTheRight ? offsetFromPointerInPoints.x : -offsetFromPointerInPoints.x),
            y: pointerLocation.y + (placesBuddyAbove ? offsetFromPointerInPoints.y : -offsetFromPointerInPoints.y)
        )

        let pillOriginX = placesPillToTheRight
            ? buddyLocation.x + gapBetweenBuddyAndPillInPoints
            : buddyLocation.x - gapBetweenBuddyAndPillInPoints - pillSize.width

        return Placement(
            buddyLocation: buddyLocation,
            pillOrigin: CGPoint(x: pillOriginX, y: buddyLocation.y - pillSize.height / 2),
            displayFrame: displayFrame
        )
    }
}
