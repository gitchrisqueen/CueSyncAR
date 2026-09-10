//
//  CalibrationVerification.swift
//  CueSync AR
//
//  The features a person can check the calibration against with their own
//  eyes, before committing to it.
//
//  A fit always returns a table. The residual says how well the taps agree
//  with each other and with a table of the declared size — it cannot say
//  the taps were on the right holes, and it is silent about the one error
//  that survives everything else, which is picking the wrong table size
//  (every standard table is 2:1, so a wrong size fits perfectly at a
//  proportionally wrong height — see ClothHeightFromPockets).
//
//  What settles it is geometry the calibration DID NOT USE. A table's
//  diamonds are inlaid at eighths and quarters of the playing surface, and
//  they are physically there, in the rails, in front of the user. Derive
//  where they must be from the candidate calibration, draw them, and the
//  question stops being "do you trust the fit?" and becomes "do those
//  eighteen dots sit on your eighteen dots?" — which anyone can answer
//  from across the room, including someone who does not believe a word of
//  it.
//
//  Everything here is in TABLE coordinates: origin at the centre of the
//  playing surface, +x along the long axis, +y along the short one, which
//  is the frame `TableCalibration.tableToWorld` expects.
//
//  Placed in TableSpace rather than ARExperience (where the issue proposed
//  it) because it is pure geometry over CueSyncCore.Table, has no ARKit in
//  it, and TableSpace is the package that Linux tests. ARExperience draws
//  the result; it does not need to own it.
//

import CueSyncCore
import Foundation

public enum CalibrationVerification {

    /// The eighteen diamonds, in table coordinates.
    ///
    /// The long rails are divided into eight equal parts, giving seven
    /// interior marks — but the middle one is where the side pocket is, so
    /// six diamonds show per long rail. The short rails are divided into
    /// four, giving three each. Six, six, three and three is the eighteen
    /// every American table carries.
    ///
    /// Note these are the marks' positions along the PLAYING SURFACE
    /// boundary. The physical inlays sit a little further out, on top of
    /// the rail past the cushion nose, so on screen they should read as
    /// slightly inside the real ones by a consistent margin. Consistent is
    /// the word that matters: a uniform inset is the rail's width, while
    /// one dot out of line is a wrong calibration.
    public static func diamonds(for size: TableSize) -> [Vec2] {
        let (width, height) = size.playField
        let (halfX, halfY) = (width / 2, height / 2)
        var marks: [Vec2] = []
        // Long rails: eighths, skipping the side pocket at the centre.
        for step in 1...7 where step != 4 {
            let x = -halfX + Double(step) * width / 8
            marks.append(Vec2(x, halfY))
            marks.append(Vec2(x, -halfY))
        }
        // Short rails: quarters.
        for step in 1...3 {
            let y = -halfY + Double(step) * height / 4
            marks.append(Vec2(halfX, y))
            marks.append(Vec2(-halfX, y))
        }
        return marks
    }

    /// The three spots on the long axis: both quarter points and the
    /// centre.
    ///
    /// One quarter point is the foot spot, where the rack goes; the other
    /// is the head spot. WHICH IS WHICH THE APP CANNOT KNOW — it depends
    /// on which end the player racks at, and nothing about the table's
    /// geometry says. So both are offered rather than one guessed at, and
    /// the caller should not label either as "foot".
    ///
    /// They matter less than the diamonds for verification, because many
    /// tables have no visible spot at all. They are here because when a
    /// table DOES carry a foot spot, it is the single most convincing dot
    /// on the cloth.
    public static func spots(for size: TableSize) -> [Vec2] {
        let (width, _) = size.playField
        return [Vec2(-width / 4, 0), Vec2(0, 0), Vec2(width / 4, 0)]
    }

    /// The head and foot strings: the two lines across the table at the
    /// quarter points, as endpoint pairs on the long rails.
    ///
    /// Same caveat as `spots` — one of them is the head string and the
    /// geometry does not say which.
    public static func quarterLines(for size: TableSize) -> [(Vec2, Vec2)] {
        let (width, height) = size.playField
        let (quarter, halfY) = (width / 4, height / 2)
        return [
            (Vec2(-quarter, -halfY), Vec2(-quarter, halfY)),
            (Vec2(quarter, -halfY), Vec2(quarter, halfY)),
        ]
    }

    /// Everything worth drawing, in world space, for a candidate
    /// calibration.
    ///
    /// One call so the overlay cannot draw the diamonds from one
    /// calibration and the pockets from another — which is exactly the
    /// class of bug that makes a verification view lie.
    public struct Overlay: Sendable, Equatable {
        public var pockets: [Vec3]
        public var diamonds: [Vec3]
        public var spots: [Vec3]
        public var quarterLines: [(Vec3, Vec3)]

        public init(pockets: [Vec3], diamonds: [Vec3], spots: [Vec3],
                    quarterLines: [(Vec3, Vec3)]) {
            self.pockets = pockets
            self.diamonds = diamonds
            self.spots = spots
            self.quarterLines = quarterLines
        }

        public static func == (lhs: Overlay, rhs: Overlay) -> Bool {
            lhs.pockets == rhs.pockets && lhs.diamonds == rhs.diamonds
                && lhs.spots == rhs.spots
                && lhs.quarterLines.count == rhs.quarterLines.count
                && zip(lhs.quarterLines, rhs.quarterLines)
                    .allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    public static func overlay(for calibration: TableCalibration) -> Overlay {
        let table = Table(size: calibration.size)
        return Overlay(
            pockets: table.pockets.map { calibration.tableToWorld($0.position) },
            diamonds: diamonds(for: calibration.size).map(calibration.tableToWorld),
            spots: spots(for: calibration.size).map(calibration.tableToWorld),
            quarterLines: quarterLines(for: calibration.size).map {
                (calibration.tableToWorld($0.0), calibration.tableToWorld($0.1))
            })
    }
}
