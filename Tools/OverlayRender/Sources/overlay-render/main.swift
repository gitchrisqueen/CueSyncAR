//
//  main.swift
//  OverlayRender
//
//  Usage: overlay-render --out <png> [--background <png>] [--layout open|blocked]
//
//  Builds a synthetic table, plans with the real ShotPlanner, converts the
//  best option to OverlayLayout exactly as the app does, fills a RealityKit
//  root with ARExperience.OverlayEntityBuilder (the device code path),
//  renders it offscreen with RealityRenderer (transparent clear colour) and
//  composites over a background still with CoreGraphics. Prints where the
//  key table points land in pixels so placement can be checked numerically.
//

import ARExperience
import AppKit
import CoachKit
import CueSyncCore
import Foundation
import Metal
import RealityKit
import TableSpace

struct Options {
    var out: String
    var background: String?
    var blocked = false
}

func parseOptions() -> Options {
    var out: String?
    var background: String?
    var blocked = false
    var args = CommandLine.arguments.dropFirst()
    func fail(_ message: String) -> Never {
        let usage = "usage: overlay-render --out <png> [--background <png>] [--layout open|blocked]"
        FileHandle.standardError.write(Data("\(message)\n\(usage)\n".utf8))
        exit(2)
    }
    while let flag = args.popFirst() {
        guard let value = args.popFirst() else { fail("missing value for \(flag)") }
        switch flag {
        case "--out": out = value
        case "--background": background = value
        case "--layout":
            guard value == "open" || value == "blocked" else { fail("--layout must be open or blocked") }
            blocked = value == "blocked"
        default: fail("unknown flag \(flag)")
        }
    }
    guard let out else { fail("--out is required") }
    return Options(out: out, background: background, blocked: blocked)
}

// MARK: - Scene

/// Pose of a phone held above the table, looking down at it, in world space
/// (table lies in the xz-plane, +y up; table +x = world +x, table +y = world -z).
struct PhoneCamera {
    var position = SIMD3<Double>(0, 1.15, 0.85)
    var target = SIMD3<Double>(0, 0, -0.05)
    var verticalFOVDegrees = 75.0
    var width = 1600
    var height = 900

    /// Same pinhole model RealityKit uses (vertical FOV, centered principal
    /// point), so this is the independent numeric check of the render.
    func project(_ p: SIMD3<Double>) -> CGPoint {
        let forward = (target - position).normalized
        let right = forward.cross(SIMD3(0, 1, 0)).normalized
        let up = right.cross(forward)
        let rel = p - position
        let (x, y, z) = (rel.dot(right), rel.dot(up), rel.dot(forward))
        let tanHalf = tan(verticalFOVDegrees * .pi / 360)
        let aspect = Double(width) / Double(height)
        let ndcX = x / (z * tanHalf * aspect)
        let ndcY = y / (z * tanHalf)
        return CGPoint(x: (ndcX + 1) / 2 * Double(width), y: (1 - ndcY) / 2 * Double(height))
    }
}

func makeState(blocked: Bool) -> TableState {
    var balls = [
        Ball(id: BallID(0), kind: .cue, position: Vec2(-0.75, -0.12)),
        Ball(id: BallID(3), kind: .solid(3), position: Vec2(0.30, 0.22)),
        Ball(id: BallID(5), kind: .solid(5), position: Vec2(0.85, -0.30)),
        Ball(id: BallID(11), kind: .stripe(11), position: Vec2(-0.20, 0.40)),
        Ball(id: BallID(13), kind: .stripe(13), position: Vec2(1.0, 0.30)),
    ]
    if blocked {
        // Sits on the open layout's cue-to-3-ball line, forcing another shot.
        balls.append(Ball(id: BallID(8), kind: .eight, position: Vec2(-0.22, 0.05)))
    }
    return TableState(table: Table(size: .nineFoot), balls: balls)
}

/// Mirrors App/Sources/ShotAdvice+UI.swift `advising` (colour = Theme.adviceLine).
func adviceOverlay(state: TableState, calibration: TableCalibration) -> (OverlayLayout, ShotOption)? {
    guard let cue = state.cueBall,
          let best = ShotPlanner.plan(state: state).first else { return nil }
    let advised = OverlayLayout.AdvisedShot(
        cue: best.aim.origin, ghost: best.ghostBall, target: best.targetPosition,
        pocket: best.pocketPosition, pocketRadius: best.pocketCaptureRadius,
        color: 0xFF4FD8, cueID: cue.id, targetID: best.target)
    let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration)
        .withSuggestion(advised, calibration: calibration)
    return (layout, best)
}

