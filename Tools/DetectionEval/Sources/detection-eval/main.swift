//
//  main.swift
//  detection-eval
//
//  Usage:
//    detection-eval --model <BallDetector.mlpackage> --image <photo.jpg>
//                   [--compute cpu|gpu|all] [--json <out.json>]
//                   [--annotate <out.png>] [--min-confidence 0.25]
//
//  Runs the same CoreMLDetectionProvider the app uses (Vision, scaleFill,
//  bottom-left→top-left box flip) so results here are what the device sees,
//  modulo compute-unit differences — which is exactly what --compute is for:
//  the shipped model is pinned .cpuOnly on iOS 26 (MPSGraph MLIR crash), and
//  the T1.3 re-export must produce matching boxes on cpu vs all before it
//  ships. Exit code is 0 on success, 1 on any failure (bad args, model
//  compile, image load) with the reason on stderr.
//

import CoreGraphics
import CoreML
import CoreVideo
import CueSyncCore
import Foundation
import ImageIO
import PerceptionKit
import UniformTypeIdentifiers

// MARK: - Argument parsing

struct EvalArguments {
    var modelPath: String
    var imagePath: String
    var computeUnits: MLComputeUnits = .cpuOnly
    var computeLabel: String = "cpu"
    var jsonPath: String?
    var annotatePath: String?
    var minConfidence: Double = 0.25

    static func parse(_ arguments: [String]) throws -> EvalArguments {
        var model: String?
        var image: String?
        var parsed = [String: String]()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else {
                throw EvalError.usage("unexpected argument '\(flag)'")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--model": model = value
            case "--image": image = value
            default: parsed[flag] = value
            }
            index += 2
        }
        guard let model, let image else {
            throw EvalError.usage("--model and --image are required")
        }
        var result = EvalArguments(modelPath: model, imagePath: image)
        if let compute = parsed["--compute"] {
            switch compute {
            case "cpu": result.computeUnits = .cpuOnly
            case "gpu": result.computeUnits = .cpuAndGPU
            case "all": result.computeUnits = .all
            default: throw EvalError.usage("--compute must be cpu|gpu|all")
            }
            result.computeLabel = compute
        }
        result.jsonPath = parsed["--json"]
        result.annotatePath = parsed["--annotate"]
        if let raw = parsed["--min-confidence"] {
            guard let value = Double(raw), (0...1).contains(value) else {
                throw EvalError.usage("--min-confidence must be in 0...1")
            }
            result.minConfidence = value
        }
        return result
    }
}

enum EvalError: Error, CustomStringConvertible {
    case usage(String)
    case imageLoad(String)
    case pixelBuffer(CVReturn)
    case annotationEncode(String)

    var description: String {
        switch self {
        case .usage(let message):
            "usage error: \(message)\nusage: detection-eval --model <path> --image <path> " +
            "[--compute cpu|gpu|all] [--json <path>] [--annotate <path>] [--min-confidence <0-1>]"
        case .imageLoad(let path): "cannot load image at \(path)"
        case .pixelBuffer(let status): "CVPixelBuffer creation failed (\(status))"
        case .annotationEncode(let path): "cannot write annotated image to \(path)"
        }
    }
}

// MARK: - Image → CVPixelBuffer

func loadCGImage(at path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw EvalError.imageLoad(path)
    }
    // Apply EXIF orientation (iPhone camera JPEGs are stored sensor-native
    // with a rotation tag; the model must see the upright pixels).
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 8192,
    ]
    if let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
        return upright
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw EvalError.imageLoad(path)
    }
    return image
}

func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary
    let status = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                     kCVPixelFormatType_32BGRA, attributes, &buffer)
    guard status == kCVReturnSuccess, let buffer else {
        throw EvalError.pixelBuffer(status)
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: image.width, height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue) else {
        throw EvalError.pixelBuffer(kCVReturnError)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
}

// MARK: - Annotation

func writeAnnotatedImage(_ image: CGImage, detections: [Detection2D], to path: String) throws {
    let width = image.width
    let height = image.height
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw EvalError.annotationEncode(path)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    for detection in detections {
        let box = detection.boundingBox
        // Core boxes are top-left origin; CGContext draws bottom-left.
        let rect = CGRect(x: box.x * Double(width),
                          y: (1 - box.y - box.height) * Double(height),
                          width: box.width * Double(width),
                          height: box.height * Double(height))
        let color: CGColor = detection.isCueStick
            ? CGColor(red: 1, green: 0.8, blue: 0, alpha: 1)
            : detection.ballKind == .cue
                ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                : CGColor(red: 0, green: 1, blue: 0.4, alpha: 1)
        context.setStrokeColor(color)
        context.setLineWidth(max(2, Double(width) / 400))
        context.stroke(rect)
    }

    guard let annotated = context.makeImage() else {
        throw EvalError.annotationEncode(path)
    }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString,
                                                            1, nil) else {
        throw EvalError.annotationEncode(path)
    }
    CGImageDestinationAddImage(destination, annotated, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw EvalError.annotationEncode(path)
    }
}

// MARK: - Output shape

struct EvalReport: Codable {
    struct Entry: Codable {
        var classLabel: String
        var confidence: Double
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var model: String
    var image: String
    var compute: String
    var imageWidth: Int
    var imageHeight: Int
    var inferenceSeconds: Double
    var detections: [Entry]
}

// MARK: - Main

do {
    let arguments = try EvalArguments.parse(CommandLine.arguments)

    let modelURL = URL(fileURLWithPath: arguments.modelPath)
    let compiledURL = try MLModel.compileModel(at: modelURL)
    let configuration = MLModelConfiguration()
    configuration.computeUnits = arguments.computeUnits
    let model = try MLModel(contentsOf: compiledURL, configuration: configuration)

    let provider = try CoreMLDetectionProvider(model: model)
    try await provider.prepare()

    let cgImage = try loadCGImage(at: arguments.imagePath)
    let buffer = try pixelBuffer(from: cgImage)
    let frame = CapturedFrame(timestamp: 0,
                              cameraTransform: .identity,
                              image: PixelBufferImage(pixelBuffer: buffer))

    let start = ContinuousClock.now
    let all = try await provider.detect(in: frame)
    let elapsed = ContinuousClock.now - start
    let detections = all.filter { $0.confidence >= arguments.minConfidence }

    let report = EvalReport(
        model: arguments.modelPath,
        image: arguments.imagePath,
        compute: arguments.computeLabel,
        imageWidth: cgImage.width,
        imageHeight: cgImage.height,
        inferenceSeconds: Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18,
        detections: detections.map {
            EvalReport.Entry(classLabel: $0.classLabel, confidence: $0.confidence,
                             x: $0.boundingBox.x, y: $0.boundingBox.y,
                             width: $0.boundingBox.width, height: $0.boundingBox.height)
        })

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = try encoder.encode(report)
    if let jsonPath = arguments.jsonPath {
        try json.write(to: URL(fileURLWithPath: jsonPath))
    }
    print(String(decoding: json, as: UTF8.self))

    if let annotatePath = arguments.annotatePath {
        try writeAnnotatedImage(cgImage, detections: detections, to: annotatePath)
        FileHandle.standardError.write(Data("annotated image → \(annotatePath)\n".utf8))
    }
} catch {
    FileHandle.standardError.write(Data("detection-eval: \(error)\n".utf8))
    exit(1)
}
