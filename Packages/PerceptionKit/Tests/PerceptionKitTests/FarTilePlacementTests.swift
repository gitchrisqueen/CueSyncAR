//
//  FarTilePlacementTests.swift
//  PerceptionKitTests
//
//  Far-tile placement from the locked table: synthetic geometry (always
//  runs) and, when a device recording is on this machine, the real pose,
//  intrinsics and calibration of the 2026-11-12 grid run. The recording is
//  local data: set CUESYNC_RECORDING_DIR, or leave it at the default under
//  ~/CueSyncRuns, and the recording tests run; without it they are skipped.
//  Nothing from the recording is committed.
//

import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import PerceptionKit

/// Camera-to-world transform for a camera at `from` looking at `target`
/// (ARKit convention: the camera looks along its -z axis).
func lookAtTransform(from: Vec3, to target: Vec3) -> Transform3D {
    let forward = (target - from).normalized
    let back = Vec3(-forward.x, -forward.y, -forward.z)
    let right = Vec3(0, 1, 0).cross(back).normalized
    let up = back.cross(right)
    return Transform3D(columns: [
        SIMD4(right.x, right.y, right.z, 0), SIMD4(up.x, up.y, up.z, 0),
        SIMD4(back.x, back.y, back.z, 0), SIMD4(from.x, from.y, from.z, 1)
    ])
}

/// A fixed table at the world origin: +x along the long axis, +y across,
/// plane normal +y world (up).
let placementCalibration = TableCalibration(
    origin: Vec3(0, 0, 0), xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, -1), size: .eightFoot)

struct PlacementImage: ImageBufferProviding {
    let width: Int
    let height: Int
}

func placementFrame(camera: Vec3, target: Vec3, focal: Double = 1300) -> CapturedFrame {
    CapturedFrame(timestamp: 1,
                  cameraTransform: lookAtTransform(from: camera, to: target),
                  image: PlacementImage(width: 1440, height: 1080),
                  intrinsics: CameraIntrinsics(focalX: focal, focalY: focal, principalX: 719.5,
                                               principalY: 539.5, imageWidth: 1440, imageHeight: 1080))
}

@Suite("FarTilePlacement (synthetic)")
struct FarTilePlacementSyntheticTests {
    /// The operator's view: behind one end of the table, 1.1 m up, looking
    /// down the long axis at the far end.
    private let frame = placementFrame(camera: Vec3(-2.3, 1.1, 0), target: Vec3(0.3, 0, 0))

    @Test func theWindowKeepsTheFramesAspectRatioAndStaysInsideTheFrame() throws {
        let plan = try #require(FarTilePlacement.plan(calibration: placementCalibration, frame: frame))
        let crop = try #require(plan.region.pixelCrop(frameWidth: 1440, frameHeight: 1080))
        #expect(Double(crop.width) / Double(crop.height) == 1440.0 / 1080.0)
        #expect(crop.x >= 0 && crop.y >= 0)
        #expect(crop.x + crop.width <= 1440 && crop.y + crop.height <= 1080)
        #expect(FarTilePlacement.sizeRange.contains(plan.region.size))
    }

