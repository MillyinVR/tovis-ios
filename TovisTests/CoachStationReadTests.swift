// The station read (camera plan P4.2) — what one reading of an empty station
// is allowed to conclude, and what it refuses to.
//
// Every fixture is built RELATIVE to the live `CoachTuning` thresholds rather
// than against copied literals, and nothing here writes a threshold: those are
// process-global `static var`s and Swift Testing runs suites in parallel — the
// same discipline as `CoachRoomMemoryTests`.
import Foundation
import Testing
@testable import Tovis

@Suite struct CoachStationReadTests {
    private func profile(warmth: Double = 0, green: Double = 0,
                         thirds: [Double] = [0, 0, 0],
                         readAt: Date = Date(timeIntervalSince1970: 1_000_000))
        -> CoachStationRead.Profile {
        CoachStationRead.Profile(warmth: warmth, greenTint: green,
                                 thirdWarmths: thirds, readAt: readAt)
    }

    /// A spread big enough to mean "two light sources" at the live threshold,
    /// and a clearly-cool value for the window third.
    private var spread: Double { CoachTuning.mixedLightSpread + 0.05 }
    private var cool: Double { min(-0.1, CoachTuning.warmCastWarmth - 0.5) }

    // MARK: - Finding the window

    @Test func aCoolLeftThirdIsAWindowOnTheLeft() {
        let p = profile(thirds: [cool, cool + spread, cool + spread])
        #expect(p.hasWindow)
        #expect(p.windowSide == "left")
    }

    @Test func aCoolRightThirdIsAWindowOnTheRight() {
        let p = profile(thirds: [cool + spread, cool + spread, cool])
        #expect(p.hasWindow)
        #expect(p.windowSide == "right")
    }

    /// A window straight ahead is a window — but not one with a nameable
    /// side, and no line anywhere should invent one.
    @Test func aCoolMiddleThirdIsAWindowWithNoSide() {
        let p = profile(thirds: [cool + spread, cool, cool + spread])
        #expect(p.hasWindow)
        #expect(p.windowSide == nil)
    }

    /// Uniform light — however warm or cool — is not a window direction. The
    /// spread is the evidence, and reuses `mixedLightSpread` because it is
    /// the same physical claim measured on the same scale.
    @Test func aUniformRoomHasNoWindow() {
        for level in [cool, 0.0, CoachTuning.warmCastWarmth + 0.1] {
            let p = profile(thirds: [level, level, level])
            #expect(!p.hasWindow, "uniform at \(level) read as a window")
            #expect(p.windowSide == nil)
        }
    }

    /// Two bulbs of different warmth make a spread, but if the "cool" side
    /// still reads as a warm cast it is not daylight, and pointing the pro at
    /// it would be confidently wrong advice.
    @Test func aLessWarmBulbIsNotAWindow() {
        let warmFloor = CoachTuning.warmCastWarmth + 0.05
        let p = profile(thirds: [warmFloor, warmFloor + spread, warmFloor + spread])
        #expect(!p.hasWindow)
        #expect(p.windowSide == nil)
    }

    // MARK: - The cast, in the live coach's own vocabulary

