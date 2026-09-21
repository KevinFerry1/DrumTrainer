import Foundation

struct PracticeScoringConfiguration: Codable, Equatable, Sendable {
    var gradeKicks: Bool

    init(gradeKicks: Bool = true) {
        self.gradeKicks = gradeKicks
    }

    static let allVoices = PracticeScoringConfiguration()

    func includes(_ voice: DrumVoice) -> Bool {
        gradeKicks || voice != .kick
    }
}

struct PracticeSessionOutcome: Codable, Equatable, Sendable {
    let pattern: PracticePattern
    let actualEvents: [PerformanceEvent]
    let matchResults: [MatchResult]
    let metrics: AggregateMetrics
    let droppedEventCount: Int
    let scoringConfiguration: PracticeScoringConfiguration?

    init(
        pattern: PracticePattern,
        actualEvents: [PerformanceEvent],
        matchResults: [MatchResult],
        metrics: AggregateMetrics,
        droppedEventCount: Int,
        scoringConfiguration: PracticeScoringConfiguration? = nil
    ) {
        self.pattern = pattern
        self.actualEvents = actualEvents
        self.matchResults = matchResults
        self.metrics = metrics
        self.droppedEventCount = droppedEventCount
        self.scoringConfiguration = scoringConfiguration
    }

    var effectiveScoringConfiguration: PracticeScoringConfiguration {
        scoringConfiguration ?? .allVoices
    }

    var accentEvaluation: AccentEvaluation? {
        AccentEvaluator().evaluate(
            expectedEvents: pattern.expectedEvents.filter {
                effectiveScoringConfiguration.includes($0.voice)
            },
            actualEvents: actualEvents.filter {
                effectiveScoringConfiguration.includes($0.voice)
            },
            matchResults: matchResults
        )
    }

    var ghostEvaluation: GhostEvaluation? {
        GhostEvaluator().evaluate(
            expectedEvents: pattern.expectedEvents.filter {
                effectiveScoringConfiguration.includes($0.voice)
            },
            actualEvents: actualEvents.filter {
                effectiveScoringConfiguration.includes($0.voice)
            },
            matchResults: matchResults
        )
    }

    var timingTimeline: PracticeTimingTimeline {
        PracticeTimingTimeline(
            pattern: pattern,
            actualEvents: actualEvents,
            matchResults: matchResults
        )
    }

    var stableTimingBiasEvaluation: StableTimingBiasEvaluation? {
        StableTimingBiasEvaluator().evaluate(matchResults)
    }
}

struct PracticeTimingTimelineEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let expectedEventID: UUID?
    let actualEventID: UUID?
    let measure: Int?
    let beat: Int?
    let subdivision: Int?
    let expectedVoice: DrumVoice?
    let playedVoice: DrumVoice?
    let expectedTimeNanoseconds: Int64?
    let actualTimeNanoseconds: Int64?
    let classification: MatchClassification
    let signedOffsetMilliseconds: Double?
    let source: EventSource?

    var isProblem: Bool { classification != .correct }

    var anchorTimeNanoseconds: Int64 {
        switch (expectedTimeNanoseconds, actualTimeNanoseconds) {
        case let (expected?, actual?): min(expected, actual)
        case let (expected?, nil): expected
        case let (nil, actual?): actual
        case (nil, nil): 0
        }
    }
}

struct PracticeTimingTimeline: Equatable, Sendable {
    let startSessionTimeNanoseconds: Int64
    let endSessionTimeNanoseconds: Int64
    let entries: [PracticeTimingTimelineEntry]

