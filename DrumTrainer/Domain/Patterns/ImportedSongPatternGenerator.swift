import Foundation

struct ImportedSongSectionConfiguration: Equatable, Sendable {
    let startMeasure: Int
    let endMeasure: Int
    let repeats: Int
    let targetBPM: Double
    let matchingToleranceMilliseconds: Double

    init(
        startMeasure: Int,
        endMeasure: Int,
        repeats: Int = 1,
        targetBPM: Double,
        matchingToleranceMilliseconds: Double = 100
    ) {
        self.startMeasure = startMeasure
        self.endMeasure = endMeasure
        self.repeats = repeats
        self.targetBPM = targetBPM
        self.matchingToleranceMilliseconds = matchingToleranceMilliseconds
    }
}

enum ImportedSongPatternGeneratorError: LocalizedError, Equatable {
    case missingTrack
    case invalidSection
    case invalidRepeatCount
    case unsupportedTempo
    case invalidTolerance
    case noMappedNotes

    var errorDescription: String? {
        switch self {
        case .missingTrack: "Choose a MIDI track to practice."
        case .invalidSection: "Choose a valid start and end measure."
        case .invalidRepeatCount: "The section must repeat at least once."
        case .unsupportedTempo: "Tempo must be between 40 and 240 BPM."
        case .invalidTolerance: "Matching tolerance cannot be negative."
        case .noMappedNotes: "Map at least one MIDI note to a drum voice before practicing."
        }
    }
}

