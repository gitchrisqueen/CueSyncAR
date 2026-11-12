//
//  PixelBufferCropper.swift
//  PerceptionKit
//
//  Deep-copies a rectangle of a CVPixelBuffer into a new buffer of the same
//  pixel format, for the far-tile pass. A plain row copy (no resampling, no
//  colour conversion): Vision scales and converts the tile exactly as it does
//  the full frame, so only the field of view differs.
//
//  Formats: 32BGRA / 32ARGB, and the two 4:2:0 bi-planar YCbCr formats ARKit
//  delivers. The crop origin and size must be even for the chroma plane.
//

import CueSyncCore
import Foundation

#if canImport(CoreVideo)
@preconcurrency import CoreVideo

public enum PixelBufferCropError: Error, Equatable {
    case unsupportedFormat(OSType)
    case invalidCrop
    case allocationFailed(Int32)
}

public enum PixelBufferCropper {
    /// A new buffer holding `crop` of `source`. The source is not retained.
    public static func crop(_ source: CVPixelBuffer,
                            to crop: FarTilePixelCrop) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard crop.width > 0, crop.height > 0, crop.x >= 0, crop.y >= 0,
              crop.x + crop.width <= sourceWidth, crop.y + crop.height <= sourceHeight,
              crop.x % 2 == 0, crop.y % 2 == 0, crop.width % 2 == 0, crop.height % 2 == 0
        else { throw PixelBufferCropError.invalidCrop }

        let bytesPerPixel: Int?
        let planar: Bool
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            bytesPerPixel = 4
            planar = false
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            bytesPerPixel = nil
            planar = true
        default:
            throw PixelBufferCropError.unsupportedFormat(format)
        }

        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, crop.width, crop.height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &created)
        guard status == kCVReturnSuccess, let destination = created else {
            throw PixelBufferCropError.allocationFailed(status)
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        if planar {
            // Plane 0: luma, 1 byte per pixel. Plane 1: interleaved CbCr at
            // half resolution, 2 bytes per chroma pixel (= 1 byte per luma
            // column, half the rows).
            try copyPlane(from: source, to: destination, plane: 0,
                          window: RowWindow(originByte: crop.x, originRow: crop.y,
                                            rowBytes: crop.width, rows: crop.height))
            try copyPlane(from: source, to: destination, plane: 1,
                          window: RowWindow(originByte: crop.x, originRow: crop.y / 2,
                                            rowBytes: crop.width, rows: crop.height / 2))
        } else if let bytesPerPixel {
            guard let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
                throw PixelBufferCropError.invalidCrop
            }
            copyRows(from: PlaneRef(base: sourceBase, stride: CVPixelBufferGetBytesPerRow(source)),
                     to: PlaneRef(base: destinationBase, stride: CVPixelBufferGetBytesPerRow(destination)),
                     window: RowWindow(originByte: crop.x * bytesPerPixel, originRow: crop.y,
                                       rowBytes: crop.width * bytesPerPixel, rows: crop.height))
        }
        return destination
    }

    /// Start of a locked plane and its row stride.
    private struct PlaneRef {
        let base: UnsafeMutableRawPointer
        let stride: Int
    }

    /// The rectangle to copy: byte offset and row of its top-left corner in
    /// the source, bytes per row and number of rows.
    private struct RowWindow {
        let originByte: Int
        let originRow: Int
        let rowBytes: Int
        let rows: Int
    }

    private static func copyPlane(from source: CVPixelBuffer, to destination: CVPixelBuffer,
                                  plane: Int, window: RowWindow) throws {
        guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
              let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
            throw PixelBufferCropError.invalidCrop
        }
        copyRows(from: PlaneRef(base: sourceBase,
                                stride: CVPixelBufferGetBytesPerRowOfPlane(source, plane)),
                 to: PlaneRef(base: destinationBase,
                              stride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane)),
                 window: window)
    }

    private static func copyRows(from source: PlaneRef, to destination: PlaneRef, window: RowWindow) {
        for row in 0..<window.rows {
            memcpy(destination.base + row * destination.stride,
                   source.base + (window.originRow + row) * source.stride + window.originByte,
                   window.rowBytes)
        }
    }
}

#if canImport(Vision) && canImport(CoreML)
extension FarTileDetector {
    /// The shipped cropper: Apple pixel buffers via `PixelBufferCropper`.
    /// Frames that are not `PixelBufferImage` (fixtures) get no tile pass.
    public static let pixelBufferCropper: Cropper = { frame, crop in
        guard let image = frame.image as? PixelBufferImage else { return nil }
        let cropped = try PixelBufferCropper.crop(image.pixelBuffer, to: crop)
        return CapturedFrame(timestamp: frame.timestamp,
                             cameraTransform: frame.cameraTransform,
                             image: PixelBufferImage(pixelBuffer: cropped),
                             intrinsics: nil)
    }
}
#endif
#endif
