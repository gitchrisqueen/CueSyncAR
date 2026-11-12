//
//  PixelBufferCropperTests.swift
//  PerceptionKitTests
//
//  The far-tile crop is a plain row copy: every pixel of the tile must equal
//  the source pixel it came from, in both the BGRA and the 4:2:0 bi-planar
//  layouts, and the source must be left untouched.
//

import Foundation
import Testing
@testable import PerceptionKit

#if canImport(CoreVideo)
@preconcurrency import CoreVideo

@Suite("PixelBufferCropper")
struct PixelBufferCropperTests {
    private func makeBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &buffer)
                == kCVReturnSuccess)
        return try #require(buffer)
    }

    /// Distinct, position-derived byte for every cell of a plane.
    private func pattern(_ column: Int, _ row: Int, plane: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: column &* 7 &+ row &* 13 &+ plane &* 101)
    }

    @Test func bgraCropCopiesExactlyTheRequestedPixels() throws {
        let source = try makeBuffer(width: 64, height: 48, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(source, [])
        let base = try #require(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(source)
        for row in 0..<48 { for byte in 0..<(64 * 4) { base[row * stride + byte] = pattern(byte, row, plane: 0) } }
        CVPixelBufferUnlockBaseAddress(source, [])

        let crop = FarTilePixelCrop(x: 10, y: 6, width: 20, height: 16, frameWidth: 64, frameHeight: 48)
        let tile = try PixelBufferCropper.crop(source, to: crop)
        #expect(CVPixelBufferGetWidth(tile) == 20 && CVPixelBufferGetHeight(tile) == 16)
        #expect(CVPixelBufferGetPixelFormatType(tile) == kCVPixelFormatType_32BGRA)

        CVPixelBufferLockBaseAddress(tile, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(tile, .readOnly) }
        let tileBase = try #require(CVPixelBufferGetBaseAddress(tile)).assumingMemoryBound(to: UInt8.self)
        let tileStride = CVPixelBufferGetBytesPerRow(tile)
        var mismatches = 0
        for row in 0..<16 {
            for byte in 0..<(20 * 4)
            where tileBase[row * tileStride + byte] != pattern(10 * 4 + byte, 6 + row, plane: 0) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test func biPlanarCropCopiesLumaAndChromaFromTheRightPlaces() throws {
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let source = try makeBuffer(width: 64, height: 48, format: format)
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(source, plane))
                .assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            let bytes = plane == 0 ? 64 : 64   // chroma: 32 CbCr pairs = 64 bytes
            for row in 0..<rows { for byte in 0..<bytes { base[row * stride + byte] = pattern(byte, row, plane: plane) } }
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        let crop = FarTilePixelCrop(x: 10, y: 6, width: 20, height: 16, frameWidth: 64, frameHeight: 48)
        let tile = try PixelBufferCropper.crop(source, to: crop)
        #expect(CVPixelBufferGetPlaneCount(tile) == 2)

        CVPixelBufferLockBaseAddress(tile, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(tile, .readOnly) }
        var mismatches = 0
        // Luma: 20 x 16 from (10, 6).
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(tile, 0)).assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(tile, 0)
        for row in 0..<16 {
            for column in 0..<20 where luma[row * lumaStride + column] != pattern(10 + column, 6 + row, plane: 0) {
                mismatches += 1
            }
        }
        // Chroma: 10 CbCr pairs x 8 rows from chroma pair 5, chroma row 3.
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(tile, 1)).assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(tile, 1)
        #expect(CVPixelBufferGetHeightOfPlane(tile, 1) == 8)
        for row in 0..<8 {
            for byte in 0..<20 where chroma[row * chromaStride + byte] != pattern(10 + byte, 3 + row, plane: 1) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test func invalidCropsAndFormatsAreRefused() throws {
        let source = try makeBuffer(width: 64, height: 48, format: kCVPixelFormatType_32BGRA)
        let outside = FarTilePixelCrop(x: 50, y: 0, width: 20, height: 16, frameWidth: 64, frameHeight: 48)
        #expect(throws: PixelBufferCropError.invalidCrop) { try PixelBufferCropper.crop(source, to: outside) }
        let odd = FarTilePixelCrop(x: 1, y: 0, width: 20, height: 16, frameWidth: 64, frameHeight: 48)
        #expect(throws: PixelBufferCropError.invalidCrop) { try PixelBufferCropper.crop(source, to: odd) }

        let gray = try makeBuffer(width: 64, height: 48, format: kCVPixelFormatType_OneComponent8)
        let fine = FarTilePixelCrop(x: 0, y: 0, width: 20, height: 16, frameWidth: 64, frameHeight: 48)
        #expect(throws: PixelBufferCropError.unsupportedFormat(kCVPixelFormatType_OneComponent8)) {
            try PixelBufferCropper.crop(gray, to: fine)
        }
    }
}
#endif
