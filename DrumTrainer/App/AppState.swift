import AppKit
import Combine
import CoreAudio
import CoreMIDI
import Foundation

enum PracticePhase: Equatable, Sendable {
    case idle
    case countIn(beatsRemaining: Int)
    case running(startSessionTime: Int64, endSessionTime: Int64)
    case results
    case error(String)

    var isActive: Bool {
        switch self {
        case .countIn, .running: true
        case .idle, .results, .error: false
        }
    }
}

enum PracticeExerciseMode: String, CaseIterable, Identifiable, Sendable {
    case builtIn
    case custom
    case importedSong

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .builtIn: "Built-in"
        case .custom: "Custom measure"
        case .importedSong: "Imported song"
        }
    }
}

enum MicrophoneCalibrationPhase: Equatable, Sendable {
    case idle
    case preparingInput
    case samplingNoise(secondsRemaining: Int)
    case collectingHits(detected: Int, target: Int)
    case review(MicrophoneCalibrationProfile)
    case saved(MicrophoneCalibrationProfile)
    case error(String)

    var isActive: Bool {
        switch self {
        case .preparingInput, .samplingNoise, .collectingHits, .review: true
        case .idle, .saved, .error: false
        }
    }
}

enum TimingAlignmentPhase: Equatable, Sendable {
    case idle
    case starting
    case countIn(beatsRemaining: Int)
    case collecting(referenceCount: Int, target: Int, detectedHits: Int)
    case review(TimingAlignmentProfile)
    case saved(TimingAlignmentProfile)
    case error(String)

