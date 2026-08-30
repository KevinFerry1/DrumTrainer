import Foundation

struct KickPatternConfiguration: Equatable, Sendable {
    let bpm: Double
    let definition: Definition
    let measures: Int
    let beatsPerMeasure: Int
    let matchingToleranceMilliseconds: Double

    enum Definition: Equatable, Sendable {
        case builtIn(KickExercise)
        case custom(CustomMeasureDefinition)
    }

    var subdivision: KickSubdivision {
        switch definition {
        case let .builtIn(exercise): exercise.subdivision
        case let .custom(measure): measure.subdivision
        }
    }

    var eventsPerMeasure: [PracticeExerciseHit] {
        switch definition {
        case let .builtIn(exercise): exercise.eventsPerMeasure
        case let .custom(measure): measure.hits
        }
    }

    var displayName: String {
        switch definition {
        case let .builtIn(exercise): exercise.displayName
        case let .custom(measure): measure.displayName
        }
    }

    init(
        bpm: Double,
        subdivision: KickSubdivision,
        measures: Int = 1,
        beatsPerMeasure: Int = 4,
        matchingToleranceMilliseconds: Double = 100
    ) {
        self.bpm = bpm
        self.definition = .builtIn(.straight(subdivision))
        self.measures = measures
        self.beatsPerMeasure = beatsPerMeasure
        self.matchingToleranceMilliseconds = matchingToleranceMilliseconds
    }

    init(
        bpm: Double,
        exercise: KickExercise,
        measures: Int = 1,
        beatsPerMeasure: Int = 4,
        matchingToleranceMilliseconds: Double = 100
    ) {
        self.bpm = bpm
        self.definition = .builtIn(exercise)
        self.measures = measures
        self.beatsPerMeasure = beatsPerMeasure
        self.matchingToleranceMilliseconds = matchingToleranceMilliseconds
    }

    init(
        bpm: Double,
        customMeasure: CustomMeasureDefinition,
        measures: Int = 1,
        beatsPerMeasure: Int = 4,
        matchingToleranceMilliseconds: Double = 100
    ) {
        self.bpm = bpm
        self.definition = .custom(customMeasure)
        self.measures = measures
        self.beatsPerMeasure = beatsPerMeasure
        self.matchingToleranceMilliseconds = matchingToleranceMilliseconds
    }
}

enum KickPatternGeneratorError: LocalizedError, Equatable {
    case unsupportedTempo
    case invalidMeasureCount
    case invalidMeter
    case invalidTolerance
    case emptyCustomMeasure

    var errorDescription: String? {
        switch self {
        case .unsupportedTempo: "Tempo must be between 40 and 240 BPM."
        case .invalidMeasureCount: "The pattern must contain at least one measure."
        case .invalidMeter: "The pattern must contain at least one beat per measure."
        case .invalidTolerance: "Matching tolerance cannot be negative."
        case .emptyCustomMeasure: "Add at least one note to the custom measure before starting."
        }
    }
}

struct KickPatternGenerator: Sendable {
    func generate(
        configuration: KickPatternConfiguration,
        startSessionTimeNanoseconds: Int64 = 0,
        startHostTime: UInt64? = nil,
        hostTimeConverter: (any HostTimeConverting)? = nil
    ) throws -> PracticePattern {
        guard (40...240).contains(configuration.bpm) else {
            throw KickPatternGeneratorError.unsupportedTempo
        }
        guard configuration.measures > 0 else {
            throw KickPatternGeneratorError.invalidMeasureCount
        }
        guard configuration.beatsPerMeasure > 0 else {
            throw KickPatternGeneratorError.invalidMeter
        }
        guard configuration.matchingToleranceMilliseconds >= 0 else {
            throw KickPatternGeneratorError.invalidTolerance
        }

        if case let .custom(measure) = configuration.definition, measure.isEmpty {
            throw KickPatternGeneratorError.emptyCustomMeasure
        }

        let notesPerBeat = configuration.subdivision.notesPerBeat
        let slotsPerMeasure = configuration.beatsPerMeasure * notesPerBeat
        let slotCount = configuration.measures * slotsPerMeasure
        let beatNanoseconds = 60_000_000_000 / configuration.bpm
        let tolerance = Int64((configuration.matchingToleranceMilliseconds * 1_000_000).rounded())
        let durationNanoseconds = Int64((Double(configuration.measures * configuration.beatsPerMeasure) * beatNanoseconds).rounded())
        let measureStartOffsets = (0...configuration.measures).map { measure in
            Int64((Double(measure * configuration.beatsPerMeasure) * beatNanoseconds).rounded())
        }
        let referenceBeats = (0..<(configuration.measures * configuration.beatsPerMeasure)).map { beatIndex in
            let beat = beatIndex % configuration.beatsPerMeasure + 1
            return PracticeReferenceBeat(
                offsetNanoseconds: Int64((Double(beatIndex) * beatNanoseconds).rounded()),
                measure: beatIndex / configuration.beatsPerMeasure + 1,
                beat: beat,
                isAccent: beat == 1
            )
        }

        let events = (0..<slotCount).flatMap { index -> [ExpectedEvent] in
            let slotInMeasure = index % slotsPerMeasure
            let hits = configuration.eventsPerMeasure.filter { $0.slot == slotInMeasure }
            guard !hits.isEmpty else { return [] }
            let offsetNanoseconds = Int64((Double(index) * beatNanoseconds / Double(notesPerBeat)).rounded())
            let sessionTime = addingWithoutOverflow(startSessionTimeNanoseconds, offsetNanoseconds)
            let hostTime = makeHostTime(
                startHostTime: startHostTime,
                offsetNanoseconds: UInt64(max(0, offsetNanoseconds)),
                converter: hostTimeConverter
            )
            let beatIndex = index / notesPerBeat
            let simultaneousGroupID = hits.count > 1 ? UUID() : nil

            return hits.map { hit in
                ExpectedEvent(
                    measure: beatIndex / configuration.beatsPerMeasure + 1,
                    beat: beatIndex % configuration.beatsPerMeasure + 1,
                    subdivision: index % notesPerBeat,
                    sessionTimeNanoseconds: sessionTime,
                    hostTime: hostTime,
                    voice: hit.voice,
                    allowedVoices: hit.allowedVoices,
                    matchingToleranceNanoseconds: tolerance,
                    simultaneousGroupID: simultaneousGroupID
                )
            }
        }

        return PracticePattern(
            name: configuration.displayName,
            bpm: configuration.bpm,
            beatsPerMeasure: configuration.beatsPerMeasure,
            measures: configuration.measures,
            subdivision: configuration.subdivision,
            startSessionTimeNanoseconds: startSessionTimeNanoseconds,
            expectedEvents: events,
            durationNanoseconds: durationNanoseconds,
            measureSignatures: Array(
                repeating: PracticeMeasureSignature(
                    numerator: configuration.beatsPerMeasure,
                    denominator: 4
                ),
                count: configuration.measures
            ),
            measureStartOffsetsNanoseconds: measureStartOffsets,
            referenceBeats: referenceBeats
        )
    }

    private func makeHostTime(
        startHostTime: UInt64?,
        offsetNanoseconds: UInt64,
        converter: (any HostTimeConverting)?
    ) -> UInt64? {
        guard let startHostTime, let converter else { return nil }
        let offset = converter.hostTime(forNanosecondDuration: offsetNanoseconds)
        let (result, overflow) = startHostTime.addingReportingOverflow(offset)
        return overflow ? UInt64.max : result
    }

    private func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return result }
        return rhs >= 0 ? Int64.max : Int64.min
    }
}