    @Test func theWindowCoversEveryBallNarrowerThanTheThreshold() throws {
        let plan = try #require(FarTilePlacement.plan(calibration: placementCalibration, frame: frame,
                                                      narrowerThanPixels: 32))
        #expect(plan.narrowSamples > 0 && plan.narrowSamples < plan.visibleSamples)
        // Every ball on a grid across the far end, projected with the same
        // camera, must land inside the window with a ball of margin.
        let radius = Ball.standardRadius
        var checked = 0
        for x in stride(from: 0.2, through: 1.1, by: 0.15) {
            for y in stride(from: -0.5, through: 0.5, by: 0.25) {
                let world = placementCalibration.tableToWorld(Vec2(x, y)) + placementCalibration.normal * radius
                guard let image = PlaneGeometryRaycaster(calibration: placementCalibration)
                    .projectToImage(worldPoint: world, frame: frame) else { continue }
                let depth = -(world - frame.cameraTransform.translation).dot(frame.cameraTransform.axis(2))
                let pixels = 1300 * 2 * radius / depth
                guard pixels < 32 else { continue }
                checked += 1
                let r = plan.region
                #expect(image.x > r.x && image.x < r.x + r.size, "x \(x) y \(y)")
                #expect(image.y > r.y && image.y < r.y + r.size, "x \(x) y \(y)")
            }
        }
        #expect(checked > 10)
    }

    @Test func aCloserCameraNeedsNoWindowBecauseEveryBallIsBig() {
        let close = placementFrame(camera: Vec3(0, 0.5, 0.4), target: Vec3(0.1, 0, 0))
        #expect(FarTilePlacement.plan(calibration: placementCalibration, frame: close) == nil)
    }

    @Test func aCameraLookingAwayFromTheTableGetsNoWindow() {
        let away = placementFrame(camera: Vec3(-2.3, 1.1, 0), target: Vec3(-6, 1.1, 0))
        #expect(FarTilePlacement.plan(calibration: placementCalibration, frame: away) == nil)
    }

    @Test func aFrameWithoutIntrinsicsGetsNoWindow() {
        var bare = frame
        bare.intrinsics = nil
        #expect(FarTilePlacement.plan(calibration: placementCalibration, frame: bare) == nil)
    }

    @Test func aHigherThresholdGrowsTheWindow() throws {
        let tight = try #require(FarTilePlacement.plan(calibration: placementCalibration, frame: frame,
                                                       narrowerThanPixels: 24))
        let loose = try #require(FarTilePlacement.plan(calibration: placementCalibration, frame: frame,
                                                       narrowerThanPixels: 44))
        #expect(loose.region.size >= tight.region.size)
        #expect(loose.narrowSamples > tight.narrowSamples)
    }

    @Test func theWindowFollowsTheCameraPose() throws {
        let left = try #require(FarTilePlacement.plan(
            calibration: placementCalibration,
            frame: placementFrame(camera: Vec3(-2.3, 1.1, 0.5), target: Vec3(0.3, 0, 0))))
        let right = try #require(FarTilePlacement.plan(
            calibration: placementCalibration,
            frame: placementFrame(camera: Vec3(-2.3, 1.1, -0.5), target: Vec3(0.3, 0, 0))))
        #expect(left.region != right.region)
    }
}

// MARK: - The recording

/// The grid run, if it is on this machine.
struct LocalRecording {
    let directory: URL
    let calibration: TableCalibration
    let frames: [CapturedFrame]

