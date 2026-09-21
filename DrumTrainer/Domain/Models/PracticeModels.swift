import Foundation

enum KickSubdivision: String, CaseIterable, Codable, Sendable {
    case eighths
    case sixteenths
    case triplets

    var notesPerBeat: Int {
        switch self {
        case .eighths: 2
        case .sixteenths: 4
        case .triplets: 3
        }
    }

    var displayName: String {
        switch self {
        case .eighths: "8th notes"
        case .sixteenths: "16th notes"
        case .triplets: "8th-note triplets"
        }
    }
}

struct PracticeExerciseHit: Codable, Equatable, Hashable, Sendable {
    let slot: Int
    let voice: DrumVoice
    let allowedVoices: Set<DrumVoice>
    private let accent: Bool?
    private let ghost: Bool?

    init(
        slot: Int,
        voice: DrumVoice,
        allowedVoices: Set<DrumVoice> = [],
        isAccent: Bool = false,
        isGhost: Bool = false
    ) {
        self.slot = slot
        self.voice = voice
        self.allowedVoices = allowedVoices
        accent = isAccent ? true : nil
        ghost = isGhost && !isAccent ? true : nil
    }

    var isAccent: Bool { accent == true }
    var isGhost: Bool { ghost == true && !isAccent }
}

/// A saved snapshot: later edits/deletion of the source measure cannot break a sequence.
struct CustomMeasureStep: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    let name: String
    let subdivision: KickSubdivision
    let hits: [PracticeExerciseHit]
    var repeats: Int

    init(measure: CustomMeasureDefinition, repeats: Int = 1) {
        name = measure.displayName
        subdivision = measure.subdivision
        hits = measure.hits
        self.repeats = repeats
    }

    var measure: CustomMeasureDefinition {
        CustomMeasureDefinition(name: name, subdivision: subdivision, hits: hits)
    }
}

struct CustomMeasureDefinition: Codable, Equatable, Sendable {
    var name: String
    private(set) var subdivision: KickSubdivision
    private(set) var hits: [PracticeExerciseHit]
    var sequenceSteps: [CustomMeasureStep]?
    var sequenceRepeats: Int?

    init(
        name: String = "My custom measure",
        subdivision: KickSubdivision = .sixteenths,
        hits: [PracticeExerciseHit] = []
    ) {
        self.name = name
        self.subdivision = subdivision
        self.hits = Self.normalized(hits, subdivision: subdivision)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Custom measure" : trimmed
    }

    var slotsPerMeasure: Int { subdivision.notesPerBeat * 4 }
    var isSequence: Bool { sequenceSteps != nil }
    var isEmpty: Bool { isSequence ? (sequenceSteps?.isEmpty ?? true) : hits.isEmpty }
    var sequenceMeasureCount: Int {
        guard let steps = sequenceSteps, steps.count <= 32,
              steps.allSatisfy({ (1...16).contains($0.repeats) }),
              (1...16).contains(sequenceRepeats ?? 1) else { return 0 }
        return steps.reduce(0) { $0 + $1.repeats } * (sequenceRepeats ?? 1)
    }
    var sequenceValidationMessage: String? {
        guard let steps = sequenceSteps else { return nil }
        guard !steps.isEmpty else { return "Add a saved measure to the sequence before starting." }
        guard steps.count <= 32, Set(steps.map(\.id)).count == steps.count,
              steps.allSatisfy({ (1...16).contains($0.repeats) && !$0.hits.isEmpty && $0.hits == $0.measure.hits }),
              (1...16).contains(sequenceRepeats ?? 1), (1...128).contains(sequenceMeasureCount) else {
            return "Use up to 32 steps, 1–16 repeats, and at most 128 total measures. Each step must contain valid notes."
        }
        let hitCount = steps.reduce(0) { $0 + $1.hits.count * $1.repeats } * (sequenceRepeats ?? 1)
        guard hitCount <= 10_000 else { return "Shorten this sequence to at most 10,000 notes per run." }
        return nil
    }
    var expandedSequence: [CustomMeasureDefinition] {
        guard let steps = sequenceSteps, sequenceValidationMessage == nil else { return [] }
        let pass = steps.flatMap { Array(repeating: $0.measure, count: $0.repeats) }
        return (0..<(sequenceRepeats ?? 1)).flatMap { _ in pass }
    }

