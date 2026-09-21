import Foundation

struct KickPatternConfiguration: Equatable, Sendable {
    let bpm: Double
    let definition: Definition
    let measures: Int
    let beatsPerMeasure: Int
    let matchingToleranceMilliseconds: Double
    let accentVelocityThreshold: Double?
    let accentVelocityContrast: Double
    let ghostVelocityCeiling: Double?
    let ghostVelocityContrast: Double

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
        matchingToleranceMilliseconds: Double = 100,
        accentVelocityThreshold: Double? = 100.0 / 127.0,
        accentVelocityContrast: Double = 18.0 / 127.0,
        ghostVelocityCeiling: Double? = 50.0 / 127.0,
        ghostVelocityContrast: Double = 18.0 / 127.0
    ) {
        self.bpm = bpm
        self.definition = .builtIn(.straight(subdivision))
        self.measures = measures
        self.beatsPerMeasure = beatsPerMeasure
        self.matchingToleranceMilliseconds = matchingToleranceMilliseconds
        self.accentVelocityThreshold = accentVelocityThreshold
        self.accentVelocityContrast = accentVelocityContrast
        self.ghostVelocityCeiling = ghostVelocityCeiling
        self.ghostVelocityContrast = ghostVelocityContrast
    }

    init(
        bpm: Double,
        exercise: KickExercise,
        measures: Int = 1,
        beatsPerMeasure: Int = 4,
        matchingToleranceMilliseconds: Double = 100,
        accentVelocityThreshold: Double? = 100.0 / 127.0,
        accentVelocityContrast: Double = 18.0 / 127.0,
        ghostVelocityCeiling: Double? = 50.0 / 127.0,
        ghostVelocityContrast: Double = 18.0 / 127.0
    ) {
        self.bpm = bpm
        self.definition = .builtIn(exercise)
        self.measures = measures
        self.beatsPerMeasure = beatsPerMeasure
        self.matchingToleranceMilliseconds = matchingToleranceMilliseconds
        self.accentVelocityThreshold = accentVelocityThreshold
        self.accentVelocityContrast = accentVelocityContrast
        self.ghostVelocityCeiling = ghostVelocityCeiling
        self.ghostVelocityContrast = ghostVelocityContrast
    }

    init(
        bpm: Double,
        customMeasure: CustomMeasureDefinition,
        measures: Int = 1,
        beatsPerMeasure: Int = 4,
        matchingToleranceMilliseconds: Double = 100,
        accentVelocityThreshold: Double? = 100.0 / 127.0,
        accentVelocityContrast: Double = 18.0 / 127.0,
        ghostVelocityCeiling: Double? = 50.0 / 127.0,
        ghostVelocityContrast: Double = 18.0 / 127.0
    ) {
        self.bpm = bpm
        self.definition = .custom(customMeasure)
        self.measures = measures
        self.beatsPerMeasure = beatsPerMeasure
        self.matchingToleranceMilliseconds = matchingToleranceMilliseconds
        self.accentVelocityThreshold = accentVelocityThreshold
        self.accentVelocityContrast = accentVelocityContrast
        self.ghostVelocityCeiling = ghostVelocityCeiling
        self.ghostVelocityContrast = ghostVelocityContrast
    }
}

