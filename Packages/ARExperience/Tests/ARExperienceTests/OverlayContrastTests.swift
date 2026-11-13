import BilliardsPhysics
import CueSyncCore
import CueSyncUI
import Foundation
import TableSpace
import Testing
@testable import ARExperience

// Every mark on the cloth, held to the review's findings: the line the player
// has to follow was the faintest mark (3.4 to 3.7 : 1, 11 px) and shared its
// green with the pocket ring. These tests are the contrast of each role
// against three nominal cloths, the hue spacing, the widths and the ring.
//
// The cloths (OverlayPalette): black #383731 (as the camera rendered the
// reviewed table), tournament green #2A7F46, tournament blue #1E5AA0, and the
// same three in a brighter room.

private let cueID = BallID(0)
private let solver = AnalyticSolver()
private let calibration = TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, -1), size: .eightFoot)

private func suggestionLayout() throws -> (OverlayLayout, TableState) {
    let table = Table(size: .eightFoot)
    var balls = [Ball(id: cueID, kind: .cue, position: Vec2(0.3, 0.07))]
    balls.append(Ball(id: BallID(7), kind: .solid(7), position: Vec2(0, 0.146)))
    let state = TableState(table: table, balls: balls, timestamp: 0)
    let object = try #require(state.ball(BallID(7)))
    let hole = try #require(table.pockets.first { $0.id == .cornerTopLeft })
    let ghost = object.position - (hole.position - object.position).normalized * (2 * object.radius)
    let prediction = try #require(TargetGuide.plan(state: state, ghostBall: ghost, solver: solver, speed: 3.5))
    let target = OverlayLayout.Target(prediction: prediction, ball: BallID(7),
                                      pocket: .cornerTopLeft, ghostBall: ghost)
    return (OverlayLayout.ballsOnly(state: state, calibration: calibration, target: target), state)
}

@Suite("Overlay palette: contrast against the cloth")
struct OverlayPaletteContrastTests {

    @Test("The object leg is at least 7 : 1 against black cloth, and 4.5 : 1 against all three, bare")
    func objectLegIsTheStrongest() {
        let line = OverlayPalette.objectPath
        #expect(Contrast.ratio(line, OverlayPalette.black.rgb) >= 7)
        for cloth in OverlayPalette.nominalCloths {
            #expect(Contrast.ratio(line, cloth.rgb) >= Contrast.aa, "\(cloth.name)")
        }
        // It was 3.4 to 3.7 : 1 as the old green.
        let oldGreen = ColorToken(0x2FA36B)
        #expect(Contrast.ratio(oldGreen, OverlayPalette.black.rgb) < 4)
    }

    @Test("The object leg out-contrasts every other role against every nominal cloth, bare")
    func objectLegBeatsTheOthers() {
        for cloth in OverlayPalette.nominalCloths {
            let object = Contrast.ratio(OverlayPalette.objectPath, cloth.rgb)
            for role in OverlayPalette.Role.allCases where role != .objectPath {
                let other = Contrast.ratio(OverlayPalette.token(for: role), cloth.rgb)
                #expect(object >= other, "\(role) vs \(cloth.name): \(other) > \(object)")
            }
        }
    }

    @Test("Every role is at least 4.5 : 1 against the cloth seen through its casing, on every nominal cloth")
    func everyRoleThroughItsCasing() {
        for cloth in OverlayPalette.nominalCloths + OverlayPalette.litCloths {
            let backdrop = OverlayPalette.backdrop(over: cloth.rgb)
            for role in OverlayPalette.Role.allCases {
                let ratio = Contrast.ratio(OverlayPalette.token(for: role), backdrop)
                #expect(ratio >= Contrast.aa, "\(role) on \(cloth.name): \(ratio)")
            }
        }
    }

    @Test("Why the casing exists: on tournament green no coloured line reaches 4.5 : 1 bare")
    func theCeilingOnMidToneCloth() {
        let green = OverlayPalette.tournamentGreen.rgb
        for role in OverlayPalette.Role.allCases where role != .objectPath {
            let bare = Contrast.ratio(OverlayPalette.token(for: role), green)
            #expect(bare < Contrast.aa, "\(role) bare on green: \(bare)")
        }
        // Even pure white only reaches about 5 : 1 there.
        #expect(Contrast.ratio(ColorToken(0xFFFFFF), green) < 5.5)
    }