    init(
        pattern: PracticePattern,
        actualEvents: [PerformanceEvent],
        matchResults: [MatchResult]
    ) {
        let expectedByID = Dictionary(uniqueKeysWithValues: pattern.expectedEvents.map { ($0.id, $0) })
        let actualByID = Dictionary(uniqueKeysWithValues: actualEvents.map { ($0.id, $0) })

        entries = matchResults.map { result in
            let expected = result.expectedEventID.flatMap { expectedByID[$0] }
            let actual = result.actualEventID.flatMap { actualByID[$0] }
            return PracticeTimingTimelineEntry(
                id: result.id,
                expectedEventID: result.expectedEventID,
                actualEventID: result.actualEventID,
                measure: expected?.measure,
                beat: expected?.beat,
                subdivision: expected?.subdivision,
                expectedVoice: expected?.voice,
                playedVoice: actual?.voice,
                expectedTimeNanoseconds: result.expectedTimeNanoseconds,
                actualTimeNanoseconds: result.actualTimeNanoseconds,
                classification: result.classification,
                signedOffsetMilliseconds: result.signedOffsetMilliseconds,
                source: actual?.source
            )
        }.sorted { lhs, rhs in
            if lhs.anchorTimeNanoseconds != rhs.anchorTimeNanoseconds {
                return lhs.anchorTimeNanoseconds < rhs.anchorTimeNanoseconds
            }
            if lhs.measure != rhs.measure { return (lhs.measure ?? Int.max) < (rhs.measure ?? Int.max) }
            if lhs.beat != rhs.beat { return (lhs.beat ?? Int.max) < (rhs.beat ?? Int.max) }
            if lhs.subdivision != rhs.subdivision {
                return (lhs.subdivision ?? Int.max) < (rhs.subdivision ?? Int.max)
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let nominalDuration = Self.nominalDurationNanoseconds(for: pattern)
        let nominalEnd = Self.addingWithoutOverflow(
            pattern.startSessionTimeNanoseconds,
            nominalDuration
        )
        let evidenceTimes = entries.flatMap { entry in
            [entry.expectedTimeNanoseconds, entry.actualTimeNanoseconds].compactMap { $0 }
        }
        startSessionTimeNanoseconds = min(
            pattern.startSessionTimeNanoseconds,
            evidenceTimes.min() ?? pattern.startSessionTimeNanoseconds
        )
        let evidenceEnd = evidenceTimes.max() ?? nominalEnd
        let latest = max(nominalEnd, evidenceEnd)
        endSessionTimeNanoseconds = max(
            latest,
            Self.addingWithoutOverflow(startSessionTimeNanoseconds, 1)
        )
    }

    private static func nominalDurationNanoseconds(for pattern: PracticePattern) -> Int64 {
        pattern.exactDurationNanoseconds
    }

    private static func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }
}

struct SavedCustomExercise: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var definition: CustomMeasureDefinition
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        definition: CustomMeasureDefinition,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.definition = definition
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum PracticeSessionExerciseKind: String, Codable, Equatable, Sendable {
    case builtIn
    case custom
    case importedSong
}

struct PracticeVoiceSummary: Codable, Equatable, Sendable {
    let voice: DrumVoice
    let totalExpected: Int
    let totalPlayed: Int
    let correctCount: Int
    let missedCount: Int
    let extraCount: Int
    let wrongVoiceCount: Int
    let recall: Double
    let precision: Double
    let meanSignedOffsetMilliseconds: Double?
    let medianAbsoluteErrorMilliseconds: Double?
    let timingStandardDeviationMilliseconds: Double?

    init(metrics: VoiceMetrics) {
        voice = metrics.voice
        totalExpected = metrics.totalExpected
        totalPlayed = metrics.totalPlayed
        correctCount = metrics.correctCount
        missedCount = metrics.missedCount
        extraCount = metrics.extraCount
        wrongVoiceCount = metrics.wrongVoiceCount
        recall = metrics.recall
        precision = metrics.precision
        meanSignedOffsetMilliseconds = metrics.meanSignedOffsetMilliseconds
        medianAbsoluteErrorMilliseconds = metrics.medianAbsoluteErrorMilliseconds
        timingStandardDeviationMilliseconds = metrics.timingStandardDeviationMilliseconds
    }
}

struct PracticeSessionSummary: Identifiable, Codable, Equatable, Sendable {
    static let scoringAlgorithmVersion = 5