    func contains(slot: Int, voice: DrumVoice) -> Bool {
        hits.contains { $0.slot == slot && $0.voice == voice }
    }

    func isAccented(slot: Int, voice: DrumVoice) -> Bool {
        hits.first { $0.slot == slot && $0.voice == voice }?.isAccent == true
    }

    var accentCount: Int { hits.count(where: \.isAccent) }

    func isGhosted(slot: Int, voice: DrumVoice) -> Bool {
        hits.first { $0.slot == slot && $0.voice == voice }?.isGhost == true
    }

    var ghostCount: Int { hits.count(where: \.isGhost) }

    mutating func toggleGhost(slot: Int, voice: DrumVoice) {
        guard (0..<slotsPerMeasure).contains(slot), Self.isScorable(voice) else { return }
        if let index = hits.firstIndex(where: { $0.slot == slot && $0.voice == voice }) {
            let hit = hits[index]
            hits[index] = PracticeExerciseHit(
                slot: slot, voice: voice, allowedVoices: hit.allowedVoices, isGhost: !hit.isGhost
            )
        } else {
            hits.append(PracticeExerciseHit(slot: slot, voice: voice, isGhost: true))
        }
        hits = Self.normalized(hits, subdivision: subdivision)
    }

    mutating func toggle(slot: Int, voice: DrumVoice) {
        guard (0..<slotsPerMeasure).contains(slot), Self.isScorable(voice) else { return }
        if let index = hits.firstIndex(where: { $0.slot == slot && $0.voice == voice }) {
            hits.remove(at: index)
        } else {
            hits.append(PracticeExerciseHit(slot: slot, voice: voice))
            hits = Self.normalized(hits, subdivision: subdivision)
        }
    }

    mutating func toggleAccent(slot: Int, voice: DrumVoice) {
        guard (0..<slotsPerMeasure).contains(slot), Self.isScorable(voice) else { return }
        if let index = hits.firstIndex(where: { $0.slot == slot && $0.voice == voice }) {
            let hit = hits[index]
            hits[index] = PracticeExerciseHit(
                slot: hit.slot,
                voice: hit.voice,
                allowedVoices: hit.allowedVoices,
                isAccent: !hit.isAccent
            )
        } else {
            hits.append(PracticeExerciseHit(slot: slot, voice: voice, isAccent: true))
        }
        hits = Self.normalized(hits, subdivision: subdivision)
    }

    mutating func clear() {
        hits = []
    }

    mutating func replace(with exercise: KickExercise) {
        subdivision = exercise.subdivision
        hits = Self.normalized(exercise.eventsPerMeasure, subdivision: subdivision)
        name = "Custom \(exercise.displayName)"
    }

    mutating func rescale(to newSubdivision: KickSubdivision) {
        guard newSubdivision != subdivision else { return }
        let oldSlotCount = max(slotsPerMeasure, 1)
        let newSlotCount = newSubdivision.notesPerBeat * 4
        hits = hits.map { hit in
            let scaled = Int((Double(hit.slot) * Double(newSlotCount) / Double(oldSlotCount)).rounded())
            return PracticeExerciseHit(
                slot: min(max(scaled, 0), newSlotCount - 1),
                voice: hit.voice,
                allowedVoices: hit.allowedVoices,
                isAccent: hit.isAccent,
                isGhost: hit.isGhost
            )
        }
        subdivision = newSubdivision
        hits = Self.normalized(hits, subdivision: newSubdivision)
    }

    private static func normalized(
        _ hits: [PracticeExerciseHit],
        subdivision: KickSubdivision
    ) -> [PracticeExerciseHit] {
        let validSlots = 0..<(subdivision.notesPerBeat * 4)
        // Grid changes can collapse slots. Keep one note per voice/cell, preferring
        // an authored dynamic marking when a marked and normal note overlap.
        let groups = Dictionary(
            grouping: hits.filter { validSlots.contains($0.slot) && isScorable($0.voice) },
            by: { "\($0.slot):\($0.voice.rawValue)" }
        )
        let uniqueHits: [PracticeExerciseHit] = groups.values.compactMap { group in
            if let accented = group.first(where: { $0.isAccent }) { return accented }
            if let ghost = group.first(where: { $0.isGhost }) { return ghost }
            return group.first
        }
        return uniqueHits.sorted { lhs, rhs in
                lhs.slot == rhs.slot
                    ? voiceOrder(lhs.voice) < voiceOrder(rhs.voice)
                    : lhs.slot < rhs.slot
            }
    }