    @Test("The casing darkens every nominal cloth, so it never lowers a role's contrast")
    func casingOnlyHelps() {
        for cloth in OverlayPalette.nominalCloths + OverlayPalette.litCloths {
            let bare = Contrast.relativeLuminance(cloth.rgb)
            let under = Contrast.relativeLuminance(OverlayPalette.backdrop(over: cloth.rgb))
            #expect(under < bare, "\(cloth.name)")
        }
    }
}

@Suite("Overlay palette: one hue per meaning")
struct OverlayPaletteHueTests {

    @Test("The object leg is the only grey; every other role is a colour")
    func objectLegIsAchromatic() {
        let white = OverlayPalette.hueAndSaturation(of: OverlayPalette.objectPath)
        #expect(white.saturation < 0.05)
        for role in OverlayPalette.Role.allCases where role != .objectPath {
            let colour = OverlayPalette.hueAndSaturation(of: OverlayPalette.token(for: role))
            #expect(colour.saturation >= 0.2, "\(role)")
        }
    }

    @Test("No two roles share a hue: coloured roles are at least 30 degrees apart")
    func huesAreSeparate() {
        let coloured = OverlayPalette.Role.allCases.filter { $0 != .objectPath }
        for (index, a) in coloured.enumerated() {
            for b in coloured[(index + 1)...] {
                let gap = OverlayPalette.hueDistance(
                    OverlayPalette.hueAndSaturation(of: OverlayPalette.token(for: a)).hue,
                    OverlayPalette.hueAndSaturation(of: OverlayPalette.token(for: b)).hue)
                #expect(gap >= 30, "\(a) vs \(b): \(gap) degrees")
            }
        }
    }

    @Test("The target pocket ring is not the object line's colour, and not the called pocket's")
    func pocketsHaveTheirOwn() {
        #expect(OverlayPalette.targetPocket != OverlayPalette.objectPath)
        #expect(OverlayPalette.targetPocket != OverlayPalette.calledPocket)
        #expect(OverlayStyle.pocketRingColor != OverlayStyle.heroObjectColor)
        #expect(OverlayStyle.calledPocketColor != OverlayStyle.pocketRingColor)
    }

    @Test("Hue helpers: the wheel wraps")
    func hueHelpers() {
        #expect(OverlayPalette.hueDistance(350, 10) == 20)
        #expect(OverlayPalette.hueDistance(10, 350) == 20)
        #expect(OverlayPalette.hueDistance(0, 180) == 180)
        let red = OverlayPalette.hueAndSaturation(of: ColorToken(0xFF0000))
        #expect(red.hue == 0 && red.saturation == 1)
        let blue = OverlayPalette.hueAndSaturation(of: ColorToken(0x0000FF))
        #expect(abs(blue.hue - 240) < 1e-9)
        #expect(OverlayPalette.hueAndSaturation(of: ColorToken(0x000000)).saturation == 0)
    }

    @Test("A role keeps its colour everywhere it is drawn")
    func roleColoursAreTiedTogether() {
        #expect(OverlayStyle.heroCueColor == OverlayPalette.token(for: .cuePath).rgb)
        #expect(OverlayStyle.cueRingColor == OverlayStyle.heroCueColor, "the cue ball's ring")
        #expect(OverlayStyle.shotColor == OverlayStyle.heroCueColor, "the ghost ball")
        #expect(OverlayStyle.heroObjectColor == OverlayPalette.token(for: .objectPath).rgb)
        #expect(OverlayStyle.objectPathColor == OverlayStyle.heroObjectColor, "the live object path")
        #expect(OverlayStyle.targetRingColor == OverlayStyle.heroObjectColor, "the target ball's ring")
        #expect(OverlayStyle.aimColor == OverlayPalette.token(for: .aim).rgb)
        #expect(OverlayStyle.postContactColor == OverlayPalette.token(for: .postContact).rgb)
        #expect(OverlayStyle.scratchColor == OverlayPalette.token(for: .scratch).rgb)
        #expect(OverlayStyle.pocketRingColor == OverlayPalette.token(for: .targetPocket).rgb)
        #expect(OverlayStyle.calledPocketColor == OverlayPalette.token(for: .calledPocket).rgb)
    }

    @Test("Every colour a layout draws is a palette role, the quiet ball ring, or a casing")
    func layoutUsesOnlyThePalette() throws {
        let (layout, _) = try suggestionLayout()
        let allowed = Set(OverlayPalette.Role.allCases.map { OverlayPalette.token(for: $0).rgb }
            + [OverlayStyle.ballRingColor, OverlayStyle.casingColor])
        for primitive in layout.primitives {
            #expect(allowed.contains(primitive.look.colour), "\(primitive.key) \(primitive.look.colour)")
        }
    }
}