    let id: UUID
    let completedAt: Date
    let exerciseName: String
    let exerciseKind: PracticeSessionExerciseKind
    let customExerciseID: UUID?
    let importedSongID: UUID?
    let bpm: Double
    let measures: Int
    let beatsPerMeasure: Int
    let subdivision: KickSubdivision
    let durationSeconds: Double
    let totalExpected: Int
    let totalPlayed: Int
    let correctCount: Int
    let missedCount: Int
    let extraCount: Int
    let wrongVoiceCount: Int
    let ambiguousCount: Int
    let recall: Double
    let precision: Double
    let meanSignedOffsetMilliseconds: Double?
    let medianAbsoluteErrorMilliseconds: Double?
    let timingStandardDeviationMilliseconds: Double?
    let stableTimingBiasMilliseconds: Double?
    let latencyAdjustedMedianErrorMilliseconds: Double?
    let longestCleanStreak: Int
    let medianLimbSpreadMilliseconds: Double?
    let droppedEventCount: Int
    let voiceSummaries: [PracticeVoiceSummary]
    let accentMetrics: AccentMetrics?
    let ghostMetrics: GhostMetrics?
    let scoringVersion: Int

    init(
        id: UUID = UUID(),
        completedAt: Date = Date(),
        outcome: PracticeSessionOutcome,
        exerciseKind: PracticeSessionExerciseKind,
        customExerciseID: UUID? = nil,
        importedSongID: UUID? = nil
    ) {
        let metrics = outcome.metrics
        self.id = id
        self.completedAt = completedAt
        exerciseName = outcome.pattern.name
        self.exerciseKind = exerciseKind
        self.customExerciseID = customExerciseID
        self.importedSongID = importedSongID
        bpm = outcome.pattern.bpm
        measures = outcome.pattern.measures
        beatsPerMeasure = outcome.pattern.beatsPerMeasure
        subdivision = outcome.pattern.subdivision
        durationSeconds = Double(outcome.pattern.exactDurationNanoseconds) / 1_000_000_000
        totalExpected = metrics.totalExpected
        totalPlayed = metrics.totalPlayed
        correctCount = metrics.correctCount
        missedCount = metrics.missedCount
        extraCount = metrics.extraCount
        wrongVoiceCount = metrics.wrongVoiceCount
        ambiguousCount = metrics.ambiguousCount
        recall = metrics.recall
        precision = metrics.precision
        meanSignedOffsetMilliseconds = metrics.meanSignedOffsetMilliseconds
        medianAbsoluteErrorMilliseconds = metrics.medianAbsoluteErrorMilliseconds
        timingStandardDeviationMilliseconds = metrics.timingStandardDeviationMilliseconds
        let stableTiming = outcome.stableTimingBiasEvaluation
        stableTimingBiasMilliseconds = stableTiming?.biasMilliseconds
        latencyAdjustedMedianErrorMilliseconds = stableTiming?.adjustedMedianAbsoluteErrorMilliseconds
        longestCleanStreak = metrics.longestCleanStreak
        medianLimbSpreadMilliseconds = metrics.limbSynchronization?.medianSpreadMilliseconds
        droppedEventCount = outcome.droppedEventCount
        voiceSummaries = metrics.perVoice.map(PracticeVoiceSummary.init(metrics:))
        accentMetrics = outcome.accentEvaluation?.metrics
        ghostMetrics = outcome.ghostEvaluation?.metrics
        scoringVersion = Self.scoringAlgorithmVersion
    }

    var isClean: Bool {
        droppedEventCount == 0
            && totalExpected > 0
            && recall >= 0.95
            && (latencyAdjustedMedianErrorMilliseconds ?? medianAbsoluteErrorMilliseconds ?? .infinity) <= 25
            && (accentMetrics?.passesCleanThreshold ?? true)
            && (ghostMetrics?.passesCleanThreshold ?? true)
    }
}

struct PracticeSessionDeviceContext: Codable, Equatable, Sendable {
    let midiDeviceID: Int32?
    let midiDeviceName: String?
    let audioInputUID: String?
    let audioInputName: String?
    let audioOutputUID: String?
    let audioOutputName: String?
    let calibrationProfile: MicrophoneCalibrationProfile?
    let midiTimingCompensationMilliseconds: Double?
    let microphoneTimingCompensationMilliseconds: Double?

