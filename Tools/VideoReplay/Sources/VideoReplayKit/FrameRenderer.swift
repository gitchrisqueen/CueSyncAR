//
//  FrameRenderer.swift
//  CueSync AR
//
//  CoreGraphics overlay for one replayed frame: the marked table quad,
//  detector boxes, tracked-ball positions, and the advised shot (cue ->
//  ghost-ball line, ghost ring, target ring, pocket ring, difficulty label).
//  Table-space shapes go back to pixels through the inverse homography, so
//  circles on the cloth come out as the perspective ellipses they are.
//

import CoachKit
import CoreGraphics
import CoreText
import CueSyncCore
import Foundation

public enum FrameRenderer {
    private static func color(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private static let cyan = color(0, 0.9, 1)
    private static let orange = color(1, 0.55, 0)
    private static let magenta = color(1, 0.2, 0.9)
    private static let yellow = color(1, 0.85, 0)
    private static let green = color(0.1, 1, 0.4)
    private static let white = color(1, 1, 1)
    private static let red = color(1, 0.25, 0.25)

    public static func render(image: CGImage, result: FrameResult, geometry: ClipGeometry,
                              caption: String) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // From here on, coordinates are pixels with a TOP-LEFT origin.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let scale = max(1, Double(width) / 720)
        context.setLineWidth(2 * scale)
        context.setLineJoin(.round)

        drawTableQuad(context, geometry: geometry, scale: scale)
        drawDetections(context, result: result, scale: scale)
        drawTracked(context, result: result, geometry: geometry, scale: scale)
        if let shot = result.selected {
            drawShot(context, shot: shot, geometry: geometry, scale: scale)
        }
        drawBanner(context, result: result, caption: caption, scale: scale)
        return context.makeImage()
    }

    // MARK: - Layers

    private static func drawTableQuad(_ context: CGContext, geometry: ClipGeometry, scale: Double) {
        context.setStrokeColor(red)
        context.setLineWidth(1.5 * scale)
        let corners = geometry.pixelCorners
        context.addLines(between: corners.map { CGPoint(x: $0.x, y: $0.y) })
        context.closePath()
        context.strokePath()
        for (index, corner) in corners.enumerated() {
            drawText(context, "c\(index)", at: CGPoint(x: corner.x + 4 * scale, y: corner.y + 4 * scale),
                     size: 11 * scale, color: red)
        }
    }

    private static func drawDetections(_ context: CGContext, result: FrameResult, scale: Double) {
        context.setLineWidth(1.5 * scale)
        let width = Double(result.imageSize.width)
        let height = Double(result.imageSize.height)
        for detection in result.detections {
            let box = detection.boundingBox
            let rect = CGRect(x: box.x * width, y: box.y * height,
                              width: box.width * width, height: box.height * height)
            let tint: CGColor = detection.isCueStick ? yellow
                : detection.ballKind == .cue ? white : green
            context.setStrokeColor(tint)
            context.stroke(rect)
            drawText(context, "\(detection.classLabel) \(Int(detection.confidence * 100))",
                     at: CGPoint(x: rect.minX, y: rect.minY - 2 * scale), size: 9 * scale, color: tint)
        }
    }

    private static func drawTracked(_ context: CGContext, result: FrameResult,
                                    geometry: ClipGeometry, scale: Double) {
        context.setStrokeColor(magenta)
        context.setLineWidth(1.5 * scale)
        for ball in result.tracked {
            guard let pixel = geometry.tableToImage.apply(ball.position) else { continue }
            let arm = 4 * scale
            context.move(to: CGPoint(x: pixel.x - arm, y: pixel.y))
            context.addLine(to: CGPoint(x: pixel.x + arm, y: pixel.y))
            context.move(to: CGPoint(x: pixel.x, y: pixel.y - arm))
            context.addLine(to: CGPoint(x: pixel.x, y: pixel.y + arm))
            context.strokePath()
        }
    }

    private static func drawShot(_ context: CGContext, shot: ShotOption, geometry: ClipGeometry,
                                 scale: Double) {
        let ballRadius = Ball.standardRadius
        context.setLineWidth(2.5 * scale)
        // Cue ball -> ghost ball.
        line(context, from: shot.aim.origin, to: shot.ghostBall, geometry: geometry, color: cyan)
        ring(context, center: shot.aim.origin, radius: ballRadius, geometry: geometry, color: white)
        ring(context, center: shot.ghostBall, radius: ballRadius, geometry: geometry, color: cyan)
        // Target -> pocket.
        line(context, from: shot.targetPosition, to: shot.pocketPosition, geometry: geometry, color: orange)
        ring(context, center: shot.targetPosition, radius: ballRadius * 1.3, geometry: geometry, color: orange)
        ring(context, center: shot.pocketPosition, radius: shot.pocketCaptureRadius, geometry: geometry,
             color: magenta)
        if let anchor = geometry.tableToImage.apply(shot.ghostBall) {
            let label = String(format: "%@ · %@ · %.2f", shot.title, shot.detail, shot.difficulty)
            drawText(context, label, at: CGPoint(x: anchor.x + 8 * scale, y: anchor.y - 8 * scale),
                     size: 12 * scale, color: cyan)
        }
    }

    private static func drawBanner(_ context: CGContext, result: FrameResult, caption: String,
                                   scale: Double) {
        let cue: String
        switch result.cueStatus {
        case .ok: cue = "cue ok"
        case .missing: cue = "NO CUE BALL"
        case .ambiguous(let count): cue = "AMBIGUOUS CUE x\(count)"
        }
        let lines = [
            "\(caption)  det \(result.detections.count)  tracked \(result.tracked.count)  \(cue)",
            "shots \(result.options.count)  sel \(result.selected?.id ?? "none")  stick \(result.stickDetections)",
        ]
        for (index, line) in lines.enumerated() {
            drawText(context, line, at: CGPoint(x: 6 * scale, y: (16 + 15 * Double(index)) * scale),
                     size: 12 * scale, color: white)
        }
    }

    // MARK: - Primitives

    private static func line(_ context: CGContext, from: Vec2, to: Vec2, geometry: ClipGeometry,
                             color: CGColor) {
        guard let start = geometry.tableToImage.apply(from),
              let end = geometry.tableToImage.apply(to) else { return }
        context.setStrokeColor(color)
        context.move(to: CGPoint(x: start.x, y: start.y))
        context.addLine(to: CGPoint(x: end.x, y: end.y))
        context.strokePath()
    }

    /// A table-space circle projected to the image (an ellipse in perspective).
    private static func ring(_ context: CGContext, center: Vec2, radius: Double, geometry: ClipGeometry,
                             color: CGColor) {
        let points = (0...32).compactMap { step -> CGPoint? in
            let angle = Double(step) / 32 * 2 * .pi
            let table = Vec2(center.x + radius * cos(angle), center.y + radius * sin(angle))
            return geometry.tableToImage.apply(table).map { CGPoint(x: $0.x, y: $0.y) }
        }
        guard points.count > 2 else { return }
        context.setStrokeColor(color)
        context.addLines(between: points)
        context.strokePath()
    }

    /// Text with a dark backing plate so labels stay legible on any cloth.
    private static func drawText(_ context: CGContext, _ text: String, at origin: CGPoint,
                                 size: Double, color: CGColor) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        context.fill(CGRect(x: origin.x - 2, y: origin.y - size, width: bounds.width + 4, height: size + 4))
        context.textPosition = origin
        CTLineDraw(line, context)
    }
}