@Suite("Overlay widths: the line to follow is the widest mark")
struct OverlayWidthTests {
    /// Pixels per metre on the reviewed iPad at the far half and the near half
    /// of the table, from the review's own measurements (an 18 mm line was
    /// 11 px far and 14 px near).
    private let farPixelsPerMetre = 11 / 0.018
    private let nearPixelsPerMetre = 14 / 0.018

    @Test("The object leg is at least as wide as the cue leg used to be, even on the far half")
    func objectLegWidth() {
        let width = OverlayStyle.width(.hero)
        #expect(width * farPixelsPerMetre >= 14, "14 px was the old cue leg")
        #expect(width >= 0.018)
        #expect(width * nearPixelsPerMetre >= 14)
    }

    @Test("The cue leg is narrower than the object leg and still clearly visible")
    func cueLegIsQuieter() {
        #expect(OverlayStyle.width(.lead) < OverlayStyle.width(.hero))
        #expect(OverlayStyle.width(.lead) > OverlayStyle.width(.aim) * 2)
        #expect(OverlayStyle.width(.lead) * farPixelsPerMetre >= 9, "9 px or more, far")
        #expect(OverlayStyle.width(.lead) * nearPixelsPerMetre >= 12, "12 px or more, near")
        #expect(OverlayStyle.opacity(.lead) >= 0.9, "opaque, so its contrast is the palette's")
    }

    @Test("Widths fall in order: hero, lead, aim, secondary; all narrower than a ball")
    func ordering() {
        let widths = [OverlayStyle.Tier.hero, .lead, .aim, .secondary].map(OverlayStyle.width)
        #expect(widths == widths.sorted(by: >))
        #expect(Set(widths).count == 4)
        for width in widths { #expect(width < Ball.standardRadius * 2) }
        #expect(OverlayStyle.opacity(.hero) == 1)
        #expect(OverlayStyle.lift(.hero) > OverlayStyle.lift(.lead))
        #expect(OverlayStyle.lift(.lead) > OverlayStyle.lift(.aim))
    }

    @Test("A suggested shot's two legs get the two widths")
    func legsInALayout() throws {
        let (layout, _) = try suggestionLayout()
        let cue = try #require(layout.targetStrips.first { $0.leg == .cue })
        let object = try #require(layout.targetStrips.first { $0.leg == .object })
        #expect(OverlayStyle.tier(of: cue) == .lead)
        #expect(OverlayStyle.tier(of: object) == .hero)
        let widths = layout.primitives.filter { $0.key.hasPrefix("hero.strip.") }.map(\.scale.z)
        #expect(widths.contains(OverlayStyle.width(.hero)) && widths.contains(OverlayStyle.width(.lead)))
        // The live aim and secondary strips have no leg.
        #expect(layout.strips.allSatisfy { $0.leg == .none })
    }
}

@Suite("Overlay casing and the pocket ring")
struct OverlayCasingAndRingTests {

    @Test("Each hero strip has a casing under it, wider by the casing margin, same heading and length")
    func casingPerStrip() throws {
        let (layout, _) = try suggestionLayout()
        let primitives = layout.primitives
        for (index, strip) in layout.targetStrips.enumerated() {
            let casing = try #require(primitives.first { $0.key == "hero.casing.\(index)" })
            let line = try #require(primitives.first { $0.key == "hero.strip.\(index)" })
            #expect(casing.isCasing && !line.isCasing)
            #expect(abs(casing.scale.z - (line.scale.z + OverlayStyle.casingExtraWidth)) < 1e-12)
            #expect(casing.scale.x == line.scale.x && casing.heading == line.heading)
            #expect(casing.position.y < line.position.y, "under its line")
            #expect(casing.look.opacity == OverlayStyle.casingOpacity)
            #expect(strip.leg != .none)
        }
    }

    @Test("The casing is a hero primitive, so it fades with its line, and the recorder can leave it out")
    func casingBelongsToTheHero() throws {
        let (layout, _) = try suggestionLayout()
        for primitive in layout.primitives where primitive.isCasing {
            #expect(primitive.group == .hero, "\(primitive.key)")
        }
        #expect(layout.primitives.contains { $0.isCasing })
        #expect(!layout.primitives.filter { !$0.key.contains("casing") }.contains { $0.isCasing })
    }