    init(
        midiDeviceID: Int32? = nil,
        midiDeviceName: String? = nil,
        audioInputUID: String? = nil,
        audioInputName: String? = nil,
        audioOutputUID: String? = nil,
        audioOutputName: String? = nil,
        calibrationProfile: MicrophoneCalibrationProfile? = nil,
        midiTimingCompensationMilliseconds: Double? = nil,
        microphoneTimingCompensationMilliseconds: Double? = nil
    ) {
        self.midiDeviceID = midiDeviceID
        self.midiDeviceName = midiDeviceName
        self.audioInputUID = audioInputUID
        self.audioInputName = audioInputName
        self.audioOutputUID = audioOutputUID
        self.audioOutputName = audioOutputName
        self.calibrationProfile = calibrationProfile
        self.midiTimingCompensationMilliseconds = midiTimingCompensationMilliseconds
        self.microphoneTimingCompensationMilliseconds = microphoneTimingCompensationMilliseconds
    }
}

struct PracticeSessionRecord: Identifiable, Codable, Equatable, Sendable {
    var summary: PracticeSessionSummary
    let pattern: PracticePattern
    let actualEvents: [PerformanceEvent]
    var matchResults: [MatchResult]
    var metrics: AggregateMetrics
    let deviceContext: PracticeSessionDeviceContext
    let scoringConfiguration: PracticeScoringConfiguration?
    var notes: String
    var tags: [String]

    var id: UUID { summary.id }

    init(
        summary: PracticeSessionSummary,
        outcome: PracticeSessionOutcome,
        deviceContext: PracticeSessionDeviceContext = PracticeSessionDeviceContext(),
        notes: String = "",
        tags: [String] = []
    ) {
        self.summary = summary
        pattern = outcome.pattern
        actualEvents = outcome.actualEvents
        matchResults = outcome.matchResults
        metrics = outcome.metrics
        self.deviceContext = deviceContext
        scoringConfiguration = outcome.scoringConfiguration
        self.notes = notes
        self.tags = Self.normalizedTags(tags)
    }

    var outcome: PracticeSessionOutcome {
        PracticeSessionOutcome(
            pattern: pattern,
            actualEvents: actualEvents,
            matchResults: matchResults,
            metrics: metrics,
            droppedEventCount: summary.droppedEventCount,
            scoringConfiguration: scoringConfiguration
        )
    }

    mutating func updateMetadata(notes: String, tags: [String]) {
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = Self.normalizedTags(tags)
    }

    mutating func rescore(
        matcher: EventMatcher = EventMatcher(),
        metricsCalculator: ScoringMetricsCalculator = ScoringMetricsCalculator()
    ) {
        let configuration = scoringConfiguration ?? .allVoices
        let scoredExpectedEvents = pattern.expectedEvents.filter { configuration.includes($0.voice) }
        let scoredActualEvents = actualEvents.filter { configuration.includes($0.voice) }
        matchResults = matcher.match(expected: scoredExpectedEvents, actual: scoredActualEvents)
        metrics = metricsCalculator.calculate(
            from: matchResults,
            expectedEvents: scoredExpectedEvents,
            actualEvents: scoredActualEvents
        )
        let newOutcome = PracticeSessionOutcome(
            pattern: pattern,
            actualEvents: actualEvents,
            matchResults: matchResults,
            metrics: metrics,
            droppedEventCount: summary.droppedEventCount,
            scoringConfiguration: scoringConfiguration
        )
        summary = PracticeSessionSummary(
            id: summary.id,
            completedAt: summary.completedAt,
            outcome: newOutcome,
            exerciseKind: summary.exerciseKind,
            customExerciseID: summary.customExerciseID,
            importedSongID: summary.importedSongID
        )
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

struct TempoProgressionSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var stepBPM: Double
    var requiredCleanSessions: Int

    init(isEnabled: Bool = false, stepBPM: Double = 5, requiredCleanSessions: Int = 3) {
        self.isEnabled = isEnabled
        self.stepBPM = min(max(stepBPM, 1), 20)
        self.requiredCleanSessions = min(max(requiredCleanSessions, 1), 10)
    }
}

struct ExerciseTempoProgression: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let exerciseName: String
    var suggestedBPM: Double
    var consecutiveCleanSessions: Int
    var highestCleanBPM: Double?
    var updatedAt: Date
}

struct CeilingModeSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var stepBPM: Double

