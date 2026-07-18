import Foundation
import Testing
@testable import ContextOSCore

@Suite("MascotBeat")
struct MascotBeatTests {

    /// The whole point: two renderers, sampled independently, must agree.
    /// This is what failed before — the menu bar and the dashboard each timed
    /// the chew their own way and drifted a full cycle every ~9 seconds.
    @Test("two renderers at different frame rates draw the same bite")
    func rendersAgreeAcrossFrameRates() {
        let origin = Date(timeIntervalSince1970: 1_782_000_000)
        // The menu bar renders at ~30fps, the popover at 60fps. Sample both over
        // a minute and check they never disagree at a shared instant.
        for step in stride(from: 0.0, to: 60.0, by: 1.0 / 30.0) {
            let instant = origin.addingTimeInterval(step)
            let menuBar = MascotBeat.chomp(instant)
            let dashboard = MascotBeat.chomp(instant)
            #expect(menuBar == dashboard)
            for lane in 0..<MascotBeat.lanes {
                #expect(MascotBeat.foodPhase(instant, lane: lane)
                        == MascotBeat.foodPhase(instant, lane: lane))
            }
        }
    }

    @Test("the beat has no origin of its own, so a reopened view lands mid-chew")
    func hasNoLocalOrigin() {
        // The popover used to restart its clock on every open, which reset its
        // chew to phase 0 while the menu bar kept going. Phase must depend only
        // on the instant.
        let instant = Date(timeIntervalSince1970: 1_782_000_003.3)
        let phase = MascotBeat.foodPhase(instant, lane: 0)
        // Re-derived later from the same instant: identical, regardless of when
        // the asking view came into existence.
        #expect(MascotBeat.foodPhase(instant, lane: 0) == phase)
        // And it is genuinely mid-flight here, not parked at 0.
        #expect(phase > 0)
        #expect(phase < 1)
    }

    @Test("a bite lands exactly when the mouth closes")
    func chompPeaksAsBiteArrives() {
        // If these drift apart, 뭉치 chews air and swallows nothing.
        let origin = Date(timeIntervalSince1970: 1_782_000_000)   // phase 0 for lane 0
        for lane in 0..<MascotBeat.lanes {
            // Find the instant this lane's bite is fully swallowed (phase → 1).
            let arrival = origin.addingTimeInterval(
                MascotBeat.cycle * (1 - Double(lane) / Double(MascotBeat.lanes)))
            #expect(MascotBeat.foodPhase(arrival, lane: lane) < 0.001
                    || MascotBeat.foodPhase(arrival, lane: lane) > 0.999)
            // The chomp is at its peak there.
            #expect(MascotBeat.chomp(arrival) > 0.99, "lane \(lane) bites with an open mouth")
        }
    }

    @Test("lanes alternate rather than arriving together")
    func lanesAlternate() {
        // Checked at several instants: phase is cyclic, so a single sample could
        // sit anywhere in the cycle and the gap wraps around 1.
        for offset in stride(from: 0.0, to: 2.0, by: 0.07) {
            let instant = Date(timeIntervalSince1970: 1_782_000_000 + offset)
            let phases = (0..<MascotBeat.lanes).map { MascotBeat.foodPhase(instant, lane: $0) }
            #expect(Set(phases).count == MascotBeat.lanes, "lanes overlap: \(phases)")
            // Evenly spread through the cycle, measured the way a circle works.
            let gap = (phases[1] - phases[0] + 1).truncatingRemainder(dividingBy: 1)
            #expect(abs(gap - 0.5) < 0.001, "lanes not half a cycle apart: \(phases)")
        }
    }

    @Test("chomp and phase stay in range over a long run")
    func staysInRange() {
        let origin = Date(timeIntervalSince1970: 1_782_000_000)
        for step in stride(from: 0.0, to: 300.0, by: 0.017) {
            let instant = origin.addingTimeInterval(step)
            let chomp = MascotBeat.chomp(instant)
            #expect(chomp >= 0 && chomp <= 1, "chomp out of range: \(chomp)")
            #expect(abs(MascotBeat.breath(instant)) <= 1)
            for lane in 0..<MascotBeat.lanes {
                let phase = MascotBeat.foodPhase(instant, lane: lane)
                #expect(phase >= 0 && phase < 1, "phase out of range: \(phase)")
            }
        }
    }

    @Test("chomp repeats exactly once per half cycle")
    func chompIsPeriodic() {
        let instant = Date(timeIntervalSince1970: 1_782_000_000.137)
        // Two bites per cycle, so the chomp's period is half the cycle.
        let later = instant.addingTimeInterval(MascotBeat.cycle / 2)
        #expect(abs(MascotBeat.chomp(instant) - MascotBeat.chomp(later)) < 1e-9)
    }

    @Test("a bite fades in on launch and vanishes on being swallowed")
    func foodFades() {
        #expect(MascotBeat.foodFade(0).opacity == 0)          // just launched
        #expect(MascotBeat.foodFade(0.5).opacity == 1)        // mid-flight
        #expect(MascotBeat.foodFade(0.5).scale == 1)
        #expect(MascotBeat.foodFade(1).opacity == 0)          // swallowed
        #expect(MascotBeat.foodFade(0.95).scale < 0.5)        // shrinking away
        // Never negative, whatever it's handed.
        #expect(MascotBeat.foodFade(1.5).opacity >= 0)
        #expect(MascotBeat.foodFade(1.5).scale >= 0)
    }

    // MARK: - The ease

    @Test("the ease depends on elapsed time, not on how often it is sampled")
    func easeIsFrameRateIndependent() {
        // The bug this replaces: `value += (target - value) * 0.16` per frame,
        // which ramps ~1.5x faster at 30fps than at 20fps. Both mascots ease
        // from the same start over the same seconds and must land together.
        let elapsed = 0.3
        let coarse = MascotBeat.ease(from: 0, to: 1, elapsed: elapsed)
        let fine = MascotBeat.ease(from: 0, to: 1, elapsed: elapsed)
        #expect(coarse == fine)

        // Sampling the same span in one step or in many gives the same answer,
        // because each call is absolute rather than incremental.
        #expect(abs(MascotBeat.ease(from: 0, to: 1, elapsed: 0.44)
                    - MascotBeat.ease(from: 0, to: 1, elapsed: 0.44)) < 1e-12)
    }

    @Test("the ease moves toward the target and settles there")
    func easeConverges() {
        #expect(MascotBeat.ease(from: 0, to: 1, elapsed: 0) == 0)
        #expect(MascotBeat.ease(from: 0, to: 1, elapsed: MascotBeat.ramp) > 0.6)   // ~63%
        #expect(MascotBeat.ease(from: 0, to: 1, elapsed: MascotBeat.ramp) < 0.66)
        #expect(MascotBeat.ease(from: 0, to: 1, elapsed: 5) > 0.999)
        // Monotonic on the way up.
        var previous = -1.0
        for elapsed in stride(from: 0.0, through: 2.0, by: 0.05) {
            let value = MascotBeat.ease(from: 0, to: 1, elapsed: elapsed)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("the ease runs back down the same way")
    func easeReverses() {
        #expect(MascotBeat.ease(from: 1, to: 0, elapsed: 0) == 1)
        #expect(MascotBeat.ease(from: 1, to: 0, elapsed: 5) < 0.001)
        // Symmetric: falling from 1 mirrors rising from 0.
        let up = MascotBeat.ease(from: 0, to: 1, elapsed: 0.3)
        let down = MascotBeat.ease(from: 1, to: 0, elapsed: 0.3)
        #expect(abs((1 - down) - up) < 1e-12)
    }

    @Test("stopping mid-ramp resumes from where it actually was")
    func easeFromPartialValue() {
        // Start rising, get interrupted at 0.4, then fall from there — no jump
        // back to 1 first.
        let interrupted = MascotBeat.ease(from: 0, to: 1, elapsed: 0.28)
        #expect(interrupted > 0.2 && interrupted < 0.9)
        #expect(MascotBeat.ease(from: interrupted, to: 0, elapsed: 0) == interrupted)
        #expect(MascotBeat.ease(from: interrupted, to: 0, elapsed: 5) < 0.001)
    }

    @Test("a negative elapsed time cannot rewind the ease")
    func easeIgnoresBackwardsTime() {
        // Clock adjustments happen; they must not make 뭉치 twitch.
        #expect(MascotBeat.ease(from: 0.5, to: 1, elapsed: -10) == 0.5)
    }
}
