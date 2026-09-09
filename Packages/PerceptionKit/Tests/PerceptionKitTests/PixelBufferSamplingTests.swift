//
//  PixelBufferSamplingTests.swift
//  PerceptionKitTests
//
//  The colour conversion is the only decision in the platform half, and
//  it is the one that would fail silently: a wrong range or a swapped
//  chroma pair still produces plausible colours, just of the wrong ball.
//

import CueSyncCore
import Foundation
import Testing

@testable import PerceptionKit

#if canImport(CoreVideo)
import CoreVideo

@Suite("Pixel buffer sampling")
struct PixelBufferSamplingTests {

    private func expectClose(_ got: Vec3, _ want: Vec3, tolerance: Double = 0.02,
                             _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(got.x - want.x) < tolerance, "\(what) red: \(got.x) vs \(want.x)",
                sourceLocation: sourceLocation)
        #expect(abs(got.y - want.y) < tolerance, "\(what) green: \(got.y) vs \(want.y)",
                sourceLocation: sourceLocation)
        #expect(abs(got.z - want.z) < tolerance, "\(what) blue: \(got.z) vs \(want.z)",
                sourceLocation: sourceLocation)
    }

    @Test("Neutral chroma is grey at every luma, in both ranges")
    func neutralChromaIsGrey() {
        for luma in stride(from: 32, through: 224, by: 32) {
            let full = PixelBufferReader.convert(luma: UInt8(luma), cb: 128, cr: 128,
                                                 videoRange: false)
            let level = Double(luma) / 255
            expectClose(full, Vec3(level, level, level), "full range luma \(luma)")
        }
        // Video range maps 16...235 onto 0...1, so mid-grey sits higher.
        let video = PixelBufferReader.convert(luma: 126, cb: 128, cr: 128, videoRange: true)
        expectClose(video, Vec3(0.502, 0.502, 0.502), "video range mid grey")
    }

    @Test("Video range reads its black floor as black, not as dark grey")
    func videoRangeBlackIsBlack() {
        let black = PixelBufferReader.convert(luma: 16, cb: 128, cr: 128, videoRange: true)
        // The eight ball is separated from colours by a value ceiling, so
        // an offset here would push it over.
        #expect(max(black.x, max(black.y, black.z)) < 0.01)
    }

    @Test("Cr drives red and Cb drives blue, not the other way round")
    func chromaChannelsAreNotSwapped() {
        let red = PixelBufferReader.convert(luma: 128, cb: 128, cr: 220, videoRange: false)
        #expect(red.x > red.z, "high Cr should be red-dominant, got \(red)")
        let blue = PixelBufferReader.convert(luma: 128, cb: 220, cr: 128, videoRange: false)
        #expect(blue.z > blue.x, "high Cb should be blue-dominant, got \(blue)")
    }

    @Test("Conversion never escapes 0...1, so a saturated pixel cannot fake a highlight")
    func conversionIsClamped() {
        for luma in [UInt8(0), 16, 128, 235, 255] {
            for cb in [UInt8(0), 128, 255] {
                for cr in [UInt8(0), 128, 255] {
                    for videoRange in [true, false] {
                        let rgb = PixelBufferReader.convert(luma: luma, cb: cb, cr: cr,
                                                            videoRange: videoRange)
                        #expect(rgb.min() >= 0 && rgb.max() <= 1,
                                "luma \(luma) cb \(cb) cr \(cr) video \(videoRange): \(rgb)")
                    }
                }
            }
        }
    }

    @Test("Only formats whose plane layout is known are accepted")
    func unknownFormatsAreRefused() {
        #expect(PixelBufferReader.supports(kCVPixelFormatType_32BGRA))
        #expect(PixelBufferReader.supports(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        #expect(PixelBufferReader.supports(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        // Reading these as if they were BGRA would produce colours, and
        // they would be wrong.
        #expect(!PixelBufferReader.supports(kCVPixelFormatType_32ARGB))
        #expect(!PixelBufferReader.supports(kCVPixelFormatType_OneComponent8))
    }

    /// Build the format ARKit actually hands over: full-range bi-planar
    /// 4:2:0, luma at full resolution and interleaved CbCr at half.
    private func makeBiPlanar(width: Int, height: Int,
                              luma: UInt8, cb: UInt8, cr: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            attributes, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let lumaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))
            .assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        for y in 0..<height {
            for x in 0..<width { lumaBase[y * lumaRow + x] = luma }
        }
        let chromaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 1))
            .assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pixels, 1) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(pixels, 1) {
                chromaBase[y * chromaRow + x * 2] = cb
                chromaBase[y * chromaRow + x * 2 + 1] = cr
            }
        }
        return pixels
    }

    @Test("ARKit's bi-planar YCbCr reads back as the colour it encodes")
    func biPlanarRoundTrips() throws {
        // A strong blue: high Cb, low Cr.
        let pixels = try makeBiPlanar(width: 16, height: 12, luma: 90, cb: 210, cr: 100)
        let image = PixelBufferImage(pixelBuffer: pixels)
        let sampled = try #require(image.withReader { reader -> [Vec3] in
            #expect(reader.pixelWidth == 16)
            #expect(reader.pixelHeight == 12)
            // Chroma is half resolution: two adjacent pixels share a
            // sample, and an off-by-one in the subsampling shows up as a
            // colour that changes every other column.
            return [reader.rgb(x: 0, y: 0), reader.rgb(x: 1, y: 0),
                    reader.rgb(x: 15, y: 11), reader.rgb(x: 8, y: 6)].compactMap { $0 }
        })
        #expect(sampled.count == 4)
        for rgb in sampled {
            #expect(rgb.z > rgb.x, "high Cb should read blue-dominant, got \(rgb)")
            expectClose(rgb, sampled[0], "uniform buffer should read uniform")
        }
    }

    @Test("The bi-planar reader refuses coordinates outside the buffer")
    func biPlanarBoundsAreChecked() throws {
        let pixels = try makeBiPlanar(width: 16, height: 12, luma: 128, cb: 128, cr: 128)
        let image = PixelBufferImage(pixelBuffer: pixels)
        let outcome = try #require(image.withReader { reader -> [Bool] in
            [reader.rgb(x: -1, y: 0) == nil, reader.rgb(x: 0, y: -1) == nil,
             reader.rgb(x: 16, y: 0) == nil, reader.rgb(x: 0, y: 12) == nil,
             reader.rgb(x: 15, y: 11) != nil]
        })
        #expect(outcome.allSatisfy { $0 })
    }

    @Test("A whole ball sampled out of a bi-planar buffer classifies")
    func samplerWorksOnABiPlanarBuffer() throws {
        // End to end on the real format: uniform orange ball filling the
        // frame, sampled through the same path the device uses.
        let pixels = try makeBiPlanar(width: 64, height: 64, luma: 150, cb: 80, cr: 160)
        let image = PixelBufferImage(pixelBuffer: pixels)
        let patch = try #require(image.withReader { reader in
            BallPatchSampler.sample(
                box: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                from: reader)
        })
        #expect(patch != nil)
        let solid = try #require(patch)
        #expect(solid.sampleCount > 100)
        // Uniform colour: one pigment, so no hue spread worth the name.
        #expect((solid.hueSpread ?? 0) < 1.0)
        #expect(solid.chromaFraction == 1.0)
    }

    @Test("A BGRA buffer reads back the colours written into it, in the right order")
    func bgraRoundTrips() throws {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA,
                            attributes, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
            .assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        // A distinctly red pixel at (5, 2): B=20, G=60, R=200.
        let offset = 2 * bytesPerRow + 5 * 4
        base[offset] = 20
        base[offset + 1] = 60
        base[offset + 2] = 200
        base[offset + 3] = 255
        CVPixelBufferUnlockBaseAddress(pixels, [])

        let image = PixelBufferImage(pixelBuffer: pixels)
        let read = try #require(image.withReader { reader -> Vec3? in
            #expect(reader.pixelWidth == 8)
            #expect(reader.pixelHeight == 4)
            #expect(reader.rgb(x: -1, y: 0) == nil)
            #expect(reader.rgb(x: 8, y: 0) == nil)
            return reader.rgb(x: 5, y: 2)
        })
        let rgb = try #require(read)
        expectClose(rgb, Vec3(200.0 / 255, 60.0 / 255, 20.0 / 255), "BGRA round trip")
    }
}
#endif