    @Test("No casing for the live aim or the dashed lines")
    func noCasingOutsideTheShot() {
        let state = TableState(table: Table(size: .eightFoot), balls: [
            Ball(id: cueID, kind: .cue, position: Vec2(-0.5, 0)),
            Ball(id: BallID(1), kind: .solid(1), position: .zero)
        ])
        let contact = Vec2(-2 * Ball.standardRadius, 0)
        let prediction = ShotPrediction(
            segments: [
                TrajectorySegment(ballID: cueID, start: Vec2(-0.5, 0), end: contact),
                TrajectorySegment(ballID: cueID, start: contact, end: Vec2(-0.1, -0.3))
            ],
            events: [.ballBall(moving: cueID, struck: BallID(1), contact: contact)], pocketedBalls: [])
        let layout = OverlayLayout.compose(state: state, prediction: prediction, calibration: calibration)
        #expect(!layout.strips.isEmpty)
        #expect(!layout.primitives.contains { $0.isCasing })
    }

    @Test("The pocket ring is centred on the pocket, 1.5 capture radii out, with a stroke you can see")
    func pocketRingGeometry() {
        for capture in [Table.cornerCaptureRadius, Table.sideCaptureRadius] {
            let ring = OverlayStyle.targetPocketRing(captureRadius: capture)
            let centre = (ring.inner + ring.outer) / 2
            #expect(abs(centre - capture * 1.5) < 1e-12, "1.5 times the capture radius")
            #expect(ring.outer - ring.inner >= 0.012, "a stroke, not a hairline")
            #expect(ring.inner > 0 && ring.inner < ring.outer)
            // The review found the line's end about a ball diameter off the
            // mouth: a mouth centre that far from the ring's centre is still
            // inside the ring.
            #expect(ring.inner > 2 * Ball.standardRadius, "capture \(capture)")
            let casing = OverlayStyle.targetPocketCasing(captureRadius: capture)
            #expect(casing.inner < ring.inner && casing.outer > ring.outer)
            #expect(abs((ring.inner - casing.inner) - OverlayStyle.targetPocketCasingMargin) < 1e-12)
        }
        // A 2 m reader needs it findable: 174 mm at a side pocket and 225 mm
        // at a corner are 1.5 times the capture diameters.
        let corner = OverlayStyle.targetPocketRing(captureRadius: Table.cornerCaptureRadius)
        #expect(abs(corner.outer * 2 - 0.232) < 0.01)
    }

    @Test("The ring in a layout is centred on the pocket and wraps the capture circle")
    func pocketRingInALayout() throws {
        let (layout, state) = try suggestionLayout()
        let marker = try #require(layout.targetPocket)
        let hole = try #require(state.table.pockets.first { $0.id == .cornerTopLeft })
        #expect(marker.radius == hole.captureRadius, "the marker keeps the capture radius")
        let ring = try #require(layout.primitives.first { $0.key == "hero.pocket" })
        let casing = try #require(layout.primitives.first { $0.key == "hero.pocket.casing" })
        let spec = OverlayStyle.targetPocketRing(captureRadius: hole.captureRadius)
        #expect(ring.look.shape == .ring(innerMicrometres: Int((spec.inner * 1e6).rounded()),
                                         outerMicrometres: Int((spec.outer * 1e6).rounded())))
        #expect(abs(ring.position.x - marker.position.x) < 1e-9 && abs(ring.position.z - marker.position.z) < 1e-9)
        #expect(casing.position.x == ring.position.x && casing.position.z == ring.position.z)
        #expect(ring.look.colour == OverlayStyle.pocketRingColor)
        #expect(ring.look.opacity == 1)
    }

    @Test("Shape differs as well as hue: the pocket is a ring, the lines are boxes, the called pocket a disc")
    func meaningIsNotColourAlone() throws {
        let (layout, _) = try suggestionLayout()
        let ring = try #require(layout.primitives.first { $0.key == "hero.pocket" })
        let line = try #require(layout.primitives.first { $0.key.hasPrefix("hero.strip.") })
        guard case .ring = ring.look.shape else {
            Issue.record("the target pocket is not a ring")
            return
        }
        #expect(line.look.shape == .box)
        #expect(OverlayPrimitive.Shape.disc != ring.look.shape)
    }

    @Test("The called pocket keeps one hue; on line is the same colour, firmer")
    func calledPocket() {
        #expect(OverlayStyle.calledPocketOnLineOpacity > OverlayStyle.calledPocketOpacity)
        #expect(OverlayStyle.calledPocketColor == OverlayPalette.calledPocket.rgb)
    }
}
