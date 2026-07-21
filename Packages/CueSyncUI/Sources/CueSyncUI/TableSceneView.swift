//
//  TableSceneView.swift
//  CueSyncUI
//
//  SwiftUI Canvas renderer for TableScene primitives. Shared by the in-app
//  mini-map and DisplayKit's external-display Table View — both compose a
//  TableScene and hand it here, so the drawing stays in one place.
//

#if canImport(SwiftUI)
import CueSyncCore
import SwiftUI

public struct TableSceneView: View {
    public let state: TableState
    public let prediction: ShotPrediction?

    private let feltColor = ColorToken(0x1E6B45)
    private let railColor = ColorToken(0x4A2C1A)

    public init(state: TableState, prediction: ShotPrediction? = nil) {
        self.state = state
        self.prediction = prediction
    }

    public var body: some View {
        Canvas { context, size in
            let scene = TableScene.compose(state: state,
                                           prediction: prediction,
                                           viewportWidth: size.width,
                                           viewportHeight: size.height)
            draw(scene, in: &context)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let pocketed = prediction?.pocketedBalls.count ?? 0
        let base = "Table view, \(state.balls.count) balls"
        return pocketed > 0 ? "\(base), \(pocketed) predicted to pocket" : base
    }

    private func draw(_ scene: TableScene, in context: inout GraphicsContext) {
        let rail = CGRect(x: scene.railFrame.x, y: scene.railFrame.y,
                          width: scene.railFrame.width, height: scene.railFrame.height)
        let felt = CGRect(x: scene.feltFrame.x, y: scene.feltFrame.y,
                          width: scene.feltFrame.width, height: scene.feltFrame.height)
        context.fill(Path(roundedRect: rail, cornerRadius: rail.width * 0.02),
                     with: .color(railColor.color))
        context.fill(Path(felt), with: .color(feltColor.color))

        for pocket in scene.pockets {
            let rect = circleRect(center: pocket.center, radius: pocket.radius)
            context.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.85)))
            if pocket.highlighted {
                let ring = circleRect(center: pocket.center, radius: pocket.radius * 1.25)
                context.stroke(Path(ellipseIn: ring),
                               with: .color(Theme.feltGreen.color),
                               lineWidth: max(2, pocket.radius * 0.25))
            }
        }

        for path in scene.paths {
            guard path.points.count > 1 else { continue }
            var line = Path()
            line.move(to: CGPoint(x: path.points[0].x, y: path.points[0].y))
            for point in path.points.dropFirst() {
                line.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            let width = max(2, scene.scale * 0.012)
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                                    dash: path.dashed ? [width * 3, width * 2.5] : [])
            context.stroke(line, with: .color(path.color.color), style: style)
        }

        if let ghost = scene.ghostBall {
            let rect = circleRect(center: ghost.center, radius: ghost.radius)
            context.stroke(Path(ellipseIn: rect),
                           with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: max(1.5, ghost.radius * 0.15),
                                              dash: [4, 3]))
        }

        for ball in scene.balls {
            drawBall(ball, in: &context)
        }
    }

    private func drawBall(_ ball: TableScene.Mark, in context: inout GraphicsContext) {
        let rect = circleRect(center: ball.center, radius: ball.radius)
        if ball.style.striped {
            context.fill(Path(ellipseIn: rect), with: .color(Theme.ballWhite.color))
            var band = context
            band.clip(to: Path(ellipseIn: rect))
            let bandRect = CGRect(x: rect.minX, y: rect.minY + rect.height * 0.25,
                                  width: rect.width, height: rect.height * 0.5)
            band.fill(Path(bandRect), with: .color(ball.style.fill.color))
        } else {
            context.fill(Path(ellipseIn: rect), with: .color(ball.style.fill.color))
        }
        context.stroke(Path(ellipseIn: rect),
                       with: .color(.black.opacity(0.35)),
                       lineWidth: max(0.5, ball.radius * 0.06))

        if let number = ball.style.number, ball.radius > 6 {
            let text = Text("\(number)")
                .font(.system(size: ball.radius * 0.9, weight: .bold, design: .rounded))
                .foregroundStyle(ball.style.fill.rgb == Theme.ballBlack.rgb ? Color.white : Color.black)
            let dotRadius = ball.radius * 0.55
            let dot = circleRect(center: ball.center, radius: dotRadius)
            context.fill(Path(ellipseIn: dot), with: .color(Theme.ballWhite.color.opacity(0.9)))
            context.draw(text, at: CGPoint(x: ball.center.x, y: ball.center.y))
        }
    }

    private func circleRect(center: Vec2, radius: Double) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius,
               width: radius * 2, height: radius * 2)
    }
}

#Preview("Rack with prediction") {
    TableSceneView(state: previewRack())
        .frame(width: 700, height: 400)
        .background(Color.black)
}

private func previewRack() -> TableState {
    let table = Table(size: .nineFoot)
    return TableState(table: table, balls: [
        Ball(id: BallID(0), kind: .cue, position: Vec2(-0.635, 0)),
        Ball(id: BallID(8), kind: .eight, position: Vec2(0.7, 0)),
        Ball(id: BallID(3), kind: .solid(3), position: Vec2(0.4, 0.2)),
        Ball(id: BallID(12), kind: .stripe(12), position: Vec2(0.5, -0.25))
    ])
}
#endif