    static func load() -> LocalRecording? {
        let override = ProcessInfo.processInfo.environment["CUESYNC_RECORDING_DIR"]
        let path = override ?? (NSHomeDirectory() + "/CueSyncRuns/goal14/session-grid/device-20261112T040347Z")
        let directory = URL(fileURLWithPath: path)
        guard let calibrationData = try? Data(contentsOf: directory.appendingPathComponent("calibration.json")),
              let framesText = try? String(contentsOf: directory.appendingPathComponent("frames.jsonl"),
                                           encoding: .utf8),
              let json = try? JSONSerialization.jsonObject(with: calibrationData) as? [String: Any],
              let origin = (json["origin"] as? [Double]), let xAxis = (json["xAxis"] as? [Double]),
              let yAxis = (json["yAxis"] as? [Double]), origin.count == 3, xAxis.count == 3, yAxis.count == 3,
              let size = (json["size"] as? [String: Any])?["name"] as? String else { return nil }
        let tableSize: TableSize
        switch size {
        case "sevenFoot": tableSize = .sevenFoot
        case "eightFoot": tableSize = .eightFoot
        case "nineFoot": tableSize = .nineFoot
        default: return nil
        }
        var frames: [CapturedFrame] = []
        for line in framesText.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let m = object["cameraTransform"] as? [Double], m.count == 16,
                  let k = object["intrinsics"] as? [String: Double],
                  let image = object["image"] as? [String: Any],
                  let width = image["width"] as? Int, let height = image["height"] as? Int,
                  let timestamp = object["timestamp"] as? Double else { return nil }
            let columns = (0..<4).map { SIMD4(m[$0 * 4], m[$0 * 4 + 1], m[$0 * 4 + 2], m[$0 * 4 + 3]) }
            frames.append(CapturedFrame(
                timestamp: timestamp, cameraTransform: Transform3D(columns: columns),
                image: PlacementImage(width: width, height: height),
                intrinsics: CameraIntrinsics(focalX: k["focalX"] ?? 0, focalY: k["focalY"] ?? 0,
                                             principalX: k["principalX"] ?? 0, principalY: k["principalY"] ?? 0,
                                             imageWidth: k["imageWidth"] ?? 0, imageHeight: k["imageHeight"] ?? 0)))
        }
        guard !frames.isEmpty else { return nil }
        return LocalRecording(
            directory: directory,
            calibration: TableCalibration(origin: Vec3(origin[0], origin[1], origin[2]),
                                          xAxis: Vec3(xAxis[0], xAxis[1], xAxis[2]),
                                          yAxis: Vec3(yAxis[0], yAxis[1], yAxis[2]), size: tableSize),
            frames: frames)
    }
}

@Suite("FarTilePlacement (local recording)", .enabled(if: LocalRecording.load() != nil))
struct FarTilePlacementRecordingTests {
    /// Image-space centres (normalized, top-left origin) of the balls measured
    /// in the recording's frames. The far three are 21-25 px wide, the
    /// near ones 40+ px.
    private let farBalls: [(String, Double, Double)] = [
        ("far left", 0.414, 0.391), ("far centre (blue)", 0.4965, 0.389), ("far right", 0.581, 0.387),
        ("dark green", 0.590, 0.409), ("orange", 0.499, 0.411), ("second left", 0.407, 0.416)
    ]

    @Test func theWindowOverTheRecordedFramesCoversTheFarRowAndKeepsTheAspect() throws {
        let recording = try #require(LocalRecording.load())
        let plan = try #require(FarTilePlacement.plan(calibration: recording.calibration,
                                                      frame: recording.frames[0]))
        let region = plan.region
        print("PLACEMENT recording: x \(region.x) y \(region.y) size \(region.size) "
              + "narrow \(plan.narrowSamples)/\(plan.visibleSamples) px \(plan.narrowestPixels)...\(plan.widestPixels)")
        let crop = try #require(region.pixelCrop(frameWidth: 1440, frameHeight: 1080))
        #expect(Double(crop.width) / Double(crop.height) == 1440.0 / 1080.0)
        // The window's apparent ball widths bracket the measured 21..43 px.
        #expect(plan.narrowestPixels > 18 && plan.narrowestPixels < 28)
        #expect(plan.widestPixels > 38 && plan.widestPixels < 70)
        for (name, x, y) in farBalls {
            #expect(x > region.x && x < region.x + region.size, "\(name) x \(x) outside \(region)")
            #expect(y > region.y && y < region.y + region.size, "\(name) y \(y) outside \(region)")
        }
    }

    @Test func theWindowIsStableAcrossTheParkedRecording() throws {
        let recording = try #require(LocalRecording.load())
        let regions = recording.frames.compactMap {
            FarTilePlacement.plan(calibration: recording.calibration, frame: $0)?.region
        }
        #expect(regions.count == recording.frames.count)
        let first = try #require(regions.first)
        for region in regions {
            #expect(abs(region.x - first.x) < 0.01 && abs(region.y - first.y) < 0.01)
            #expect(abs(region.size - first.size) < 0.01)
        }
    }
}
