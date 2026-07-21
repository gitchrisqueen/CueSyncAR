//
//  RoboflowRemoteProvider.swift
//  DetectionRoboflow
//
//  Task M2-06: DetectionProviding over Roboflow's hosted inference API
//  (detect.roboflow.com). Exists for model evaluation/A-B testing — the MVP
//  ships an on-device Core ML model (M2-01) and must work offline; this
//  adapter requires network + an API key and degrades to a clear error
//  without one.
//
//  Cross-platform by construction: HTTP goes through the HTTPPosting seam
//  and frame→JPEG encoding through FrameJPEGEncoding, so response parsing
//  and request building are fully tested on Linux CI. Apple-only impls of
//  both seams live behind canImport gates.
//

import CueSyncCore
import Foundation

/// One hosted model, e.g. slug "pool-ball-agzev", version 1.
public struct RoboflowModelRef: Sendable, Equatable, Codable, Identifiable, Hashable {
    public var slug: String
    public var version: Int
    /// Human label for pickers ("xhujustin — Pool Ball").
    public var label: String

    public init(slug: String, version: Int, label: String) {
        self.slug = slug
        self.version = version
        self.label = label
    }

    public var id: String { "\(slug)/\(version)" }
}

/// Minimal HTTP seam so the provider is testable without a network.
public protocol HTTPPosting: Sendable {
    func post(url: URL, body: Data, contentType: String) async throws -> Data
}

/// Converts a captured frame into JPEG data for upload. Apple platforms use
/// PixelBufferJPEGEncoder; tests inject fixtures.
public protocol FrameJPEGEncoding: Sendable {
    /// Returns JPEG data plus the encoded pixel dimensions (post-downscale).
    func encodeJPEG(from frame: CapturedFrame) throws -> (data: Data, width: Int, height: Int)
}

public enum RoboflowError: Error, Equatable {
    case missingAPIKey
    case frameNotEncodable
    case badResponse(String)
}

public struct RoboflowRemoteProvider: DetectionProviding {
    public let model: RoboflowModelRef
    private let apiKey: String
    private let transport: any HTTPPosting
    private let encoder: any FrameJPEGEncoding
    /// Server-side confidence floor (0...1) — keep low; the pipeline gates.
    private let confidenceFloor: Double

    public init(model: RoboflowModelRef,
                apiKey: String,
                transport: any HTTPPosting,
                encoder: any FrameJPEGEncoding,
                confidenceFloor: Double = 0.2) {
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
        self.encoder = encoder
        self.confidenceFloor = confidenceFloor
    }

    public func prepare() async throws {
        guard !apiKey.isEmpty else { throw RoboflowError.missingAPIKey }
    }

    public func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        guard !apiKey.isEmpty else { throw RoboflowError.missingAPIKey }
        let encoded = try encoder.encodeJPEG(from: frame)
        let url = Self.requestURL(model: model, apiKey: apiKey,
                                  confidenceFloor: confidenceFloor)
        let body = Data(encoded.data.base64EncodedString().utf8)
        let responseData = try await transport.post(
            url: url, body: body,
            contentType: "application/x-www-form-urlencoded")
        return try Self.parse(responseData)
    }

    // MARK: - Pure pieces (unit-tested)

    static func requestURL(model: RoboflowModelRef, apiKey: String,
                           confidenceFloor: Double) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "detect.roboflow.com"
        components.path = "/\(model.slug)/\(model.version)"
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "confidence", value: String(confidenceFloor)),
            URLQueryItem(name: "overlap", value: "0.5")
        ]
        // Components above are always URL-safe; force unwrap would still be
        // wrong under playbook style, so fail closed to a harmless URL.
        return components.url ?? URL(fileURLWithPath: "/invalid")
    }

    struct Response: Decodable {
        struct Prediction: Decodable {
            let x: Double        // box CENTER, pixels of the uploaded image
            let y: Double
            let width: Double
            let height: Double
            let confidence: Double
            let `class`: String
        }
        struct Size: Decodable {
            let width: Double
            let height: Double
        }
        let predictions: [Prediction]
        let image: Size
    }

    static func parse(_ data: Data) throws -> [Detection2D] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            throw RoboflowError.badResponse(snippet)
        }
        guard response.image.width > 0, response.image.height > 0 else {
            throw RoboflowError.badResponse("zero image size")
        }
        return response.predictions.map { p in
            Detection2D(
                classLabel: p.class,
                boundingBox: NormalizedRect(
                    x: (p.x - p.width / 2) / response.image.width,
                    y: (p.y - p.height / 2) / response.image.height,
                    width: p.width / response.image.width,
                    height: p.height / response.image.height),
                confidence: p.confidence)
        }
    }
}

// MARK: - URLSession transport

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct URLSessionTransport: HTTPPosting {
    public init() {}

    public func post(url: URL, body: Data, contentType: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let snippet = data.map { String(decoding: $0.prefix(200), as: UTF8.self) } ?? ""
                    continuation.resume(throwing: RoboflowError.badResponse(
                        "HTTP \(http.statusCode): \(snippet)"))
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
            task.resume()
        }
    }
}

// MARK: - Apple-platform JPEG encoder

#if canImport(CoreImage) && canImport(CoreVideo) && canImport(ImageIO)
import CoreImage
import CoreVideo
import ImageIO

/// Encodes CVPixelBuffer-backed frames, downscaling so the long side is at
/// most `maxDimension` (API latency is dominated by upload size).
public struct PixelBufferJPEGEncoder: FrameJPEGEncoding, @unchecked Sendable {
    // CIContext is documented thread-safe.
    private let context = CIContext(options: [.cacheIntermediates: false])
    public let maxDimension: Double

    public init(maxDimension: Double = 640) {
        self.maxDimension = maxDimension
    }

    public func encodeJPEG(from frame: CapturedFrame) throws -> (data: Data, width: Int, height: Int) {
        guard let image = frame.image,
              let buffer = (image as? PixelBufferProviding)?.cvPixelBuffer else {
            throw RoboflowError.frameNotEncodable
        }
        var ciImage = CIImage(cvPixelBuffer: buffer)
        let extent = ciImage.extent
        let longSide = max(extent.width, extent.height)
        if longSide > maxDimension {
            let scale = maxDimension / longSide
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = context.jpegRepresentation(
            of: ciImage, colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
        else {
            throw RoboflowError.frameNotEncodable
        }
        return (data, Int(ciImage.extent.width.rounded()), Int(ciImage.extent.height.rounded()))
    }
}

/// Cross-package view of a pixel-buffer-backed frame image. PerceptionKit's
/// PixelBufferImage conforms in the app target (one-line retroactive
/// conformance) to avoid a package dependency cycle.
public protocol PixelBufferProviding {
    var cvPixelBuffer: CVPixelBuffer { get }
}
#endif
