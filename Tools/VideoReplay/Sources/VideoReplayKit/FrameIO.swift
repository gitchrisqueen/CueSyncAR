//
//  FrameIO.swift
//  CueSync AR
//
//  Image plumbing: file -> CGImage -> BGRA CVPixelBuffer (what the app's
//  CoreMLDetectionProvider consumes), and CGImage -> PNG. The loaders mirror
//  Tools/DetectionEval (a separate executable package, so not importable).
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FrameIOError: Error, CustomStringConvertible {
    case load(String)
    case pixelBuffer(CVReturn)
    case encode(String)

    public var description: String {
        switch self {
        case .load(let path): "cannot load image at \(path)"
        case .pixelBuffer(let status): "CVPixelBuffer creation failed (\(status))"
        case .encode(let path): "cannot write PNG to \(path)"
        }
    }
}

public enum FrameIO {
    /// Image files in `directory` (png/jpg/jpeg), sorted by name.
    public static func frameURLs(in directory: URL) throws -> [URL] {
        let allowed: Set<String> = ["png", "jpg", "jpeg"]
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FrameIOError.load(url.path)
        }
        return image
    }

    public static func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                         kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw FrameIOError.pixelBuffer(status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw FrameIOError.pixelBuffer(kCVReturnError)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FrameIOError.encode(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FrameIOError.encode(url.path) }
    }
}