    var isActive: Bool {
        switch self {
        case .starting, .countIn, .collecting: true
        case .idle, .review, .saved, .error: false
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let countInBeats = 8

    private let clock: any ClockProviding
    private let timeline: SessionTimeline
    private let eventStream: UnifiedEventStream
    private let midiMappingStore: any MIDIMappingPersisting
    private let microphoneCalibrationStore: any MicrophoneCalibrationPersisting
    private let timingAlignmentStore: any TimingAlignmentPersisting
    private let practiceDataStore: any PracticeDataPersisting
    private var simulationTask: Task<Void, Never>?
    private var practiceFinishTask: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private var timingAlignmentFinishTask: Task<Void, Never>?
    private var timingAlignmentStartWatchdogTask: Task<Void, Never>?
    private var metronomeHeartbeatTask: Task<Void, Never>?
    private var metronomeStallRecoveryAttempts = 0
    private var activeAudioFlowGeneration = 0
    private var practiceRecording: PracticeSessionRecording?
    private var pendingPracticeBounds: (startSessionTime: Int64, endSessionTime: Int64)?
    private var hasStartedHardwareMonitoring = false
    private var midiMapping: [UInt8: DrumVoice] = [:]
    private var calibrationNoiseSamples: [Double] = []
    private var microphoneLevelSampleSequence: UInt64 = 0
    private var calibrationHitCollector = MicrophoneCalibrationHitCollector(initialLockoutMilliseconds: 40)
    private var preCalibrationConfiguration: KickDetectorConfiguration?
    private let calibrationAnalyzer = MicrophoneCalibrationAnalyzer()
    private var microphoneCrosstalkGuard = MicrophoneCrosstalkGuard()
    private let kickSoundClassifier = KickSoundClassifier()
    private var timingAlignmentCollector = TimingAlignmentCollector(source: .midi, voice: .snare)

    private lazy var midiInputService = MIDIInputService(
        onDevicesChanged: { [weak self] devices in
            Task { @MainActor [weak self] in
                self?.midiDevices = devices
            }
        },
        onNoteOn: { [weak self] note, endpointName in
            Task { @MainActor [weak self] in
                await self?.publishMIDI(note, endpointName: endpointName)
            }
        },
        onStatusChanged: { [weak self] status in
            Task { @MainActor [weak self] in
                self?.midiStatus = status
            }
        }
    )

    private lazy var audioInputService = AudioInputService(
        timeline: timeline,
        configuration: currentKickConfiguration,
        onDevicesChanged: { [weak self] devices in
            Task { @MainActor [weak self] in
                self?.audioDevices = devices
            }
        },
        onPermissionChanged: { [weak self] permission in
            Task { @MainActor [weak self] in
                self?.microphonePermission = permission
            }
        },
        onStatusChanged: { [weak self] status in
            Task { @MainActor [weak self] in
                self?.audioStatus = status
            }
        },
        onLevel: { [weak self] level in
            Task { @MainActor [weak self] in
                self?.appendMicrophoneLevel(level)
            }
        },
        onKick: { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.publishMicrophoneEvent(event)
            }
        }
    )

    private lazy var metronomeEngine = MetronomeEngine(
        onDevicesChanged: { [weak self] devices in
            Task { @MainActor [weak self] in
                self?.audioOutputDevices = devices
            }
        },
        onStatusChanged: { [weak self] status in
            Task { @MainActor [weak self] in
                self?.metronomeStatus = status
                if case .running = status {
                    self?.isMetronomeRunning = true
                } else {
                    self?.isMetronomeRunning = false
                }
                self?.handleTimingAlignmentMetronomeStatus(status)
            }
        },
        onTick: { [weak self] tick in
            Task { @MainActor [weak self] in
                await self?.publishMetronomeTick(tick)
            }
        },
        onHealthChanged: { [weak self] health in
            Task { @MainActor [weak self] in
                self?.metronomeSchedulingHealth = health
            }
        },
        onOutputLevelChanged: { [weak self] level in
            Task { @MainActor [weak self] in
                self?.appOutputLevel = level
            }
        },
        onOutputLatencyChanged: { [weak self] milliseconds in
            Task { @MainActor [weak self] in
                self?.metronomeOutputPresentationLatencyMilliseconds = milliseconds
            }
        }
    )

    @Published var events: [PerformanceEvent] = []
    @Published var recentLevels: [Double] = Array(repeating: 0, count: 80)
    @Published var droppedEventCount = 0
    @Published var eventTimestampDisplayMode: EventTimestampDisplayMode = .session
    @Published var isSimulationRunning = false
    @Published var midiDevices: [MIDIInputDevice] = []
    @Published var selectedMIDIInputID: MIDIUniqueID?
    @Published var midiStatus: MIDIInputStatus = .stopped
    @Published var lastMIDINote: UInt8?
    @Published var lastMIDIVelocity: UInt8?
    @Published var midiMappingVoice: DrumVoice = .unknown
    @Published var audioDevices: [AudioInputDevice] = []
    @Published var selectedAudioInputID: AudioDeviceID?
    @Published var audioStatus: AudioInputStatus = .stopped
    @Published var microphonePermission: MicrophonePermissionState = .unknown
    @Published var audioOutputDevices: [AudioOutputDevice] = []
    @Published var selectedAudioOutputID: AudioDeviceID?
    @Published var metronomeStatus: MetronomeStatus = .stopped
    @Published var metronomeSchedulingHealth = MetronomeSchedulingHealth()
    @Published var isMetronomeRunning = false
    @Published var metronomeBPM = 120.0 {
        didSet { metronomeEngine.updateBPM(metronomeBPM) }
    }
    @Published var metronomeSound: MetronomeSound = .cuttingElectronic {
        didSet {
            metronomeEngine.updateSound(metronomeSound)
            UserDefaults.standard.set(metronomeSound.rawValue, forKey: "DrumTrainer.metronome.sound")
        }
    }
    @Published var metronomeGainDecibels = -3.0 {
        didSet {
            metronomeEngine.updateGainDecibels(metronomeGainDecibels)
            UserDefaults.standard.set(metronomeGainDecibels, forKey: "DrumTrainer.metronome.gainDB")
        }
    }
    @Published var metronomeLimiterEnabled = true {
        didSet {
            metronomeEngine.updateLimiter(
                enabled: metronomeLimiterEnabled,
                ceilingDBFS: metronomeLimiterCeilingDBFS
            )
            UserDefaults.standard.set(metronomeLimiterEnabled, forKey: "DrumTrainer.metronome.limiterEnabled")
        }
    }
    @Published var metronomeLimiterCeilingDBFS = -1.0 {
        didSet {
            metronomeEngine.updateLimiter(
                enabled: metronomeLimiterEnabled,
                ceilingDBFS: metronomeLimiterCeilingDBFS
            )
            UserDefaults.standard.set(metronomeLimiterCeilingDBFS, forKey: "DrumTrainer.metronome.limiterCeilingDBFS")
        }
    }
    @Published var appOutputLevel = AppOutputLevel.silence
    @Published var isRefreshingAudioEngine = false
    @Published var audioEngineRecoveryMessage: String?
    @Published var metronomeOutputPresentationLatencyMilliseconds: Double?
    @Published var kickThreshold = 0.45 {
        didSet { audioInputService.updateConfiguration(currentKickConfiguration) }
    }
    @Published var retriggerLockoutMilliseconds = 40.0 {
        didSet { audioInputService.updateConfiguration(currentKickConfiguration) }
    }
    @Published var midiCrosstalkSuppressionEnabled = true {
        didSet {
            microphoneCrosstalkGuard.configuration.isEnabled = midiCrosstalkSuppressionEnabled
        }
    }
    @Published var suppressedMicrophoneCrosstalkCount = 0
    @Published var kickSoundFilterEnabled = true
    @Published var minimumKickSoundSimilarity = 0.20
    @Published var rejectedNonKickSoundCount = 0
    @Published var lastKickSoundSimilarity: Double?
    @Published var practiceExerciseMode: PracticeExerciseMode = .builtIn
    @Published var practiceExercise: KickExercise = .straightSixteenths
    @Published var practiceCustomMeasure = CustomMeasureDefinition()
    @Published var savedCustomExercises: [SavedCustomExercise] = []
    @Published var selectedSavedCustomExerciseID: UUID?
    @Published var importedSongs: [ImportedSong] = []
    @Published var selectedImportedSongID: UUID?
    @Published var importedSectionStartMeasure = 1
    @Published var importedSectionEndMeasure = 1
    @Published var importedSectionRepeats = 1
    @Published var practiceHistory: [PracticeSessionSummary] = []
    @Published var practiceSessionRecords: [PracticeSessionRecord] = []
    @Published var tempoProgressionSettings = TempoProgressionSettings()
    @Published var tempoProgressions: [ExerciseTempoProgression] = []
    @Published var lastTempoProgressionMessage: String?
    @Published var ceilingModeSettings = CeilingModeSettings()
    @Published var activeCeilingRun: CeilingRun?
    @Published var ceilingRecords: [ExerciseCeilingRecord] = []
    @Published var lastCeilingMessage: String?
    @Published var practiceDataStatusMessage: String?
    @Published var practiceBPM = 120.0
    @Published var practiceMeasures = 4
    @Published var practicePhase: PracticePhase = .idle
    @Published var practiceActivePattern: PracticePattern?
    @Published var practiceExpectedEvents: [ExpectedEvent] = []
    @Published var practiceOutcome: PracticeSessionOutcome?
    @Published var practiceRecordedHitCount = 0
    @Published var microphoneCalibrationPhase: MicrophoneCalibrationPhase = .idle
    @Published var calibrationNoiseEstimate: MicrophoneNoiseEstimate?
    @Published var activeMicrophoneCalibrationProfile: MicrophoneCalibrationProfile?
    @Published var calibrationSuppressedTransientCount = 0
    @Published var timingAlignmentSource: TimingAlignmentSource = .midi
    @Published var timingAlignmentVoice: DrumVoice = .snare
    @Published var timingAlignmentPhase: TimingAlignmentPhase = .idle
    @Published var timingAlignmentProfiles: [TimingAlignmentProfile] = []

    init(
        clock: any ClockProviding = MachHostClock(),
        converter: any HostTimeConverting = CoreAudioHostTimeConverter(),
        midiMappingStore: any MIDIMappingPersisting = UserDefaultsMIDIMappingStore(),
        microphoneCalibrationStore: any MicrophoneCalibrationPersisting = UserDefaultsMicrophoneCalibrationStore(),
        timingAlignmentStore: any TimingAlignmentPersisting = UserDefaultsTimingAlignmentStore(),
        practiceDataStore: any PracticeDataPersisting = UserDefaultsPracticeDataStore(),
        eventCapacity: Int = 500
    ) {
        self.clock = clock
        self.midiMappingStore = midiMappingStore
        self.microphoneCalibrationStore = microphoneCalibrationStore
        self.timingAlignmentStore = timingAlignmentStore
        self.practiceDataStore = practiceDataStore
        let timeline = SessionTimeline(originHostTime: clock.currentHostTime(), converter: converter)
        self.timeline = timeline
        self.eventStream = UnifiedEventStream(capacity: eventCapacity)
        timingAlignmentProfiles = timingAlignmentStore.loadProfiles()
        do {
            let archive = try practiceDataStore.load()
            savedCustomExercises = archive.customExercises.sorted {
                $0.definition.displayName.localizedCaseInsensitiveCompare($1.definition.displayName) == .orderedAscending
            }
            importedSongs = archive.importedSongs.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            practiceHistory = archive.sessions.sorted { $0.completedAt > $1.completedAt }
            practiceSessionRecords = archive.sessionRecords.sorted {
                $0.summary.completedAt > $1.summary.completedAt
            }
            tempoProgressionSettings = archive.tempoProgressionSettings
            tempoProgressions = archive.tempoProgressions.sorted { $0.updatedAt > $1.updatedAt }
            ceilingModeSettings = archive.ceilingModeSettings
            activeCeilingRun = archive.activeCeilingRun
            ceilingRecords = archive.ceilingRecords.sorted { $0.achievedAt > $1.achievedAt }
        } catch {
            practiceDataStatusMessage = error.localizedDescription
        }
        let defaults = UserDefaults.standard
        if let rawSound = defaults.string(forKey: "DrumTrainer.metronome.sound"),
           let savedSound = MetronomeSound(rawValue: rawSound) {
            metronomeSound = savedSound
        }
        if defaults.object(forKey: "DrumTrainer.metronome.gainDB") != nil {
            metronomeGainDecibels = min(max(defaults.double(forKey: "DrumTrainer.metronome.gainDB"), -36), 12)
        }
        if defaults.object(forKey: "DrumTrainer.metronome.limiterEnabled") != nil {
            metronomeLimiterEnabled = defaults.bool(forKey: "DrumTrainer.metronome.limiterEnabled")
        }
        if defaults.object(forKey: "DrumTrainer.metronome.limiterCeilingDBFS") != nil {
            metronomeLimiterCeilingDBFS = min(
                max(defaults.double(forKey: "DrumTrainer.metronome.limiterCeilingDBFS"), -12),
                -0.5
            )
        }
        metronomeEngine.updateSound(metronomeSound)
        metronomeEngine.updateGainDecibels(metronomeGainDecibels)
        metronomeEngine.updateLimiter(
            enabled: metronomeLimiterEnabled,
            ceilingDBFS: metronomeLimiterCeilingDBFS
        )
    }

    func toggleSimulation() {
        isSimulationRunning ? stopSimulation() : startSimulation()
    }

    func startPractice() {
        guard !practicePhase.isActive, !isRefreshingAudioEngine else { return }
        if timingAlignmentPhase.isActive { cancelTimingAlignment() }
        if practiceExerciseMode == .custom, practiceCustomMeasure.isEmpty {
            practicePhase = .error(KickPatternGeneratorError.emptyCustomMeasure.localizedDescription)
            return
        }
        if practiceExerciseMode == .importedSong {
            guard let song = selectedImportedSong else {
                practicePhase = .error("Import or choose a MIDI song before starting.")
                return
            }
            guard song.mappedNoteCount > 0 else {
                practicePhase = .error(ImportedSongPatternGeneratorError.noMappedNotes.localizedDescription)
                return
            }
        }
        stopSimulation()
        activeAudioFlowGeneration &+= 1
        audioEngineRecoveryMessage = nil
        practiceFinishTask?.cancel()
        practiceFinishTask = nil
        practiceRecording = nil
        pendingPracticeBounds = nil
        practiceActivePattern = nil
        practiceExpectedEvents = []
        practiceOutcome = nil
        practiceRecordedHitCount = 0
        lastTempoProgressionMessage = nil
        metronomeStallRecoveryAttempts = 0
        prepareCeilingRunForStart()
        practicePhase = .countIn(beatsRemaining: Self.countInBeats)
        metronomeBPM = min(max(practiceBPM, 40), 240)
        practiceBPM = metronomeBPM
        metronomeEngine.start(bpm: practiceBPM)
        scheduleMetronomeHeartbeat()
    }

    func cancelPractice() {
        activeAudioFlowGeneration &+= 1
        cancelMetronomeHeartbeat()
        practiceFinishTask?.cancel()
        practiceFinishTask = nil
        practiceRecording = nil
        pendingPracticeBounds = nil
        practiceActivePattern = nil
        practiceExpectedEvents = []
        practiceOutcome = nil
        practiceRecordedHitCount = 0
        practicePhase = .idle
        metronomeEngine.stop()
    }

    func dismissPracticeResults() {
        guard !practicePhase.isActive else { return }
        practiceOutcome = nil
        practiceActivePattern = nil
        practiceExpectedEvents = []
        practiceRecordedHitCount = 0
        practicePhase = .idle
    }

    func toggleCustomMeasureHit(slot: Int, voice: DrumVoice) {
        guard !practicePhase.isActive else { return }
        var updated = practiceCustomMeasure
        updated.toggle(slot: slot, voice: voice)
        practiceCustomMeasure = updated
        if case .error = practicePhase { practicePhase = .idle }
    }

    func setCustomMeasureSubdivision(_ subdivision: KickSubdivision) {
        guard !practicePhase.isActive else { return }
        var updated = practiceCustomMeasure
        updated.rescale(to: subdivision)
        practiceCustomMeasure = updated
    }

    func clearCustomMeasure() {
        guard !practicePhase.isActive else { return }
        var updated = practiceCustomMeasure
        updated.clear()
        practiceCustomMeasure = updated
    }

    func loadCustomMeasureExample(_ exercise: KickExercise = .basicRockGroove) {
        guard !practicePhase.isActive else { return }
        var updated = practiceCustomMeasure
        updated.replace(with: exercise)
        practiceCustomMeasure = updated
        selectedSavedCustomExerciseID = nil
        practiceExerciseMode = .custom
        if case .error = practicePhase { practicePhase = .idle }
    }

    func loadSavedCustomExercise(id: UUID) {
        guard !practicePhase.isActive,
              let saved = savedCustomExercises.first(where: { $0.id == id }) else { return }
        selectedSavedCustomExerciseID = saved.id
        practiceCustomMeasure = saved.definition
        practiceExerciseMode = .custom
        practiceDataStatusMessage = "Loaded \(saved.definition.displayName)."
        if case .error = practicePhase { practicePhase = .idle }
    }

    func saveCustomExercise(asNew: Bool = false) {
        guard !practicePhase.isActive, !practiceCustomMeasure.isEmpty else { return }
        var definition = practiceCustomMeasure
        definition.name = definition.displayName
        practiceCustomMeasure = definition
        let now = Date()

        if !asNew,
           let selectedSavedCustomExerciseID,
           let index = savedCustomExercises.firstIndex(where: { $0.id == selectedSavedCustomExerciseID }) {
            savedCustomExercises[index].definition = definition
            savedCustomExercises[index].updatedAt = now
            practiceDataStatusMessage = "Updated \(definition.displayName)."
        } else {
            let saved = SavedCustomExercise(definition: definition, createdAt: now, updatedAt: now)
            savedCustomExercises.append(saved)
            selectedSavedCustomExerciseID = saved.id
            practiceDataStatusMessage = "Saved \(definition.displayName)."
        }
        sortSavedCustomExercises()
        persistPracticeData()
    }

    func deleteSavedCustomExercise(id: UUID) {
        guard !practicePhase.isActive,
              let saved = savedCustomExercises.first(where: { $0.id == id }) else { return }
        savedCustomExercises.removeAll { $0.id == id }
        if selectedSavedCustomExerciseID == id { selectedSavedCustomExerciseID = nil }
        practiceDataStatusMessage = "Deleted \(saved.definition.displayName)."
        persistPracticeData()
    }

    func importStandardMIDI(_ data: Data, filename: String) throws {
        guard !practicePhase.isActive else { return }
        guard data.count <= 100_000_000 else {
            throw PracticeDataPersistenceError.invalidArchive("The MIDI file is larger than 100 MB.")
        }
        let song = try StandardMIDIFileParser().parse(data: data, filename: filename)
        importedSongs.append(song)
        sortImportedSongs()
        selectedImportedSongID = song.id
        practiceExerciseMode = .importedSong
        configureSelectedImportedSong(resetSection: true)
        practiceDataStatusMessage = "Imported \(song.displayName). Review the track and drum mappings before practicing."
        persistPracticeData()
    }

    func loadImportedSong(id: UUID) {
        guard !practicePhase.isActive, importedSongs.contains(where: { $0.id == id }) else { return }
        selectedImportedSongID = id
        practiceExerciseMode = .importedSong
        configureSelectedImportedSong(resetSection: true)
        if let song = selectedImportedSong {
            practiceDataStatusMessage = "Loaded \(song.displayName)."
        }
    }

    func deleteImportedSong(id: UUID) {
        guard !practicePhase.isActive,
              let song = importedSongs.first(where: { $0.id == id }) else { return }
        importedSongs.removeAll { $0.id == id }
        if selectedImportedSongID == id {
            selectedImportedSongID = importedSongs.first?.id
            configureSelectedImportedSong(resetSection: true)
        }
        practiceDataStatusMessage = "Deleted \(song.displayName). Existing session history is kept."
        persistPracticeData()
    }

    func renameSelectedImportedSong(_ name: String) {
        updateSelectedImportedSong { song in
            song.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            song.updatedAt = Date()
        }
    }

    func selectImportedTrack(_ trackIndex: Int) {
        updateSelectedImportedSong { song in
            guard song.tracks.contains(where: { $0.index == trackIndex }) else { return }
            song.selectedTrackIndex = trackIndex
            let notes = song.tracks.first { $0.index == trackIndex }?.notes ?? []
            song.noteMappings = Set(notes.map(\.noteNumber)).sorted().map {
                ImportedMIDINoteMapping(noteNumber: $0, voice: GeneralMIDIDrumMap.voice(for: $0))
            }
            song.updatedAt = Date()
        }
        configureSelectedImportedSong(resetSection: true)
    }

    func mapImportedMIDINote(_ noteNumber: UInt8, to voice: DrumVoice) {
        updateSelectedImportedSong { song in song.setVoice(voice, for: noteNumber) }
    }

    func setImportedSection(start: Int? = nil, end: Int? = nil, repeats: Int? = nil) {
        let count = max(importedSongMeasureCount, 1)
        if let start { importedSectionStartMeasure = min(max(start, 1), count) }
        if let end { importedSectionEndMeasure = min(max(end, 1), count) }
        if importedSectionEndMeasure < importedSectionStartMeasure {
            if start != nil { importedSectionEndMeasure = importedSectionStartMeasure }
            else { importedSectionStartMeasure = importedSectionEndMeasure }
        }
        if let repeats { importedSectionRepeats = min(max(repeats, 1), 32) }
        practiceMeasures = (importedSectionEndMeasure - importedSectionStartMeasure + 1) * importedSectionRepeats
    }

    func deletePracticeSession(id: UUID) {
        practiceHistory.removeAll { $0.id == id }
        practiceSessionRecords.removeAll { $0.id == id }
        if var run = activeCeilingRun {
            run.sessionIDs.removeAll { $0 == id }
            activeCeilingRun = run
        }
        persistPracticeData()
    }

    func clearPracticeHistory() {
        practiceHistory = []
        practiceSessionRecords = []
        tempoProgressions = []
        activeCeilingRun = nil
        ceilingRecords = []
        lastCeilingMessage = nil
        practiceDataStatusMessage = "Cleared practice history."
        persistPracticeData()
    }

    func practiceSessionRecord(id: UUID) -> PracticeSessionRecord? {
        practiceSessionRecords.first { $0.id == id }
    }

    func updatePracticeSessionMetadata(id: UUID, notes: String, tags: [String]) {
        guard let index = practiceSessionRecords.firstIndex(where: { $0.id == id }) else { return }
        practiceSessionRecords[index].updateMetadata(notes: notes, tags: tags)
        practiceDataStatusMessage = "Saved session notes and tags."
        persistPracticeData()
    }

    func rescorePracticeSession(id: UUID) {
        guard let recordIndex = practiceSessionRecords.firstIndex(where: { $0.id == id }) else {
            practiceDataStatusMessage = "This legacy summary does not contain events to rescore."
            return
        }
        practiceSessionRecords[recordIndex].rescore(matcher: currentEventMatcher)
        let updatedSummary = practiceSessionRecords[recordIndex].summary
        if let summaryIndex = practiceHistory.firstIndex(where: { $0.id == id }) {
            practiceHistory[summaryIndex] = updatedSummary
        } else {
            practiceHistory.append(updatedSummary)
        }
        practiceHistory.sort { $0.completedAt > $1.completedAt }
        practiceDataStatusMessage = "Rescored \(updatedSummary.exerciseName) from its saved events."
        persistPracticeData()
    }

    func exportPracticeData() throws -> Data {
        try currentPracticeDataArchive().encodedJSON(prettyPrinted: true)
    }

    func importPracticeData(_ data: Data) throws {
        guard data.count <= 250_000_000 else {
            throw PracticeDataPersistenceError.invalidArchive("The import is larger than 250 MB.")
        }
        let imported = try PracticeDataArchive.decodeAndValidate(data)

        var exercisesByID = Dictionary(uniqueKeysWithValues: savedCustomExercises.map { ($0.id, $0) })
        for exercise in imported.customExercises {
            if let existing = exercisesByID[exercise.id], existing.updatedAt > exercise.updatedAt { continue }
            exercisesByID[exercise.id] = exercise
        }
        var songsByID = Dictionary(uniqueKeysWithValues: importedSongs.map { ($0.id, $0) })
        for song in imported.importedSongs {
            if let existing = songsByID[song.id], existing.updatedAt > song.updatedAt { continue }
            songsByID[song.id] = song
        }

        var recordsByID = Dictionary(uniqueKeysWithValues: practiceSessionRecords.map { ($0.id, $0) })
        for record in imported.sessionRecords { recordsByID[record.id] = record }

        var summariesByID = Dictionary(uniqueKeysWithValues: practiceHistory.map { ($0.id, $0) })
        for summary in imported.sessions { summariesByID[summary.id] = summary }
        for record in recordsByID.values { summariesByID[record.id] = record.summary }

        var progressionsByID = Dictionary(uniqueKeysWithValues: tempoProgressions.map { ($0.id, $0) })
        for progression in imported.tempoProgressions {
            if let existing = progressionsByID[progression.id], existing.updatedAt > progression.updatedAt { continue }
            progressionsByID[progression.id] = progression
        }
        var ceilingsByID = Dictionary(uniqueKeysWithValues: ceilingRecords.map { ($0.id, $0) })
        for ceiling in imported.ceilingRecords {
            if let existing = ceilingsByID[ceiling.id],
               existing.highestVerifiedBPM > ceiling.highestVerifiedBPM
                    || (existing.highestVerifiedBPM == ceiling.highestVerifiedBPM
                        && existing.achievedAt > ceiling.achievedAt) { continue }
            ceilingsByID[ceiling.id] = ceiling
        }

        savedCustomExercises = Array(exercisesByID.values)
        sortSavedCustomExercises()
        importedSongs = Array(songsByID.values)
        sortImportedSongs()
        practiceSessionRecords = recordsByID.values.sorted { $0.summary.completedAt > $1.summary.completedAt }
        practiceHistory = summariesByID.values.sorted { $0.completedAt > $1.completedAt }
        tempoProgressions = progressionsByID.values.sorted { $0.updatedAt > $1.updatedAt }
        tempoProgressionSettings = imported.tempoProgressionSettings
        ceilingRecords = ceilingsByID.values.sorted { $0.achievedAt > $1.achievedAt }
        ceilingModeSettings = imported.ceilingModeSettings
        if let importedRun = imported.activeCeilingRun,
           activeCeilingRun == nil
                || importedRun.updatedAt > (activeCeilingRun?.updatedAt ?? .distantPast) {
            activeCeilingRun = importedRun
        }
        practiceDataStatusMessage = "Imported \(imported.sessions.count) sessions, \(imported.customExercises.count) custom exercises, and \(imported.importedSongs.count) songs."
        persistPracticeData()
    }

    func saveTempoProgressionSettings() {
        tempoProgressionSettings = TempoProgressionSettings(
            isEnabled: tempoProgressionSettings.isEnabled,
            stepBPM: tempoProgressionSettings.stepBPM,
            requiredCleanSessions: tempoProgressionSettings.requiredCleanSessions
        )
        if tempoProgressionSettings.isEnabled {
            ceilingModeSettings.isEnabled = false
        }
        practiceDataStatusMessage = tempoProgressionSettings.isEnabled
            ? "Automatic tempo progression is on."
            : "Automatic tempo progression is off."
        persistPracticeData()
    }

    func saveCeilingModeSettings() {
        ceilingModeSettings = CeilingModeSettings(
            isEnabled: ceilingModeSettings.isEnabled,
            stepBPM: ceilingModeSettings.stepBPM
        )
        if ceilingModeSettings.isEnabled {
            tempoProgressionSettings.isEnabled = false
            practiceDataStatusMessage = "Find My Ceiling is on for the selected exercise."
        } else {
            practiceDataStatusMessage = "Find My Ceiling is off."
        }
        persistPracticeData()
    }

    func resetCeilingRun() {
        activeCeilingRun = nil
        lastCeilingMessage = nil
        practiceDataStatusMessage = "Reset the active ceiling search."
        persistPracticeData()
    }

    func continueCeilingRun() {
        guard ceilingModeSettings.isEnabled else { return }
        dismissPracticeResults()
        startPractice()
    }

    func startMicrophoneCalibration() {
        if timingAlignmentPhase.isActive { cancelTimingAlignment() }
        guard let selectedAudioInputID,
              audioDevices.contains(where: { $0.id == selectedAudioInputID }) else {
            microphoneCalibrationPhase = .error("Choose and start monitoring a microphone before calibration.")
            return
        }

        if practicePhase.isActive { cancelPractice() }
        stopSimulation()
        calibrationTask?.cancel()
        microphoneCalibrationPhase = .preparingInput
        let startingSampleSequence = microphoneLevelSampleSequence
        audioInputService.select(deviceID: selectedAudioInputID)

        calibrationTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<120 {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      microphoneCalibrationPhase == .preparingInput else { return }
                if audioStatus.isMonitoring,
                   microphoneLevelSampleSequence >= startingSampleSequence &+ 3 {
                    calibrationTask = nil
                    beginMicrophoneCalibrationCollection()
                    return
                }
                if microphonePermission == .denied || microphonePermission == .restricted {
                    calibrationTask = nil
                    microphoneCalibrationPhase = .error(audioStatus.message)
                    return
                }
            }

            calibrationTask = nil
            microphoneCalibrationPhase = .error(
                audioStatus.isMonitoring
                    ? "Blue Snowball opened, but no audio samples arrived. Unplug and reconnect it, then retry."
                    : "Could not start the selected microphone. (audioStatus.message)"
            )
        }
    }

