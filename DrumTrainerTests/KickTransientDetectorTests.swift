import XCTest
@testable import DrumTrainer

final class KickTransientDetectorTests: XCTestCase {
    private let timeline = SessionTimeline(
        originHostTime: 0,
        converter: LinearHostTimeConverter(nanosecondsPerTick: 1)
    )

    func testThresholdCrossingUsesInBufferFrameTimestamp() {
        var detector = KickTransientDetector(
            configuration: .init(threshold: 0.5, retriggerLockoutMilliseconds: 40)
        )

        let events = detector.processEnvelope(
            [0.1, 0.2, 0.7, 0.9, 0.2],
            bufferHostTime: 1_000_000_000,
            sampleRate: 1_000,
            timeline: timeline
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].hostTime, 1_002_000_000)
        guard case let .microphone(_, _, frameOffset) = events[0].rawMetadata else {
            return XCTFail("Expected microphone metadata")
        }
        XCTAssertEqual(frameOffset, 2)
    }

    func testRingingAndHitsInsideLockoutDoNotDuplicate() {
        var detector = KickTransientDetector(
            configuration: .init(threshold: 0.5, retriggerLockoutMilliseconds: 40)
        )

        let events = detector.processEnvelope(
            [0.1, 0.8, 0.7, 0.2, 0.75, 0.1, 0.9],
            bufferHostTime: 0,
            sampleRate: 1_000,
            timeline: timeline
        )

        XCTAssertEqual(events.count, 1)
    }

    func testLegitimateHitAfterLockoutIsDetected() {
        var detector = KickTransientDetector(
            configuration: .init(threshold: 0.5, retriggerLockoutMilliseconds: 30)
        )

        let events = detector.processEnvelope(
            [0.1, 0.8, 0.1] + Array(repeating: 0.1, count: 30) + [0.8],
            bufferHostTime: 0,
            sampleRate: 1_000,
            timeline: timeline
        )

        XCTAssertEqual(events.count, 2)
    }

    func testSecondaryPeakOutsideLockoutDoesNotTriggerUntilSignalSustainsQuiet() {
        var detector = KickTransientDetector(
            configuration: .init(threshold: 0.5, retriggerLockoutMilliseconds: 40)
        )
        let resonantTail = Array(repeating: 0.3, count: 50)
        let sustainedQuiet = Array(repeating: 0.1, count: 12)

        let events = detector.processEnvelope(
            [0.1, 0.8] + resonantTail + [0.75] + sustainedQuiet + [0.8],
            bufferHostTime: 0,
            sampleRate: 1_000,
            timeline: timeline
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].hostTime, 1_000_000)
        XCTAssertEqual(events[1].hostTime, 65_000_000)
    }

    func testRearmQuietPeriodCanSpanAudioBuffers() {
        var detector = KickTransientDetector(
            configuration: .init(threshold: 0.5, retriggerLockoutMilliseconds: 30)
        )

        let first = detector.processEnvelope(
            [0.1, 0.8] + Array(repeating: 0.1, count: 7),
            bufferHostTime: 0,
            sampleRate: 1_000,
            timeline: timeline
        )
        let second = detector.processEnvelope(
            Array(repeating: 0.1, count: 25) + [0.8],
            bufferHostTime: 9_000_000,
            sampleRate: 1_000,
            timeline: timeline
        )

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].hostTime, 34_000_000)
    }

    func testPCMChannelsUseLoudestChannelAndFrameTimestamp() {
        var detector = KickTransientDetector(
            configuration: .init(threshold: 0.5, retriggerLockoutMilliseconds: 40)
        )
        var left: [Float] = [0.1, 0.2, 0.2, 0.1]
        var right: [Float] = [0.1, 0.2, 0.8, 0.1]

        let firstOutput = left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                let channelPointers = [leftBuffer.baseAddress!, rightBuffer.baseAddress!]
                return channelPointers.withUnsafeBufferPointer { pointers in
                    detector.processPCM(
                        channels: pointers.baseAddress!,
                        channelCount: 2,
                        frameCount: 4,
                        bufferHostTime: 1_000_000_000,
                        sampleRate: 1_000,
                        timeline: timeline
                    )
                }
            }
        }

        var tail = Array(repeating: Float(0.02), count: 20)
        let tailCount = tail.count
        let secondOutput = tail.withUnsafeMutableBufferPointer { tailBuffer in
            let channelPointers = [tailBuffer.baseAddress!]
            return channelPointers.withUnsafeBufferPointer { pointers in
                detector.processPCM(
                    channels: pointers.baseAddress!,
                    channelCount: 1,
                    frameCount: tailCount,
                    bufferHostTime: 1_004_000_000,
                    sampleRate: 1_000,
                    timeline: timeline
                )
            }
        }

        XCTAssertTrue(firstOutput.events.isEmpty)
        XCTAssertEqual(secondOutput.events.count, 1)
        XCTAssertEqual(secondOutput.events[0].hostTime, 1_002_000_000)
        XCTAssertNotNil(secondOutput.events[0].audioFeatures)
        XCTAssertEqual(firstOutput.peak, 0.8, accuracy: 0.000_1)
    }

    func testKickSoundSignatureSeparatesLowKickBodyFromStickClick() throws {
        let classifier = KickSoundClassifier()
        let sampleRate = 48_000.0
        let trainingFeatures = try (0..<12).map { index in
            try XCTUnwrap(classifier.extractFeatures(
                samples: dampedTone(frequency: 95 + Double(index % 4) * 8, sampleRate: sampleRate),
                sampleRate: sampleRate
            ))
        }
        let signature = try XCTUnwrap(classifier.makeSignature(from: trainingFeatures))
        let kick = try XCTUnwrap(classifier.extractFeatures(
            samples: dampedTone(frequency: 110, sampleRate: sampleRate),
            sampleRate: sampleRate
        ))
        let stick = try XCTUnwrap(classifier.extractFeatures(
            samples: dampedTone(frequency: 4_200, sampleRate: sampleRate),
            sampleRate: sampleRate
        ))

        XCTAssertGreaterThan(classifier.similarity(of: kick, to: signature), 0.75)
        XCTAssertLessThan(classifier.similarity(of: stick, to: signature), 0.20)
        XCTAssertGreaterThan(kick.lowFrequencyRatio, stick.lowFrequencyRatio)
        XCTAssertLessThan(kick.spectralCentroidHertz, stick.spectralCentroidHertz)
    }

    private func dampedTone(frequency: Double, sampleRate: Double) -> [Double] {
        (0..<768).map { frame in
            let time = Double(frame) / sampleRate
            return sin(2 * Double.pi * frequency * time) * exp(-time * 95)
        }
    }
}
