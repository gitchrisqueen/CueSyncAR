import Testing
@testable import CueSyncUI

@Suite("HUD bar rows")
struct HUDBarRowsTests {
    private let spacing = 12.0

    @Test("Everything that fits stays on one row")
    func oneRow() {
        let rows = HUDBarRows.rows(widths: [80, 100, 80, 44, 44], spacing: spacing, available: 500)
        #expect(rows == [0..<5])
    }

    @Test("An exact fit stays on one row; one point less wraps")
    func exactFit() {
        // 100 + 12 + 100 = 212
        #expect(HUDBarRows.rows(widths: [100, 100], spacing: spacing, available: 212) == [0..<2])
        #expect(HUDBarRows.rows(widths: [100, 100], spacing: spacing, available: 211) == [0..<1, 1..<2])
    }

    @Test("At large text the bar wraps to two rows with no control dropped")
    func wrapsInsteadOfTruncating() {
        // The SE at an accessibility size: five controls, ~359 pt available.
        let widths = [120.0, 130, 110, 44, 44]
        let rows = HUDBarRows.rows(widths: widths, spacing: spacing, available: 359)
        #expect(rows.count == 2)
        // Order kept, every control present exactly once.
        #expect(rows.flatMap { Array($0) } == Array(widths.indices))
        // Each row fits.
        for row in rows {
            let used = widths[row].reduce(0, +) + spacing * Double(row.count - 1)
            #expect(used <= 359)
        }
    }

    @Test("A wrapped bar is evened out, not a full row and a lone icon")
    func wrappedRowsAreBalanced() {
        // Greedy would give [120, 130] / [110, 44, 44]... or worse, 4 + 1.
        let widths = [60.0, 90, 100, 80, 44]
        let rows = HUDBarRows.rows(widths: widths, spacing: spacing, available: 340)
        #expect(rows.count == 2)
        #expect(rows.flatMap { Array($0) } == Array(widths.indices))
        // Neither row is a lone control.
        #expect(rows.allSatisfy { $0.count >= 2 })
    }

    @Test("A control wider than the screen gets its own row")
    func oversizeControlAlone() {
        let rows = HUDBarRows.rows(widths: [60, 500, 60], spacing: spacing, available: 300)
        #expect(rows == [0..<1, 1..<2, 2..<3])
    }

    @Test("No controls, no rows")
    func empty() {
        #expect(HUDBarRows.rows(widths: [], spacing: spacing, available: 300).isEmpty)
    }

    @Test("A single control is one row even when it does not fit")
    func single() {
        #expect(HUDBarRows.rows(widths: [900], spacing: spacing, available: 300) == [0..<1])
    }
}