struct ImportedSongPatternGenerator: Sendable {
    func generate(
        song: ImportedSong,
        configuration: ImportedSongSectionConfiguration,
        startSessionTimeNanoseconds: Int64 = 0,
        startHostTime: UInt64? = nil,
        hostTimeConverter: (any HostTimeConverting)? = nil
    ) throws -> PracticePattern {
        guard let track = song.selectedTrack else { throw ImportedSongPatternGeneratorError.missingTrack }
        guard configuration.repeats > 0 else { throw ImportedSongPatternGeneratorError.invalidRepeatCount }
        guard (40...240).contains(configuration.targetBPM) else {
            throw ImportedSongPatternGeneratorError.unsupportedTempo
        }
        guard configuration.matchingToleranceMilliseconds >= 0 else {
            throw ImportedSongPatternGeneratorError.invalidTolerance
        }
        let allMeasures = ImportedSongTimeline.measures(for: song)
        guard configuration.startMeasure >= 1,
              configuration.endMeasure >= configuration.startMeasure,
              configuration.endMeasure <= allMeasures.count else {
            throw ImportedSongPatternGeneratorError.invalidSection
        }
        let sectionMeasures = Array(allMeasures[(configuration.startMeasure - 1)...(configuration.endMeasure - 1)])
        guard let firstMeasure = sectionMeasures.first, let lastMeasure = sectionMeasures.last else {
            throw ImportedSongPatternGeneratorError.invalidSection
        }
        let sectionStartTick = firstMeasure.startTick
        let sectionEndTick = lastMeasure.endTick
        let sourceBPM = ImportedSongTimeline.bpm(at: sectionStartTick, song: song)
        let timeScale = sourceBPM / configuration.targetBPM
        let sourceSectionDuration = ImportedSongTimeline.nanoseconds(
            from: sectionStartTick,
            to: sectionEndTick,
            song: song
        )
        let sectionDuration = scaled(sourceSectionDuration, by: timeScale)
        let totalDuration = multiplyingWithoutOverflow(sectionDuration, configuration.repeats)
        let tolerance = Int64((configuration.matchingToleranceMilliseconds * 1_000_000).rounded())
        let mapping = Dictionary(uniqueKeysWithValues: song.noteMappings.map { ($0.noteNumber, $0.voice) })
        let sectionNotes = track.notes.filter { note in
            note.tick >= sectionStartTick
                && note.tick < sectionEndTick
                && mapping[note.noteNumber].map(ImportedSong.isScorable) == true
        }
        guard !sectionNotes.isEmpty else { throw ImportedSongPatternGeneratorError.noMappedNotes }

        var events: [ExpectedEvent] = []
        var signatures: [PracticeMeasureSignature] = []
        var measureOffsets: [Int64] = []
        var referenceBeats: [PracticeReferenceBeat] = []
        let notesByTick = Dictionary(grouping: sectionNotes, by: \.tick)

        for repeatIndex in 0..<configuration.repeats {
            let repeatOffset = multiplyingWithoutOverflow(sectionDuration, repeatIndex)
            for (localMeasureIndex, measure) in sectionMeasures.enumerated() {
                signatures.append(PracticeMeasureSignature(
                    numerator: measure.numerator,
                    denominator: measure.denominator
                ))
                let localMeasureOffset = scaled(
                    ImportedSongTimeline.nanoseconds(
                        from: sectionStartTick,
                        to: measure.startTick,
                        song: song
                    ),
                    by: timeScale
                )
                measureOffsets.append(addingWithoutOverflow(repeatOffset, localMeasureOffset))

                let measureNotes = notesByTick
                    .filter { $0.key >= measure.startTick && $0.key < measure.endTick }
                    .sorted { $0.key < $1.key }
                let ticksPerBeat = max(
                    Int64(song.ticksPerQuarterNote) * 4 / Int64(measure.denominator),
                    1
                )
                for beatIndex in 0..<measure.numerator {
                    let beatTick = measure.startTick + Int64(beatIndex) * ticksPerBeat
                    let sourceBeatOffset = ImportedSongTimeline.nanoseconds(
                        from: sectionStartTick,
                        to: beatTick,
                        song: song
                    )
                    referenceBeats.append(PracticeReferenceBeat(
                        offsetNanoseconds: addingWithoutOverflow(
                            repeatOffset,
                            scaled(sourceBeatOffset, by: timeScale)
                        ),
                        measure: repeatIndex * sectionMeasures.count + localMeasureIndex + 1,
                        beat: beatIndex + 1,
                        isAccent: beatIndex == 0
                    ))
                }
                for (tick, notes) in measureNotes {
                    let positionTicks = tick - measure.startTick
                    let beatIndex = min(Int(positionTicks / ticksPerBeat), measure.numerator - 1)
                    let fraction = Double(positionTicks % ticksPerBeat) / Double(ticksPerBeat)
                    let subdivision = min(max(Int((fraction * 4).rounded()), 0), 3)
                    let sourceOffset = ImportedSongTimeline.nanoseconds(
                        from: sectionStartTick,
                        to: tick,
                        song: song
                    )
                    let eventOffset = addingWithoutOverflow(repeatOffset, scaled(sourceOffset, by: timeScale))
                    let sessionTime = addingWithoutOverflow(startSessionTimeNanoseconds, eventOffset)
                    let groupID = notes.count > 1 ? UUID() : nil
                    let patternMeasure = repeatIndex * sectionMeasures.count + localMeasureIndex + 1

                    for note in notes {
                        guard let voice = mapping[note.noteNumber], ImportedSong.isScorable(voice) else { continue }
                        events.append(ExpectedEvent(
                            measure: patternMeasure,
                            beat: beatIndex + 1,
                            subdivision: subdivision,
                            sessionTimeNanoseconds: sessionTime,
                            hostTime: makeHostTime(
                                startHostTime: startHostTime,
                                offsetNanoseconds: eventOffset,
                                converter: hostTimeConverter
                            ),
                            voice: voice,
                            expectedVelocity: Double(note.velocity) / 127,
                            matchingToleranceNanoseconds: tolerance,
                            simultaneousGroupID: groupID
                        ))
                    }
                }
            }
        }
        measureOffsets.append(totalDuration)

        return PracticePattern(
            name: song.displayName,
            bpm: configuration.targetBPM,
            beatsPerMeasure: sectionMeasures.first?.numerator ?? 4,
            measures: sectionMeasures.count * configuration.repeats,
            subdivision: .sixteenths,
            startSessionTimeNanoseconds: startSessionTimeNanoseconds,
            expectedEvents: events.sorted { lhs, rhs in
                lhs.sessionTimeNanoseconds == rhs.sessionTimeNanoseconds
                    ? lhs.voice.rawValue < rhs.voice.rawValue
                    : lhs.sessionTimeNanoseconds < rhs.sessionTimeNanoseconds
            },
            durationNanoseconds: totalDuration,
            measureSignatures: signatures,
            measureStartOffsetsNanoseconds: measureOffsets,
            referenceBeats: referenceBeats
        )
    }

    private func scaled(_ value: Int64, by scale: Double) -> Int64 {
        guard scale.isFinite, scale > 0 else { return value }
        return Int64(min(Double(value) * scale, Double(Int64.max)).rounded())
    }

    private func multiplyingWithoutOverflow(_ value: Int64, _ multiplier: Int) -> Int64 {
        let (result, overflow) = value.multipliedReportingOverflow(by: Int64(multiplier))
        return overflow ? Int64.max : result
    }

    private func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }

    private func makeHostTime(
        startHostTime: UInt64?,
        offsetNanoseconds: Int64,
        converter: (any HostTimeConverting)?
    ) -> UInt64? {
        guard let startHostTime, let converter else { return nil }
        let offset = converter.hostTime(forNanosecondDuration: UInt64(max(offsetNanoseconds, 0)))
        let (result, overflow) = startHostTime.addingReportingOverflow(offset)
        return overflow ? UInt64.max : result
    }
}
