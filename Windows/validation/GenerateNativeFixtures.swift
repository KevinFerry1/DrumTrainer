import Foundation

struct NativeFixture: Encodable {
    var name: String
    var expected: [ExpectedEvent]
    var actual: [PerformanceEvent]
    var gradeKicks: Bool
    var corrections: [String: Double]
    var voiceCorrections: [String: Double]
    var matchResults: [MatchResult]
    var metrics: AggregateMetrics
    var accents: AccentEvaluation?
    var ghosts: GhostEvaluation?
    var stableTiming: StableTimingBiasEvaluation?
    var timeline: TimelineFixture
    var coaching: PracticeCoachingSummary
    var clean: Bool
}
struct TimelineFixture: Encodable {
    let start: Int64; let end: Int64; let entries: [TimelineEntryFixture]
    init(_ timeline: PracticeTimingTimeline) { start = timeline.startSessionTimeNanoseconds; end = timeline.endSessionTimeNanoseconds; entries = timeline.entries.map(TimelineEntryFixture.init) }
}
struct TimelineEntryFixture: Encodable {
    let id: UUID; let expectedEventID: UUID?; let actualEventID: UUID?; let measure: Int?; let beat: Int?; let subdivision: Int?; let expectedVoice: DrumVoice?; let playedVoice: DrumVoice?; let expectedTimeNanoseconds: Int64?; let actualTimeNanoseconds: Int64?; let classification: MatchClassification; let signedOffsetMilliseconds: Double?; let source: EventSource?; let isProblem: Bool; let anchorTimeNanoseconds: Int64
    init(_ e: PracticeTimingTimelineEntry) { id = e.id; expectedEventID = e.expectedEventID; actualEventID = e.actualEventID; measure = e.measure; beat = e.beat; subdivision = e.subdivision; expectedVoice = e.expectedVoice; playedVoice = e.playedVoice; expectedTimeNanoseconds = e.expectedTimeNanoseconds; actualTimeNanoseconds = e.actualTimeNanoseconds; classification = e.classification; signedOffsetMilliseconds = e.signedOffsetMilliseconds; source = e.source; isProblem = e.isProblem; anchorTimeNanoseconds = e.anchorTimeNanoseconds }
}
struct GeometryFixture: Encodable { let measure: Int; let slot: Double; let slotsPerMeasure: Int; let measureWidth: Double; let position: Double }
struct AlignmentFixture: Encodable { var name: String; var source: EventSource; var voice: DrumVoice?; var references: [Int64]; var events: [PerformanceEvent]; var maximumOffsetMilliseconds: Double; var measurement: TimingAlignmentMeasurement? }
struct GeneratedPattern: Codable { var exercise: String; var pattern: PracticePattern }
struct FeatureFixture: Codable { var sampleRate: Double; var samples: [Double]; var features: AudioTransientFeatures? }
struct NativeFixtureArchive: Encodable { var patterns: [GeneratedPattern]; var scoring: [NativeFixture]; var audio: [FeatureFixture]; var signature: KickSoundSignature?; var geometry: [GeometryFixture]; var alignment: [AlignmentFixture] }