// MARK: - Rendering

struct RenderError: Error, CustomStringConvertible {
    var description: String
}

/// RealityRenderer's antialiasing property is not available on macOS 15, so the
/// overlay is rendered at this multiple and downsampled when compositing.
let supersample = 2

@MainActor
func renderOverlay(layout: OverlayLayout, camera: PhoneCamera) async throws -> CGImage {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw RenderError(description: "no Metal device")
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: camera.width * supersample,
        height: camera.height * supersample, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw RenderError(description: "texture allocation failed")
    }

    let renderer = try RealityRenderer()
    let root = Entity()
    OverlayEntityBuilder.populate(root: root, layout: layout)
    renderer.entities.append(root)

    let cameraEntity = PerspectiveCamera()
    cameraEntity.camera.fieldOfViewInDegrees = Float(camera.verticalFOVDegrees)
    renderer.entities.append(cameraEntity)
    cameraEntity.look(at: SIMD3<Float>(camera.target), from: SIMD3<Float>(camera.position),
                      relativeTo: nil)
    renderer.activeCamera = cameraEntity
    renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
    renderer.cameraSettings.isToneMappingEnabled = false

    let output = try RealityRenderer.CameraOutput(
        RealityRenderer.CameraOutput.Descriptor.singleProjection(colorTexture: texture))
    // Warm-up frames let mesh/material resources finish loading; only the
    // last frame is read back.
    for _ in 0..<3 {
        try await renderFrame(renderer, output: output)
    }
    return try image(from: readable(copyOf: texture, device: device))
}

@MainActor
func renderFrame(_ renderer: RealityRenderer, output: RealityRenderer.CameraOutput) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        do {
            try renderer.updateAndRender(deltaTime: 1.0 / 30, cameraOutput: output,
                                         onComplete: { _ in continuation.resume() })
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

/// RealityKit renders into a private texture. Blit to a managed one and
/// synchronize for CPU readback: on this Mac (Intel + discrete AMD GPU) a
/// plain getBytes on the render target, or a blit into a shared texture,
/// read back all zeros.
func readable(copyOf texture: MTLTexture, device: MTLDevice) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
    descriptor.storageMode = .managed
    guard let copy = device.makeTexture(descriptor: descriptor),
          let queue = device.makeCommandQueue(),
          let buffer = queue.makeCommandBuffer(),
          let blit = buffer.makeBlitCommandEncoder() else {
        throw RenderError(description: "could not set up readback blit")
    }
    blit.copy(from: texture, to: copy)
    blit.synchronize(resource: copy)
    blit.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    return copy
}

/// Distance (output pixels) from `point` to the nearest overlay pixel with
/// alpha > 0, searching a 40 px radius; 40 when none.
func nearestCoveredDistance(in image: CGImage, around point: CGPoint, scale: Int) -> Double {
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 40 }
    let (cx, cy) = (Int(point.x * Double(scale)), Int(point.y * Double(scale)))
    var best = 40.0
    let reach = 40 * scale
    for y in max(0, cy - reach)..<min(image.height, cy + reach) {
        for x in max(0, cx - reach)..<min(image.width, cx + reach) where bytes[y * image.bytesPerRow + x * 4 + 3] > 0 {
            best = min(best, hypot(Double(x - cx), Double(y - cy)) / Double(scale))
        }
    }
    return best
}

func image(from texture: MTLTexture) throws -> CGImage {
    let (width, height) = (texture.width, texture.height)
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)
    // Alpha is the top byte of each little-endian BGRA pixel.
    let covered = stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 0 ? 1 : 0) }
    print("overlay pixels with alpha > 0: \(covered) of \(width * height)")
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                              bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent) else {
        throw RenderError(description: "could not wrap texture bytes in a CGImage")
    }
    return image
}

// MARK: - Compositing

func makeContext(_ camera: PhoneCamera) throws -> CGContext {
    guard let context = CGContext(
        data: nil, width: camera.width, height: camera.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue) else {
        throw RenderError(description: "could not create bitmap context")
    }
    return context
}