    init(isEnabled: Bool = false, stepBPM: Double = 5) {
        self.isEnabled = isEnabled
        self.stepBPM = min(max(stepBPM, 1), 20)
    }
}

enum CeilingRunPhase: Codable, Equatable, Sendable {
    case testing(bpm: Double)
    case readyForNext(bpm: Double)
    case found(highestCleanBPM: Double?, failedBPM: Double?)
}

struct CeilingRun: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let exerciseID: String
    let exerciseName: String
    let exerciseKind: PracticeSessionExerciseKind
    let customExerciseID: UUID?
    let startedAt: Date
    var updatedAt: Date
    let startingBPM: Double
    var highestCleanBPM: Double?
    var attemptedBPMs: [Double]
    var sessionIDs: [UUID]
    var phase: CeilingRunPhase

    mutating func record(
        _ summary: PracticeSessionSummary,
        stepBPM: Double
    ) -> CeilingRoundDecision {
        updatedAt = summary.completedAt
        attemptedBPMs.append(summary.bpm)
        sessionIDs.append(summary.id)

        if summary.isClean {
            highestCleanBPM = max(highestCleanBPM ?? summary.bpm, summary.bpm)
            if summary.bpm >= 240 {
                phase = .found(highestCleanBPM: highestCleanBPM, failedBPM: nil)
                return .maximumVerified(bpm: 240)
            }
            let nextBPM = min(summary.bpm + min(max(stepBPM, 1), 20), 240)
            phase = .readyForNext(bpm: nextBPM)
            return .advance(passedBPM: summary.bpm, nextBPM: nextBPM)
        }

        phase = .found(highestCleanBPM: highestCleanBPM, failedBPM: summary.bpm)
        if let highestCleanBPM {
            return .found(highestCleanBPM: highestCleanBPM, failedBPM: summary.bpm)
        }
        return .belowStartingTempo(failedBPM: summary.bpm)
    }
}

enum CeilingRoundDecision: Equatable, Sendable {
    case advance(passedBPM: Double, nextBPM: Double)
    case found(highestCleanBPM: Double, failedBPM: Double)
    case belowStartingTempo(failedBPM: Double)
    case maximumVerified(bpm: Double)
}

struct ExerciseCeilingRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let exerciseName: String
    var highestVerifiedBPM: Double
    var achievedAt: Date
    var ceilingRunID: UUID
    var startingBPM: Double
    var failedBPM: Double?
    var roundsCompleted: Int
}

