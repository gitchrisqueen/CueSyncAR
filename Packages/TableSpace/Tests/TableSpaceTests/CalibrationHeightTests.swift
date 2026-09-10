//
//  CalibrationHeightTests.swift
//  CueSync AR
//

import Testing
@testable import TableSpace

@Suite("Calibration height source")
struct CalibrationHeightSourceTests {

    @Test("An empty table says exactly what to do, with a number")
    func emptyTableGivesActionableAdvice() throws {
        let advice = try #require(CalibrationHeightSource.unconstrained.advice)
        // "Put some balls out" leaves a person wondering whether two is
        // some. The estimator needs three, and range spread improves it.
        #expect(advice.contains("three"))
        #expect(advice.contains("spread"))
        #expect(!CalibrationHeightSource.unconstrained.isTrustworthy)
    }

    @Test("A good ball estimate needs no advice and is trusted")
    func goodBallEstimateIsSilent() {
        // The reading taken off the device: 23 samples, 12 mm spread —
        // and, crucially, an estimate that has stopped moving.
        let source = CalibrationHeightSource.balls(
            samples: 23, spreadMillimetres: 12, driftMillimetres: 3)
        #expect(source.advice == nil)
        #expect(source.isTrustworthy)
    }

    @Test("Too few balls asks for more and counts what it has")
    func tooFewBalls() throws {
        let source = CalibrationHeightSource.balls(samples: 2, spreadMillimetres: 10, driftMillimetres: 3)
        let advice = try #require(source.advice)
        #expect(advice.contains("2"))
        #expect(!source.isTrustworthy)
    }

    @Test("Balls that disagree are called out rather than averaged over")
    func scatteredBallsAreSuspicious() {
        // A table's balls all rest on the same surface. A wide spread means
        // something that is not a ball is being measured as one.
        let source = CalibrationHeightSource.balls(samples: 20, spreadMillimetres: 90, driftMillimetres: 3)
        #expect(source.advice != nil)
        #expect(!source.isTrustworthy)
    }

    @Test("A tight spread on a moving estimate is NOT trusted")
    func driftingEstimateIsNotTrusted() throws {
        // The reading that caused all of this: 44 balls, 8 mm of spread,
        // 114 mm wrong, and still walking. Every old check passed it.
        let source = CalibrationHeightSource.balls(
            samples: 44, spreadMillimetres: 8, driftMillimetres: 60)
        #expect(!source.isTrustworthy)
        let advice = try #require(source.advice)
        #expect(advice.contains("settling"))
    }

    @Test("Not knowing the drift yet is not the same as no drift")
    func unknownDriftIsNotTrusted() throws {
        let source = CalibrationHeightSource.balls(
            samples: 44, spreadMillimetres: 8, driftMillimetres: nil)
        #expect(!source.isTrustworthy)
        #expect(try #require(source.advice).contains("measuring"))
    }

    @Test("A pocket-solved height is trusted, and says how well it fitted")
    func pocketGeometryIsTrusted() {
        // The reading off the device: four corner taps, six spans, 7 mm.
        let source = CalibrationHeightSource.pocketGeometry(spans: 6, residualMillimetres: 7)
        #expect(source.isTrustworthy)
        #expect(source.advice == nil)
        #expect(source.summary.contains("7 mm"))
    }

    @Test("Taps that do not make a table of that shape are called out")
    func badPocketShapeIsCalledOut() throws {
        // The six-pocket attempt on device: 55 mm rms, because the two
        // side pockets were sighted on the leather rather than the mouth.
        let source = CalibrationHeightSource.pocketGeometry(spans: 15, residualMillimetres: 55)
        #expect(!source.isTrustworthy)
        #expect(try #require(source.advice).contains("table size"))
    }

    @Test("Every source has a summary a person can read")
    func summariesAreReadable() {
        let sources: [CalibrationHeightSource] = [
            .balls(samples: 23, spreadMillimetres: 12, driftMillimetres: 3),
            .balls(samples: 23, spreadMillimetres: 12, driftMillimetres: nil),
            .pocketGeometry(spans: 6, residualMillimetres: 7),
            .detectedPlane, .unconstrained,
        ]
        for source in sources {
            #expect(!source.summary.isEmpty)
            #expect(source.summary == source.summary.lowercased()
                    || source.summary.contains("("))
        }
    }
}

@Suite("Calibration refinement")
struct CalibrationRefinementTests {