enum KickPatternGeneratorError: LocalizedError, Equatable {
    case unsupportedTempo
    case invalidMeasureCount
    case invalidMeter
    case invalidTolerance
    case invalidAccentVelocityThreshold
    case invalidAccentVelocityContrast
    case invalidGhostDynamics
    case emptyCustomMeasure
    case invalidSequence(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTempo: "Tempo must be between 40 and 240 BPM."
        case .invalidMeasureCount: "The pattern must contain at least one measure."
        case .invalidMeter: "The pattern must contain at least one beat per measure."
        case .invalidTolerance: "Matching tolerance cannot be negative."
        case .invalidAccentVelocityThreshold: "Accent velocity must be between 1 and 127."
        case .invalidAccentVelocityContrast: "Accent contrast must be between 1 and 127 MIDI velocity points."
        case .invalidGhostDynamics: "Ghost-note ceiling and contrast must be between 1 and 127 MIDI velocity points."
        case .emptyCustomMeasure: "Add at least one note to the custom measure before starting."
        case let .invalidSequence(message): message
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
        if case let .custom(definition) = configuration.definition, definition.isSequence {
            return try generateSequence(definition, configuration: configuration,
                startSessionTime: startSessionTimeNanoseconds, startHostTime: startHostTime, converter: hostTimeConverter)
        }
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
        guard configuration.accentVelocityThreshold.map({ $0 > 0 && $0 <= 1 }) ?? true else {
            throw KickPatternGeneratorError.invalidAccentVelocityThreshold
        }
        guard configuration.accentVelocityContrast > 0,
              configuration.accentVelocityContrast <= 1 else {
            throw KickPatternGeneratorError.invalidAccentVelocityContrast
        }

        guard configuration.ghostVelocityCeiling.map({ $0 > 0 && $0 <= 1 }) ?? true,
              configuration.ghostVelocityContrast > 0,
              configuration.ghostVelocityContrast <= 1 else {
            throw KickPatternGeneratorError.invalidGhostDynamics
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
                    minimumAccentVelocity: hit.isAccent ? configuration.accentVelocityThreshold : nil,
                    minimumAccentContrast: hit.isAccent ? configuration.accentVelocityContrast : nil,
                    maximumGhostVelocity: hit.isGhost ? configuration.ghostVelocityCeiling : nil,
                    minimumGhostContrast: hit.isGhost ? configuration.ghostVelocityContrast : nil,
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

    private func generateSequence(
        _ definition: CustomMeasureDefinition,
        configuration: KickPatternConfiguration,
        startSessionTime: Int64,
        startHostTime: UInt64?,
        converter: (any HostTimeConverting)?
    ) throws -> PracticePattern {
        if let message = definition.sequenceValidationMessage { throw KickPatternGeneratorError.invalidSequence(message) }
        guard (40...240).contains(configuration.bpm) else { throw KickPatternGeneratorError.unsupportedTempo }
        let measures = definition.expandedSequence
        let beatNS = 60_000_000_000 / configuration.bpm
        let offsets = (0...measures.count).map { Int64((Double($0 * 4) * beatNS).rounded()) }
        var events: [ExpectedEvent] = []
        for (index, measure) in measures.enumerated() {
            let part = try generate(configuration: KickPatternConfiguration(
                bpm: configuration.bpm, customMeasure: measure, measures: 1,
                matchingToleranceMilliseconds: configuration.matchingToleranceMilliseconds,
                accentVelocityThreshold: configuration.accentVelocityThreshold,
                accentVelocityContrast: configuration.accentVelocityContrast,
                ghostVelocityCeiling: configuration.ghostVelocityCeiling,
                ghostVelocityContrast: configuration.ghostVelocityContrast
            ))
            events += part.expectedEvents.map { event in
                // Compute each note from its absolute beat, avoiding accumulated rounding at transitions.
                let beat = Double(index * 4 + event.beat - 1)
                    + Double(event.subdivision) / Double(measure.subdivision.notesPerBeat)
                let offset = Int64((beat * beatNS).rounded())
                return ExpectedEvent(
                    measure: index + 1, beat: event.beat, subdivision: event.subdivision,
                    sessionTimeNanoseconds: addingWithoutOverflow(startSessionTime, offset),
                    hostTime: makeHostTime(startHostTime: startHostTime, offsetNanoseconds: UInt64(offset), converter: converter),
                    voice: event.voice, allowedVoices: event.allowedVoices,
                    minimumAccentVelocity: event.minimumAccentVelocity, minimumAccentContrast: event.minimumAccentContrast,
                    maximumGhostVelocity: event.maximumGhostVelocity, minimumGhostContrast: event.minimumGhostContrast,
                    matchingToleranceNanoseconds: event.matchingToleranceNanoseconds,
                    simultaneousGroupID: event.simultaneousGroupID
                )
            }
        }
        let references: [PracticeReferenceBeat] = (0..<(measures.count * 4)).map { index in
            let offset = Int64((Double(index) * beatNS).rounded())
            return PracticeReferenceBeat(offsetNanoseconds: offset,
                measure: index / 4 + 1, beat: index % 4 + 1, isAccent: index.isMultiple(of: 4))
        }
        let signatures = Array(repeating: PracticeMeasureSignature(numerator: 4, denominator: 4), count: measures.count)
        let subdivisions = measures.map(\.subdivision)
        let labels = measures.map(\.displayName)
        return PracticePattern(
            name: definition.displayName, bpm: configuration.bpm, beatsPerMeasure: 4,
            measures: measures.count, subdivision: measures.first?.subdivision ?? .sixteenths,
            startSessionTimeNanoseconds: startSessionTime, expectedEvents: events,
            durationNanoseconds: offsets.last,
            measureSignatures: signatures,
            measureStartOffsetsNanoseconds: offsets,
            referenceBeats: references,
            measureSubdivisions: subdivisions, measureLabels: labels
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