    @Test func castFollowsTheLiveThresholdsAndPrecedence() {
        #expect(profile(warmth: CoachTuning.warmCastWarmth + 0.05).cast == .warm)
        #expect(profile(green: CoachTuning.greenCastTint + 0.05).cast == .green)
        #expect(profile().cast == .neutral)
        // ColorCoach reports green before warm; the read agrees.
        #expect(profile(warmth: CoachTuning.warmCastWarmth + 0.05,
                        green: CoachTuning.greenCastTint + 0.05).cast == .green)
        // At the threshold exactly, nothing fires — same `>` as ColorCoach.
        #expect(profile(warmth: CoachTuning.warmCastWarmth).cast == .neutral)
    }

    // MARK: - Corroboration (what lets the GOT IT offer come early)

    @Test func theStationCorroboratesExactlyWhatItMeasured() {
        let warm = profile(warmth: CoachTuning.warmCastWarmth + 0.05)
        #expect(warm.corroborates(.colorWarm))
        #expect(!warm.corroborates(.colorGreenish))
        #expect(!warm.corroborates(.colorMixed))

        let green = profile(green: CoachTuning.greenCastTint + 0.05)
        #expect(green.corroborates(.colorGreenish))
        #expect(!green.corroborates(.colorWarm))

        let mixed = profile(thirds: [cool, cool + spread, cool + spread])
        #expect(mixed.corroborates(.colorMixed))
        #expect(!mixed.corroborates(.colorWarm))
    }

    /// With no person to segment, a station frame's edge energy measures how
    /// busy the PICTURE is, not the backdrop — the bench's portraits-only
    /// finding. The busy-backdrop tip therefore earns its offer the slow way
    /// only, whatever the station looked like.
    @Test func theStationNeverCorroboratesTheBackdropTip() {
        let everything = profile(warmth: 1, green: 1, thirds: [cool, 0.5, 1])
        #expect(!everything.corroborates(.backgroundBusy))
        // …and nothing outside the colour moments, ever.
        for moment in CoachMoment.allCases
        where ![.colorMixed, .colorGreenish, .colorWarm].contains(moment) {
            #expect(!everything.corroborates(moment), "\(moment)")
        }
    }

    // MARK: - The accumulator (one read attempt)

    private func sample(thirds: [Double] = [0, 0, 0], warmth: Double = 0,
                        green: Double = 0, luma: Double = 0.5,
                        face: Bool = false) -> CoachStationRead.Sample {
        CoachStationRead.Sample(thirdWarmths: thirds, warmth: warmth,
                                greenTint: green, luma: luma, faceSeen: face)
    }

    @Test func aReadNeedsItsFullSecondOfFrames() {
        var acc = CoachStationRead.Accumulator()
        for _ in 0..<(CoachStationRead.samplesPerRead - 1) {
            acc.add(sample())
            #expect(acc.outcome(readAt: Date()) == nil, "concluded early")
        }
        acc.add(sample())
        #expect(acc.outcome(readAt: Date()) != nil)
    }

    @Test func theReadIsTheAverageOfItsFrames() throws {
        var acc = CoachStationRead.Accumulator()
        let n = CoachStationRead.samplesPerRead
        for i in 0..<n {
            // Alternate around a mean so a single noisy frame demonstrably
            // isn't the record.
            let jitter = (i % 2 == 0) ? 0.1 : -0.1
            acc.add(sample(thirds: [cool + jitter, 0.5 + jitter, 0.5 + jitter],
                           warmth: 0.4 + jitter, green: 0.0, luma: 0.5))
        }
        let readAt = Date(timeIntervalSince1970: 5)
        guard case let .read(p)? = acc.outcome(readAt: readAt) else {
            Issue.record("expected a read"); return
        }
        #expect(abs(p.warmth - 0.4) < 1e-9)
        #expect(abs(p.thirdWarmths[0] - cool) < 1e-9)
        #expect(p.readAt == readAt)
    }

    /// A person through frame for one sixth of a second still puts skin and
    /// clothes into "the room's light" — the whole attempt is refused, not
    /// averaged around.
    @Test func aFaceInAnySingleFrameRefusesTheWholeRead() {
        var acc = CoachStationRead.Accumulator()
        acc.add(sample(face: true))
        for _ in 1..<CoachStationRead.samplesPerRead { acc.add(sample()) }
        #expect(acc.outcome(readAt: Date()) == .someoneInFrame)
    }

    @Test func aDarkRoomIsRefusedNotRecorded() {
        var acc = CoachStationRead.Accumulator()
        for _ in 0..<CoachStationRead.samplesPerRead {
            acc.add(sample(luma: CoachTuning.lumaTooDark - 0.05))
        }
        #expect(acc.outcome(readAt: Date()) == .tooDark)
    }

    // MARK: - The summary (the one place the side is spoken)

    @Test func theSummaryNamesTheSideAndTheLight() {
        #expect(profile(warmth: CoachTuning.warmCastWarmth + 0.05,
                        thirds: [cool, cool + spread, cool + spread]).summary
                == "Window on your left · warm light")
        #expect(profile(thirds: [cool + spread, cool + spread, cool]).summary
                == "Window on your right · neutral light")
        #expect(profile(green: CoachTuning.greenCastTint + 0.05).summary
                == "No window in view · greenish light")
        #expect(profile(thirds: [cool + spread, cool, cool + spread]).summary
                == "Window in view · neutral light")
    }
}
