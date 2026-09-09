//
//  PixelBufferSampling.swift
//  PerceptionKit
//
//  Reading RGB out of a camera pixel buffer, for BallPatchSampler.
//
//  Contains no decisions — every threshold and every piece of geometry
//  is in BallPatchSampler, which is pure and tested on Linux. What is
//  here is the part that cannot be: ARKit hands over bi-planar
//  YCbCr, and the colour conversion has to happen somewhere.
//
//  Two things worth knowing before touching this file:
//
//  * The buffer is locked ONCE, for the life of the reader, rather than
//    per pixel. A ball is a few hundred pixels and locking each one
//    would dominate the cost. `withReader` scopes the lock; the reader
//    must not escape it, and is not Sendable so it cannot.
//  * ARKit's capture pool is tiny and the pipeline only ever hands out
//    deep copies (`ARSessionCoordinator.copyPixelBuffer`). Nothing here
//    retains a buffer beyond the call, and nothing here may start to.
//

import CueSyncCore
import Foundation

#if canImport(CoreVideo)
@preconcurrency import CoreVideo

extension PixelBufferImage {
    /// Run `body` with a pixel reader over this buffer.
    ///
    /// Returns nil when the format is not one this understands, rather
    /// than reading garbage: a wrong guess about the plane layout would
    /// produce plausible colours from the wrong bytes, which is the
    /// worst possible failure for a classifier.
    public func withReader<Result>(
        _ body: (PixelBufferReader) throws -> Result
    ) rethrows -> Result? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard PixelBufferReader.supports(format) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let reader = PixelBufferReader(locked: pixelBuffer) else { return nil }
        return try body(reader)
    }
}

/// A pixel reader over an already-locked buffer.
///
/// Deliberately not Sendable and deliberately holding raw pointers: it
/// is valid only inside `PixelBufferImage.withReader`.
public struct PixelBufferReader: PixelSampling, @unchecked Sendable {
    private enum Layout {
        /// One interleaved plane, 8 bits per channel.
        case bgra(base: UnsafeRawPointer, bytesPerRow: Int)
        /// Luma plane plus interleaved chroma at half resolution — what
        /// ARKit delivers.
        case biPlanarYCbCr(luma: UnsafeRawPointer, lumaBytesPerRow: Int,
                           chroma: UnsafeRawPointer, chromaBytesPerRow: Int,
                           chromaWidth: Int, chromaHeight: Int, videoRange: Bool)
    }

    private let layout: Layout
    public let pixelWidth: Int
    public let pixelHeight: Int

    static func supports(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return true
        default:
            return false
        }
    }

    init?(locked buffer: CVPixelBuffer) {
        pixelWidth = CVPixelBufferGetWidth(buffer)
        pixelHeight = CVPixelBufferGetHeight(buffer)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            layout = .bgra(base: UnsafeRawPointer(base),
                           bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard CVPixelBufferGetPlaneCount(buffer) >= 2,
                  let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
            layout = .biPlanarYCbCr(
                luma: UnsafeRawPointer(luma),
                lumaBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                chroma: UnsafeRawPointer(chroma),
                chromaBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
                chromaWidth: CVPixelBufferGetWidthOfPlane(buffer, 1),
                chromaHeight: CVPixelBufferGetHeightOfPlane(buffer, 1),
                videoRange: CVPixelBufferGetPixelFormatType(buffer)
                    == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        default:
            return nil
        }
    }

    public func rgb(x: Int, y: Int) -> Vec3? {
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        switch layout {
        case .bgra(let base, let bytesPerRow):
            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
                .assumingMemoryBound(to: UInt8.self)
            return Vec3(Double(pixel[2]) / 255, Double(pixel[1]) / 255, Double(pixel[0]) / 255)
        case .biPlanarYCbCr(let luma, let lumaRow, let chroma, let chromaRow,
                            let chromaWidth, let chromaHeight, let videoRange):
            let yByte = luma.advanced(by: y * lumaRow + x)
                .assumingMemoryBound(to: UInt8.self).pointee
            let cx = min(x / 2, chromaWidth - 1)
            let cy = min(y / 2, chromaHeight - 1)
            let cPair = chroma.advanced(by: cy * chromaRow + cx * 2)
                .assumingMemoryBound(to: UInt8.self)
            return Self.convert(luma: yByte, cb: cPair[0], cr: cPair[1], videoRange: videoRange)
        }
    }

    /// BT.601 full- or video-range YCbCr to RGB.
    ///
    /// 601 rather than 709 because that is what the capture pipeline
    /// tags these buffers with. The classifier works in hue, which is
    /// forgiving of the choice, but the eight ball's value ceiling is
    /// not, and video range would otherwise read 16/255 as black rather
    /// than as 0.
    static func convert(luma: UInt8, cb: UInt8, cr: UInt8, videoRange: Bool) -> Vec3 {
        var luminance = Double(luma) / 255
        if videoRange {
            luminance = (Double(luma) - 16) / 219
        }
        let blueDiff = (Double(cb) - 128) / 255 * (videoRange ? 255 / 224 : 1)
        let redDiff = (Double(cr) - 128) / 255 * (videoRange ? 255 / 224 : 1)
        let red = luminance + 1.402 * redDiff
        let green = luminance - 0.344136 * blueDiff - 0.714136 * redDiff
        let blue = luminance + 1.772 * blueDiff
        return Vec3(min(max(red, 0), 1), min(max(green, 0), 1), min(max(blue, 0), 1))
    }
}
#endif