    private func beginMicrophoneCalibrationCollection() {
        preCalibrationConfiguration = currentKickConfiguration
        calibrationNoiseSamples = []
        calibrationHitCollector = MicrophoneCalibrationHitCollector(
            initialLockoutMilliseconds: retriggerLockoutMilliseconds
        )
        calibrationSuppressedTransientCount = 0
        calibrationNoiseEstimate = nil
        microphoneCalibrationPhase = .samplingNoise(secondsRemaining: 3)

        calibrationTask = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: 2, through: 0, by: -1) {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if remaining > 0 {
                    microphoneCalibrationPhase = .samplingNoise(secondsRemaining: remaining)
                } else {
                    finishNoiseSampling()
                }
            }
        }
    }

    func cancelMicrophoneCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        if let previous = preCalibrationConfiguration {
            kickThreshold = previous.threshold
            retriggerLockoutMilliseconds = previous.retriggerLockoutMilliseconds
        }
        preCalibrationConfiguration = nil
        calibrationNoiseSamples = []
        calibrationHitCollector = MicrophoneCalibrationHitCollector(
            initialLockoutMilliseconds: retriggerLockoutMilliseconds
        )
        calibrationSuppressedTransientCount = 0
        calibrationNoiseEstimate = nil
        microphoneCalibrationPhase = .idle
    }

    func saveMicrophoneCalibration() {
        guard case let .review(profile) = microphoneCalibrationPhase else { return }
        let adjustedProfile = MicrophoneCalibrationProfile(
            id: profile.id,
            deviceUID: profile.deviceUID,
            deviceName: profile.deviceName,
            createdAt: profile.createdAt,
            noiseFloor: profile.noiseFloor,
            noisePercentile95: profile.noisePercentile95,
            suggestedThreshold: kickThreshold,
            retriggerLockoutMilliseconds: retriggerLockoutMilliseconds,
            detectedHitCount: profile.detectedHitCount,
            weakestHitAmplitude: profile.weakestHitAmplitude,
            medianHitAmplitude: profile.medianHitAmplitude,
            signalToNoiseDecibels: profile.signalToNoiseDecibels,
            quality: profile.quality,
            kickSoundSignature: profile.kickSoundSignature
        )
        microphoneCalibrationStore.saveProfile(adjustedProfile)
        activeMicrophoneCalibrationProfile = adjustedProfile
        preCalibrationConfiguration = nil
        microphoneCalibrationPhase = .saved(adjustedProfile)
    }

    func dismissMicrophoneCalibrationStatus() {
        guard !microphoneCalibrationPhase.isActive else { return }
        if case .error = microphoneCalibrationPhase {
            cancelMicrophoneCalibration()
            return
        }
        microphoneCalibrationPhase = .idle
    }

    func deleteActiveMicrophoneCalibration() {
        guard let device = selectedAudioInputDevice else { return }
        microphoneCalibrationStore.deleteProfile(deviceUID: device.uid)
        activeMicrophoneCalibrationProfile = nil
    }

    var activeTimingAlignmentProfile: TimingAlignmentProfile? {
        guard let identity = currentTimingAlignmentIdentity(for: timingAlignmentSource) else { return nil }
        let key = TimingAlignmentProfile.key(
            source: timingAlignmentSource,
            inputID: identity.inputID,
            outputUID: identity.outputUID
        )
        return timingAlignmentProfiles.first { $0.key == key }
    }

    func startTimingAlignment() {
        guard !isRefreshingAudioEngine else { return }
        guard !practicePhase.isActive, !microphoneCalibrationPhase.isActive else {
            timingAlignmentPhase = .error("Finish the active practice or microphone calibration first.")
            return
        }
        guard currentTimingAlignmentIdentity(for: timingAlignmentSource) != nil else {
            timingAlignmentPhase = .error(
                timingAlignmentSource == .midi
                    ? "Choose an e-kit MIDI input first."
                    : "Choose a microphone input first."
            )
            return
        }
        if timingAlignmentSource == .microphone, !audioStatus.isMonitoring {
            timingAlignmentPhase = .error("Start microphone monitoring before timing alignment.")
            return
        }

        stopSimulation()
        activeAudioFlowGeneration &+= 1
        audioEngineRecoveryMessage = nil
        timingAlignmentFinishTask?.cancel()
        timingAlignmentFinishTask = nil
        timingAlignmentStartWatchdogTask?.cancel()
        let voice = timingAlignmentSource == .microphone ? DrumVoice.kick : timingAlignmentVoice
        timingAlignmentCollector = TimingAlignmentCollector(
            source: timingAlignmentSource.eventSource,
            voice: voice
        )
        metronomeStallRecoveryAttempts = 0
        beginTimingAlignmentMetronomeStart()
    }

    private func beginTimingAlignmentMetronomeStart() {
        let flowGeneration = activeAudioFlowGeneration
        timingAlignmentPhase = .starting
        metronomeEngine.start(bpm: 60)
        timingAlignmentStartWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.activeAudioFlowGeneration == flowGeneration,
                  self.timingAlignmentPhase == .starting else { return }
            self.timingAlignmentStartWatchdogTask = nil
            self.timingAlignmentPhase = .error(
                "The click did not start. Check the selected output, then retry."
            )
            self.metronomeEngine.stop()
        }
    }

    func cancelTimingAlignment() {
        activeAudioFlowGeneration &+= 1
        cancelMetronomeHeartbeat()
        timingAlignmentStartWatchdogTask?.cancel()
        timingAlignmentStartWatchdogTask = nil
        timingAlignmentFinishTask?.cancel()
        timingAlignmentFinishTask = nil
        timingAlignmentCollector = TimingAlignmentCollector(source: .midi, voice: .snare)
        timingAlignmentPhase = .idle
        metronomeEngine.stop()
    }

    func saveTimingAlignment() {
        guard case let .review(profile) = timingAlignmentPhase else { return }
        timingAlignmentStore.saveProfile(profile)
        timingAlignmentProfiles.removeAll { $0.key == profile.key }
        timingAlignmentProfiles.append(profile)
        timingAlignmentProfiles.sort { $0.createdAt > $1.createdAt }
        timingAlignmentPhase = .saved(profile)
    }

    func deleteActiveTimingAlignment() {
        guard let profile = activeTimingAlignmentProfile else { return }
        timingAlignmentStore.deleteProfile(key: profile.key)
        timingAlignmentProfiles.removeAll { $0.key == profile.key }
        timingAlignmentPhase = .idle
    }

    func dismissTimingAlignmentStatus() {
        guard !timingAlignmentPhase.isActive else { return }
        timingAlignmentPhase = .idle
    }

    func startHardwareMonitoring() {
        if !hasStartedHardwareMonitoring {
            hasStartedHardwareMonitoring = true
            midiInputService.start()
            audioInputService.start()
            metronomeEngine.startMonitoring()
            if selectedAudioInputID == nil {
                audioStatus = .ready
            }
        }
        ensureSelectedAudioInputIsMonitoring()
    }

    func restartSelectedAudioInputMonitoring() {
        guard let selectedAudioInputID else { return }
        if microphoneCalibrationPhase.isActive {
            cancelMicrophoneCalibration()
        }
        if let device = audioDevices.first(where: { $0.id == selectedAudioInputID }) {
            audioStatus = .starting(device.name)
        }
        audioInputService.select(deviceID: selectedAudioInputID)
    }

    private func ensureSelectedAudioInputIsMonitoring() {
        guard let selectedAudioInputID,
              !audioStatus.isMonitoring,
              !audioStatus.isStarting else { return }
        audioInputService.select(deviceID: selectedAudioInputID)
    }

    func selectMIDIInput(_ deviceID: MIDIUniqueID?) {
        if timingAlignmentPhase.isActive { cancelTimingAlignment() }
        if deviceID != nil { stopSimulation() }
        microphoneCrosstalkGuard.reset()
        selectedMIDIInputID = deviceID
        midiMapping = deviceID.map { midiMappingStore.loadMapping(for: $0) } ?? [:]
        lastMIDINote = nil
        lastMIDIVelocity = nil
        midiMappingVoice = .unknown
        midiInputService.select(deviceID: deviceID)
    }

    func saveMappingForLastMIDINote() {
        guard let deviceID = selectedMIDIInputID, let note = lastMIDINote else { return }
        midiMapping[note] = midiMappingVoice
        midiMappingStore.saveMapping(midiMapping, for: deviceID)
    }

    func resetMappingForLastMIDINote() {
        guard let deviceID = selectedMIDIInputID, let note = lastMIDINote else { return }
        midiMapping.removeValue(forKey: note)
        midiMappingStore.saveMapping(midiMapping, for: deviceID)
        midiMappingVoice = MIDINoteMapper().voice(for: note)
    }

    func requestMicrophoneAccess() {
        audioInputService.requestPermission()
    }

    func openMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func selectAudioInput(_ deviceID: AudioDeviceID?) {
        if microphoneCalibrationPhase.isActive { cancelMicrophoneCalibration() }
        if timingAlignmentPhase.isActive { cancelTimingAlignment() }
        if deviceID != nil { stopSimulation() }
        microphoneCrosstalkGuard.reset()
        suppressedMicrophoneCrosstalkCount = 0
        rejectedNonKickSoundCount = 0
        lastKickSoundSimilarity = nil
        selectedAudioInputID = deviceID
        if let device = audioDevices.first(where: { $0.id == deviceID }),
           let profile = microphoneCalibrationStore.loadProfile(deviceUID: device.uid) {
            activeMicrophoneCalibrationProfile = profile
            kickThreshold = profile.suggestedThreshold
            retriggerLockoutMilliseconds = profile.retriggerLockoutMilliseconds
        } else {
            activeMicrophoneCalibrationProfile = nil
        }
        audioInputService.select(deviceID: deviceID)
    }

    func selectAudioOutput(_ deviceID: AudioDeviceID?) {
        if timingAlignmentPhase.isActive { cancelTimingAlignment() }
        selectedAudioOutputID = deviceID
        metronomeEngine.select(deviceID: deviceID)
    }

    func refreshAudioEngine(retryActiveFlow: Bool = true) {
        refreshAudioEngine(
            retryActiveFlow: retryActiveFlow,
            preserveAutomaticRecoveryAttempt: false
        )
    }

    func refreshAudioEngineAndRetryPractice() {
        if !practicePhase.isActive {
            practicePhase = .countIn(beatsRemaining: Self.countInBeats)
        }
        refreshAudioEngine(retryActiveFlow: true)
    }

    func refreshAudioEngineAndRetryTimingAlignment() {
        if !timingAlignmentPhase.isActive {
            timingAlignmentPhase = .starting
        }
        refreshAudioEngine(retryActiveFlow: true)
    }

    private func refreshAudioEngine(
        retryActiveFlow: Bool,
        preserveAutomaticRecoveryAttempt: Bool
    ) {
        guard !isRefreshingAudioEngine else { return }
        let retryPractice = retryActiveFlow && practicePhase.isActive
        let retryTimingAlignment = retryActiveFlow && timingAlignmentPhase.isActive

        activeAudioFlowGeneration &+= 1
        let refreshGeneration = activeAudioFlowGeneration
        isRefreshingAudioEngine = true
        audioEngineRecoveryMessage = "Rebuilding the click audio engine…"
        cancelMetronomeHeartbeat()
        practiceFinishTask?.cancel()
        practiceFinishTask = nil
        timingAlignmentStartWatchdogTask?.cancel()
        timingAlignmentStartWatchdogTask = nil
        timingAlignmentFinishTask?.cancel()
        timingAlignmentFinishTask = nil

        if practicePhase.isActive {
            practiceRecording = nil
            pendingPracticeBounds = nil
            practiceActivePattern = nil
            practiceExpectedEvents = []
            practiceOutcome = nil
            practiceRecordedHitCount = 0
            practicePhase = .idle
        }
        if timingAlignmentPhase.isActive {
            timingAlignmentCollector = TimingAlignmentCollector(source: .midi, voice: .snare)
            timingAlignmentPhase = .idle
        }

        metronomeEngine.rebuildAudioGraph { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeAudioFlowGeneration == refreshGeneration else { return }
                self.isRefreshingAudioEngine = false
                self.audioEngineRecoveryMessage = "Click audio refreshed."
                if retryPractice {
                    self.startPractice()
                    if preserveAutomaticRecoveryAttempt {
                        self.metronomeStallRecoveryAttempts = 1
                    }
                } else if retryTimingAlignment {
                    self.startTimingAlignment()
                    if preserveAutomaticRecoveryAttempt {
                        self.metronomeStallRecoveryAttempts = 1
                    }
                }
            }
        }
    }

    func toggleMetronome() {
        if timingAlignmentPhase.isActive {
            cancelTimingAlignment()
            return
        }
        if practicePhase.isActive {
            cancelPractice()
            return
        }
        if isMetronomeRunning {
            metronomeEngine.stop()
        } else {
            stopSimulation()
            metronomeEngine.start(bpm: metronomeBPM)
        }
    }

    func clearEvents() {
        events.removeAll(keepingCapacity: true)
        suppressedMicrophoneCrosstalkCount = 0
        rejectedNonKickSoundCount = 0
        lastKickSoundSimilarity = nil
        microphoneCrosstalkGuard.reset()
        Task {
            let snapshot = await eventStream.clear()
            droppedEventCount = snapshot.droppedCount
        }
    }

    private func startSimulation() {
        guard simulationTask == nil else { return }
        if practicePhase.isActive { cancelPractice() }
        if isMetronomeRunning { metronomeEngine.stop() }
        isSimulationRunning = true

        simulationTask = Task { [weak self] in
            guard let self else { return }
            var step = 0

            while !Task.isCancelled {
                let hostTime = clock.currentHostTime()
                let source: EventSource
                let voice: DrumVoice
                let velocity: Double?
                let confidence: Double
                let metadata: EventMetadata

                switch step % 4 {
                case 0:
                    source = .metronome
                    voice = .metronome
                    velocity = nil
                    confidence = 1
                    metadata = .metronome(beat: (step / 4) % 4 + 1, subdivision: 0)
                case 1:
                    source = .midi
                    voice = .snare
                    velocity = 104.0 / 127.0
                    confidence = 1
                    metadata = .midi(channel: 10, note: 38, velocity: 104, endpointName: "Simulated e-kit")
                case 2:
                    source = .microphone
                    voice = .kick
                    velocity = nil
                    confidence = 0.94
                    metadata = .microphone(amplitude: 0.82, threshold: 0.45, frameOffset: 126)
                default:
                    source = .midi
                    voice = .closedHiHat
                    velocity = 88.0 / 127.0
                    confidence = 1
                    metadata = .midi(channel: 10, note: 42, velocity: 88, endpointName: "Simulated e-kit")
                }

                let event = timeline.makeEvent(
                    source: source,
                    voice: voice,
                    hostTime: hostTime,
                    velocity: velocity,
                    confidence: confidence,
                    metadata: metadata
                )
                await publish(event)

                let level = source == .microphone ? 0.82 : Double.random(in: 0.04...0.16)
                recentLevels.append(level)
                if recentLevels.count > 80 { recentLevels.removeFirst(recentLevels.count - 80) }

                step += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
        isSimulationRunning = false
    }

    private func publish(_ event: PerformanceEvent) async {
        if isCollectingCalibration {
            collectCalibrationHitIfNeeded(event)
        } else if shouldSuppressAsNonKickSound(event) {
            rejectedNonKickSoundCount += 1
            return
        }
        if shouldSuppressAsMIDICrosstalk(event) {
            suppressedMicrophoneCrosstalkCount += 1
            return
        }
        if !isCollectingCalibration {
            collectCalibrationHitIfNeeded(event)
        }
        practiceRecording?.record(event)
        practiceRecordedHitCount = practiceRecording?.actualEvents.count ?? practiceRecordedHitCount
        let snapshot = await eventStream.append(event)
        events = snapshot.events
        droppedEventCount = snapshot.droppedCount
    }

    private func publishMicrophoneEvent(_ event: PerformanceEvent) async {
        collectTimingAlignmentEvent(event)
        if midiCrosstalkSuppressionEnabled {
            let graceMilliseconds = microphoneCrosstalkGuard.configuration.midiArrivalGraceMilliseconds
            do {
                try await Task.sleep(for: .milliseconds(Int64(graceMilliseconds.rounded())))
            } catch {
                return
            }
        }
        await publish(event)
    }

    private func publishMIDI(_ note: MIDINoteOn, endpointName: String) async {
        let hostTime = note.hostTime == 0 ? clock.currentHostTime() : note.hostTime
        let voice = MIDINoteMapper(overrides: midiMapping).voice(for: note.note)
        lastMIDINote = note.note
        lastMIDIVelocity = note.velocity
        midiMappingVoice = voice
        let event = timeline.makeEvent(
            source: .midi,
            voice: voice,
            hostTime: hostTime,
            velocity: Double(note.velocity) / 127,
            metadata: .midi(
                channel: note.channel,
                note: note.note,
                velocity: note.velocity,
                endpointName: endpointName
            )
        )
        collectTimingAlignmentEvent(event)
        microphoneCrosstalkGuard.observeMIDIHit(
            voice: voice,
            sessionTimeNanoseconds: event.sessionTimeNanoseconds
        )
        await publish(event)
    }

    private func publishMetronomeTick(_ tick: MetronomeTick) async {
        let event = timeline.makeEvent(
            source: .metronome,
            voice: .metronome,
            hostTime: tick.hostTime,
            confidence: 1,
            metadata: .metronome(beat: tick.beat, subdivision: 0)
        )
        await publish(event)
        recordMetronomeHeartbeat()
        handleTimingAlignmentTick(tick)
        handlePracticeTick(tick)
    }

    private func handleTimingAlignmentTick(_ tick: MetronomeTick) {
        switch timingAlignmentPhase {
        case let .countIn(beatsRemaining):
            if beatsRemaining > 1 {
                timingAlignmentPhase = .countIn(beatsRemaining: beatsRemaining - 1)
            } else {
                timingAlignmentPhase = .collecting(referenceCount: 0, target: 12, detectedHits: 0)
            }

        case let .collecting(referenceCount, target, _):
            let referenceTime = timeline.sessionTimeNanoseconds(for: tick.hostTime)
            timingAlignmentCollector.recordReference(referenceTime)
            let newCount = referenceCount + 1
            timingAlignmentPhase = .collecting(
                referenceCount: newCount,
                target: target,
                detectedHits: timingAlignmentCollector.events.count
            )
            guard newCount >= target else { return }
            timingAlignmentFinishTask?.cancel()
            let flowGeneration = activeAudioFlowGeneration
            timingAlignmentFinishTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(600))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self,
                      self.activeAudioFlowGeneration == flowGeneration else { return }
                self.finishTimingAlignment()
            }

        case .idle, .starting, .review, .saved, .error:
            break
        }
    }

    func handleTimingAlignmentMetronomeStatus(_ status: MetronomeStatus) {
        switch status {
        case .running:
            guard timingAlignmentPhase == .starting else { return }
            timingAlignmentStartWatchdogTask?.cancel()
            timingAlignmentStartWatchdogTask = nil
            timingAlignmentPhase = .countIn(beatsRemaining: Self.countInBeats)
            scheduleMetronomeHeartbeat()

        case let .error(message):
            guard timingAlignmentPhase.isActive else { return }
            timingAlignmentStartWatchdogTask?.cancel()
            timingAlignmentStartWatchdogTask = nil
            timingAlignmentFinishTask?.cancel()
            timingAlignmentFinishTask = nil
            cancelMetronomeHeartbeat()
            timingAlignmentPhase = .error(message)

        case let .disconnected(name):
            guard timingAlignmentPhase.isActive else { return }
            timingAlignmentStartWatchdogTask?.cancel()
            timingAlignmentStartWatchdogTask = nil
            timingAlignmentFinishTask?.cancel()
            timingAlignmentFinishTask = nil
            cancelMetronomeHeartbeat()
            timingAlignmentPhase = .error("\(name) disconnected. Choose an available output and retry.")

        case .stopped, .ready:
            break
        }
    }

    private func recordMetronomeHeartbeat() {
        let isWaitingForTicks: Bool
        switch timingAlignmentPhase {
        case .countIn, .collecting:
            isWaitingForTicks = true
        case .idle, .starting, .review, .saved, .error:
            if case .countIn = practicePhase {
                isWaitingForTicks = true
            } else {
                isWaitingForTicks = false
            }
        }
        guard isWaitingForTicks else { return }
        scheduleMetronomeHeartbeat()
    }

    private func scheduleMetronomeHeartbeat() {
        metronomeHeartbeatTask?.cancel()
        let flowGeneration = activeAudioFlowGeneration
        metronomeHeartbeatTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.activeAudioFlowGeneration == flowGeneration else { return }
            self.metronomeHeartbeatTask = nil
            self.recoverFromMetronomeStall()
        }
    }

    private func cancelMetronomeHeartbeat() {
        metronomeHeartbeatTask?.cancel()
        metronomeHeartbeatTask = nil
    }

    private func recoverFromMetronomeStall() {
        if timingAlignmentPhase.isActive {
            if metronomeStallRecoveryAttempts == 0 {
                metronomeStallRecoveryAttempts = 1
                refreshAudioEngine(
                    retryActiveFlow: true,
                    preserveAutomaticRecoveryAttempt: true
                )
            } else {
                timingAlignmentStartWatchdogTask?.cancel()
                timingAlignmentStartWatchdogTask = nil
                timingAlignmentFinishTask?.cancel()
                timingAlignmentFinishTask = nil
                timingAlignmentPhase = .error(
                    "The click stopped during count-in. The audio engine restarted once but stalled again. Re-select the output and retry."
                )
                metronomeEngine.stop()
            }
            return
        }

        guard case .countIn = practicePhase else { return }
        if metronomeStallRecoveryAttempts == 0 {
            metronomeStallRecoveryAttempts = 1
            refreshAudioEngine(
                retryActiveFlow: true,
                preserveAutomaticRecoveryAttempt: true
            )
        } else {
            practicePhase = .error(
                "The click stopped during count-in. The audio engine restarted once but stalled again. Re-select the output and retry."
            )
            metronomeEngine.stop()
        }
    }

    private func collectTimingAlignmentEvent(_ event: PerformanceEvent) {
        guard case let .collecting(referenceCount, target, _) = timingAlignmentPhase else { return }
        timingAlignmentCollector.record(event)
        timingAlignmentPhase = .collecting(
            referenceCount: referenceCount,
            target: target,
            detectedHits: timingAlignmentCollector.events.count
        )
    }

    private func finishTimingAlignment() {
        cancelMetronomeHeartbeat()
        timingAlignmentStartWatchdogTask?.cancel()
        timingAlignmentStartWatchdogTask = nil
        timingAlignmentFinishTask = nil
        metronomeEngine.stop()
        guard let measurement = timingAlignmentCollector.measurement(),
              measurement.sampleCount >= 8 else {
            timingAlignmentPhase = .error(
                "Not enough matching hits were detected. Play the selected drum once on each click, then retry."
            )
            return
        }
        guard let identity = currentTimingAlignmentIdentity(for: timingAlignmentSource) else {
            timingAlignmentPhase = .error("The selected input or output changed during alignment.")
            return
        }

        let correction = min(max(measurement.compensationMilliseconds, -250), 250)
        let profile = TimingAlignmentProfile(
            id: UUID(),
            source: timingAlignmentSource,
            inputID: identity.inputID,
            inputName: identity.inputName,
            outputUID: identity.outputUID,
            outputName: identity.outputName,
            voice: timingAlignmentSource == .microphone ? .kick : timingAlignmentVoice,
            compensationMilliseconds: correction,
            medianAbsoluteDeviationMilliseconds: measurement.medianAbsoluteDeviationMilliseconds,
            sampleCount: measurement.sampleCount,
            createdAt: Date()
        )
        timingAlignmentPhase = .review(profile)
    }

    private func handlePracticeTick(_ tick: MetronomeTick) {
        guard case let .countIn(beatsRemaining) = practicePhase else { return }
        if let pendingPracticeBounds {
            cancelMetronomeHeartbeat()
            practicePhase = .running(
                startSessionTime: pendingPracticeBounds.startSessionTime,
                endSessionTime: pendingPracticeBounds.endSessionTime
            )
            self.pendingPracticeBounds = nil
            return
        }
        guard beatsRemaining <= 1 else {
            practicePhase = .countIn(beatsRemaining: beatsRemaining - 1)
            return
        }

        do {
            let beatNanoseconds = MetronomeTimeline.intervalNanoseconds(bpm: practiceBPM)
            let startHostTime = timeline.hostTime(addingNanoseconds: beatNanoseconds, to: tick.hostTime)
            let startSessionTime = timeline.sessionTimeNanoseconds(for: startHostTime)
            let pattern = try makePracticePattern(
                bpm: practiceBPM,
                startSessionTimeNanoseconds: startSessionTime,
                startHostTime: startHostTime
            )
            let durationNanoseconds = UInt64(max(pattern.exactDurationNanoseconds, 0))
            let endSessionTime = addingWithoutOverflow(startSessionTime, pattern.exactDurationNanoseconds)

            if practiceExerciseMode == .importedSong,
               let referenceBeats = pattern.referenceBeats,
               !referenceBeats.isEmpty {
                metronomeEngine.followTempoMap(
                    startPresentationHostTime: startHostTime,
                    referenceBeats: referenceBeats
                )
            }

            practiceExpectedEvents = pattern.expectedEvents
            practiceActivePattern = pattern
            practiceRecording = PracticeSessionRecording(
                pattern: pattern,
                exerciseEndSessionTimeNanoseconds: endSessionTime
            )
            pendingPracticeBounds = (startSessionTime, endSessionTime)
            practicePhase = .countIn(beatsRemaining: 0)

            let toleranceNanoseconds = UInt64(pattern.expectedEvents
                .map(\.matchingToleranceNanoseconds)
                .max() ?? 0)
            schedulePracticeFinish(
                at: timeline.hostTime(
                    addingNanoseconds: durationNanoseconds + toleranceNanoseconds,
                    to: startHostTime
                )
            )
        } catch {
            cancelMetronomeHeartbeat()
            pendingPracticeBounds = nil
            practicePhase = .error(error.localizedDescription)
            metronomeEngine.stop()
        }
    }

    private func schedulePracticeFinish(at targetHostTime: UInt64) {
        practiceFinishTask?.cancel()
        let flowGeneration = activeAudioFlowGeneration
        practiceFinishTask = Task { [weak self] in
            guard let self else { return }
            let now = clock.currentHostTime()
            let delayNanoseconds = targetHostTime > now
                ? timeline.converter.nanoseconds(forHostTimeDuration: targetHostTime - now)
                : 0
            do {
                try await Task.sleep(for: .nanoseconds(Int64(min(delayNanoseconds, UInt64(Int64.max)))))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  activeAudioFlowGeneration == flowGeneration else { return }
            finishPractice()
        }
    }

    private func finishPractice() {
        cancelMetronomeHeartbeat()
        guard practicePhase.isActive, let practiceRecording else { return }
        let outcome = practiceRecording.finish(matcher: currentEventMatcher)
        practiceOutcome = outcome
        let summary = PracticeSessionSummary(
            outcome: outcome,
            exerciseKind: currentExerciseIdentity.kind,
            customExerciseID: currentExerciseIdentity.customExerciseID,
            importedSongID: practiceExerciseMode == .importedSong ? selectedImportedSongID : nil
        )
        practiceHistory.insert(summary, at: 0)
        practiceSessionRecords.insert(PracticeSessionRecord(
            summary: summary,
            outcome: outcome,
            deviceContext: currentPracticeDeviceContext
        ), at: 0)
        if practiceHistory.count > 2_000 {
            practiceHistory.removeLast(practiceHistory.count - 2_000)
            let retainedIDs = Set(practiceHistory.map(\.id))
            practiceSessionRecords.removeAll { !retainedIDs.contains($0.id) }
        }
        updateTempoProgression(after: summary)
        updateCeilingRun(after: summary)
        persistPracticeData()
        self.practiceRecording = nil
        pendingPracticeBounds = nil
        practiceFinishTask = nil
        practicePhase = .results
        metronomeEngine.stop()
    }

    private func exerciseDurationNanoseconds(
        bpm: Double,
        measures: Int,
        beatsPerMeasure: Int
    ) -> UInt64 {
        UInt64((Double(measures * beatsPerMeasure) * 60_000_000_000 / bpm).rounded())
    }

    private func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }

    private var currentKickConfiguration: KickDetectorConfiguration {
        KickDetectorConfiguration(
            threshold: kickThreshold,
            retriggerLockoutMilliseconds: retriggerLockoutMilliseconds
        )
    }

    var practicePreviewPattern: PracticePattern? {
        let bpm = min(max(practiceBPM, 40), 240)
        if practiceExerciseMode == .importedSong {
            return try? makePracticePattern(
                bpm: bpm,
                startSessionTimeNanoseconds: 0,
                startHostTime: nil
            )
        }
        let configuration = practicePatternConfiguration(bpm: bpm)
        if let pattern = try? KickPatternGenerator().generate(configuration: configuration) {
            return pattern
        }
        guard practiceExerciseMode == .custom else { return nil }
        return PracticePattern(
            name: practiceCustomMeasure.displayName,
            bpm: bpm,
            beatsPerMeasure: 4,
            measures: practiceMeasures,
            subdivision: practiceCustomMeasure.subdivision,
            expectedEvents: []
        )
    }

    var practiceSubdivision: KickSubdivision {
        switch practiceExerciseMode {
        case .builtIn: practiceExercise.subdivision
        case .custom: practiceCustomMeasure.subdivision
        case .importedSong: .sixteenths
        }
    }

    var practiceHitsPerMeasure: Int {
        switch practiceExerciseMode {
        case .builtIn: return practiceExercise.hitsPerMeasure
        case .custom: return practiceCustomMeasure.hits.count
        case .importedSong:
            guard let pattern = practicePreviewPattern, pattern.measures > 0 else { return 0 }
            return Int((Double(pattern.expectedEvents.count) / Double(pattern.measures)).rounded())
        }
    }

    var practiceGuidance: String {
        switch practiceExerciseMode {
        case .builtIn: practiceExercise.guidance
        case .custom: "Click the grid to place exact drum voices. The authored measure repeats for the selected measure count."
        case .importedSong: "Choose the drum track, verify every MIDI-note mapping, then loop a measure range. The click follows the scaled MIDI tempo and meter map."
        }
    }

    var currentTempoProgression: ExerciseTempoProgression? {
        let identity = currentExerciseIdentity
        let id = tempoProgressionID(
            exerciseName: identity.name,
            kind: identity.kind,
            customExerciseID: identity.customExerciseID,
            importedSongID: selectedImportedSongID
        )
        return tempoProgressions.first { $0.id == id }
    }

    var currentCeilingRun: CeilingRun? {
        let identity = currentExerciseIdentity
        return activeCeilingRun?.exerciseID == identity.id ? activeCeilingRun : nil
    }

    var currentCeilingRecord: ExerciseCeilingRecord? {
        let identity = currentExerciseIdentity
        return ceilingRecords.first { $0.id == identity.id }
    }

    private func practicePatternConfiguration(bpm: Double) -> KickPatternConfiguration {
        if practiceExerciseMode == .custom {
            return KickPatternConfiguration(
                bpm: bpm,
                customMeasure: practiceCustomMeasure,
                measures: practiceMeasures
            )
        }
        return KickPatternConfiguration(
            bpm: bpm,
            exercise: practiceExercise,
            measures: practiceMeasures
        )
    }

    private func makePracticePattern(
        bpm: Double,
        startSessionTimeNanoseconds: Int64,
        startHostTime: UInt64?
    ) throws -> PracticePattern {
        if practiceExerciseMode == .importedSong {
            guard let song = selectedImportedSong else {
                throw ImportedSongPatternGeneratorError.missingTrack
            }
            return try ImportedSongPatternGenerator().generate(
                song: song,
                configuration: ImportedSongSectionConfiguration(
                    startMeasure: importedSectionStartMeasure,
                    endMeasure: importedSectionEndMeasure,
                    repeats: importedSectionRepeats,
                    targetBPM: bpm
                ),
                startSessionTimeNanoseconds: startSessionTimeNanoseconds,
                startHostTime: startHostTime,
                hostTimeConverter: startHostTime == nil ? nil : timeline.converter
            )
        }
        return try KickPatternGenerator().generate(
            configuration: practicePatternConfiguration(bpm: bpm),
            startSessionTimeNanoseconds: startSessionTimeNanoseconds,
            startHostTime: startHostTime,
            hostTimeConverter: startHostTime == nil ? nil : timeline.converter
        )
    }

    private func sortSavedCustomExercises() {
        savedCustomExercises.sort {
            $0.definition.displayName.localizedCaseInsensitiveCompare($1.definition.displayName) == .orderedAscending
        }
    }

    private func sortImportedSongs() {
        importedSongs.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var selectedImportedSong: ImportedSong? {
        guard let selectedImportedSongID else { return nil }
        return importedSongs.first { $0.id == selectedImportedSongID }
    }

    var importedSongMeasureCount: Int {
        selectedImportedSong.map { ImportedSongTimeline.measures(for: $0).count } ?? 0
    }

    var importedNoteSummaries: [ImportedMIDINoteSummary] {
        guard let track = selectedImportedSong?.selectedTrack else { return [] }
        return Dictionary(grouping: track.notes, by: \.noteNumber)
            .map { note, events in
                ImportedMIDINoteSummary(
                    noteNumber: note,
                    count: events.count,
                    channels: Set(events.map(\.channel))
                )
            }
            .sorted { $0.noteNumber < $1.noteNumber }
    }

    private func updateSelectedImportedSong(_ update: (inout ImportedSong) -> Void) {
        guard !practicePhase.isActive,
              let id = selectedImportedSongID,
              let index = importedSongs.firstIndex(where: { $0.id == id }) else { return }
        update(&importedSongs[index])
        sortImportedSongs()
        persistPracticeData()
        if case .error = practicePhase { practicePhase = .idle }
    }

    private func configureSelectedImportedSong(resetSection: Bool) {
        guard let song = selectedImportedSong else {
            importedSectionStartMeasure = 1
            importedSectionEndMeasure = 1
            importedSectionRepeats = 1
            practiceMeasures = 1
            return
        }
        let measures = ImportedSongTimeline.measures(for: song)
        if resetSection {
            importedSectionStartMeasure = 1
            importedSectionEndMeasure = min(max(measures.count, 1), 4)
            importedSectionRepeats = 1
            practiceBPM = min(max(song.originalBPM.rounded(), 40), 240)
        }
        setImportedSection()
    }

    private func persistPracticeData() {
        do {
            try practiceDataStore.save(currentPracticeDataArchive())
        } catch {
            practiceDataStatusMessage = error.localizedDescription
        }
    }

    private func currentPracticeDataArchive() -> PracticeDataArchive {
        PracticeDataArchive(
            customExercises: savedCustomExercises,
            importedSongs: importedSongs,
            sessions: practiceHistory,
            sessionRecords: practiceSessionRecords,
            tempoProgressionSettings: tempoProgressionSettings,
            tempoProgressions: tempoProgressions,
            ceilingModeSettings: ceilingModeSettings,
            activeCeilingRun: activeCeilingRun,
            ceilingRecords: ceilingRecords
        )
    }

    private var currentPracticeDeviceContext: PracticeSessionDeviceContext {
        let midiDevice = selectedMIDIInputID.flatMap { selectedID in
            midiDevices.first { $0.id == selectedID }
        }
        let audioInput = selectedAudioInputID.flatMap { selectedID in
            audioDevices.first { $0.id == selectedID }
        }
        let audioOutput = selectedAudioOutputID.flatMap { selectedID in
            audioOutputDevices.first { $0.id == selectedID }
        }
        return PracticeSessionDeviceContext(
            midiDeviceID: midiDevice?.id,
            midiDeviceName: midiDevice?.name,
            audioInputUID: audioInput?.uid,
            audioInputName: audioInput?.name,
            audioOutputUID: audioOutput?.uid,
            audioOutputName: audioOutput?.name,
            calibrationProfile: activeMicrophoneCalibrationProfile,
            midiTimingCompensationMilliseconds: currentTimingAlignmentProfile(for: .midi)?.compensationMilliseconds,
            microphoneTimingCompensationMilliseconds: currentTimingAlignmentProfile(for: .microphone)?.compensationMilliseconds
        )
    }

    private func updateTempoProgression(after summary: PracticeSessionSummary) {
        let progressionID = tempoProgressionID(
            exerciseName: summary.exerciseName,
            kind: summary.exerciseKind,
            customExerciseID: summary.customExerciseID,
            importedSongID: summary.importedSongID
        )
        let index: Int
        if let existingIndex = tempoProgressions.firstIndex(where: { $0.id == progressionID }) {
            index = existingIndex
        } else {
            tempoProgressions.append(ExerciseTempoProgression(
                id: progressionID,
                exerciseName: summary.exerciseName,
                suggestedBPM: summary.bpm,
                consecutiveCleanSessions: 0,
                highestCleanBPM: nil,
                updatedAt: summary.completedAt
            ))
            index = tempoProgressions.count - 1
        }

        tempoProgressions[index].updatedAt = summary.completedAt
        if summary.isClean {
            tempoProgressions[index].highestCleanBPM = max(
                tempoProgressions[index].highestCleanBPM ?? summary.bpm,
                summary.bpm
            )
        }

        guard tempoProgressionSettings.isEnabled, !ceilingModeSettings.isEnabled else {
            tempoProgressions.sort { $0.updatedAt > $1.updatedAt }
            return
        }

        if summary.isClean {
            tempoProgressions[index].consecutiveCleanSessions += 1
            let count = tempoProgressions[index].consecutiveCleanSessions
            if count >= tempoProgressionSettings.requiredCleanSessions {
                let nextBPM = min(
                    max(tempoProgressions[index].suggestedBPM, summary.bpm)
                        + tempoProgressionSettings.stepBPM,
                    240
                )
                tempoProgressions[index].suggestedBPM = nextBPM
                tempoProgressions[index].consecutiveCleanSessions = 0
                practiceBPM = nextBPM
                lastTempoProgressionMessage = "Advanced \(summary.exerciseName) to \(Int(nextBPM.rounded())) BPM."
            } else {
                lastTempoProgressionMessage = "Clean run \(count)/\(tempoProgressionSettings.requiredCleanSessions) toward the next tempo."
            }
        } else {
            tempoProgressions[index].consecutiveCleanSessions = 0
            lastTempoProgressionMessage = "Clean-run streak reset; keep this tempo for another pass."
        }
        tempoProgressions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func prepareCeilingRunForStart() {
        guard ceilingModeSettings.isEnabled else { return }
        let identity = currentExerciseIdentity
        let boundedBPM = min(max(practiceBPM, 40), 240)
        let now = Date()

        if var run = activeCeilingRun, run.exerciseID == identity.id {
            switch run.phase {
            case let .readyForNext(nextBPM):
                practiceBPM = nextBPM
                run.phase = .testing(bpm: nextBPM)
            case let .testing(bpm):
                practiceBPM = bpm
            case .found:
                run = makeCeilingRun(identity: identity, startingBPM: boundedBPM, now: now)
            }
            run.updatedAt = now
            activeCeilingRun = run
        } else {
            activeCeilingRun = makeCeilingRun(identity: identity, startingBPM: boundedBPM, now: now)
        }
        lastCeilingMessage = "Testing \(Int(practiceBPM.rounded())) BPM. Pass cleanly to move up."
        persistPracticeData()
    }

    private func updateCeilingRun(after summary: PracticeSessionSummary) {
        guard ceilingModeSettings.isEnabled, var run = activeCeilingRun else { return }
        let summaryID = tempoProgressionID(
            exerciseName: summary.exerciseName,
            kind: summary.exerciseKind,
            customExerciseID: summary.customExerciseID,
            importedSongID: summary.importedSongID
        )
        guard run.exerciseID == summaryID else { return }

        switch run.record(summary, stepBPM: ceilingModeSettings.stepBPM) {
        case let .advance(passedBPM, nextBPM):
            practiceBPM = nextBPM
            lastCeilingMessage = "Clean at \(Int(passedBPM.rounded())) BPM. Next round: \(Int(nextBPM.rounded())) BPM."
        case let .found(highestCleanBPM, failedBPM):
            lastCeilingMessage = "Ceiling found: \(Int(highestCleanBPM.rounded())) BPM. The \(Int(failedBPM.rounded())) BPM round did not pass cleanly."
            updateCeilingRecord(from: run, failedBPM: failedBPM)
        case let .belowStartingTempo(failedBPM):
            lastCeilingMessage = "Your ceiling is below the \(Int(failedBPM.rounded())) BPM starting point. Lower the tempo and start a new search."
        case .maximumVerified:
            lastCeilingMessage = "Ceiling verified at the app maximum: 240 BPM."
            updateCeilingRecord(from: run, failedBPM: nil)
        }
        activeCeilingRun = run
        ceilingRecords.sort { $0.achievedAt > $1.achievedAt }
    }

    private func updateCeilingRecord(from run: CeilingRun, failedBPM: Double?) {
        guard let highest = run.highestCleanBPM else { return }
        let candidate = ExerciseCeilingRecord(
            id: run.exerciseID,
            exerciseName: run.exerciseName,
            highestVerifiedBPM: highest,
            achievedAt: run.updatedAt,
            ceilingRunID: run.id,
            startingBPM: run.startingBPM,
            failedBPM: failedBPM,
            roundsCompleted: run.sessionIDs.count
        )
        if let index = ceilingRecords.firstIndex(where: { $0.id == run.exerciseID }) {
            if candidate.highestVerifiedBPM >= ceilingRecords[index].highestVerifiedBPM {
                ceilingRecords[index] = candidate
            }
        } else {
            ceilingRecords.append(candidate)
        }
    }

    private var currentExerciseIdentity: (
        id: String,
        name: String,
        kind: PracticeSessionExerciseKind,
        customExerciseID: UUID?
    ) {
        let name: String
        let kind: PracticeSessionExerciseKind
        let customID: UUID?
        let importedID: UUID?
        switch practiceExerciseMode {
        case .builtIn:
            name = practiceExercise.displayName
            kind = .builtIn
            customID = nil
            importedID = nil
        case .custom:
            name = practiceCustomMeasure.displayName
            kind = .custom
            customID = selectedSavedCustomExerciseID
            importedID = nil
        case .importedSong:
            name = selectedImportedSong?.displayName ?? "Imported song"
            kind = .importedSong
            customID = nil
            importedID = selectedImportedSongID
        }
        return (
            tempoProgressionID(
                exerciseName: name,
                kind: kind,
                customExerciseID: customID,
                importedSongID: importedID
            ),
            name,
            kind,
            customID
        )
    }

    private func makeCeilingRun(
        identity: (id: String, name: String, kind: PracticeSessionExerciseKind, customExerciseID: UUID?),
        startingBPM: Double,
        now: Date
    ) -> CeilingRun {
        practiceBPM = startingBPM
        return CeilingRun(
            id: UUID(),
            exerciseID: identity.id,
            exerciseName: identity.name,
            exerciseKind: identity.kind,
            customExerciseID: identity.customExerciseID,
            startedAt: now,
            updatedAt: now,
            startingBPM: startingBPM,
            highestCleanBPM: nil,
            attemptedBPMs: [],
            sessionIDs: [],
            phase: .testing(bpm: startingBPM)
        )
    }

    private func tempoProgressionID(
        exerciseName: String,
        kind: PracticeSessionExerciseKind,
        customExerciseID: UUID?,
        importedSongID: UUID? = nil
    ) -> String {
        switch kind {
        case .custom:
            return customExerciseID.map { "custom:\($0.uuidString)" }
                ?? "custom-name:\(exerciseName)"
        case .importedSong:
            return importedSongID.map { "imported:\($0.uuidString)" }
                ?? "imported-name:\(exerciseName)"
        case .builtIn:
            return "built-in:\(exerciseName)"
        }
    }

    var sessionOriginHostTime: UInt64 { timeline.originHostTime }

    var practicePlayheadSessionTime: Int64? {
        guard case let .running(startSessionTime, endSessionTime) = practicePhase else { return nil }
        let now = timeline.sessionTimeNanoseconds(for: clock.currentHostTime())
        return min(max(now, startSessionTime), endSessionTime)
    }

    private func appendMicrophoneLevel(_ level: Double) {
        microphoneLevelSampleSequence &+= 1
        if case .samplingNoise = microphoneCalibrationPhase {
            calibrationNoiseSamples.append(level)
            if calibrationNoiseSamples.count > 1_000 {
                calibrationNoiseSamples.removeFirst(calibrationNoiseSamples.count - 1_000)
            }
        }
        recentLevels.append(level)
        if recentLevels.count > 80 {
            recentLevels.removeFirst(recentLevels.count - 80)
        }
    }

    private func finishNoiseSampling() {
        calibrationTask = nil
        guard let estimate = calibrationAnalyzer.analyzeNoise(calibrationNoiseSamples),
              estimate.sampleCount >= 10 else {
            microphoneCalibrationPhase = .error(
                "Not enough microphone samples were received. Confirm the input is monitoring, then retry."
            )
            return
        }
        calibrationNoiseEstimate = estimate
        kickThreshold = estimate.collectionThreshold
        microphoneCalibrationPhase = .collectingHits(detected: 0, target: 20)
    }

    private func collectCalibrationHitIfNeeded(_ event: PerformanceEvent) {
        guard case let .collectingHits(_, target) = microphoneCalibrationPhase,
              event.source == .microphone,
              case let .microphone(amplitude, _, _) = event.rawMetadata else { return }
        let accepted = calibrationHitCollector.record(
            amplitude: amplitude,
            soundFeatures: event.audioFeatures,
            sessionTimeNanoseconds: event.sessionTimeNanoseconds
        )
        calibrationSuppressedTransientCount = calibrationHitCollector.suppressedTransientCount
        if calibrationHitCollector.suggestedLockoutMilliseconds > retriggerLockoutMilliseconds {
            retriggerLockoutMilliseconds = calibrationHitCollector.suggestedLockoutMilliseconds
        }
        guard accepted else { return }

        let detected = calibrationHitCollector.amplitudes.count
        if detected < target {
            microphoneCalibrationPhase = .collectingHits(detected: detected, target: target)
            return
        }

        guard let noise = calibrationNoiseEstimate,
              let device = selectedAudioInputDevice,
              let profile = calibrationAnalyzer.makeProfile(
                deviceUID: device.uid,
                deviceName: device.name,
                noise: noise,
                hitAmplitudes: calibrationHitCollector.amplitudes,
                hitSoundFeatures: calibrationHitCollector.soundFeatures,
                retriggerLockoutMilliseconds: retriggerLockoutMilliseconds
              ) else {
            microphoneCalibrationPhase = .error("Calibration could not produce a profile. Please retry.")
            return
        }
        kickThreshold = profile.suggestedThreshold
        microphoneCalibrationPhase = .review(profile)
    }

    private var selectedAudioInputDevice: AudioInputDevice? {
        audioDevices.first(where: { $0.id == selectedAudioInputID })
    }

    private func currentTimingAlignmentIdentity(
        for source: TimingAlignmentSource
    ) -> (inputID: String, inputName: String, outputUID: String, outputName: String)? {
        let inputID: String
        let inputName: String
        switch source {
        case .midi:
            guard let selectedMIDIInputID,
                  let device = midiDevices.first(where: { $0.id == selectedMIDIInputID }) else { return nil }
            inputID = String(device.id)
            inputName = device.name
        case .microphone:
            guard let device = selectedAudioInputDevice else { return nil }
            inputID = device.uid
            inputName = device.name
        }

        if let selectedAudioOutputID,
           let output = audioOutputDevices.first(where: { $0.id == selectedAudioOutputID }) {
            return (inputID, inputName, output.uid, output.name)
        }
        return (inputID, inputName, "system-default", "System Default")
    }

    private func currentTimingAlignmentProfile(for source: TimingAlignmentSource) -> TimingAlignmentProfile? {
        guard let identity = currentTimingAlignmentIdentity(for: source) else { return nil }
        let key = TimingAlignmentProfile.key(
            source: source,
            inputID: identity.inputID,
            outputUID: identity.outputUID
        )
        return timingAlignmentProfiles.first { $0.key == key }
    }

    private var currentEventMatcher: EventMatcher {
        var corrections: [EventSource: Int64] = [:]
        for source in TimingAlignmentSource.allCases {
            guard let milliseconds = currentTimingAlignmentProfile(for: source)?.compensationMilliseconds else {
                continue
            }
            corrections[source.eventSource] = Int64((milliseconds * 1_000_000).rounded())
        }
        return EventMatcher(sourceTimingCompensationNanoseconds: corrections)
    }

    private func shouldSuppressAsMIDICrosstalk(_ event: PerformanceEvent) -> Bool {
        guard event.source == .microphone,
              case let .microphone(amplitude, threshold, _) = event.rawMetadata else { return false }
        let similarity = kickSoundSimilarity(for: event)
        return microphoneCrosstalkGuard.shouldSuppressMicrophoneHit(
            amplitude: amplitude,
            threshold: threshold,
            calibratedWeakestKickAmplitude: activeMicrophoneCalibrationProfile?.weakestHitAmplitude,
            kickSoundSimilarity: similarity,
            minimumKickSimilarity: minimumKickSoundSimilarity,
            sessionTimeNanoseconds: event.sessionTimeNanoseconds
        )
    }

    private var isCollectingCalibration: Bool {
        if case .collectingHits = microphoneCalibrationPhase { return true }
        return false
    }

    private func kickSoundSimilarity(for event: PerformanceEvent) -> Double? {
        guard let features = event.audioFeatures,
              let signature = activeMicrophoneCalibrationProfile?.kickSoundSignature else { return nil }
        return kickSoundClassifier.similarity(of: features, to: signature)
    }

    private func shouldSuppressAsNonKickSound(_ event: PerformanceEvent) -> Bool {
        guard kickSoundFilterEnabled, event.source == .microphone,
              let similarity = kickSoundSimilarity(for: event) else { return false }
        lastKickSoundSimilarity = similarity
        return similarity < minimumKickSoundSimilarity
    }
}