    private static func isScorable(_ voice: DrumVoice) -> Bool {
        voice != .metronome && voice != .unknown
    }

    private static func voiceOrder(_ voice: DrumVoice) -> Int {
        DrumVoice.allCases.firstIndex(of: voice) ?? Int.max
    }
}

enum KickExercise: String, CaseIterable, Codable, Identifiable, Sendable {
    case straightEighths
    case straightSixteenths
    case triplets
    case offbeatEighths
    case gallop
    case reverseGallop
    case threeNoteBursts
    case fourOnFourOff
    case displacedSixteenths
    case basicRockGroove
    case doubleBassBackbeat
    case discoGroove
    case alternatingBlast
    case simultaneousBlast
    case tripletBlast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .straightEighths: "Straight 8ths"
        case .straightSixteenths: "Straight 16ths"
        case .triplets: "8th-note triplets"
        case .offbeatEighths: "Offbeat 8ths"
        case .gallop: "Gallop"
        case .reverseGallop: "Reverse gallop"
        case .threeNoteBursts: "Three-note bursts"
        case .fourOnFourOff: "Four on / four off"
        case .displacedSixteenths: "Displaced 16ths"
        case .basicRockGroove: "Rock backbeat"
        case .doubleBassBackbeat: "Double-bass backbeat"
        case .discoGroove: "Open-hat groove"
        case .alternatingBlast: "Alternating blast"
        case .simultaneousBlast: "Unison blast"
        case .tripletBlast: "Triplet blast"
        }
    }

    var category: String {
        switch self {
        case .straightEighths, .straightSixteenths, .triplets: "FOUNDATIONS"
        case .offbeatEighths, .gallop, .reverseGallop: "COORDINATION"
        case .threeNoteBursts, .fourOnFourOff, .displacedSixteenths: "CONTROL & BURSTS"
        case .basicRockGroove, .doubleBassBackbeat, .discoGroove: "FULL KIT GROOVES"
        case .alternatingBlast, .simultaneousBlast, .tripletBlast: "BLAST BEATS"
        }
    }

    var difficulty: Int {
        switch self {
        case .straightEighths: 1
        case .straightSixteenths, .triplets, .offbeatEighths: 2
        case .gallop, .reverseGallop, .fourOnFourOff: 3
        case .threeNoteBursts: 4
        case .displacedSixteenths: 5
        case .basicRockGroove: 2
        case .discoGroove: 3
        case .doubleBassBackbeat: 4
        case .alternatingBlast, .tripletBlast: 4
        case .simultaneousBlast: 5
        }
    }

    var guidance: String {
        switch self {
        case .straightEighths: "Even, relaxed strokes on 1 & 2 & 3 & 4 &."
        case .straightSixteenths: "Continuous 1 e & a with identical spacing."
        case .triplets: "Three evenly spaced hits per beat: 1-trip-let."
        case .offbeatEighths: "Play only each &: leave the numbered beats empty."
        case .gallop: "One hit on the beat, then two quick sixteenths on &-a."
        case .reverseGallop: "Three hits on 1-e-& followed by the a rest."
        case .threeNoteBursts: "Three sixteenths, one rest, repeated every beat."
        case .fourOnFourOff: "One beat of 16ths followed by one full beat of rest."
        case .displacedSixteenths: "A changing three-note shape that shifts the missing sixteenth."
        case .basicRockGroove: "8th-note cymbal, snare on 2 and 4, with kick on 1, 3, and the & of 3."
        case .doubleBassBackbeat: "Continuous 16th-note feet under 8th-note cymbal and snare on 2 and 4."
        case .discoGroove: "Quarter-note kick, snare on 2 and 4, and open hi-hat on every 8th note."
        case .alternatingBlast: "Alternate cymbal-plus-kick with snare on the neighboring 16th notes."
        case .simultaneousBlast: "Cymbal, snare, and kick land together on every 8th note."
        case .tripletBlast: "Cymbal-plus-kick, snare, then kick across each triplet beat."
        }
    }

    var subdivision: KickSubdivision {
        switch self {
        case .straightEighths, .offbeatEighths: .eighths
        case .triplets, .tripletBlast: .triplets
        case .straightSixteenths, .gallop, .reverseGallop, .threeNoteBursts,
             .fourOnFourOff, .displacedSixteenths, .doubleBassBackbeat,
             .alternatingBlast: .sixteenths
        case .basicRockGroove, .discoGroove, .simultaneousBlast: .eighths
        }
    }

    var hitSlotsPerMeasure: Set<Int> {
        Set(eventsPerMeasure.map(\.slot))
    }

    var hitsPerMeasure: Int { eventsPerMeasure.count }

    var usesMultipleVoices: Bool {
        Set(eventsPerMeasure.map(\.voice)).count > 1
    }

    var eventsPerMeasure: [PracticeExerciseHit] {
        let kick: (Int) -> PracticeExerciseHit = { PracticeExerciseHit(slot: $0, voice: .kick) }
        let snare: (Int) -> PracticeExerciseHit = {
            PracticeExerciseHit(slot: $0, voice: .snare, allowedVoices: [.crossStick])
        }
        let cymbal: (Int) -> PracticeExerciseHit = {
            PracticeExerciseHit(
                slot: $0,
                voice: .crash1,
                allowedVoices: [.crash2, .ride, .rideBell, .closedHiHat, .openHiHat, .china]
            )
        }
        let closedHat: (Int) -> PracticeExerciseHit = {
            PracticeExerciseHit(slot: $0, voice: .closedHiHat, allowedVoices: [.ride])
        }

        switch self {
        case .straightEighths:
            return (0..<8).map(kick)
        case .straightSixteenths:
            return (0..<16).map(kick)
        case .triplets:
            return (0..<12).map(kick)
        case .offbeatEighths:
            return [1, 3, 5, 7].map(kick)
        case .gallop:
            return slots(repeating: [0, 2, 3]).sorted().map(kick)
        case .reverseGallop, .threeNoteBursts:
            return slots(repeating: [0, 1, 2]).sorted().map(kick)
        case .fourOnFourOff:
            return [0, 1, 2, 3, 8, 9, 10, 11].map(kick)
        case .displacedSixteenths:
            return [0, 1, 2, 4, 5, 7, 8, 10, 11, 13, 14, 15].map(kick)
        case .basicRockGroove:
            return sortedHits((0..<8).map(closedHat) + [2, 6].map(snare) + [0, 4, 5].map(kick))
        case .doubleBassBackbeat:
            return sortedHits((0..<16).map(kick) + stride(from: 0, to: 16, by: 2).map(cymbal) + [4, 12].map(snare))
        case .discoGroove:
            let hats = (0..<8).map {
                PracticeExerciseHit(slot: $0, voice: .openHiHat)
            }
            return sortedHits(hats + [0, 2, 4, 6].map(kick) + [2, 6].map(snare))
        case .alternatingBlast:
            return sortedHits(
                stride(from: 0, to: 16, by: 2).flatMap { [cymbal($0), kick($0)] }
                    + stride(from: 1, to: 16, by: 2).map(snare)
            )
        case .simultaneousBlast:
            return sortedHits((0..<8).flatMap { [cymbal($0), snare($0), kick($0)] })
        case .tripletBlast:
            return sortedHits((0..<4).flatMap { beat in
                let first = beat * 3
                return [cymbal(first), kick(first), snare(first + 1), kick(first + 2)]
            })
        }
    }

    static func straight(_ subdivision: KickSubdivision) -> KickExercise {
        switch subdivision {
        case .eighths: .straightEighths
        case .sixteenths: .straightSixteenths
        case .triplets: .triplets
        }
    }

    private func slots(repeating positions: [Int]) -> Set<Int> {
        Set((0..<4).flatMap { beat in
            positions.map { beat * 4 + $0 }
        })
    }

    private func sortedHits(_ hits: [PracticeExerciseHit]) -> [PracticeExerciseHit] {
        hits.enumerated().sorted { lhs, rhs in
            lhs.element.slot == rhs.element.slot ? lhs.offset < rhs.offset : lhs.element.slot < rhs.element.slot
        }.map(\.element)
    }
}

