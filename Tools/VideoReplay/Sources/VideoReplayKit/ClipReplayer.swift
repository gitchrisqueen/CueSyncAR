//
//  ClipReplayer.swift
//  CueSync AR
//
//  Replays one clip directory: <clip>/frames/*.png + <clip>/corners.json ->
//  <out>/f0001.png ..., <out>/contact-sheet.png, <out>/summary.json.
//

import CoreGraphics
import CoreML
import CueSyncCore
import Foundation
import PerceptionKit

public struct ReplayOutcome: Sendable {
    public var stats: ClipStats
    public var contactSheetURL: URL?
}

public enum ClipReplayer {
    /// Compiles the model once (the shipped BallDetector is cpuOnly) and
    /// wraps it in the app's own provider.
    public static func makeDetector(modelURL: URL, computeUnits: MLComputeUnits = .cpuOnly) throws
    -> CoreMLDetectionProvider {
        let compiled = try MLModel.compileModel(at: modelURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try CoreMLDetectionProvider(model: MLModel(contentsOf: compiled, configuration: configuration))
    }

    public static func replay(clipDirectory: URL, outputDirectory: URL,
                              detector: any DetectionProviding,
                              config: AnalyzerConfig, sheetFrames: Int = 12) async throws -> ReplayOutcome {
        let geometry = try ClipGeometry.load(from: clipDirectory.appendingPathComponent("corners.json"))
        let frameURLs = try FrameIO.frameURLs(in: clipDirectory.appendingPathComponent("frames"))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let analyzer = FrameAnalyzer(detector: detector, geometry: geometry, config: config)
        var results: [FrameResult] = []
        var annotated: [CGImage] = []
        for (index, url) in frameURLs.enumerated() {
            let image = try FrameIO.loadImage(at: url)
            let result = try await analyzer.process(image: image)
            results.append(result)
            if let rendered = FrameRenderer.render(image: image, result: result, geometry: geometry,
                                                   caption: "#\(index + 1)") {
                annotated.append(rendered)
                try FrameIO.writePNG(rendered, to: outputDirectory.appendingPathComponent(url.lastPathComponent))
            }
        }

        var sheetURL: URL?
        let picks = ContactSheet.sampleIndices(total: annotated.count, count: sheetFrames).map { annotated[$0] }
        if let sheet = ContactSheet.make(images: picks) {
            sheetURL = outputDirectory.appendingPathComponent("contact-sheet.png")
            try FrameIO.writePNG(sheet, to: sheetURL!)
        }

        let stats = ClipStats.summarize(results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stats).write(to: outputDirectory.appendingPathComponent("summary.json"))
        return ReplayOutcome(stats: stats, contactSheetURL: sheetURL)
    }
}
