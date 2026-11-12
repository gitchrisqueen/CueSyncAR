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

/// Where the crop's destination buffer comes from. The attributes matter to
/// Vision: a buffer without IOSurface backing (and, on device, Metal
/// compatibility) can take a slower preprocessing path than the camera's own
/// buffers, and a fresh allocation every frame costs time of its own.
public struct PixelBufferAllocator: Sendable {
    let make: @Sendable (_ width: Int, _ height: Int, _ format: OSType) throws -> CVPixelBuffer

    public init(make: @escaping @Sendable (Int, Int, OSType) throws -> CVPixelBuffer) {
        self.make = make
    }

    private static func create(_ width: Int, _ height: Int, _ format: OSType,
                               attributes: [CFString: Any]) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                         attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let buffer = created else {
            throw PixelBufferCropError.allocationFailed(status)
        }
        return buffer
    }

    /// A new IOSurface-backed buffer per call.
    public static let ioSurface = PixelBufferAllocator { w, h, f in
        try create(w, h, f, attributes: [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()])
    }

    /// A new IOSurface-backed, Metal-compatible buffer per call: the
    /// attributes ARKit's capture buffers carry.
    public static let ioSurfaceMetal = PixelBufferAllocator { w, h, f in
        try create(w, h, f, attributes: [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                                         kCVPixelBufferMetalCompatibilityKey: true])
    }

    /// A new plain buffer per call (no IOSurface).
    public static let plain = PixelBufferAllocator { w, h, f in
        try create(w, h, f, attributes: [:])
    }

    /// Buffers recycled through a `CVPixelBufferPool` (IOSurface-backed,
    /// Metal-compatible): no allocation per frame. A buffer returns to the
    /// pool when the last reference to it goes, so one handed to Vision and
    /// released after the inference is reused by the next frame.
    public static func pooled() -> PixelBufferAllocator {
        let pools = PoolBox()
        return PixelBufferAllocator { w, h, f in try pools.buffer(width: w, height: h, format: f) }
    }

    private final class PoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var key: [Int] = []
        private var pool: CVPixelBufferPool?

        func buffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
            lock.lock()
            defer { lock.unlock() }
            let wanted = [width, height, Int(format)]
            if key != wanted || pool == nil {
                var created: CVPixelBufferPool?
                let attributes: [CFString: Any] = [
                    kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                    kCVPixelBufferPixelFormatTypeKey: Int(format),
                    kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                    kCVPixelBufferMetalCompatibilityKey: true
                ]
                let status = CVPixelBufferPoolCreate(
                    kCFAllocatorDefault,
                    [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary,
                    attributes as CFDictionary, &created)
                guard status == kCVReturnSuccess, let created else {
                    throw PixelBufferCropError.allocationFailed(status)
                }
                pool = created
                key = wanted
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw PixelBufferCropError.allocationFailed(status)
            }
            return buffer
        }
    }
}

public enum PixelBufferCropper {
    /// A buffer holding `crop` of `source`, from `allocator`. The source is
    /// not retained.
    public static func crop(_ source: CVPixelBuffer,
                            to crop: FarTilePixelCrop,
                            allocator: PixelBufferAllocator = .ioSurface) throws -> CVPixelBuffer {
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

        let destination = try allocator.make(crop.width, crop.height, format)

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
    /// The shipped cropper: Apple pixel buffers via `PixelBufferCropper`, into
    /// pooled IOSurface, Metal-compatible buffers (the attributes of the
    /// camera's own buffers, no allocation per frame).
    /// Frames that are not `PixelBufferImage` (fixtures) get no tile pass.
    public static let pixelBufferCropper: Cropper = makePixelBufferCropper(allocator: .pooled())

    /// A cropper that takes its destination buffers from `allocator`.
    public static func makePixelBufferCropper(allocator: PixelBufferAllocator) -> Cropper {
        { frame, crop in
            guard let image = frame.image as? PixelBufferImage else { return nil }
            let cropped = try PixelBufferCropper.crop(image.pixelBuffer, to: crop, allocator: allocator)
            return CapturedFrame(timestamp: frame.timestamp,
                                 cameraTransform: frame.cameraTransform,
                                 image: PixelBufferImage(pixelBuffer: cropped),
                                 intrinsics: nil)
        }
    }
}
#endif
#endif