struct PracticeMeasureSignature: Codable, Equatable, Sendable {
    let numerator: Int
    let denominator: Int
}

struct PracticeReferenceBeat: Codable, Equatable, Sendable {
    let offsetNanoseconds: Int64
    let measure: Int
    let beat: Int
    let isAccent: Bool
}

struct PracticePattern: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let bpm: Double
    let beatsPerMeasure: Int
    let measures: Int
    let subdivision: KickSubdivision
    let startSessionTimeNanoseconds: Int64
    let expectedEvents: [ExpectedEvent]
    let durationNanoseconds: Int64?
    let measureSignatures: [PracticeMeasureSignature]?
    let measureStartOffsetsNanoseconds: [Int64]?
    let referenceBeats: [PracticeReferenceBeat]?
    let measureSubdivisions: [KickSubdivision]?
    let measureLabels: [String]?

    init(
        id: UUID = UUID(),
        name: String,
        bpm: Double,
        beatsPerMeasure: Int,
        measures: Int,
        subdivision: KickSubdivision = .sixteenths,
        startSessionTimeNanoseconds: Int64? = nil,
        expectedEvents: [ExpectedEvent],
        durationNanoseconds: Int64? = nil,
        measureSignatures: [PracticeMeasureSignature]? = nil,
        measureStartOffsetsNanoseconds: [Int64]? = nil,
        referenceBeats: [PracticeReferenceBeat]? = nil,
        measureSubdivisions: [KickSubdivision]? = nil,
        measureLabels: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.bpm = bpm
        self.beatsPerMeasure = beatsPerMeasure
        self.measures = measures
        self.subdivision = subdivision
        self.startSessionTimeNanoseconds = startSessionTimeNanoseconds
            ?? expectedEvents.map(\.sessionTimeNanoseconds).min()
            ?? 0
        self.expectedEvents = expectedEvents
        self.durationNanoseconds = durationNanoseconds
        self.measureSignatures = measureSignatures
        self.measureStartOffsetsNanoseconds = measureStartOffsetsNanoseconds
        self.referenceBeats = referenceBeats
        self.measureSubdivisions = measureSubdivisions
        self.measureLabels = measureLabels
    }

    func subdivision(forMeasure measure: Int) -> KickSubdivision {
        guard let measureSubdivisions, measure > 0, measure <= measureSubdivisions.count else { return subdivision }
        return measureSubdivisions[measure - 1]
    }

    func label(forMeasure measure: Int) -> String? {
        guard let measureLabels, measure > 0, measure <= measureLabels.count else { return nil }
        return measureLabels[measure - 1]
    }

    func signature(forMeasure measure: Int) -> PracticeMeasureSignature {
        guard let measureSignatures,
              measure > 0,
              measure <= measureSignatures.count else {
            return PracticeMeasureSignature(numerator: beatsPerMeasure, denominator: 4)
        }
        return measureSignatures[measure - 1]
    }

    var exactDurationNanoseconds: Int64 {
        if let durationNanoseconds { return max(durationNanoseconds, 0) }
        guard bpm > 0, beatsPerMeasure > 0, measures > 0 else { return 0 }
        let duration = Double(measures * beatsPerMeasure) * 60_000_000_000 / bpm
        return Int64(min(max(duration.rounded(), 0), Double(Int64.max)))
    }
}

