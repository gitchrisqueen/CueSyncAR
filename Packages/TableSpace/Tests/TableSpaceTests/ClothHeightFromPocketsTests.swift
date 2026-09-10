//
//  ClothHeightFromPocketsTests.swift
//  CueSync AR
//
//  Pinning the claim this makes: the height is recoverable from the taps
//  alone, to a precision the ball estimate never reached.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Cloth height from pockets")
struct ClothHeightFromPocketsTests {

    private func reference(height: Double, yaw: Double = 0.3) -> TableCalibration {
        let up = Vec3(0, 1, 0)
        let xAxis = Vec3(cos(yaw), 0, sin(yaw)).normalized
        return TableCalibration(origin: Vec3(0, height, -2.6),
                                xAxis: xAxis, yAxis: up.cross(xAxis).normalized,
                                size: .eightFoot)
    }

    /// Rays from one camera through the real pocket positions — what the
    /// app has after four taps.
    private func rays(to ids: [PocketID], of calibration: TableCalibration,
                      camera: Vec3 = Vec3(0, 0, 0)) -> [(pocket: PocketID, ray: TapRay)] {
        let table = Table(size: calibration.size)
        return ids.compactMap { id in
            guard let pocket = table.pockets.first(where: { $0.id == id }) else { return nil }
            let world = calibration.tableToWorld(pocket.position)
            return (id, TapRay(origin: camera, direction: world - camera))
        }
    }

    private let fourCorners: [PocketID] = [.cornerTopLeft, .cornerTopRight,
                                           .cornerBottomLeft, .cornerBottomRight]