    @Test("A better estimate moves a locked table")
    func refinesOnBetterEvidence() {
        // Locked early on thin evidence at -0.50; the balls now say -0.533,
        // which is the value two separate device calibrations produced.
        let decision = CalibrationRefinement.decide(
            lockedHeight: -0.50, samples: 23, spreadMillimetres: 12,
            estimatedHeight: -0.533, driftMillimetres: 3)
        guard case let .refine(to, correction) = decision else {
            Issue.record("expected a refinement, got \(decision)"); return
        }
        #expect(abs(to - (-0.533)) < 1e-9)
        #expect(abs(correction - (-0.033)) < 1e-9)
    }

    @Test("A millimetre of disagreement is left alone")
    func doesNotChurn() {
        // Re-anchoring the table for a difference nobody can see is worse
        // than leaving it: the overlay would twitch for no reason.
        let decision = CalibrationRefinement.decide(
            lockedHeight: -0.533, samples: 30, spreadMillimetres: 10,
            estimatedHeight: -0.5345, driftMillimetres: 3)
        #expect(decision == .alreadyGoodEnough)
    }

    @Test("A wild disagreement blames the estimate, not the table")
    func implausibleCorrectionIsRefused() {
        // 40 cm is not a calibration error, it is a bad minute from the
        // detector. Yanking a locked table that far would be a worse bug
        // than the one this fixes.
        let decision = CalibrationRefinement.decide(
            lockedHeight: -0.533, samples: 30, spreadMillimetres: 10,
            estimatedHeight: -0.133, driftMillimetres: 3)
        guard case .correctionImplausible = decision else {
            Issue.record("expected refusal, got \(decision)"); return
        }
    }

    @Test("Thin or scattered evidence is not acted on")
    func weakEvidenceIsIgnored() {
        let thin = CalibrationRefinement.decide(
            lockedHeight: -0.50, samples: 4, spreadMillimetres: 10,
            estimatedHeight: -0.533, driftMillimetres: 3)
        #expect(thin == .estimateTooThin(samples: 4))

        let scattered = CalibrationRefinement.decide(
            lockedHeight: -0.50, samples: 40, spreadMillimetres: 85,
            estimatedHeight: -0.533, driftMillimetres: 3)
        #expect(scattered == .estimateTooScattered(spreadMillimetres: 85))
    }

    @Test("A still-moving estimate is not refined towards")
    func driftingEstimateIsNotRefinedTowards() {
        // Chasing an estimate that is still converging re-derives the
        // corners every time it moves, which is the quad walking across
        // the cloth that started this.
        let decision = CalibrationRefinement.decide(
            lockedHeight: -0.367, samples: 44, spreadMillimetres: 8,
            estimatedHeight: -0.512, driftMillimetres: 60)
        #expect(decision == .stillSettling(driftMillimetres: 60))
    }

    @Test("An unknown drift waits rather than acting")
    func unknownDriftWaits() {
        let decision = CalibrationRefinement.decide(
            lockedHeight: -0.367, samples: 44, spreadMillimetres: 8,
            estimatedHeight: -0.512, driftMillimetres: nil)
        #expect(decision == .stillSettling(driftMillimetres: nil))
    }

    @Test("Once it settles, the same correction IS applied")
    func settledEstimateIsRefinedTowards() {
        // The same 145 mm, now stationary: this is a real correction and
        // must not be lost to the new gate.
        let decision = CalibrationRefinement.decide(
            lockedHeight: -0.367, samples: 80, spreadMillimetres: 13,
            estimatedHeight: -0.481, driftMillimetres: 4)
        guard case let .refine(to, _) = decision else {
            Issue.record("the settled correction was refused: \(decision)"); return
        }
        #expect(abs(to - (-0.481)) < 1e-9)
    }

    @Test("It refines in both directions")
    func worksUpwardsAndDownwards() {
        for estimate in [-0.60, -0.46] {
            let decision = CalibrationRefinement.decide(
                lockedHeight: -0.533, samples: 20, spreadMillimetres: 12,
                estimatedHeight: estimate, driftMillimetres: 3)
            guard case .refine = decision else {
                Issue.record("expected a refinement toward \(estimate), got \(decision)")
                continue
            }
        }
    }

    @Test("The thresholds are ordered so no decision is unreachable")
    func configIsCoherent() {
        let config = CalibrationRefinement.Config()
        #expect(config.minimumCorrection < config.maximumCorrection)
        #expect(config.minimumSamples >= 3, "must not act on less than the estimator needs")
    }
}
