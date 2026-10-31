//
//  LessonImageTools.swift
//  leanring-buddy
//
//  Image work shared by the compiler and follow mode: downscaling, cropping,
//  on-device text recognition, and a cheap "did the screen change" comparison.
//  Everything here runs locally, so none of it costs a model call.
//

import AppKit
import CoreGraphics
import Foundation
import Vision

enum LessonImageTools {
    static func decodedImage(from imageData: Data) -> CGImage? {
        NSBitmapImageRep(data: imageData)?.cgImage
    }

    static func jpegData(from image: CGImage, compressionFactor: Double = 0.8) -> Data? {
        NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
    }

    static func resizedImage(_ image: CGImage, toWidth targetWidth: Int, height targetHeight: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// Fits the longest edge to `maximumDimension`, never scaling up.
    static func downscaledJPEG(from imageData: Data, maximumDimension: Int, compressionFactor: Double = 0.7) -> Data? {
        guard let sourceImage = decodedImage(from: imageData) else { return nil }
        let longestEdge = max(sourceImage.width, sourceImage.height)
        guard longestEdge > maximumDimension else {
            return jpegData(from: sourceImage, compressionFactor: compressionFactor)
        }

        let scaleFactor = CGFloat(maximumDimension) / CGFloat(longestEdge)
        guard let resized = resizedImage(
            sourceImage,
            toWidth: Int((CGFloat(sourceImage.width) * scaleFactor).rounded()),
            height: Int((CGFloat(sourceImage.height) * scaleFactor).rounded())
        ) else {
            return nil
        }
        return jpegData(from: resized, compressionFactor: compressionFactor)
    }

    /// Crops around a point given in display points, clamping at the image
    /// edges. A frame's pixels and the display's points differ by a scale factor.
    static func croppedJPEG(
        from imageData: Data,
        aroundDisplayPoint centerInDisplayPoints: CGPoint,
        displaySizeInPoints: CGSize,
        cropSizeInPoints: CGSize
    ) -> Data? {
        guard let sourceImage = decodedImage(from: imageData),
              displaySizeInPoints.width > 0, displaySizeInPoints.height > 0 else {
            return nil
        }

        let pixelsPerPointX = CGFloat(sourceImage.width) / displaySizeInPoints.width
        let pixelsPerPointY = CGFloat(sourceImage.height) / displaySizeInPoints.height

        let cropWidthInPixels = cropSizeInPoints.width * pixelsPerPointX
        let cropHeightInPixels = cropSizeInPoints.height * pixelsPerPointY

        let cropRectInPixels = CGRect(
            x: centerInDisplayPoints.x * pixelsPerPointX - cropWidthInPixels / 2,
            y: centerInDisplayPoints.y * pixelsPerPointY - cropHeightInPixels / 2,
            width: cropWidthInPixels,
            height: cropHeightInPixels
        ).intersection(CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height))

        guard !cropRectInPixels.isNull,
              let croppedImage = sourceImage.cropping(to: cropRectInPixels.integral) else {
            return nil
        }
        return jpegData(from: croppedImage)
    }
}

// MARK: - On-Device Text

enum LessonOnDeviceText {
    /// All text Vision can read in an image, lowercased, as whole lines.
    nonisolated static func recognizedLines(inImageData imageData: Data) -> [String] {
        guard let sourceImage = NSBitmapImageRep(data: imageData)?.cgImage else { return [] }

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false

        guard (try? VNImageRequestHandler(cgImage: sourceImage).perform([textRequest])) != nil else {
            return []
        }

        return (textRequest.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string.lowercased()
        }
    }

    /// Text can only prove a step happened if it wasn't already on screen, so
    /// a candidate counts only when it's visible now and wasn't before. Matches
    /// whole words, because "file" is not evidence of "profile".
    static func firstNewlyVisibleText(
        among candidateTexts: [String],
        currentLines: [String],
        baselineLines: [String]
    ) -> String? {
        candidateTexts.first { candidateText in
            let isVisibleNow = currentLines.contains { lineContainsWholePhrase($0, phrase: candidateText) }
            let wasVisibleBefore = baselineLines.contains { lineContainsWholePhrase($0, phrase: candidateText) }
            return isVisibleNow && !wasVisibleBefore
        }
    }

    static func lineContainsWholePhrase(_ line: String, phrase: String) -> Bool {
        let escapedPhrase = NSRegularExpression.escapedPattern(for: phrase.lowercased())
        guard !escapedPhrase.isEmpty,
              let wholePhraseRegex = try? NSRegularExpression(pattern: "(^|\\W)\(escapedPhrase)($|\\W)") else {
            return false
        }
        return wholePhraseRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}

// MARK: - Screen Change Detection

/// A tiny grayscale copy of the screen. Comparing these is how follow mode
/// notices the follower did something, without paying for a model call on
/// every tick of an unchanged screen.
struct LessonScreenFingerprint {
    private static let fingerprintWidth = 240
    private static let fingerprintHeight = 150
    private static let tileEdgeInPixels = 6

    /// Mean brightness shift, out of 255, for a tile to count as changed. High
    /// enough to ignore JPEG noise, low enough to catch a selection highlight.
    private static let tileChangeThreshold = 3

    let grayscalePixels: [UInt8]

    init?(imageData: Data) {
        guard let sourceImage = LessonImageTools.decodedImage(from: imageData) else { return nil }
        var pixels = [UInt8](repeating: 0, count: Self.fingerprintWidth * Self.fingerprintHeight)
        let didDraw: Bool = pixels.withUnsafeMutableBytes { pixelBuffer in
            guard let context = CGContext(
                data: pixelBuffer.baseAddress,
                width: Self.fingerprintWidth,
                height: Self.fingerprintHeight,
                bitsPerComponent: 8,
                bytesPerRow: Self.fingerprintWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: Self.fingerprintWidth, height: Self.fingerprintHeight))
            return true
        }
        guard didDraw else { return nil }
        grayscalePixels = pixels
    }

    /// How many small tiles differ between two fingerprints. Tiles rather than
    /// a global average, so a small popover on a huge screen still registers.
    func changedTileCount(comparedTo otherFingerprint: LessonScreenFingerprint) -> Int {
        var changedTiles = 0
        let tileEdge = Self.tileEdgeInPixels

        for tileTop in stride(from: 0, to: Self.fingerprintHeight - tileEdge + 1, by: tileEdge) {
            for tileLeft in stride(from: 0, to: Self.fingerprintWidth - tileEdge + 1, by: tileEdge) {
                var totalDifference = 0
                for rowOffset in 0..<tileEdge {
                    let rowStart = (tileTop + rowOffset) * Self.fingerprintWidth + tileLeft
                    for pixelOffset in 0..<tileEdge {
                        let firstPixel = Int(grayscalePixels[rowStart + pixelOffset])
                        let secondPixel = Int(otherFingerprint.grayscalePixels[rowStart + pixelOffset])
                        totalDifference += abs(firstPixel - secondPixel)
                    }
                }
                if totalDifference / (tileEdge * tileEdge) >= Self.tileChangeThreshold {
                    changedTiles += 1
                }
            }
        }
        return changedTiles
    }
}
