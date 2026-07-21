import CueSyncCore
import Testing
@testable import CueSyncUI

@Suite("NormalizedRotation composition")
struct RotationCombinationTests {
    @Test func anglesAddModulo360() {
        #expect(NormalizedRotation.clockwise90.combined(with: .clockwise90) == .half)
        #expect(NormalizedRotation.half.combined(with: .half) == .none)
        #expect(NormalizedRotation.counterClockwise90.combined(with: .clockwise90) == .none)
        #expect(NormalizedRotation.none.combined(with: .counterClockwise90) == .counterClockwise90)
    }

    @Test func combinationMatchesSequentialApplication() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        for first in NormalizedRotation.allCases {
            for second in NormalizedRotation.allCases {
                let sequential = second.apply(first.apply(rect))
                let combined = first.combined(with: second).apply(rect)
                #expect(abs(sequential.x - combined.x) < 1e-12)
                #expect(abs(sequential.y - combined.y) < 1e-12)
                #expect(abs(sequential.width - combined.width) < 1e-12)
                #expect(abs(sequential.height - combined.height) < 1e-12)
            }
        }
    }
}