struct ExpectedEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let measure: Int
    let beat: Int
    let subdivision: Int
    let sessionTimeNanoseconds: Int64
    let hostTime: UInt64?
    let voice: DrumVoice
    let allowedVoices: Set<DrumVoice>
    let expectedVelocity: Double?
    let minimumAccentVelocity: Double?
    let minimumAccentContrast: Double?
    let maximumGhostVelocity: Double?
    let minimumGhostContrast: Double?
    let matchingToleranceNanoseconds: Int64
    let simultaneousGroupID: UUID?

    init(
        id: UUID = UUID(),
        measure: Int,
        beat: Int,
        subdivision: Int,
        sessionTimeNanoseconds: Int64,
        hostTime: UInt64? = nil,
        voice: DrumVoice,
        allowedVoices: Set<DrumVoice> = [],
        expectedVelocity: Double? = nil,
        minimumAccentVelocity: Double? = nil,
        minimumAccentContrast: Double? = nil,
        maximumGhostVelocity: Double? = nil,
        minimumGhostContrast: Double? = nil,
        matchingToleranceNanoseconds: Int64 = 100_000_000,
        simultaneousGroupID: UUID? = nil
    ) {
        self.id = id
        self.measure = measure
        self.beat = beat
        self.subdivision = subdivision
        self.sessionTimeNanoseconds = sessionTimeNanoseconds
        self.hostTime = hostTime
        self.voice = voice
        self.allowedVoices = allowedVoices
        self.expectedVelocity = expectedVelocity
        self.minimumAccentVelocity = minimumAccentVelocity.map { min(max($0, 0), 1) }
        self.minimumAccentContrast = minimumAccentContrast.map { min(max($0, 0), 1) }
        self.maximumGhostVelocity = maximumGhostVelocity
        self.minimumGhostContrast = minimumGhostContrast
        self.matchingToleranceNanoseconds = max(0, matchingToleranceNanoseconds)
        self.simultaneousGroupID = simultaneousGroupID
    }

    func accepts(_ actualVoice: DrumVoice) -> Bool {
        actualVoice == voice || allowedVoices.contains(actualVoice)
    }

    var isAccent: Bool { minimumAccentVelocity != nil || minimumAccentContrast != nil }
    var isGhost: Bool { maximumGhostVelocity != nil || minimumGhostContrast != nil }
}

