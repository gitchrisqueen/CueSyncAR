//
//  BallStyle.swift
//  CueSyncUI
//
//  Standard pool-ball styling shared by the 2D table renderer and any HUD
//  element that shows a ball. Pure data — SwiftUI conversion happens in the
//  view layer.
//

import CueSyncCore

public struct BallStyle: Sendable, Equatable {
    public var fill: ColorToken
    public var striped: Bool
    /// Printed number, nil for the cue ball and unknown detections.
    public var number: Int?

    public init(fill: ColorToken, striped: Bool, number: Int?) {
        self.fill = fill
        self.striped = striped
        self.number = number
    }
}

extension Theme {
    /// Classic American pool colors, shared by 1/9, 2/10, … pairs.
    public static let ballWhite = ColorToken(0xF5F2E9)
    public static let ballBlack = ColorToken(0x1B1B1F)
    static let numberColors: [Int: ColorToken] = [
        1: ColorToken(0xF2C022), // yellow
        2: ColorToken(0x1F5FBF), // blue
        3: ColorToken(0xD93025), // red
        4: ColorToken(0x7B3FA0), // purple
        5: ColorToken(0xF07A22), // orange
        6: ColorToken(0x1E7D46), // green
        7: ColorToken(0x8C2F39)  // maroon
    ]

    public static func ballStyle(for kind: Ball.Kind) -> BallStyle {
        switch kind {
        case .cue:
            BallStyle(fill: ballWhite, striped: false, number: nil)
        case .eight:
            BallStyle(fill: ballBlack, striped: false, number: 8)
        case .solid(let n):
            BallStyle(fill: numberColors[n] ?? ballBlack, striped: false, number: n)
        case .stripe(let n):
            BallStyle(fill: numberColors[n - 8] ?? ballBlack, striped: true, number: n)
        case .unknown:
            BallStyle(fill: ColorToken(0x9AA0A6), striped: false, number: nil)
        }
    }
}