struct PracticeDataArchive: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 9

    var schemaVersion: Int
    var customExercises: [SavedCustomExercise]
    var importedSongs: [ImportedSong]
    var sessions: [PracticeSessionSummary]
    var sessionRecords: [PracticeSessionRecord]
    var tempoProgressionSettings: TempoProgressionSettings
    var tempoProgressions: [ExerciseTempoProgression]
    var ceilingModeSettings: CeilingModeSettings
    var activeCeilingRun: CeilingRun?
    var ceilingRecords: [ExerciseCeilingRecord]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        customExercises: [SavedCustomExercise] = [],
        importedSongs: [ImportedSong] = [],
        sessions: [PracticeSessionSummary] = [],
        sessionRecords: [PracticeSessionRecord] = [],
        tempoProgressionSettings: TempoProgressionSettings = TempoProgressionSettings(),
        tempoProgressions: [ExerciseTempoProgression] = [],
        ceilingModeSettings: CeilingModeSettings = CeilingModeSettings(),
        activeCeilingRun: CeilingRun? = nil,
        ceilingRecords: [ExerciseCeilingRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.customExercises = customExercises
        self.importedSongs = importedSongs
        self.sessions = sessions
        self.sessionRecords = sessionRecords
        self.tempoProgressionSettings = tempoProgressionSettings
        self.tempoProgressions = tempoProgressions
        self.ceilingModeSettings = ceilingModeSettings
        self.activeCeilingRun = activeCeilingRun
        self.ceilingRecords = ceilingRecords
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case customExercises
        case importedSongs
        case sessions
        case sessionRecords
        case tempoProgressionSettings
        case tempoProgressions
        case ceilingModeSettings
        case activeCeilingRun
        case ceilingRecords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        customExercises = try container.decodeIfPresent([SavedCustomExercise].self, forKey: .customExercises) ?? []
        importedSongs = try container.decodeIfPresent([ImportedSong].self, forKey: .importedSongs) ?? []
        sessions = try container.decodeIfPresent([PracticeSessionSummary].self, forKey: .sessions) ?? []
        sessionRecords = try container.decodeIfPresent([PracticeSessionRecord].self, forKey: .sessionRecords) ?? []
        tempoProgressionSettings = try container.decodeIfPresent(
            TempoProgressionSettings.self,
            forKey: .tempoProgressionSettings
        ) ?? TempoProgressionSettings()
        tempoProgressions = try container.decodeIfPresent(
            [ExerciseTempoProgression].self,
            forKey: .tempoProgressions
        ) ?? []
        ceilingModeSettings = try container.decodeIfPresent(
            CeilingModeSettings.self,
            forKey: .ceilingModeSettings
        ) ?? CeilingModeSettings()
        activeCeilingRun = try container.decodeIfPresent(CeilingRun.self, forKey: .activeCeilingRun)
        ceilingRecords = try container.decodeIfPresent(
            [ExerciseCeilingRecord].self,
            forKey: .ceilingRecords
        ) ?? []
    }

    func validatedAndMigrated() throws -> PracticeDataArchive {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw PracticeDataPersistenceError.unsupportedSchema(schemaVersion)
        }
        guard customExercises.count <= 1_000,
              importedSongs.count <= 500,
              sessions.count <= 2_000,
              sessionRecords.count <= 2_000,
              tempoProgressions.count <= 2_000,
              ceilingRecords.count <= 2_000 else {
            throw PracticeDataPersistenceError.invalidArchive("The archive exceeds supported collection limits.")
        }
        guard customExercises.allSatisfy({ $0.definition.sequenceValidationMessage == nil }) else {
            throw PracticeDataPersistenceError.invalidArchive("A saved sequence is empty, invalid, or exceeds the supported measure/note limits.")
        }
        guard importedSongs.allSatisfy({ song in
            song.ticksPerQuarterNote > 0
                && song.tracks.count <= 256
                && song.tracks.reduce(0) { $0 + $1.notes.count } <= 250_000
                && song.tracks.contains { $0.index == song.selectedTrackIndex }
                && Set(song.tracks.map(\.index)).count == song.tracks.count
                && Set(song.noteMappings.map(\.noteNumber)).count == song.noteMappings.count
                && song.noteMappings.count <= 128
                && song.tempoChanges.count <= 10_000
                && song.timeSignatureChanges.count <= 10_000
        }) else {
            throw PracticeDataPersistenceError.invalidArchive("An imported song exceeds supported MIDI limits or has invalid mappings.")
        }
        guard (1...20).contains(tempoProgressionSettings.stepBPM),
              (1...10).contains(tempoProgressionSettings.requiredCleanSessions),
              (1...20).contains(ceilingModeSettings.stepBPM),
              !(tempoProgressionSettings.isEnabled && ceilingModeSettings.isEnabled),
              ceilingRecords.allSatisfy({ (40...240).contains($0.highestVerifiedBPM) }),
              activeCeilingRun.map({
                  !$0.exerciseID.isEmpty
                      && (40...240).contains($0.startingBPM)
                      && $0.attemptedBPMs.count == $0.sessionIDs.count
                      && $0.attemptedBPMs.count <= 100
                      && $0.attemptedBPMs.allSatisfy { (40...240).contains($0) }
              }) ?? true else {
            throw PracticeDataPersistenceError.invalidArchive("Progression settings or ceiling data are out of range.")
        }
        guard sessionRecords.allSatisfy({ record in
            record.pattern.expectedEvents.count <= 10_000
                && record.pattern.expectedEvents.allSatisfy { event in
                    (event.minimumAccentVelocity.map { $0 > 0 && $0 <= 1 } ?? true)
                        && (event.minimumAccentContrast.map { $0 > 0 && $0 <= 1 } ?? true)
                        && (event.maximumGhostVelocity.map { $0 > 0 && $0 <= 1 } ?? true)
                        && (event.minimumGhostContrast.map { $0 > 0 && $0 <= 1 } ?? true)
                        && !(event.isGhost && event.isAccent)
                }
                && record.actualEvents.count <= 10_000
                && record.matchResults.count <= 20_000
                && record.notes.count <= 100_000
                && record.tags.count <= 100
        }) else {
            throw PracticeDataPersistenceError.invalidArchive("A session exceeds supported evidence limits or contains an invalid accent threshold.")
        }
        let recordIDs = Set(sessionRecords.map(\.id))
        let existingSessionIDs = Set(sessions.map(\.id))
        let combinedSessions = sessions + sessionRecords
            .filter { !existingSessionIDs.contains($0.id) }
            .map(\.summary)
        guard Set(sessionRecords.map(\.id)).count == sessionRecords.count,
              Set(customExercises.map(\.id)).count == customExercises.count,
              Set(importedSongs.map(\.id)).count == importedSongs.count,
              Set(combinedSessions.map(\.id)).count == combinedSessions.count,
              Set(tempoProgressions.map(\.id)).count == tempoProgressions.count,
              Set(ceilingRecords.map(\.id)).count == ceilingRecords.count else {
            throw PracticeDataPersistenceError.invalidArchive("Duplicate or orphaned identifiers were found.")
        }
        let summariesByID = Dictionary(uniqueKeysWithValues: combinedSessions.map { ($0.id, $0) })
        guard recordIDs.isSubset(of: Set(combinedSessions.map(\.id))),
              sessionRecords.allSatisfy({ summariesByID[$0.id] == $0.summary }),
              activeCeilingRun.map({
                  Set($0.sessionIDs).isSubset(of: Set(combinedSessions.map(\.id)))
              }) ?? true else {
            throw PracticeDataPersistenceError.invalidArchive("Session records do not match their summaries.")
        }
        return PracticeDataArchive(
            customExercises: customExercises,
            importedSongs: importedSongs,
            sessions: combinedSessions,
            sessionRecords: sessionRecords,
            tempoProgressionSettings: tempoProgressionSettings,
            tempoProgressions: tempoProgressions,
            ceilingModeSettings: ceilingModeSettings,
            activeCeilingRun: activeCeilingRun,
            ceilingRecords: ceilingRecords
        )
    }

    static func decodeAndValidate(_ data: Data) throws -> PracticeDataArchive {
        do {
            return try JSONDecoder().decode(PracticeDataArchive.self, from: data).validatedAndMigrated()
        } catch let error as PracticeDataPersistenceError {
            throw error
        } catch {
            throw PracticeDataPersistenceError.unreadableData
        }
    }

    func encodedJSON(prettyPrinted: Bool = false) throws -> Data {
        let archive = try validatedAndMigrated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        do {
            return try encoder.encode(archive)
        } catch {
            throw PracticeDataPersistenceError.encodingFailed
        }
    }
}