enum AccentResultClassification: String, Codable, Equatable, Sendable {
    case achieved
    case belowThreshold
    case insufficientContrast
    case missed
    case velocityUnavailable
    case baselineUnavailable
}

struct AccentResult: Identifiable, Codable, Equatable, Sendable {
    let expectedEventID: UUID
    let actualEventID: UUID?
    let voice: DrumVoice
    let minimumVelocity: Double?
    let baselineVelocity: Double?
    let requiredContrast: Double?
    let requiredVelocity: Double?
    let usedMinimumOnly: Bool?
    let actualVelocity: Double?
    let classification: AccentResultClassification

    var id: UUID { expectedEventID }
    var didUseMinimumOnly: Bool { usedMinimumOnly == true }
}

struct AccentMetrics: Codable, Equatable, Sendable {
    let expectedCount: Int
    let achievedCount: Int
    let belowThresholdCount: Int
    let missedCount: Int
    let velocityUnavailableCount: Int
    let baselineUnavailableCount: Int?
    let accuracy: Double

    var notEvaluatedCount: Int {
        missedCount + velocityUnavailableCount + (baselineUnavailableCount ?? 0)
    }

    var passesCleanThreshold: Bool {
        expectedCount > 0 && accuracy >= 0.9
    }
}

struct AccentEvaluation: Codable, Equatable, Sendable {
    let metrics: AccentMetrics
    let results: [AccentResult]

    func voiceAccuracy(for voice: DrumVoice) -> DynamicVoiceAccuracy? {
        let voiceResults = results.filter { $0.voice == voice }
        guard !voiceResults.isEmpty else { return nil }
        return DynamicVoiceAccuracy(
            expectedCount: voiceResults.count,
            achievedCount: voiceResults.count { $0.classification == .achieved }
        )
    }
}

enum GhostResultClassification: String, Codable, Equatable, Sendable {
    case achieved
    case aboveThreshold
    case insufficientContrast
    case missed
    case velocityUnavailable
    case baselineUnavailable
}

struct GhostResult: Identifiable, Codable, Equatable, Sendable {
    let expectedEventID: UUID
    let actualEventID: UUID?
    let voice: DrumVoice
    let maximumVelocity: Double?
    let baselineVelocity: Double?
    let requiredContrast: Double?
    let requiredVelocity: Double?
    let usedMaximumOnly: Bool?
    let actualVelocity: Double?
    let classification: GhostResultClassification

    var id: UUID { expectedEventID }
    var didUseMaximumOnly: Bool { usedMaximumOnly == true }
}

struct GhostMetrics: Codable, Equatable, Sendable {
    let expectedCount: Int
    let achievedCount: Int
    let aboveThresholdCount: Int
    let missedCount: Int
    let velocityUnavailableCount: Int
    let baselineUnavailableCount: Int?
    let accuracy: Double

