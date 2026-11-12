//
//  Bench.swift
//  detection-eval
//
//  Timing of the detect stage with and without the far-tile pass:
//
//    detection-eval --bench --model <BallDetector.mlpackage> --frames-dir <pngs>
//        [--compute cpu|gpu|all|ane] [--count 40] [--format 420|bgra]
//
//  Frames are converted to the camera's own pixel format (4:2:0 bi-planar,
//  full range, like ARKit's capture buffers) so the Vision preprocessing
//  path matches the device's. Each row is the median and mean milliseconds
//  per FRAME over `count` frames after a warm-up, cycling through six
//  distinct pictures. Times are wall-clock for what `PerceptionPipeline`
//  calls the detect stage: inference(s), crop, merge.
//
//  Limit: this Mac's chip decides what is measured. On an Intel Mac there is
//  no Neural Engine, so these rows show crop, allocation and preprocessing
//  cost and the effect of scheduling, NOT the iPad's ANE inference time.
//

import CoreGraphics
import CoreML
import CoreVideo
import CueSyncCore
import Foundation
import PerceptionKit

struct BenchArguments {
    var modelPath = ""
    var framesDirectory = ""
    var computeUnits: MLComputeUnits = .cpuOnly
    var count = 40
    var yuv = true

    static func parse(_ arguments: [String]) throws -> BenchArguments {
        var result = BenchArguments()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--bench" { index += 1; continue }
            guard flag.hasPrefix("--"), index + 1 < arguments.count else {
                throw EvalError.usage("unexpected argument '\(flag)'")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--model": result.modelPath = value
            case "--frames-dir": result.framesDirectory = value
            case "--count": result.count = max(5, Int(value) ?? 40)
            case "--format": result.yuv = value != "bgra"
            case "--compute":
                switch value {
                case "cpu": result.computeUnits = .cpuOnly
                case "gpu": result.computeUnits = .cpuAndGPU
                case "all": result.computeUnits = .all
                case "ane": result.computeUnits = .cpuAndNeuralEngine
                default: throw EvalError.usage("--compute must be cpu|gpu|all|ane")
                }
            default: throw EvalError.usage("unknown flag '\(flag)'")
            }
            index += 2
        }
        guard !result.modelPath.isEmpty, !result.framesDirectory.isEmpty else {
            throw EvalError.usage("--bench needs --model and --frames-dir")
        }
        return result
    }
}

/// BGRA picture to the camera's 4:2:0 bi-planar full-range format, on the
/// CPU (BT.601 full range, chroma averaged over each 2 x 2 block).
private func yuvBuffer(from image: CGImage) throws -> CVPixelBuffer {
    let bgra = try pixelBuffer(from: image)
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, image.width, image.height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
         kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw EvalError.pixelBuffer(status) }
    CVPixelBufferLockBaseAddress(bgra, .readOnly)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
    }
    let width = image.width, height = image.height
    let source = CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to: UInt8.self)
    let sourceStride = CVPixelBufferGetBytesPerRow(bgra)
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
    for row in 0..<height {
        for column in 0..<width {
            let p = source + row * sourceStride + column * 4
            let (b, g, r) = (Double(p[0]), Double(p[1]), Double(p[2]))
            luma[row * lumaStride + column] = clamp(0.299 * r + 0.587 * g + 0.114 * b)
        }
    }
    for row in 0..<(height / 2) {
        for column in 0..<(width / 2) {
            var (sb, sg, sr) = (0.0, 0.0, 0.0)
            for dy in 0..<2 {
                for dx in 0..<2 {
                    let p = source + (row * 2 + dy) * sourceStride + (column * 2 + dx) * 4
                    sb += Double(p[0]); sg += Double(p[1]); sr += Double(p[2])
                }
            }
            let (b, g, r) = (sb / 4, sg / 4, sr / 4)
            chroma[row * chromaStride + column * 2] = clamp(128 - 0.168736 * r - 0.331264 * g + 0.5 * b)
            chroma[row * chromaStride + column * 2 + 1] = clamp(128 + 0.5 * r - 0.418688 * g - 0.081312 * b)
        }
    }
    return buffer
}