protocol PracticeDataPersisting: Sendable {
    func load() throws -> PracticeDataArchive
    func save(_ archive: PracticeDataArchive) throws
}

enum PracticeDataPersistenceError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case unreadableData
    case encodingFailed
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): "Practice data uses unsupported schema version \(version)."
        case .unreadableData: "Saved practice data could not be read."
        case .encodingFailed: "Practice data could not be saved."
        case let .invalidArchive(message): "Practice data is invalid: \(message)"
        }
    }
}

final class UserDefaultsPracticeDataStore: PracticeDataPersisting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "DrumTrainer.practiceData"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func load() throws -> PracticeDataArchive {
        try lock.withLock {
            guard let data = defaults.data(forKey: storageKey) else { return PracticeDataArchive() }
            return try PracticeDataArchive.decodeAndValidate(data)
        }
    }

    func save(_ archive: PracticeDataArchive) throws {
        try lock.withLock {
            let data = try archive.encodedJSON()
            defaults.set(data, forKey: storageKey)
        }
    }
}

struct PracticeSessionRecording: Sendable {
    let pattern: PracticePattern
    let exerciseEndSessionTimeNanoseconds: Int64
    let capacity: Int
    let scoringConfiguration: PracticeScoringConfiguration

    private(set) var actualEvents: [PerformanceEvent] = []
    private(set) var droppedEventCount = 0