    var notEvaluatedCount: Int {
        missedCount + velocityUnavailableCount + (baselineUnavailableCount ?? 0)
    }

    var passesCleanThreshold: Bool {
        expectedCount > 0 && accuracy >= 0.9
    }
}

struct GhostEvaluation: Codable, Equatable, Sendable {
    let metrics: GhostMetrics
    let results: [GhostResult]

    func voiceAccuracy(for voice: DrumVoice) -> DynamicVoiceAccuracy? {
        let voiceResults = results.filter { $0.voice == voice }
        guard !voiceResults.isEmpty else { return nil }
        return DynamicVoiceAccuracy(
            expectedCount: voiceResults.count,
            achievedCount: voiceResults.count { $0.classification == .achieved }
        )
    }
}

struct DynamicVoiceAccuracy: Equatable, Sendable {
    let expectedCount: Int
    let achievedCount: Int

    var accuracy: Double {
        expectedCount == 0 ? 0 : Double(achievedCount) / Double(expectedCount)
    }
}

enum MatchClassification: String, Codable, Equatable, Sendable {
    case correct
    case wrongVoice
    case missed
    case extra
    case ambiguous
}

enum TimingBand: String, Codable, Equatable, Sendable {
    case tight
    case good
    case acceptable
    case loose
    case unmatched
}

struct MatchResult: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let expectedEventID: UUID?
    let actualEventID: UUID?
    let classification: MatchClassification
    let expectedTimeNanoseconds: Int64?
    let actualTimeNanoseconds: Int64?
    let signedOffsetMilliseconds: Double?
    let absoluteTimingErrorMilliseconds: Double?

    init(
        id: UUID? = nil,
        expectedEventID: UUID?,
        actualEventID: UUID?,
        classification: MatchClassification,
        expectedTimeNanoseconds: Int64?,
        actualTimeNanoseconds: Int64?,
        signedOffsetMilliseconds: Double?
    ) {
        self.id = id ?? expectedEventID ?? actualEventID ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        self.expectedEventID = expectedEventID
        self.actualEventID = actualEventID
        self.classification = classification
        self.expectedTimeNanoseconds = expectedTimeNanoseconds
        self.actualTimeNanoseconds = actualTimeNanoseconds
        self.signedOffsetMilliseconds = signedOffsetMilliseconds
        self.absoluteTimingErrorMilliseconds = signedOffsetMilliseconds.map(abs)
    }
}

struct VoiceMetrics: Identifiable, Codable, Equatable, Sendable {
    var id: DrumVoice { voice }
    let voice: DrumVoice
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
}

struct VoiceSynchronizationOffset: Identifiable, Codable, Equatable, Sendable {
    var id: DrumVoice { voice }
    let voice: DrumVoice
    let sampleCount: Int
    let meanOffsetFromGroupCenterMilliseconds: Double
    let medianOffsetFromGroupCenterMilliseconds: Double
}

struct LimbSynchronizationMetrics: Codable, Equatable, Sendable {
    let eligibleGroupCount: Int
    let completedGroupCount: Int
    let averageSpreadMilliseconds: Double?
    let medianSpreadMilliseconds: Double?
    let worstSpreadMilliseconds: Double?
    let voiceOffsets: [VoiceSynchronizationOffset]
}

struct AggregateMetrics: Codable, Equatable, Sendable {
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
    let meanAbsoluteErrorMilliseconds: Double?
    let medianAbsoluteErrorMilliseconds: Double?
    let timingStandardDeviationMilliseconds: Double?
    let earlyCount: Int
    let lateCount: Int
    let longestCleanStreak: Int
    let perVoice: [VoiceMetrics]
    let limbSynchronization: LimbSynchronizationMetrics?
}

struct StableTimingBiasEvaluation: Equatable, Sendable {
    let sampleCount: Int
    let biasMilliseconds: Double
    let medianAbsoluteDeviationMilliseconds: Double
    let rawMedianAbsoluteErrorMilliseconds: Double
    let adjustedMedianAbsoluteErrorMilliseconds: Double
}

struct PracticeCoachingSummary: Equatable, Sendable {
    let overview: String
    let nextStep: String
}
