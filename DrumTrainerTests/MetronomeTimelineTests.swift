import XCTest
@testable import DrumTrainer

final class MetronomeTimelineTests: XCTestCase {
    func testDigitalAmplitudeConvertsToDecibelsFS() {
        XCTAssertEqual(AudioLevelMeasurement.decibelsFS(forAmplitude: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(
            AudioLevelMeasurement.decibelsFS(forAmplitude: 0.5),
            -6.020_599_913,
            accuracy: 0.0001
        )
        XCTAssertEqual(AudioLevelMeasurement.decibelsFS(forAmplitude: 0), -80)
        XCTAssertEqual(AudioLevelMeasurement.decibelsFS(forAmplitude: .nan), -80)
    }

    func testEveryMetronomeSoundHasUserFacingGuidance() {
        XCTAssertEqual(MetronomeSound.allCases.count, 5)
        XCTAssertTrue(MetronomeSound.allCases.allSatisfy {
            !$0.displayName.isEmpty && !$0.guidance.isEmpty
        })
    }

    func testSchedulingHealthTracksMinimumLeadAndAtRiskTicks() {
        let converter = LinearHostTimeConverter(nanosecondsPerTick: 1)
        var health = MetronomeSchedulingHealth(warningThresholdMilliseconds: 20)

        health.record(scheduledHostTime: 50_000_000, currentHostTime: 0, converter: converter)
        health.record(scheduledHostTime: 65_000_000, currentHostTime: 50_000_000, converter: converter)
        health.record(scheduledHostTime: 80_000_000, currentHostTime: 85_000_000, converter: converter)

        XCTAssertEqual(health.scheduledTickCount, 3)
        XCTAssertEqual(health.atRiskTickCount, 2)
        XCTAssertEqual(health.lastLeadTimeMilliseconds, -5)
        XCTAssertEqual(health.minimumLeadTimeMilliseconds, -5)
        XCTAssertTrue(health.hasWarning)
    }

    func testSchedulingHealthTreatsThresholdAsStrictlyAtRisk() {
        let converter = LinearHostTimeConverter(nanosecondsPerTick: 1)
        var health = MetronomeSchedulingHealth(warningThresholdMilliseconds: 20)

        health.record(scheduledHostTime: 20_000_000, currentHostTime: 0, converter: converter)

        XCTAssertEqual(health.atRiskTickCount, 0)
        XCTAssertFalse(health.hasWarning)
    }

    func testBeatIntervalsUseTempo() {
        XCTAssertEqual(MetronomeTimeline.intervalNanoseconds(bpm: 120), 500_000_000)
        XCTAssertEqual(MetronomeTimeline.intervalNanoseconds(bpm: 60), 1_000_000_000)
        XCTAssertEqual(MetronomeTimeline.intervalNanoseconds(bpm: 240), 250_000_000)
    }

    func testTempoIsBoundedToSupportedRange() {
        XCTAssertEqual(
            MetronomeTimeline.intervalNanoseconds(bpm: 1),
            MetronomeTimeline.intervalNanoseconds(bpm: 40)
        )
        XCTAssertEqual(
            MetronomeTimeline.intervalNanoseconds(bpm: 999),
            MetronomeTimeline.intervalNanoseconds(bpm: 240)
        )
    }

    func testBeatNumbersRepeatInFourFour() {
        XCTAssertEqual((0..<8).map { MetronomeTimeline.beatNumber(forTick: $0) }, [1, 2, 3, 4, 1, 2, 3, 4])
    }

    func testOutputLatencyUsesValidDownstreamValueAndRejectsStaleValues() {
        XCTAssertEqual(
            MetronomeTimeline.outputLatencyNanoseconds(
                downstreamSeconds: 0.018,
                hardwareSeconds: 0.007
            ),
            18_000_000
        )
        XCTAssertEqual(
            MetronomeTimeline.outputLatencyNanoseconds(
                downstreamSeconds: 12,
                hardwareSeconds: 0.007
            ),
            7_000_000
        )
        XCTAssertEqual(
            MetronomeTimeline.outputLatencyNanoseconds(
                downstreamSeconds: .infinity,
                hardwareSeconds: .nan
            ),
            0
        )
    }

    func testPresentationTimeIncludesSelectedOutputLatency() {
        let presentationTime = MetronomeTimeline.presentationHostTime(
            renderHostTime: 10_000,
            outputLatencyNanoseconds: 25_000_000,
            converter: LinearHostTimeConverter(nanosecondsPerTick: 100)
        )

        XCTAssertEqual(presentationTime, 260_000)
    }

    func testPresentationTimeSaturatesInsteadOfOverflowing() {
        let presentationTime = MetronomeTimeline.presentationHostTime(
            renderHostTime: UInt64.max - 5,
            outputLatencyNanoseconds: 1_000,
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1)
        )

        XCTAssertEqual(presentationTime, UInt64.max)
    }

    func testRenderTimeSubtractsOutputLatencyAndSaturatesAtZero() {
        let converter = LinearHostTimeConverter(nanosecondsPerTick: 100)
        XCTAssertEqual(
            MetronomeTimeline.renderHostTime(
                presentationHostTime: 260_000,
                outputLatencyNanoseconds: 25_000_000,
                converter: converter
            ),
            10_000
        )
        XCTAssertEqual(
            MetronomeTimeline.renderHostTime(
                presentationHostTime: 10,
                outputLatencyNanoseconds: 25_000_000,
                converter: converter
            ),
            0
        )
    }
}