private func milliseconds(_ body: () async throws -> Void) async rethrows -> Double {
    let start = ContinuousClock.now
    try await body()
    let elapsed = ContinuousClock.now - start
    return (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * 1000
}

private func summarize(_ label: String, _ samples: [Double]) {
    let sorted = samples.sorted()
    let median = sorted[sorted.count / 2]
    let mean = samples.reduce(0, +) / Double(samples.count)
    let line = String(format: "%-58@ median %7.1f ms   mean %7.1f ms   (n=%d)",
                      label as NSString, median, mean, samples.count)
    print(line)
    fflush(stdout)
}

func runBench(_ arguments: BenchArguments) async throws {
    FileHandle.standardError.write(Data("bench: compiling model\n".utf8))
    let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: arguments.modelPath))
    FileHandle.standardError.write(Data("bench: model compiled, converting frames\n".utf8))
    let configuration = MLModelConfiguration()
    configuration.computeUnits = arguments.computeUnits
    let model = try MLModel(contentsOf: compiled, configuration: configuration)
    let provider = try CoreMLDetectionProvider(model: model)
    let secondProvider = try CoreMLDetectionProvider(model: model)

    let names = try FileManager.default.contentsOfDirectory(atPath: arguments.framesDirectory)
        .filter { $0.hasSuffix(".png") }.sorted()
    let picked = stride(from: 0, to: names.count, by: max(1, names.count / 6)).prefix(6).map { names[$0] }
    var frames: [CapturedFrame] = []
    for name in picked {
        let image = try loadCGImage(at: arguments.framesDirectory + "/" + name)
        let buffer = arguments.yuv ? try yuvBuffer(from: image) : try pixelBuffer(from: image)
        frames.append(CapturedFrame(timestamp: 0, cameraTransform: .identity,
                                    image: PixelBufferImage(pixelBuffer: buffer)))
    }
    FileHandle.standardError.write(Data("bench: frames ready\n".utf8))
    let width = frames[0].image?.width ?? 0, height = frames[0].image?.height ?? 0
    guard let crop = FarTileRegion.default.pixelCrop(frameWidth: width, frameHeight: height) else { return }
    print("compute \(arguments.computeUnits.rawValue)  format \(arguments.yuv ? "420f" : "bgra")  "
          + "frame \(width)x\(height)  tile \(crop.width)x\(crop.height)  frames cycled \(frames.count)")

    func cycle(_ n: Int, _ body: (CapturedFrame) async throws -> Void) async throws -> [Double] {
        var out: [Double] = []
        for i in 0..<(n + 5) {
            let frame = frames[i % frames.count]
            let ms = try await milliseconds { try await body(frame) }
            if i >= 5 { out.append(ms) }
        }
        return out
    }
    func cropped(_ frame: CapturedFrame, _ allocator: PixelBufferAllocator) throws -> CapturedFrame {
        guard let image = frame.image as? PixelBufferImage else { return frame }
        return CapturedFrame(timestamp: 0, cameraTransform: .identity,
                             image: PixelBufferImage(pixelBuffer: try PixelBufferCropper.crop(
                                image.pixelBuffer, to: crop, allocator: allocator)))
    }
    let n = arguments.count

    // Components.
    summarize("full frame, inference only", try await cycle(n) { _ = try await provider.detect(in: $0) })
    summarize("crop only, new IOSurface buffer", try await cycle(n) { _ = try cropped($0, .ioSurface) })
    summarize("crop only, new IOSurface+Metal buffer", try await cycle(n) { _ = try cropped($0, .ioSurfaceMetal) })
    summarize("crop only, new plain buffer", try await cycle(n) { _ = try cropped($0, .plain) })
    let pooled = PixelBufferAllocator.pooled()
    summarize("crop only, pooled buffer", try await cycle(n) { _ = try cropped($0, pooled) })

    // Tile inference on a PRE-MADE tile (no crop in the timing).
    let tiles = try frames.map { try cropped($0, .ioSurfaceMetal) }
    var tileIndex = 0
    summarize("tile inference only (pre-made Metal buffer)", try await cycle(n) { _ in
        _ = try await provider.detect(in: tiles[tileIndex % tiles.count]); tileIndex += 1
    })
    let plainTiles = try frames.map { try cropped($0, .plain) }
    do {
        summarize("tile inference only (pre-made plain buffer)", try await cycle(n) { _ in
            _ = try await provider.detect(in: plainTiles[tileIndex % plainTiles.count]); tileIndex += 1
        })
    } catch {
        print("tile inference only (pre-made plain buffer)             FAILED in Vision: \(error)".prefix(200))
    }
    summarize("tile inference only, then full, alternating sizes", try await cycle(n) {
        _ = try await provider.detect(in: tiles[0]); _ = try await provider.detect(in: $0)
    })

    // Whole detect stage as the pipeline sees it.
    func wrapper(_ period: Int, _ allocator: PixelBufferAllocator) -> FarTileDetector {
        FarTileDetector(inner: provider, period: period, mode: .on, cropper: { frame, crop in
            guard let image = frame.image as? PixelBufferImage else { return nil }
            return CapturedFrame(timestamp: 0, cameraTransform: .identity,
                                 image: PixelBufferImage(pixelBuffer: try PixelBufferCropper.crop(
                                    image.pixelBuffer, to: crop, allocator: allocator)))
        })
    }
    for (name, allocator) in [("IOSurface", PixelBufferAllocator.ioSurface),
                              ("IOSurface+Metal", .ioSurfaceMetal), ("pooled", pooled)] {
        let w = wrapper(1, allocator)
        summarize("detect stage, tile every frame, \(name) crop", try await cycle(n) { _ = try await w.detect(in: $0) })
    }
    for period in [2, 3, 4] {
        let w = wrapper(period, pooled)
        summarize("detect stage, tile every \(period) frames, pooled crop (per frame avg)",
                  try await cycle(n * period) { _ = try await w.detect(in: $0) })
    }
    let off = FarTileDetector(inner: provider, mode: .off, cropper: { _, _ in nil })
    summarize("detect stage, tile off", try await cycle(n) { _ = try await off.detect(in: $0) })

    // Two passes at once, each on its own provider (own serial queue).
    summarize("detect stage, full and tile CONCURRENT (two providers)", try await cycle(n) { frame in
        let tile = try cropped(frame, pooled)
        async let full = provider.detect(in: frame)
        async let tileDetections = secondProvider.detect(in: tile)
        _ = try await (full, tileDetections)
    })
}
