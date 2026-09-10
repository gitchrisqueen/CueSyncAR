//
//  CalibrationHeightTests.swift
//  CueSync AR
//

import Testing
@testable import TableSpace

@Suite("Calibration height source")
struct CalibrationHeightSourceTests {

    @Test("An empty table says exactly what to do, with a number")
    func emptyTableGivesActionableAdvice() {
        let advice = try? #require(CalibrationHeightSource.unconstrained.advice)
        // "Put some balls out" leaves a person wondering whether two is
        // some. The estimator needs three, and range spread improves it.
        #expect((advice ?? "").contains("three"))
        #expect((advice ?? "").contains("spread"))
        #expect(!CalibrationHeightSource.unconstrained.isTrustworthy)
    }

    @Test("A good ball estimate needs no advice and is trusted")
    func goodBallEstimateIsSilent() {
        // The reading taken off the device: 23 samples, 12 mm spread.
        let source = CalibrationHeightSource.balls(samples: 23, spreadMillimetres: 12)
        #expect(source.advice == nil)
        #expect(source.isTrustworthy)
    }

    @Test("Too few balls asks for more and counts what it has")
    func tooFewBalls() {
        let source = CalibrationHeightSource.balls(samples: 2, spreadMillimetres: 10)
        let advice = try? #require(source.advice)
        #expect((advice ?? "").contains("2"))
        #expect(!source.isTrustworthy)
    }

    @Test("Balls that disagree are called out rather than averaged over")
    func scatteredBallsAreSuspicious() {
        // A table's balls all rest on the same surface. A wide spread means
        // something that is not a ball is being measured as one.
        let source = CalibrationHeightSource.balls(samples: 20, spreadMillimetres: 90)
        #expect(source.advice != nil)
        #expect(!source.isTrustworthy)
    }

    @Test("Every source has a summary a person can read")
    func summariesAreReadable() {
        let sources: [CalibrationHeightSource] = [
            .balls(samples: 23, spreadMillimetres: 12), .detectedPlane, .unconstrained,
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
            estimatedHeight: -0.533)
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
            estimatedHeight: -0.5345)
        #expect(decision == .alreadyGoodEnough)
    }

    @Test("A wild disagreement blames the estimate, not the table")
    func implausibleCorrectionIsRefused() {
        // 40 cm is not a calibration error, it is a bad minute from the
        // detector. Yanking a locked table that far would be a worse bug
        // than the one this fixes.
        let decision = CalibrationRefinement.decide(
            lockedHeight: -0.533, samples: 30, spreadMillimetres: 10,
            estimatedHeight: -0.133)
        guard case .correctionImplausible = decision else {
            Issue.record("expected refusal, got \(decision)"); return
        }
    }

    @Test("Thin or scattered evidence is not acted on")
    func weakEvidenceIsIgnored() {
        let thin = CalibrationRefinement.decide(
            lockedHeight: -0.50, samples: 4, spreadMillimetres: 10,
            estimatedHeight: -0.533)
        #expect(thin == .estimateTooThin(samples: 4))

        let scattered = CalibrationRefinement.decide(
            lockedHeight: -0.50, samples: 40, spreadMillimetres: 85,
            estimatedHeight: -0.533)
        #expect(scattered == .estimateTooScattered(spreadMillimetres: 85))
    }

    @Test("It refines in both directions")
    func worksUpwardsAndDownwards() {
        for estimate in [-0.60, -0.46] {
            let decision = CalibrationRefinement.decide(
                lockedHeight: -0.533, samples: 20, spreadMillimetres: 12,
                estimatedHeight: estimate)
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