@main struct GenerateNativeFixtures {
    static func expected(_ time: Double, _ voice: DrumVoice = .kick, allowed: Set<DrumVoice> = [], group: UUID? = nil,
                         accent: Double? = nil, accentContrast: Double? = nil, ghost: Double? = nil, ghostContrast: Double? = nil,
                         tolerance: Double = 100) -> ExpectedEvent {
        ExpectedEvent(measure: max(Int(time / 2_000) + 1, 1), beat: 1, subdivision: 0,
                      sessionTimeNanoseconds: Int64((time * 1_000_000).rounded()), voice: voice, allowedVoices: allowed,
                      minimumAccentVelocity: accent, minimumAccentContrast: accentContrast, maximumGhostVelocity: ghost,
                      minimumGhostContrast: ghostContrast, matchingToleranceNanoseconds: Int64((tolerance * 1_000_000).rounded()), simultaneousGroupID: group)
    }
    static func actual(_ time: Double, _ voice: DrumVoice = .kick, velocity: Double? = 80.0 / 127, source: EventSource = .midi) -> PerformanceEvent {
        PerformanceEvent(source: source, voice: voice, hostTime: 0, sessionTimeNanoseconds: Int64((time * 1_000_000).rounded()),
                         velocity: velocity, rawMetadata: .simulated(label: "Synthetic parity fixture"))
    }
    static func fixture(_ name: String, _ expected: [ExpectedEvent], _ actual: [PerformanceEvent], gradeKicks: Bool = true,
                        corrections: [String: Double] = [:], voiceCorrections: [String: Double] = [:]) -> NativeFixture {
        let e = expected.filter { gradeKicks || $0.voice != .kick }, a = actual.filter { gradeKicks || $0.voice != .kick }
        let sourceCorrections = Dictionary(uniqueKeysWithValues: corrections.compactMap { key, value in
            EventSource(rawValue: key).map { ($0, Int64((value * 1_000_000).rounded())) }
        })
        var voiceCorrectionMap: [EventTimingCompensationKey: Int64] = [:]
        for (key, value) in voiceCorrections {
            let parts = key.split(separator: "/").map(String.init)
            if parts.count == 2, let source = EventSource(rawValue: parts[0]), let voice = DrumVoice(rawValue: parts[1]) {
                voiceCorrectionMap[EventTimingCompensationKey(source: source, voice: voice)] = Int64((value * 1_000_000).rounded())
            }
        }
        let matches = EventMatcher(sourceTimingCompensationNanoseconds: sourceCorrections, voiceTimingCompensationNanoseconds: voiceCorrectionMap).match(expected: e, actual: a)
        let metrics = ScoringMetricsCalculator().calculate(from: matches, expectedEvents: e, actualEvents: a)
        let accents = AccentEvaluator().evaluate(expectedEvents: e, actualEvents: a, matchResults: matches)
        let ghosts = GhostEvaluator().evaluate(expectedEvents: e, actualEvents: a, matchResults: matches)
        let stable = StableTimingBiasEvaluator().evaluate(matches)
        let clean = metrics.totalExpected > 0 && metrics.recall >= 0.95
            && (stable?.adjustedMedianAbsoluteErrorMilliseconds ?? metrics.medianAbsoluteErrorMilliseconds ?? .infinity) <= 25
            && (accents?.metrics.passesCleanThreshold ?? true) && (ghosts?.metrics.passesCleanThreshold ?? true)
        let pattern = PracticePattern(name: name, bpm: 120, beatsPerMeasure: 4, measures: 4, expectedEvents: e)
        let coaching = PracticeResultCoach().summarize(PracticeSessionOutcome(pattern: pattern, actualEvents: a, matchResults: matches, metrics: metrics))
        return NativeFixture(name: name, expected: expected, actual: actual, gradeKicks: gradeKicks, corrections: corrections, voiceCorrections: voiceCorrections,
                             matchResults: matches, metrics: metrics, accents: accents, ghosts: ghosts, stableTiming: stable, timeline: TimelineFixture(PracticeTimingTimeline(pattern: pattern, actualEvents: a, matchResults: matches)), coaching: coaching, clean: clean)
    }
    static func alignmentFixtures() -> [AlignmentFixture] {
        let references = (0..<12).map { Int64($0) * 1_000_000_000 }
        let cases: [(String, EventSource, DrumVoice?, [Int64], [PerformanceEvent], Double)] = [
            ("median shared MIDI offset", .midi, nil, references, (0..<12).map { actual(Double($0) * 1000 + 42 + Double($0 % 3 - 1) * 3, .snare) }, 400),
            ("microphone source and voice isolation", .microphone, .kick, [0, 1_000_000_000], [actual(20, .snare), actual(35, velocity: nil, source: .microphone), actual(1030, .snare, source: .microphone), actual(1060, velocity: nil, source: .microphone)], 400),
            ("nearest unused event once per click", .midi, nil, [0, 1_000_000_000], [actual(-100), actual(20), actual(60), actual(990)], 400),
            ("400 ms inclusive boundary", .midi, nil, [0, 1_000_000_000], [actual(400), actual(1400.000001)], 400),
            ("MIDI accepts every known drum", .midi, nil, [0, 1_000_000_000, 2_000_000_000], [actual(10,.snare),actual(1020,.highTom),actual(2030,.closedHiHat),actual(0,.unknown),actual(1000,.metronome)], 400),
            ("raw early bias and broad variation", .midi, nil, references, (0..<12).map { actual(Double($0) * 1000 - 100 + Double($0 % 4 - 2) * 65) }, 400),
            ("no matching evidence", .midi, nil, references, [actual(500)], 400),
            ("empty alignment", .midi, nil, [], [], 400)
        ]
        return cases.map { name, source, voice, refs, events, maximum in
            var collector = TimingAlignmentCollector(source: source, voice: voice)
            refs.forEach { collector.recordReference($0) }; events.forEach { collector.record($0) }
            return AlignmentFixture(name: name, source: source, voice: voice, references: refs, events: events, maximumOffsetMilliseconds: maximum, measurement: collector.measurement(maximumOffsetMilliseconds: maximum))
        }
    }
    static func main() throws {
        var patterns: [GeneratedPattern] = []
        for bpm in [40.0, 113.0, 240.0] {
            for exercise in KickExercise.allCases {
                let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(bpm: bpm, exercise: exercise, measures: 4))
                patterns.append(GeneratedPattern(exercise: exercise.rawValue, pattern: pattern))
            }
        }
        let group = UUID(), nextGroup = UUID()
        var tests: [NativeFixture] = [
            fixture("empty", [], []),
            fixture("extra only", [], [actual(0)]),
            fixture("missed only", [expected(0)], []),
            fixture("exact boundary", [expected(0)], [actual(100)]),
            fixture("outside boundary by one nanosecond", [expected(0)], [actual(100.000001)]),
            fixture("equal distance ambiguity", [expected(100)], [actual(80), actual(120)]),
            fixture("duplicate onset ambiguity", [expected(100)], [actual(100), actual(100)]),
            fixture("adjacent overlapping windows", [expected(0),expected(60)], [actual(40),actual(-90)]),
            fixture("wrong voice", [expected(0,.snare)], [actual(10,.highTom)]),
            fixture("allowed alternate voice credit", [expected(0,.snare,allowed:[.crossStick])], [actual(0,.crossStick)]),
            fixture("reversed chord arrivals", [expected(0,.kick,group:group),expected(0,.snare,group:group),expected(0,.ride,group:group)], [actual(12,.ride),actual(-3,.snare),actual(8,.kick)]),
            fixture("all MIDI limb offsets remain raw", [expected(0,.kick,group:group),expected(0,.snare,group:group)], [actual(45,.kick),actual(35,.snare)], corrections:["midi":40], voiceCorrections:["midi/kick":45]),
            fixture("mixed input corrected limb spread", [expected(0,.kick,group:group),expected(0,.snare,group:group)], [actual(55,.kick,velocity:nil,source:.microphone),actual(15,.snare)], corrections:["midi":10,"microphone":50]),
            fixture("ignore kicks", [expected(0,.kick,group:group),expected(0,.snare,group:group)], [actual(10,.snare)], gradeKicks:false),
            fixture("metronome excluded", [expected(0)], [actual(0),actual(0,.metronome,source:.metronome)]),
            fixture("accent minimum fallback without baseline", [expected(0,.snare,accent:100.0/127,accentContrast:18.0/127)], [actual(0,.snare,velocity:120.0/127)]),
            fixture("accent relative only missing baseline", [expected(0,.snare,accentContrast:18.0/127)], [actual(0,.snare,velocity:120.0/127)]),
            fixture("ghost maximum fallback without baseline", [expected(0,.snare,ghost:50.0/127,ghostContrast:18.0/127)], [actual(0,.snare,velocity:25.0/127)]),
            fixture("ghost microphone velocity unavailable", [expected(0,.kick,ghost:50.0/127,ghostContrast:18.0/127)], [actual(0,velocity:0.1,source:.microphone)]),
            fixture("ghost alternate voice velocity unavailable", [expected(0,.snare,allowed:[.crossStick],ghost:50.0/127,ghostContrast:18.0/127)], [actual(0,.crossStick,velocity:25.0/127)]),
            fixture("authored dynamics relative contrast", [expected(0,.snare),expected(500,.snare,accent:100.0/127,accentContrast:18.0/127),expected(1000,.snare,ghost:50.0/127,ghostContrast:18.0/127)], [actual(0,.snare),actual(500,.snare,velocity:120.0/127),actual(1000,.snare,velocity:25.0/127)]),
            fixture("successive chords with missing tone", [expected(0,.kick,group:group),expected(0,.snare,group:group),expected(500,.kick,group:nextGroup),expected(500,.snare,group:nextGroup)], [actual(0),actual(0,.snare),actual(500,.snare)]),
        ]
        var unisonExpected: [ExpectedEvent] = [], unisonActual: [PerformanceEvent] = []
        for i in 0..<8 { let g = UUID(), t = Double(i) * 500
            unisonExpected += [expected(t, .snare, group: g), expected(t, .closedHiHat, group: g)]
            unisonActual += [actual(t + 60, .snare), actual(t + 40, .closedHiHat)]
        }
        tests.append(fixture("snare hat synchronization precedes stable-bias advice", unisonExpected, unisonActual))
        tests.append(fixture("coach accents too soft", [expected(0,.snare), expected(500,.snare,accent:100.0/127,accentContrast:18.0/127)], [actual(0,.snare),actual(500,.snare,velocity:90.0/127)]))
        tests.append(fixture("coach accents need contrast", [expected(0,.snare), expected(500,.snare,accent:80.0/127,accentContrast:18.0/127)], [actual(0,.snare),actual(500,.snare,velocity:90.0/127)]))
        tests.append(fixture("coach ghosts too loud", [expected(0,.snare), expected(500,.snare,ghost:50.0/127,ghostContrast:18.0/127)], [actual(0,.snare),actual(500,.snare,velocity:60.0/127)]))
        tests.append(fixture("coach ghosts need contrast", [expected(0,.snare), expected(500,.snare,ghost:100.0/127,ghostContrast:18.0/127)], [actual(0,.snare),actual(500,.snare,velocity:70.0/127)]))
        for bias in [0.0, 29.0, 30.0, 50.0, 80.0, 81.0, -40.0] {
            let expected = (0..<12).map { Self.expected(Double($0)*500) }
            let actual = (0..<12).map { Self.actual(Double($0)*500+bias+Double($0%3-1)*2) }
            tests.append(fixture("stable bias \(bias)", expected, actual))
        }
        var random: UInt64 = 0x31415926
        func next(_ bound: Int) -> Int { random = random &* 6364136223846793005 &+ 1; return Int((random >> 32) % UInt64(bound)) }
        let voices: [DrumVoice] = [.kick,.snare,.closedHiHat,.highTom,.ride]
        for seed in 0..<32 {
            var e: [ExpectedEvent] = [], a: [PerformanceEvent] = []
            for index in 0..<64 {
                let voice = voices[next(voices.count)], time = Double(index)*62.5
                e.append(expected(time,voice,allowed:voice == .snare ? [.crossStick]:[]))
                if next(10) > 1 { a.append(actual(time+Double(next(151)-75), next(10)>1 ? voice:voices[next(voices.count)],velocity:Double(next(127)+1)/127)) }
                if next(10) == 0 { a.append(actual(time+Double(next(151)-75),voices[next(voices.count)])) }
            }
            tests.append(fixture("deterministic mixed run \(seed)",e,a))
        }
        let dense = (0..<960).map { expected(Double($0)*62.5) }
        tests.append(fixture("60 seconds 960 hits",dense,(0..<960).map { actual(Double($0)*62.5+Double($0%3-1)*5) }))
        let classifier = KickSoundClassifier()
        var features: [FeatureFixture] = []
        for frequency in [85.0,240.0,960.0,3800.0,7600.0] {
            for sampleRate in [44100.0,48000.0] {
                let samples = (0..<768).map { i in sin(Double(i)*2*Double.pi*frequency/sampleRate)*exp(-Double(i)/240)*0.7 }
                features.append(FeatureFixture(sampleRate: sampleRate, samples: samples, features: classifier.extractFeatures(samples: samples, sampleRate: sampleRate)))
            }
        }
        let archive = NativeFixtureArchive(patterns: patterns, scoring: tests, audio: features,
            signature: classifier.makeSignature(from: features.compactMap(\.features)),
            geometry: [2, 3, 4].flatMap { perBeat in [330.0, 460.0].flatMap { width in [-0.35, 0.0, 1.0, Double(perBeat * 4)].map { slot in GeometryFixture(measure: 2, slot: slot, slotsPerMeasure: perBeat * 4, measureWidth: width, position: PracticeScoreTimeline.notePosition(measure: 2, slot: slot, slotsPerMeasure: perBeat * 4, measureWidth: width)) } } }, alignment: alignmentFixtures())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        let path = CommandLine.arguments.dropFirst().first ?? "Windows/validation/native-fixtures.json"
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        print("Generated \(patterns.count) native patterns, \(tests.count) scoring fixtures and \(features.count) audio feature fixtures.")
    }
}