    init(
        pattern: PracticePattern,
        exerciseEndSessionTimeNanoseconds: Int64,
        capacity: Int = 10_000,
        scoringConfiguration: PracticeScoringConfiguration = .allVoices
    ) {
        precondition(capacity > 0)
        self.pattern = pattern
        self.exerciseEndSessionTimeNanoseconds = exerciseEndSessionTimeNanoseconds
        self.capacity = capacity
        self.scoringConfiguration = scoringConfiguration
        actualEvents.reserveCapacity(min(capacity, pattern.expectedEvents.count * 2))
    }

    var scoredActualEventCount: Int {
        actualEvents.count { scoringConfiguration.includes($0.voice) }
    }

    mutating func record(_ event: PerformanceEvent) {
        guard event.source != .metronome, event.voice != .metronome else { return }
        guard !pattern.expectedEvents.isEmpty else { return }
        let maximumTolerance = pattern.expectedEvents
            .map(\.matchingToleranceNanoseconds)
            .max() ?? 0
        let earliestAcceptedTime = subtractingWithoutOverflow(
            pattern.startSessionTimeNanoseconds,
            maximumTolerance
        )
        let latestAcceptedTime = addingWithoutOverflow(
            exerciseEndSessionTimeNanoseconds,
            maximumTolerance
        )
        guard (earliestAcceptedTime...latestAcceptedTime).contains(event.sessionTimeNanoseconds) else { return }

        guard actualEvents.count < capacity else {
            droppedEventCount += 1
            return
        }
        actualEvents.append(event)
    }

    func finish(
        matcher: EventMatcher = EventMatcher(),
        metricsCalculator: ScoringMetricsCalculator = ScoringMetricsCalculator()
    ) -> PracticeSessionOutcome {
        let scoredExpectedEvents = pattern.expectedEvents.filter { scoringConfiguration.includes($0.voice) }
        let scoredActualEvents = actualEvents.filter { scoringConfiguration.includes($0.voice) }
        let matches = matcher.match(expected: scoredExpectedEvents, actual: scoredActualEvents)
        return PracticeSessionOutcome(
            pattern: pattern,
            actualEvents: actualEvents,
            matchResults: matches,
            metrics: metricsCalculator.calculate(
                from: matches,
                expectedEvents: scoredExpectedEvents,
                actualEvents: scoredActualEvents
            ),
            droppedEventCount: droppedEventCount,
            scoringConfiguration: scoringConfiguration
        )
    }

    private func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }

    private func subtractingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        return overflow ? Int64.min : result
    }
}
