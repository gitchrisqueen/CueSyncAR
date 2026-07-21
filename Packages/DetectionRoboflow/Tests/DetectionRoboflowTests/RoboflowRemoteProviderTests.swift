import CueSyncCore
import CueSyncTestSupport
import Foundation
import Testing
@testable import DetectionRoboflow

private let sampleModel = RoboflowModelRef(slug: "pool-ball-agzev", version: 1,
                                           label: "xhujustin — Pool Ball")

private let sampleResponse = """
{
  "time": 0.05,
  "image": {"width": 640, "height": 480},
  "predictions": [
    {"x": 320, "y": 240, "width": 64, "height": 48, "confidence": 0.91,
     "class": "cue", "class_id": 0, "detection_id": "a"},
    {"x": 100, "y": 120, "width": 40, "height": 40, "confidence": 0.72,
     "class": "8", "class_id": 8, "detection_id": "b"}
  ]
}
"""

struct StubTransport: HTTPPosting {
    let response: Data
    let onRequest: (@Sendable (URL, Data, String) -> Void)?

    init(response: Data, onRequest: (@Sendable (URL, Data, String) -> Void)? = nil) {
        self.response = response
        self.onRequest = onRequest
    }

    func post(url: URL, body: Data, contentType: String) async throws -> Data {
        onRequest?(url, body, contentType)
        return response
    }
}

struct StubEncoder: FrameJPEGEncoding {
    func encodeJPEG(from frame: CapturedFrame) throws -> (data: Data, width: Int, height: Int) {
        (Data([0xFF, 0xD8, 0xFF]), 640, 480)
    }
}

@Suite("Roboflow response parsing")
struct ResponseParsingTests {
    @Test func centersConvertToTopLeftNormalizedRects() throws {
        let detections = try RoboflowRemoteProvider.parse(Data(sampleResponse.utf8))
        #expect(detections.count == 2)

        let cue = detections[0]
        #expect(cue.classLabel == "cue")
        #expect(cue.ballKind == .cue)
        // Center (320,240) size (64,48) in 640×480 →
        // x: (320-32)/640 = 0.45; y: (240-24)/480 = 0.45.
        #expect(abs(cue.boundingBox.x - 0.45) < 1e-9)
        #expect(abs(cue.boundingBox.y - 0.45) < 1e-9)
        #expect(abs(cue.boundingBox.width - 0.1) < 1e-9)
        #expect(abs(cue.boundingBox.height - 0.1) < 1e-9)
        #expect(abs(cue.confidence - 0.91) < 1e-9)

        #expect(detections[1].ballKind == .eight)
    }

    @Test func malformedJSONThrowsBadResponse() {
        #expect(throws: RoboflowError.self) {
            _ = try RoboflowRemoteProvider.parse(Data("not json".utf8))
        }
        #expect(throws: RoboflowError.self) {
            _ = try RoboflowRemoteProvider.parse(Data(#"{"predictions":[],"image":{"width":0,"height":0}}"#.utf8))
        }
    }

    @Test func emptyPredictionsAreValid() throws {
        let data = Data(#"{"predictions":[],"image":{"width":640,"height":480}}"#.utf8)
        let detections = try RoboflowRemoteProvider.parse(data)
        #expect(detections.isEmpty)
    }
}

@Suite("Roboflow request building")
struct RequestBuildingTests {
    @Test func urlEncodesModelKeyAndThresholds() {
        let url = RoboflowRemoteProvider.requestURL(model: sampleModel,
                                                    apiKey: "test-key",
                                                    confidenceFloor: 0.2)
        let s = url.absoluteString
        #expect(s.hasPrefix("https://detect.roboflow.com/pool-ball-agzev/1?"))
        #expect(s.contains("api_key=test-key"))
        #expect(s.contains("confidence=0.2"))
    }
}

@Suite("Roboflow provider behavior")
struct ProviderBehaviorTests {
    private func makeFrame() -> CapturedFrame {
        CapturedFrame(timestamp: 0, cameraTransform: .identity,
                      image: FixtureImageBuffer())
    }

    @Test func detectPostsBase64JPEGAndParses() async throws {
        let recorded = RecordedRequest()
        let provider = RoboflowRemoteProvider(
            model: sampleModel, apiKey: "k",
            transport: StubTransport(response: Data(sampleResponse.utf8)) { url, body, contentType in
                recorded.set(url: url, body: body, contentType: contentType)
            },
            encoder: StubEncoder())
        let detections = try await provider.detect(in: makeFrame())
        #expect(detections.count == 2)
        let (url, body, contentType) = recorded.get()
        #expect(url?.host == "detect.roboflow.com")
        #expect(contentType == "application/x-www-form-urlencoded")
        // Body is base64 of the stub JPEG bytes.
        #expect(body.map { String(decoding: $0, as: UTF8.self) } == Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
    }

    @Test func missingKeyFailsFastWithoutNetwork() async {
        let provider = RoboflowRemoteProvider(
            model: sampleModel, apiKey: "",
            transport: StubTransport(response: Data()),
            encoder: StubEncoder())
        await #expect(throws: RoboflowError.missingAPIKey) {
            try await provider.prepare()
        }
        await #expect(throws: RoboflowError.missingAPIKey) {
            _ = try await provider.detect(in: makeFrame())
        }
    }

    @Test func meetsDetectionProviderContract() async {
        let provider = RoboflowRemoteProvider(
            model: sampleModel, apiKey: "k",
            transport: StubTransport(response: Data(sampleResponse.utf8)),
            encoder: StubEncoder())
        let failures = await ProviderContracts.checkDetectionProvider(provider)
        #expect(failures.isEmpty, "\(failures)")
    }
}

/// Tiny thread-safe capture box for the stub callback.
private final class RecordedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var body: Data?
    private var contentType: String = ""

    func set(url: URL, body: Data, contentType: String) {
        lock.lock()
        defer { lock.unlock() }
        self.url = url
        self.body = body
        self.contentType = contentType
    }

    func get() -> (URL?, Data?, String) {
        lock.lock()
        defer { lock.unlock() }
        return (url, body, contentType)
    }
}