    @Test("Four tapped corners recover the height they were tapped at",
          arguments: [-0.528, -0.35, -0.72] as [Double])
    func recoversTheHeight(truth: Double) throws {
        let solved = try PocketCalibration.solveHeight(
            rays: rays(to: fourCorners, of: reference(height: truth)), size: .eightFoot)
        #expect(abs(solved.height - truth) < 0.002,
                "solved \(solved.height) for a cloth at \(truth)")
        #expect(solved.residual < 0.002)
        #expect(solved.spanCount == 6)
    }

    @Test("It beats the measured ball estimate by two orders of magnitude")
    func beatsTheBallEstimate() throws {
        // The session this was written from: true cloth -0.528, and the
        // ball estimator reporting -0.349, -0.370, -0.512 and -0.229 at
        // different moments. The worst of those is 299 mm out; the one it
        // settled on was 158 mm out.
        let truth = -0.528
        let solved = try PocketCalibration.solveHeight(
            rays: rays(to: fourCorners, of: reference(height: truth)), size: .eightFoot)
        let ballWorst = abs(-0.229 - truth)
        #expect(abs(solved.height - truth) < ballWorst / 100)
    }

    @Test("Two pockets are enough for a height, unlike for a table")
    func twoPocketsGiveAHeight() throws {
        // Worth stating: four pockets is the bar for the TABLE, because a
        // rigid fit through two has no redundancy. A HEIGHT is a single
        // unknown, and one distance constrains it.
        let solved = try PocketCalibration.solveHeight(
            rays: rays(to: [.cornerTopLeft, .cornerBottomRight],
                       of: reference(height: -0.528)), size: .eightFoot)
        #expect(abs(solved.height - (-0.528)) < 0.005)
        #expect(solved.spanCount == 1)
    }

    @Test("One pocket cannot say how far away the cloth is")
    func onePocketIsRefused() {
        #expect(throws: PocketCalibration.HeightFailure.needTwoPockets) {
            _ = try PocketCalibration.solveHeight(
                rays: rays(to: [.cornerTopLeft], of: reference(height: -0.5)),
                size: .eightFoot)
        }
    }

    @Test("A pixel of tap error costs millimetres, not centimetres")
    func toleratesTapNoise() throws {
        let truth = -0.528
        var noisy = rays(to: fourCorners, of: reference(height: truth))
        // About a pixel at this range, pushed the same way on every tap —
        // the systematic case, which is the one that hurt the balls.
        noisy = noisy.map { entry in
            var direction = entry.ray.direction
            direction.x += 0.002
            return (entry.pocket, TapRay(origin: entry.ray.origin, direction: direction))
        }
        let solved = try PocketCalibration.solveHeight(rays: noisy, size: .eightFoot)
        #expect(abs(solved.height - truth) < 0.02,
                "a systematic pixel of tap error moved the cloth \(solved.height - truth) m")
    }

    @Test("The wrong table size is INVISIBLE here, and that is the point")
    func wrongSizeIsNotVisibleInTheResidual() throws {
        // Every standard table is exactly 2:1, so a nine-foot table's
        // pockets are a uniform scaling of an eight-foot table's — and
        // moving the plane is a uniform scaling. Solving an eight-foot
        // table's taps as a nine-foot one therefore fits PERFECTLY, at a
        // proportionally wrong height.
        //
        // This is pinned rather than fixed because it is a fact about
        // tables, and because anyone reading a zero residual later needs
        // to know what it does and does not certify.
        let rays = rays(to: fourCorners, of: reference(height: -0.528))
        let honest = try PocketCalibration.solveHeight(rays: rays, size: .eightFoot)
        let wrong = try PocketCalibration.solveHeight(rays: rays, size: .nineFoot)
        #expect(wrong.residual < 0.002, "the wrong size fitted badly — tables changed shape")
        #expect(abs(honest.height - (-0.528)) < 0.002)
        // And the height it returns is wrong by exactly the size ratio.
        let ratio = 2.54 / 2.34
        let cameraY = 0.0
        #expect(abs((wrong.height - cameraY) - (honest.height - cameraY) * ratio) < 0.005)
    }

    @Test("The balls break the size ambiguity the pockets cannot")
    func ballsPickTheSize() throws {
        // Crude as it is, the ball estimate is the only measurement that
        // does not depend on which size was chosen. It only has to be
        // right to within a few centimetres to tell a seven-foot table
        // from a nine-foot one.
        let truth = -0.528
        let taps = rays(to: fourCorners, of: reference(height: truth))
        let ranked = PocketCalibration.sizeAgreeingWith(ballHeight: -0.50, rays: taps)
        #expect(ranked.first?.size == .eightFoot)
        // A frank disagreement is what it is for: a nine-foot table read
        // as seven-foot would put the cloth 28 % out.
        let sevenFoot = try #require(ranked.first { $0.size == .sevenFoot })
        #expect(sevenFoot.disagreement > 0.03)
    }

    @Test("Pockets a hair apart in the image are refused, not guessed at")
    func degenerateRaysAreRefused() {
        let camera = Vec3(0, 0, 0)
        let almostIdentical: [(pocket: PocketID, ray: TapRay)] = [
            (.cornerTopLeft, TapRay(origin: camera, direction: Vec3(0.0, -1, -1))),
            (.cornerTopRight, TapRay(origin: camera, direction: Vec3(1e-7, -1, -1))),
        ]
        #expect(throws: (any Error).self) {
            _ = try PocketCalibration.solveHeight(rays: almostIdentical, size: .eightFoot)
        }
    }

    @Test("Rays pointed at the ceiling have no answer")
    func upwardRaysAreRefused() {
        let camera = Vec3(0, 0, 0)
        let upward: [(pocket: PocketID, ray: TapRay)] = [
            (.cornerTopLeft, TapRay(origin: camera, direction: Vec3(0, 1, -1))),
            (.cornerTopRight, TapRay(origin: camera, direction: Vec3(1, 1, -1))),
        ]
        #expect(throws: (any Error).self) {
            _ = try PocketCalibration.solveHeight(rays: upward, size: .eightFoot)
        }
    }

    @Test("Four corner taps recover the height whatever ORDER they came in",
          arguments: [
            [0, 1, 2, 3], [2, 0, 3, 1], [3, 2, 1, 0], [1, 3, 0, 2],
          ] as [[Int]])
    func cornerOrderDoesNotMatter(order: [Int]) throws {
        // The corner path takes taps in whatever order suits the user, so
        // the solve compares sorted distance multisets rather than
        // guessing an assignment. Any permutation must give one answer.
        let truth = -0.528
        let taps = rays(to: fourCorners, of: reference(height: truth)).map(\.ray)
        let shuffled = order.map { taps[$0] }
        let solved = try PocketCalibration.solveHeightForCorners(
            rays: shuffled, size: .eightFoot)
        #expect(abs(solved.height - truth) < 0.002,
                "order \(order) gave \(solved.height)")
        #expect(solved.residual < 0.002)
    }

    @Test("Corners that are not a table of that size are refused by residual")
    func cornersOfTheWrongShapeShowUp() throws {
        // Three corners tapped correctly and one 25 cm inside the table —
        // the mis-tap the corner path actually suffers from. It cannot be
        // absorbed by moving the plane, because moving the plane scales
        // all four together.
        let table = reference(height: -0.528)
        var taps = rays(to: fourCorners, of: table).map(\.ray)
        let camera = Vec3(0, 0, 0)
        let pocket = try #require(Table(size: .eightFoot).pockets
            .first { $0.id == .cornerBottomRight })
        let inside = table.tableToWorld(pocket.position + Vec2(-0.25, 0.25))
        taps[3] = TapRay(origin: camera, direction: inside - camera)
        let solved = try PocketCalibration.solveHeightForCorners(rays: taps, size: .eightFoot)
        #expect(solved.residual > 0.03,
                "a 25 cm mis-tap fitted to \(solved.residual) m rms and would have been used")
    }

    @Test("Three corners are not four")
    func threeCornersAreRefused() {
        let taps = rays(to: [.cornerTopLeft, .cornerTopRight, .cornerBottomLeft],
                        of: reference(height: -0.5)).map(\.ray)
        #expect(throws: (any Error).self) {
            _ = try PocketCalibration.solveHeightForCorners(rays: taps, size: .eightFoot)
        }
    }

    @Test("The same pocket tapped twice adds no span")
    func repeatedPocketIsNotTwo() {
        let table = reference(height: -0.5)
        let once = rays(to: [.cornerTopLeft], of: table)
        #expect(throws: PocketCalibration.HeightFailure.needTwoPockets) {
            _ = try PocketCalibration.solveHeight(rays: once + once, size: .eightFoot)
        }
    }
}