/// Flat cloth-coloured stand-in (no footage), with a stand-in disc for each
/// ball at its projected position so overlay rings can be judged against
/// something. Drawn with the independent `PhoneCamera.project`.
func syntheticBackground(state: TableState, calibration: TableCalibration,
                         camera: PhoneCamera) throws -> CGImage {
    let context = try makeContext(camera)
    let rect = CGRect(x: 0, y: 0, width: camera.width, height: camera.height)
    context.setFillColor(CGColor(red: 0.10, green: 0.36, blue: 0.22, alpha: 1))
    context.fill(rect)
    // Table outline (rails) from the four playfield corners.
    let half = (state.table.size.playField.width / 2, state.table.size.playField.height / 2)
    let corners = [(-half.0, -half.1), (half.0, -half.1), (half.0, half.1), (-half.0, half.1)]
        .map { screen(calibration.tableToWorld(Vec2($0.0, $0.1)), camera) }
    context.setStrokeColor(CGColor(red: 0.35, green: 0.22, blue: 0.12, alpha: 1))
    context.setLineWidth(10)
    context.addLines(between: corners)
    context.closePath()
    context.strokePath()
    for ball in state.balls {
        let centre = screen(calibration.tableToWorld(ball.position) + SIMD3(0, ball.radius, 0), camera)
        let edge = screen(calibration.tableToWorld(ball.position) + SIMD3(ball.radius, ball.radius, 0), camera)
        let radius = abs(edge.x - centre.x)
        context.setFillColor(ball.kind == .cue
                             ? CGColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1)
                             : CGColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                       width: radius * 2, height: radius * 2))
    }
    guard let image = context.makeImage() else {
        throw RenderError(description: "could not make background image")
    }
    return image
}

/// Camera pixels (top-left origin) → CoreGraphics context point (bottom-left origin).
func screen(_ world: SIMD3<Double>, _ camera: PhoneCamera) -> CGPoint {
    let p = camera.project(world)
    return CGPoint(x: p.x, y: Double(camera.height) - p.y)
}

func composite(background: CGImage, overlay: CGImage, camera: PhoneCamera) throws -> CGImage {
    let context = try makeContext(camera)
    let rect = CGRect(x: 0, y: 0, width: camera.width, height: camera.height)
    context.draw(background, in: rect)
    context.interpolationQuality = .high
    context.draw(overlay, in: rect)
    guard let image = context.makeImage() else {
        throw RenderError(description: "composite failed")
    }
    return image
}

func writePNG(_ image: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw RenderError(description: "PNG encode failed")
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url)
    print("wrote \(url.path) (\(data.count) bytes)")
}

// MARK: - Main

@MainActor
func run() async throws {
    let options = parseOptions()
    let camera = PhoneCamera()
    // World xz-plane, table +y mapped to world -z, centered at the origin.
    let calibration = TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                       yAxis: Vec3(0, 0, -1), size: .nineFoot)
    let state = makeState(blocked: options.blocked)
    guard let (layout, best) = adviceOverlay(state: state, calibration: calibration) else {
        throw RenderError(description: "no viable shot in the demo layout")
    }
    print("advice: \(best.title) - \(best.detail) - difficulty \(String(format: "%.2f", best.difficulty))")
    let probes = [("cue", best.aim.origin), ("ghost", best.ghostBall),
                  ("target", best.targetPosition), ("pocket", best.pocketPosition)]
    let overlay = try await renderOverlay(layout: layout, camera: camera)
    // Independent check: the pinhole projection of each table point must land
    // on (or within a few pixels of) rendered overlay pixels.
    for (name, point) in probes {
        let px = camera.project(calibration.tableToWorld(point))
        let gap = nearestCoveredDistance(in: overlay, around: px, scale: supersample)
        print(String(format: "probe %@ projects to pixel (%.1f, %.1f); nearest overlay pixel %.1f px away",
                     name, px.x, px.y, gap))
    }
    let background: CGImage
    if let path = options.background {
        guard let source = NSImage(contentsOfFile: path),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RenderError(description: "cannot read background \(path)")
        }
        background = cg
    } else {
        background = try syntheticBackground(state: state, calibration: calibration, camera: camera)
    }
    try writePNG(composite(background: background, overlay: overlay, camera: camera), to: options.out)
    if let raw = ProcessInfo.processInfo.environment["OVERLAY_RENDER_RAW"] {
        try writePNG(overlay, to: raw)
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("overlay-render failed: \(error)\n".utf8))
    exit(1)
}
