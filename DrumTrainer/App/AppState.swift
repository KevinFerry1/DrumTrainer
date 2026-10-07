import AppKit
import Combine
import CoreAudio
import CoreMIDI
import Foundation

enum PracticePhase: Equatable, Sendable {
    case idle
    case waitingForPlayback
    case countIn(beatsRemaining: Int)
    case running(startSessionTime: Int64, endSessionTime: Int64)
    case results
    case error(String)

    var isActive: Bool {
        switch self {
        case .waitingForPlayback, .countIn, .running: true
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

    var locksConfiguration: Bool {
        switch self {
        case .starting, .countIn, .collecting, .review: true
        case .idle, .saved, .error: false
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
    private let practiceAudioStore: PracticeAudioFileStore
    private let practiceAudioRecorder: PracticeAudioRecorder
    private var simulationTask: Task<Void, Never>?
    private var practiceFinishTask: Task<Void, Never>?
    private var practiceAutoGoTask: Task<Void, Never>?
    private var practiceAutoGoID: UUID?
    private var practiceAutoGoDeadline: UInt64?
    private var isPracticeViewVisible = false
    private var playbackArmTask: Task<Void, Never>?
    private var playbackTimeoutTask: Task<Void, Never>?
    private var playbackSourceTask: Task<Void, Never>?
    private var playbackSourceRequestID: UUID?
    private(set) var playbackArmID: UUID?
    private var playbackPreRoll: [PerformanceEvent] = []
    private var latestDroppedPlaybackEventTime: Int64?
    private let externalPlaybackListener: any ExternalPlaybackListening
    private var calibrationTask: Task<Void, Never>?
    private var timingAlignmentFinishTask: Task<Void, Never>?
    private var timingAlignmentStartWatchdogTask: Task<Void, Never>?
    private var timingAlignmentBeatClearTask: Task<Void, Never>?
    private var metronomeHeartbeatTask: Task<Void, Never>?
    private var audioEngineRefreshWatchdogTask: Task<Void, Never>?
    private(set) var audioEngineRefreshID: UUID?
    private let injectedMetronomeEngine: (any MetronomeControlling)?
    private var metronomeEngineGeneration = 0
    private var audioEngineRefreshFlowGeneration: Int?
    private var audioEngineRefreshShouldRetryPractice = false
    private var audioEngineRefreshShouldRetryTimingAlignment = false
    private var audioEngineRefreshPreservesAutomaticAttempt = false
    private var earliestPracticeTickHostTime: UInt64 = 0
    private var metronomeStallRecoveryAttempts = 0
    private var activeAudioFlowGeneration = 0
    private var practiceRecording: PracticeSessionRecording?
    private var activePracticeSessionID: UUID?
    private var isPracticeAudioScheduled = false
    private var activePracticeRecordingCaptureDeviceID: AudioDeviceID?
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
    private var timingAlignmentCollector = TimingAlignmentCollector(source: .midi, voice: nil)

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
                guard let self else { return }
                self.audioDevices = devices
                self.configurePracticeAudioInputCapture()
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
        },
        practiceAudioRecorder: practiceAudioRecorder
    )

    private lazy var practiceRecordingInputService = PracticeRecordingInputService(
        recorder: practiceAudioRecorder,
        onStatusChanged: { [weak self] status in
            Task { @MainActor [weak self] in
                self?.practiceAudioInputStatus = status
            }
        }
    )

    private lazy var metronomeEngine: any MetronomeControlling = injectedMetronomeEngine
        ?? makeMetronomeEngine(generation: metronomeEngineGeneration)

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
    @Published var kickMonitorEnabled = false {
        didSet {
            updateKickMonitorAudioConfiguration()
            UserDefaults.standard.set(kickMonitorEnabled, forKey: "DrumTrainer.kickMonitor.enabled")
        }
    }
    @Published var kickMonitorSource: KickMonitorSource = .both {
        didSet {
            UserDefaults.standard.set(kickMonitorSource.rawValue, forKey: "DrumTrainer.kickMonitor.source")
        }
    }
    @Published var kickMonitorSound: KickMonitorSound = .studioPunch {
        didSet {
            updateKickMonitorAudioConfiguration()
            UserDefaults.standard.set(kickMonitorSound.rawValue, forKey: "DrumTrainer.kickMonitor.sound")
        }
    }
    @Published var kickMonitorGainDecibels = -6.0 {
        didSet {
            updateKickMonitorAudioConfiguration()
            UserDefaults.standard.set(kickMonitorGainDecibels, forKey: "DrumTrainer.kickMonitor.gainDB")
        }
    }
    @Published var kickMonitorVelocitySensitive = true {
        didSet {
            updateKickMonitorAudioConfiguration()
            UserDefaults.standard.set(
                kickMonitorVelocitySensitive,
                forKey: "DrumTrainer.kickMonitor.velocitySensitive"
            )
        }
    }
    @Published var kickMonitorRetriggerMilliseconds = 30.0 {
        didSet {
            updateKickMonitorAudioConfiguration()
            UserDefaults.standard.set(
                kickMonitorRetriggerMilliseconds,
                forKey: "DrumTrainer.kickMonitor.retriggerMilliseconds"
            )
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
    @Published var practiceCustomMeasure = CustomMeasureDefinition() {
        didSet {
            if practiceCustomMeasure.isSequence { practiceMeasures = max(practiceCustomMeasure.sequenceMeasureCount, 1) }
        }
    }
    private var singleMeasureDraft: (CustomMeasureDefinition, UUID?)?
    private var sequenceDraft: (CustomMeasureDefinition, UUID?)?
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
    @Published var practiceAudioRecordingEnabled = false {
        didSet {
            UserDefaults.standard.set(
                practiceAudioRecordingEnabled,
                forKey: "DrumTrainer.practiceAudioRecording.enabled"
            )
            configurePracticeAudioInputCapture()
        }
    }
    /// Nil follows the microphone used for kick detection. A UID selects a
    /// separate input such as the Scarlett carrying the module's analog audio.
    @Published var practiceAudioInputUID: String? = nil {
        didSet {
            UserDefaults.standard.set(
                practiceAudioInputUID,
                forKey: "DrumTrainer.practiceAudioRecording.inputUID"
            )
            configurePracticeAudioInputCapture()
        }
    }
    @Published var practiceAudioChannelSelection: PracticeAudioChannelSelection = .input1 {
        didSet {
            UserDefaults.standard.set(
                practiceAudioChannelSelection.rawValue,
                forKey: "DrumTrainer.practiceAudioRecording.channelSelection"
            )
        }
    }
    @Published private(set) var practiceAudioInputStatus: AudioInputStatus = .stopped
    @Published private(set) var practiceAudioStatusMessage: String?
    @Published private(set) var practiceAudioLibraryRevision = 0
    @Published var practiceBPM = 120.0
    @Published var practiceMeasures = 4
    @Published var practiceAccentVelocityThreshold = 100 {
        didSet {
            UserDefaults.standard.set(
                practiceAccentVelocityThreshold,
                forKey: "DrumTrainer.practice.accentVelocityThreshold"
            )
        }
    }
    @Published var practiceAccentVelocityFloorEnabled = true {
        didSet {
            UserDefaults.standard.set(
                practiceAccentVelocityFloorEnabled,
                forKey: "DrumTrainer.practice.accentVelocityFloorEnabled"
            )
        }
    }
    @Published var practiceAccentContrastPoints = 18 {
        didSet {
            UserDefaults.standard.set(
                practiceAccentContrastPoints,
                forKey: "DrumTrainer.practice.accentContrastPoints"
            )
        }
    }
    @Published var practiceGradeKicks = true {
        didSet {
            UserDefaults.standard.set(practiceGradeKicks, forKey: "DrumTrainer.practice.gradeKicks")
        }
    }
    @Published var practiceGhostVelocityCeiling = 50 {
        didSet { UserDefaults.standard.set(practiceGhostVelocityCeiling, forKey: "DrumTrainer.practice.ghostVelocityCeiling") }
    }
    @Published var practiceGhostVelocityCeilingEnabled = true {
        didSet { UserDefaults.standard.set(practiceGhostVelocityCeilingEnabled, forKey: "DrumTrainer.practice.ghostVelocityCeilingEnabled") }
    }
    @Published var practiceGhostContrastPoints = 18 {
        didSet { UserDefaults.standard.set(practiceGhostContrastPoints, forKey: "DrumTrainer.practice.ghostContrastPoints") }
    }
    @Published var practiceAutoGoEnabled = false {
        didSet {
            if !practiceAutoGoEnabled { cancelPracticeAutoGoCountdown() }
        }
    }
    @Published var practiceAutoGoDelaySeconds = 8.0
    @Published private(set) var practiceAutoGoSecondsRemaining: Int?
    @Published var practicePhase: PracticePhase = .idle {
        didSet {
            if practicePhase != .results { cancelPracticeAutoGoCountdown() }
        }
    }
    @Published var practiceActivePattern: PracticePattern?
    @Published var practiceExpectedEvents: [ExpectedEvent] = []
    @Published var practiceOutcome: PracticeSessionOutcome?
    @Published var waitForExternalPlayback = false
    @Published var playbackAudioSources: [PlaybackAudioSource] = []
    @Published var selectedPlaybackSourceID: Int32?
    @Published var isLoadingPlaybackSources = false
    @Published var playbackSourceMessage: String?
    @Published var playbackStartOffsetMilliseconds = 0.0
    @Published var playbackDetectionThresholdDBFS = -45.0
    @Published private(set) var playbackInputLevelDBFS = -120.0
    @Published private(set) var playbackSyncMessage = "Pause Songsterr before arming."
    @Published private(set) var isExternalPlaybackRun = false
    @Published var practiceRecordedHitCount = 0
    @Published var microphoneCalibrationPhase: MicrophoneCalibrationPhase = .idle
    @Published var calibrationNoiseEstimate: MicrophoneNoiseEstimate?
    @Published var activeMicrophoneCalibrationProfile: MicrophoneCalibrationProfile?
    @Published var calibrationSuppressedTransientCount = 0
    @Published var timingAlignmentSource: TimingAlignmentSource = .midi
    @Published var timingAlignmentPhase: TimingAlignmentPhase = .idle
    @Published var timingAlignmentProfiles: [TimingAlignmentProfile] = []
    @Published private(set) var timingAlignmentVisibleBeat: Int?

    init(
        clock: any ClockProviding = MachHostClock(),
        converter: any HostTimeConverting = CoreAudioHostTimeConverter(),
        midiMappingStore: any MIDIMappingPersisting = UserDefaultsMIDIMappingStore(),
        microphoneCalibrationStore: any MicrophoneCalibrationPersisting = UserDefaultsMicrophoneCalibrationStore(),
        timingAlignmentStore: any TimingAlignmentPersisting = UserDefaultsTimingAlignmentStore(),
        practiceDataStore: any PracticeDataPersisting = UserDefaultsPracticeDataStore(),
        practiceAudioDirectoryURL: URL? = nil,
        eventCapacity: Int = 500,
        metronomeEngine injectedMetronome: (any MetronomeControlling)? = nil,
        externalPlaybackListener: (any ExternalPlaybackListening)? = nil
    ) {
        self.clock = clock
        self.injectedMetronomeEngine = injectedMetronome
        self.externalPlaybackListener = externalPlaybackListener ?? ExternalPlaybackListener()
        self.midiMappingStore = midiMappingStore
        self.microphoneCalibrationStore = microphoneCalibrationStore
        self.timingAlignmentStore = timingAlignmentStore
        self.practiceDataStore = practiceDataStore
        let practiceAudioStore = PracticeAudioFileStore(
            directoryURL: practiceAudioDirectoryURL ?? PracticeAudioFileStore.defaultDirectoryURL()
        )
        self.practiceAudioStore = practiceAudioStore
        self.practiceAudioRecorder = PracticeAudioRecorder(store: practiceAudioStore)
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
            metronomeGainDecibels = MetronomeGain.clamped(
                defaults.double(forKey: "DrumTrainer.metronome.gainDB")
            )
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
        if let rawSource = defaults.string(forKey: "DrumTrainer.kickMonitor.source"),
           let savedSource = KickMonitorSource(rawValue: rawSource) {
            kickMonitorSource = savedSource
        }
        if let rawSound = defaults.string(forKey: "DrumTrainer.kickMonitor.sound"),
           let savedSound = KickMonitorSound(rawValue: rawSound) {
            kickMonitorSound = savedSound
        }
        if defaults.object(forKey: "DrumTrainer.kickMonitor.gainDB") != nil {
            kickMonitorGainDecibels = min(
                max(defaults.double(forKey: "DrumTrainer.kickMonitor.gainDB"), -36),
                6
            )
        }
        if defaults.object(forKey: "DrumTrainer.kickMonitor.velocitySensitive") != nil {
            kickMonitorVelocitySensitive = defaults.bool(
                forKey: "DrumTrainer.kickMonitor.velocitySensitive"
            )
        }
        if defaults.object(forKey: "DrumTrainer.kickMonitor.retriggerMilliseconds") != nil {
            kickMonitorRetriggerMilliseconds = min(
                max(defaults.double(forKey: "DrumTrainer.kickMonitor.retriggerMilliseconds"), 10),
                150
            )
        }
        if defaults.object(forKey: "DrumTrainer.kickMonitor.enabled") != nil {
            kickMonitorEnabled = defaults.bool(forKey: "DrumTrainer.kickMonitor.enabled")
        }
        if defaults.object(forKey: "DrumTrainer.practice.gradeKicks") != nil {
            practiceGradeKicks = defaults.bool(forKey: "DrumTrainer.practice.gradeKicks")
        }
        if let savedRecordingInputUID = defaults.string(
            forKey: "DrumTrainer.practiceAudioRecording.inputUID"
        ) {
            practiceAudioInputUID = savedRecordingInputUID
        }
        if let savedChannel = defaults.string(
            forKey: "DrumTrainer.practiceAudioRecording.channelSelection"
        ), let channelSelection = PracticeAudioChannelSelection(rawValue: savedChannel) {
            practiceAudioChannelSelection = channelSelection
        }
        if defaults.object(forKey: "DrumTrainer.practiceAudioRecording.enabled") != nil {
            practiceAudioRecordingEnabled = defaults.bool(
                forKey: "DrumTrainer.practiceAudioRecording.enabled"
            )
        }
        if defaults.object(forKey: "DrumTrainer.practice.accentVelocityThreshold") != nil {
            practiceAccentVelocityThreshold = min(
                max(defaults.integer(forKey: "DrumTrainer.practice.accentVelocityThreshold"), 1),
                127
            )
        }
        if defaults.object(forKey: "DrumTrainer.practice.accentVelocityFloorEnabled") != nil {
            practiceAccentVelocityFloorEnabled = defaults.bool(
                forKey: "DrumTrainer.practice.accentVelocityFloorEnabled"
            )
        }
        if defaults.object(forKey: "DrumTrainer.practice.accentContrastPoints") != nil {
            practiceAccentContrastPoints = min(
                max(defaults.integer(forKey: "DrumTrainer.practice.accentContrastPoints"), 1),
                127
            )
        }
        if defaults.object(forKey: "DrumTrainer.practice.ghostVelocityCeiling") != nil {
            practiceGhostVelocityCeiling = min(max(defaults.integer(forKey: "DrumTrainer.practice.ghostVelocityCeiling"), 1), 127)
        }
        if defaults.object(forKey: "DrumTrainer.practice.ghostVelocityCeilingEnabled") != nil {
            practiceGhostVelocityCeilingEnabled = defaults.bool(forKey: "DrumTrainer.practice.ghostVelocityCeilingEnabled")
        }
        if defaults.object(forKey: "DrumTrainer.practice.ghostContrastPoints") != nil {
            practiceGhostContrastPoints = min(max(defaults.integer(forKey: "DrumTrainer.practice.ghostContrastPoints"), 1), 127)
        }
        metronomeEngine.updateSound(metronomeSound)
        metronomeEngine.updateGainDecibels(metronomeGainDecibels)
        metronomeEngine.updateLimiter(
            enabled: metronomeLimiterEnabled,
            ceilingDBFS: metronomeLimiterCeilingDBFS
        )
        updateKickMonitorAudioConfiguration()
    }

    private func makeMetronomeEngine(generation: Int) -> MetronomeEngine {
        MetronomeEngine(
            onDevicesChanged: { [weak self] devices in
                Task { @MainActor [weak self] in
                    guard let self, self.metronomeEngineGeneration == generation else { return }
                    self.audioOutputDevices = devices
                }
            },
            onStatusChanged: { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.metronomeEngineGeneration == generation else { return }
                    self.metronomeStatus = status
                    if case .running = status {
                        self.isMetronomeRunning = true
                    } else {
                        self.isMetronomeRunning = false
                    }
                    self.handleTimingAlignmentMetronomeStatus(status)
                    self.handlePracticeMetronomeStatus(status)
                }
            },
            onTick: { [weak self] tick in
                Task { @MainActor [weak self] in
                    guard let self, self.metronomeEngineGeneration == generation else { return }
                    await self.publishMetronomeTick(tick)
                }
            },
            onHealthChanged: { [weak self] health in
                Task { @MainActor [weak self] in
                    guard let self, self.metronomeEngineGeneration == generation else { return }
                    self.metronomeSchedulingHealth = health
                }
            },
            onOutputLevelChanged: { [weak self] level in
                Task { @MainActor [weak self] in
                    guard let self, self.metronomeEngineGeneration == generation else { return }
                    self.appOutputLevel = level
                }
            },
            onOutputLatencyChanged: { [weak self] milliseconds in
                Task { @MainActor [weak self] in
                    guard let self, self.metronomeEngineGeneration == generation else { return }
                    self.metronomeOutputPresentationLatencyMilliseconds = milliseconds
                }
            }
        )
    }

    /// Replaces the complete audio transport, including its serial queue. Recovery
    /// must not be submitted to the old queue because a native AVFAudio call can
    /// remain blocked there indefinitely after a USB route interruption.
    @discardableResult
    private func replaceMetronomeEngine() -> Bool {
        guard injectedMetronomeEngine == nil else { return false }
        guard let previousEngine = metronomeEngine as? MetronomeEngine else { return false }
        metronomeEngineGeneration &+= 1
        let replacement = makeMetronomeEngine(generation: metronomeEngineGeneration)
        metronomeEngine = replacement

        // A poisoned Core Audio graph may block even during deinit. Retire it on
        // a background queue; the old callbacks are generation-gated above.
        previousEngine.retire()

        replacement.updateSound(metronomeSound)
        replacement.updateGainDecibels(metronomeGainDecibels)
        replacement.updateLimiter(
            enabled: metronomeLimiterEnabled,
            ceilingDBFS: metronomeLimiterCeilingDBFS
        )
        replacement.select(deviceID: selectedAudioOutputID)
        replacement.updateKickMonitoring(
            enabled: kickMonitorEnabled,
            sound: kickMonitorSound,
            gainDecibels: kickMonitorGainDecibels,
            velocitySensitive: kickMonitorVelocitySensitive,
            retriggerMilliseconds: kickMonitorRetriggerMilliseconds,
            startAudioIfNeeded: hasStartedHardwareMonitoring
        )
        if hasStartedHardwareMonitoring { replacement.startMonitoring() }
        metronomeStatus = .ready
        isMetronomeRunning = false
        metronomeSchedulingHealth = MetronomeSchedulingHealth()
        appOutputLevel = .silence
        metronomeOutputPresentationLatencyMilliseconds = nil
        return true
    }

    func toggleSimulation() {
        isSimulationRunning ? stopSimulation() : startSimulation()
    }

    func startPractice() {
        guard !practicePhase.isActive, !isRefreshingAudioEngine else { return }
        cancelPracticeAutoGoCountdown()
        let externalStart = practiceExerciseMode == .importedSong && waitForExternalPlayback
        if externalStart {
            guard selectedPlaybackSourceID != nil else {
                practicePhase = .error("Load audio sources and select the browser playing Songsterr first.")
                return
            }
            guard importedSectionRepeats == 1 else {
                practicePhase = .error("External playback currently supports one pass. Set section repeats to 1 and turn off looping in Songsterr.")
                return
            }
        }
        if timingAlignmentPhase.isActive { cancelTimingAlignment() }
        if practiceExerciseMode == .custom, let message = practiceCustomMeasure.sequenceValidationMessage {
            practicePhase = .error(message)
            return
        }
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
            guard importedSectionMappedHitCount > 0 else {
                practicePhase = .error("Measures \(importedSectionStartMeasure)–\(importedSectionEndMeasure) contain no mapped drum notes. Jump to the first playable section or choose a different measure range.")
                return
            }
            guard importedSectionEligibleHitCount > 0 else {
                practicePhase = .error("This section contains only mapped kick notes, but Grade kicks is off. Turn it on or choose a section containing other drums.")
                return
            }
        }
        if !practiceGradeKicks,
           let preview = practicePreviewPattern,
           !preview.expectedEvents.contains(where: { $0.voice != .kick }) {
            practicePhase = .error(
                practiceExerciseMode == .importedSong
                    ? "This section only contains kick notes. Turn Grade kicks on or choose a section with kit notes."
                    : "This exercise only contains kick notes. Turn Grade kicks on or choose a kit groove."
            )
            return
        }
        stopSimulation()
        discardActivePracticeAudio()
        activeAudioFlowGeneration &+= 1
        audioEngineRecoveryMessage = nil
        practiceAudioStatusMessage = nil
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
        isExternalPlaybackRun = externalStart
        if externalStart {
            practiceBPM = min(max(practiceBPM, 40), 240)
            beginWaitingForPlayback()
            return
        }
        prepareCeilingRunForStart()
        practicePhase = .countIn(beatsRemaining: Self.countInBeats)
        earliestPracticeTickHostTime = clock.currentHostTime()
        metronomeBPM = min(max(practiceBPM, 40), 240)
        practiceBPM = metronomeBPM
        metronomeEngine.start(bpm: practiceBPM)
        scheduleMetronomeHeartbeat()
    }

    func loadPlaybackAudioSources() {
        guard !practicePhase.isActive else { return }
        playbackSourceTask?.cancel()
        let id = UUID()
        playbackSourceRequestID = id
        isLoadingPlaybackSources = true
        playbackSourceMessage = "Allow Screen & System Audio Recording if macOS asks. No audio or video is saved."
        playbackSourceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sources = try await externalPlaybackListener.sources()
                guard playbackSourceRequestID == id, !Task.isCancelled else { return }
                playbackAudioSources = sources
                if !sources.contains(where: { $0.id == selectedPlaybackSourceID }) {
                    selectedPlaybackSourceID = nil
                }
                playbackSourceMessage = sources.isEmpty
                    ? "No apps found. Open your browser and reload sources."
                    : "Select your browser. All audible tabs in that browser can trigger the start."
            } catch {
                guard playbackSourceRequestID == id, !Task.isCancelled else { return }
                playbackSourceMessage = "Could not load sources: \(error.localizedDescription). Check System Settings → Privacy & Security → Screen & System Audio Recording; you may need to quit and reopen DrumTrainer."
            }
            isLoadingPlaybackSources = false
        }
    }

    func openPlaybackCapturePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func beginWaitingForPlayback() {
        stopWaitingForPlayback()
        playbackSourceTask?.cancel()
        playbackSourceRequestID = nil
        isLoadingPlaybackSources = false
        cancelMetronomeHeartbeat()
        metronomeEngine.stop()
        let id = UUID()
        playbackArmID = id
        earliestPracticeTickHostTime = clock.currentHostTime()
        practicePhase = .waitingForPlayback
        playbackInputLevelDBFS = -120
        playbackSyncMessage = "Starting audio capture. Keep Songsterr paused until Ready appears."
        let sourceID = selectedPlaybackSourceID!
        let threshold = min(max(playbackDetectionThresholdDBFS, -80), -10)
        playbackTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            self?.handlePlaybackWaitTimeout(id: id)
        }
        playbackArmTask = Task { [weak self] in
            guard let self, playbackArmID == id else { return }
            do {
                try await externalPlaybackListener.start(
                    sourceID: sourceID, thresholdDBFS: threshold,
                    onLevel: { [weak self] level, ready in
                        guard let self, playbackArmID == id else { return }
                        playbackInputLevelDBFS = level
                        playbackSyncMessage = ready
                            ? "Ready — press Play in Songsterr now. Waiting for sound…"
                            : "Waiting for 0.3 seconds of quiet. Pause Songsterr and silence other browser tabs."
                    },
                    onOnset: { [weak self] hostTime in
                        self?.handleExternalPlaybackOnset(hostTime: hostTime, id: id)
                    },
                    onError: { [weak self] message in
                        guard let self, playbackArmID == id else { return }
                        failPractice("Browser audio stopped: \(message). Check capture permission, then re-arm.")
                    }
                )
            } catch {
                guard playbackArmID == id, !Task.isCancelled else { return }
                failPractice("Could not listen to browser audio: \(error.localizedDescription). Check Screen & System Audio Recording permission, then re-arm.")
            }
        }
    }

    func handlePlaybackWaitTimeout(id: UUID) {
        guard playbackArmID == id, case .waitingForPlayback = practicePhase else { return }
        failPractice("No playback start detected within 45 seconds. Pause Songsterr, check the source and capture permission, then re-arm. If the level stays low during playback, lower the detection threshold.")
    }

    private func stopWaitingForPlayback() {
        playbackArmID = nil
        playbackArmTask?.cancel()
        playbackArmTask = nil
        playbackTimeoutTask?.cancel()
        playbackTimeoutTask = nil
        externalPlaybackListener.stop()
        playbackPreRoll.removeAll(keepingCapacity: true)
        latestDroppedPlaybackEventTime = nil
    }

    func handleExternalPlaybackOnset(hostTime: UInt64, id: UUID) {
        guard playbackArmID == id, case .waitingForPlayback = practicePhase else { return }
        let now = clock.currentHostTime()
        let age = timeline.sessionTimeNanoseconds(for: now) - timeline.sessionTimeNanoseconds(for: hostTime)
        guard hostTime >= earliestPracticeTickHostTime, (-250_000_000...2_000_000_000).contains(age) else {
            failPractice("Playback arrived with an unreliable timestamp. Cancel and re-arm before grading.")
            return
        }
        let preRoll = playbackPreRoll
        let latestDroppedTime = latestDroppedPlaybackEventTime
        stopWaitingForPlayback()
        let offsetMS = playbackStartOffsetMilliseconds.isFinite
            ? min(max(playbackStartOffsetMilliseconds, -5_000), 5_000) : 0
        let offsetTicks = timeline.converter.hostTime(forNanosecondDuration: UInt64(abs(offsetMS) * 1_000_000))
        let startHostTime = offsetMS >= 0
            ? timeline.hostTime(addingNanoseconds: UInt64(offsetMS * 1_000_000), to: hostTime)
            : hostTime - min(hostTime, offsetTicks)
        do {
            let start = timeline.sessionTimeNanoseconds(for: startHostTime)
            let pattern = try makePracticePattern(bpm: practiceBPM, startSessionTimeNanoseconds: start, startHostTime: startHostTime)
            let tolerance = pattern.expectedEvents.map(\.matchingToleranceNanoseconds).max() ?? 0
            if let latestDroppedTime, latestDroppedTime >= start - tolerance {
                failPractice("Too many drum hits arrived before playback was confirmed. This attempt was discarded; re-arm and wait for Songsterr before playing.")
                return
            }
            let end = addingWithoutOverflow(start, pattern.exactDurationNanoseconds)
            guard end > timeline.sessionTimeNanoseconds(for: now) else {
                failPractice("The start offset places this section in the past. Adjust the offset and re-arm.")
                return
            }
            practiceExpectedEvents = pattern.expectedEvents
            practiceActivePattern = pattern
            practiceRecording = PracticeSessionRecording(
                pattern: pattern, exerciseEndSessionTimeNanoseconds: end,
                scoringConfiguration: PracticeScoringConfiguration(gradeKicks: practiceGradeKicks)
            )
            for event in preRoll { practiceRecording?.record(event) }
            practiceRecordedHitCount = practiceRecording?.scoredActualEventCount ?? 0
            practicePhase = .running(startSessionTime: start, endSessionTime: end)
            playbackSyncMessage = "Audio start detected — alignment unverified. Fixed MIDI timeline; pauses, skips and tempo changes are not followed."
            schedulePracticeFinish(at: timeline.hostTime(
                addingNanoseconds: UInt64(max(pattern.exactDurationNanoseconds + tolerance, 0)), to: startHostTime
            ))
        } catch {
            failPractice(error.localizedDescription)
        }
    }

    func markExternalPlaybackSyncLost() {
        guard isExternalPlaybackRun, practicePhase.isActive else { return }
        failPractice("Sync lost — this attempt was discarded. Pause Songsterr, return to the selected measure and re-arm.")
    }

    func cancelPractice() {
        stopWaitingForPlayback()
        discardActivePracticeAudio()
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

    /// Restores an idle, startable practice transport even if an earlier Core Audio
    /// rebuild never delivered its completion callback.
    func resetPracticeTransport() {
        stopWaitingForPlayback()
        discardActivePracticeAudio()
        if timingAlignmentPhase.isActive { cancelTimingAlignment() }
        activeAudioFlowGeneration &+= 1
        audioEngineRefreshID = nil
        audioEngineRefreshFlowGeneration = nil
        audioEngineRefreshShouldRetryPractice = false
        audioEngineRefreshShouldRetryTimingAlignment = false
        audioEngineRefreshPreservesAutomaticAttempt = false
        audioEngineRefreshWatchdogTask?.cancel()
        audioEngineRefreshWatchdogTask = nil
        isRefreshingAudioEngine = false
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
        metronomeStallRecoveryAttempts = 0
        // Reset is also offered after a failed run and while idle. Those states
        // can still hold a poisoned serial audio queue, so always replace it.
        if replaceMetronomeEngine() {
            audioEngineRecoveryMessage = "Practice and its audio transport were reset. You can start again."
        } else {
            audioEngineRecoveryMessage = "Practice controls reset. You can start again or refresh the audio output."
            metronomeEngine.stop()
        }
    }

    func dismissPracticeResults() {
        guard !practicePhase.isActive else { return }
        practiceOutcome = nil
        practiceActivePattern = nil
        practiceExpectedEvents = []
        practiceRecordedHitCount = 0
        practicePhase = .idle
    }

    func setPracticeViewVisible(_ visible: Bool) {
        isPracticeViewVisible = visible
        if !visible { cancelPracticeAutoGoCountdown() }
    }

    private func cancelPracticeAutoGoCountdown() {
        practiceAutoGoTask?.cancel()
        practiceAutoGoTask = nil
        practiceAutoGoID = nil
        practiceAutoGoDeadline = nil
        practiceAutoGoSecondsRemaining = nil
    }

    private var canAutoGoFromResults: Bool {
        guard practiceAutoGoEnabled, isPracticeViewVisible, practicePhase == .results,
              practiceOutcome != nil, !isRefreshingAudioEngine,
              !microphoneCalibrationPhase.isActive, !timingAlignmentPhase.locksConfiguration else { return false }
        // Find My Ceiling offers Done when the search finishes, rather than another round.
        if !isExternalPlaybackRun, ceilingModeSettings.isEnabled,
           let run = activeCeilingRun, case .found = run.phase { return false }
        return true
    }

    private func schedulePracticeAutoGo() {
        cancelPracticeAutoGoCountdown()
        guard canAutoGoFromResults else { return }
        let seconds = practiceAutoGoDelaySeconds.isFinite
            ? min(max(practiceAutoGoDelaySeconds.rounded(), 1), 30) : 8
        let id = UUID()
        practiceAutoGoID = id
        practiceAutoGoDeadline = timeline.hostTime(
            addingNanoseconds: UInt64(seconds * 1_000_000_000), to: clock.currentHostTime()
        )
        practiceAutoGoSecondsRemaining = Int(seconds)
        practiceAutoGoTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self, self.practiceAutoGoID == id else { return }
                self.handlePracticeAutoGoTimer(at: self.clock.currentHostTime())
            }
        }
    }

    func handlePracticeAutoGoTimer(at hostTime: UInt64) {
        guard let deadline = practiceAutoGoDeadline else { return }
        guard canAutoGoFromResults else {
            cancelPracticeAutoGoCountdown()
            return
        }
        if hostTime < deadline {
            let remaining = timeline.converter.nanoseconds(forHostTimeDuration: deadline - hostTime)
            practiceAutoGoSecondsRemaining = Int(ceil(Double(remaining) / 1_000_000_000))
            return
        }
        // Follow the same replay path as Play Again / Next Round / Re-arm.
        dismissPracticeResults()
        startPractice()
    }

    var isCustomSequence: Bool { practiceExerciseMode == .custom && practiceCustomMeasure.isSequence }

    func setCustomSequenceMode(_ enabled: Bool) {
        guard !practicePhase.isActive, enabled != practiceCustomMeasure.isSequence else { return }
        if enabled {
            singleMeasureDraft = (practiceCustomMeasure, selectedSavedCustomExerciseID)
            var empty = CustomMeasureDefinition(name: "My sequence")
            empty.sequenceSteps = []
            empty.sequenceRepeats = 1
            let draft = sequenceDraft ?? (empty, nil)
            practiceCustomMeasure = draft.0
            selectedSavedCustomExerciseID = draft.1
        } else {
            sequenceDraft = (practiceCustomMeasure, selectedSavedCustomExerciseID)
            let draft = singleMeasureDraft ?? (CustomMeasureDefinition(), nil)
            practiceCustomMeasure = draft.0
            selectedSavedCustomExerciseID = draft.1
            practiceMeasures = 4
        }
        practiceActivePattern = nil
        if case .error = practicePhase { practicePhase = .idle }
    }

    func addCustomSequenceStep(savedID: UUID) {
        guard !practicePhase.isActive, practiceCustomMeasure.isSequence,
              let saved = savedCustomExercises.first(where: { $0.id == savedID }),
              !saved.definition.isSequence, !saved.definition.isEmpty else { return }
        var updated = practiceCustomMeasure
        updated.sequenceSteps?.append(CustomMeasureStep(measure: saved.definition))
        applySequenceEdit(updated)
    }

    func updateCustomSequenceStep(id: UUID, repeats: Int? = nil, moveBy: Int? = nil, remove: Bool = false) {
        guard !practicePhase.isActive, var steps = practiceCustomMeasure.sequenceSteps,
              let index = steps.firstIndex(where: { $0.id == id }) else { return }
        if remove { steps.remove(at: index) }
        else if let repeats { steps[index].repeats = repeats }
        else if let moveBy, steps.indices.contains(index + moveBy) { steps.swapAt(index, index + moveBy) }
        var updated = practiceCustomMeasure
        updated.sequenceSteps = steps
        applySequenceEdit(updated)
    }

    func setCustomSequenceRepeats(_ repeats: Int) {
        guard !practicePhase.isActive else { return }
        var updated = practiceCustomMeasure
        updated.sequenceRepeats = repeats
        applySequenceEdit(updated)
    }

    private func applySequenceEdit(_ updated: CustomMeasureDefinition) {
        if !updated.isEmpty, let message = updated.sequenceValidationMessage {
            practiceDataStatusMessage = message
            return
        }
        practiceCustomMeasure = updated
        practiceActivePattern = nil
        practiceDataStatusMessage = "Sequence edited. Save or update it to keep these changes."
        if case .error = practicePhase { practicePhase = .idle }
    }

    func toggleCustomMeasureHit(slot: Int, voice: DrumVoice) {
        guard !practicePhase.isActive else { return }
        var updated = practiceCustomMeasure
        updated.toggle(slot: slot, voice: voice)
        practiceCustomMeasure = updated
        if case .error = practicePhase { practicePhase = .idle }
    }

    func toggleCustomMeasureAccent(slot: Int, voice: DrumVoice) {
        guard !practicePhase.isActive else { return }
        var updated = practiceCustomMeasure
        updated.toggleAccent(slot: slot, voice: voice)
        practiceCustomMeasure = updated
        if case .error = practicePhase { practicePhase = .idle }
    }

    func toggleCustomMeasureGhost(slot: Int, voice: DrumVoice) {
        guard !practicePhase.isActive else { return }
        var updated = practiceCustomMeasure
        updated.toggleGhost(slot: slot, voice: voice)
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
        if !saved.definition.isSequence { practiceMeasures = min(max(practiceMeasures, 1), 16) }
        practiceActivePattern = nil
        practiceExerciseMode = .custom
        practiceDataStatusMessage = "Loaded \(saved.definition.displayName)."
        if case .error = practicePhase { practicePhase = .idle }
    }

    func saveCustomExercise(asNew: Bool = false) {
        guard !practicePhase.isActive, !practiceCustomMeasure.isEmpty else { return }
        if let message = practiceCustomMeasure.sequenceValidationMessage {
            practiceDataStatusMessage = message
            return
        }
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

    func jumpToFirstGradableImportedSection() {
        guard let song = selectedImportedSong else { return }
        let first = song.firstMeasureWithScorableNote(includeKicks: practiceGradeKicks)
            ?? song.firstMeasureWithScorableNote(includeKicks: true)
        guard let first else { return }
        let sectionLength = max(importedSectionEndMeasure - importedSectionStartMeasure + 1, 1)
        importedSectionStartMeasure = first
        importedSectionEndMeasure = min(first + sectionLength - 1, max(importedSongMeasureCount, 1))
        setImportedSection()
        if case .error = practicePhase { practicePhase = .idle }
        practiceDataStatusMessage = "Selected the first playable section: measures \(importedSectionStartMeasure)–\(importedSectionEndMeasure)."
    }

    func deletePracticeSession(id: UUID) {
        practiceHistory.removeAll { $0.id == id }
        practiceSessionRecords.removeAll { $0.id == id }
        do {
            try practiceAudioStore.deleteRecording(for: id)
            practiceAudioLibraryRevision &+= 1
        } catch {
            practiceDataStatusMessage = "The session was deleted, but its audio could not be removed: \(error.localizedDescription)"
        }
        if var run = activeCeilingRun {
            run.sessionIDs.removeAll { $0 == id }
            activeCeilingRun = run
        }
        persistPracticeData()
    }

    func clearPracticeHistory() {
        practiceHistory = []
        practiceSessionRecords = []
        var audioDeletionError: String?
        do {
            try practiceAudioStore.deleteAllRecordings()
            practiceAudioLibraryRevision &+= 1
        } catch {
            audioDeletionError = error.localizedDescription
        }
        tempoProgressions = []
        activeCeilingRun = nil
        ceilingRecords = []
        lastCeilingMessage = nil
        practiceDataStatusMessage = audioDeletionError.map {
            "History was cleared, but some audio files could not be removed: \($0)"
        } ?? "Cleared practice history and saved practice audio."
        persistPracticeData()
    }

    func practiceAudioAsset(sessionID: UUID) -> PracticeAudioAsset? {
        _ = practiceAudioLibraryRevision
        return practiceAudioStore.asset(for: sessionID)
    }

    var practiceAudioStorageBytes: Int64 {
        _ = practiceAudioLibraryRevision
        return practiceAudioStore.totalSizeBytes()
    }

    func deletePracticeAudio(sessionID: UUID) {
        do {
            try practiceAudioStore.deleteRecording(for: sessionID)
            practiceAudioLibraryRevision &+= 1
            practiceAudioStatusMessage = "Deleted the saved practice recording."
        } catch {
            practiceAudioStatusMessage = "Could not delete the recording: \(error.localizedDescription)"
        }
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
        cancelPracticeAutoGoCountdown()
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
        currentTimingAlignmentProfile(for: timingAlignmentSource)
    }

    var timingAlignmentProfilesForCurrentSetup: [TimingAlignmentProfile] {
        guard let identity = currentTimingAlignmentIdentity(for: timingAlignmentSource) else { return [] }
        return timingAlignmentProfiles
            .filter {
                $0.source == timingAlignmentSource
                    && $0.inputID == identity.inputID
                    && $0.outputUID == identity.outputUID
                    && $0.voice == (timingAlignmentSource == .midi ? .unknown : .kick)
            }
            .sorted { lhs, rhs in
                let lhsIndex = DrumVoice.allCases.firstIndex(of: lhs.voice) ?? Int.max
                let rhsIndex = DrumVoice.allCases.firstIndex(of: rhs.voice) ?? Int.max
                return lhsIndex == rhsIndex ? lhs.createdAt > rhs.createdAt : lhsIndex < rhsIndex
            }
    }

    /// Older builds saved one MIDI correction per drum voice. Those values remain
    /// readable for backwards compatibility, but are deliberately excluded from
    /// scoring now that the kit uses one shared MIDI-clock correction.
    var hasIgnoredLegacyMIDITimingProfilesForCurrentSetup: Bool {
        guard timingAlignmentSource == .midi,
              let identity = currentTimingAlignmentIdentity(for: .midi) else { return false }
        return timingAlignmentProfiles.contains {
            $0.source == .midi
                && $0.inputID == identity.inputID
                && $0.outputUID == identity.outputUID
                && $0.voice != .unknown
        }
    }

    func selectTimingAlignmentSource(_ source: TimingAlignmentSource) {
        guard !timingAlignmentPhase.locksConfiguration else { return }
        timingAlignmentSource = source
        timingAlignmentPhase = .idle
    }

    func startTimingAlignment() {
        cancelPracticeAutoGoCountdown()
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
        clearTimingAlignmentVisualBeat()
        timingAlignmentFinishTask?.cancel()
        timingAlignmentFinishTask = nil
        timingAlignmentStartWatchdogTask?.cancel()
        timingAlignmentCollector = TimingAlignmentCollector(
            source: timingAlignmentSource.eventSource,
            voice: timingAlignmentSource == .microphone ? .kick : nil
        )
        metronomeStallRecoveryAttempts = 0
        beginTimingAlignmentMetronomeStart()
    }

    /// Calibration retries use a new transport instead of trusting an AVAudioEngine that
    /// has already completed a stop/start cycle. Old callbacks are generation-gated, so a
    /// wedged USB/Core Audio queue cannot strand the new run or move its state backwards.
    func retryTimingAlignment() {
        guard !isRefreshingAudioEngine else { return }
        let replacedTransport = replaceMetronomeEngine()
        if !replacedTransport {
            metronomeEngine.stop()
        }
        startTimingAlignment()
        if replacedTransport, timingAlignmentPhase == .starting {
            audioEngineRecoveryMessage = "Calibration audio was restarted with a fresh transport."
        }
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
        clearTimingAlignmentVisualBeat()
        timingAlignmentStartWatchdogTask?.cancel()
        timingAlignmentStartWatchdogTask = nil
        timingAlignmentFinishTask?.cancel()
        timingAlignmentFinishTask = nil
        timingAlignmentCollector = TimingAlignmentCollector(source: .midi, voice: nil)
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
            updateKickMonitorAudioConfiguration()
            if selectedAudioInputID == nil {
                audioStatus = .ready
            }
        }
        ensureSelectedAudioInputIsMonitoring()
        configurePracticeAudioInputCapture()
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

    func refreshMIDIInputs() {
        midiInputService.start()
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
        configurePracticeAudioInputCapture()
    }

    func selectPracticeAudioInput(uid: String?) {
        practiceAudioInputUID = uid
    }

    func selectAudioOutput(_ deviceID: AudioDeviceID?) {
        if timingAlignmentPhase.isActive { cancelTimingAlignment() }
        if isExternalPlaybackRun, practicePhase.isActive {
            markExternalPlaybackSyncLost()
        }
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
        guard !isRefreshingAudioEngine else { return }
        if !practicePhase.isActive {
            practicePhase = .countIn(beatsRemaining: Self.countInBeats)
        }
        refreshAudioEngine(retryActiveFlow: true)
    }

    func refreshAudioEngineAndRetryTimingAlignment() {
        guard !isRefreshingAudioEngine else { return }
        retryTimingAlignment()
    }

    private func refreshAudioEngine(
        retryActiveFlow: Bool,
        preserveAutomaticRecoveryAttempt: Bool
    ) {
        guard !isRefreshingAudioEngine else { return }
        stopWaitingForPlayback()
        let retryPractice = retryActiveFlow && practicePhase.isActive
        let retryTimingAlignment = retryActiveFlow && timingAlignmentPhase.isActive

        activeAudioFlowGeneration &+= 1
        let refreshGeneration = activeAudioFlowGeneration
        let refreshID = UUID()
        audioEngineRefreshID = refreshID
        audioEngineRefreshFlowGeneration = refreshGeneration
        audioEngineRefreshShouldRetryPractice = retryPractice
        audioEngineRefreshShouldRetryTimingAlignment = retryTimingAlignment
        audioEngineRefreshPreservesAutomaticAttempt = preserveAutomaticRecoveryAttempt
        isRefreshingAudioEngine = true
        audioEngineRecoveryMessage = "Rebuilding the app audio engine…"
        audioEngineRefreshWatchdogTask?.cancel()
        audioEngineRefreshWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.handleAudioRefreshTimeout(requestID: refreshID)
        }
        cancelMetronomeHeartbeat()
        practiceFinishTask?.cancel()
        practiceFinishTask = nil
        timingAlignmentStartWatchdogTask?.cancel()
        timingAlignmentStartWatchdogTask = nil
        timingAlignmentFinishTask?.cancel()
        timingAlignmentFinishTask = nil

        if practicePhase.isActive {
            discardActivePracticeAudio()
            practiceRecording = nil
            pendingPracticeBounds = nil
            practiceActivePattern = nil
            practiceExpectedEvents = []
            practiceOutcome = nil
            practiceRecordedHitCount = 0
            practicePhase = .idle
        }
        if timingAlignmentPhase.isActive {
            clearTimingAlignmentVisualBeat()
            timingAlignmentCollector = TimingAlignmentCollector(source: .midi, voice: nil)
            timingAlignmentPhase = .idle
        }

        metronomeEngine.rebuildAudioGraph { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.audioEngineRefreshID == refreshID else { return }
                self.audioEngineRefreshID = nil
                self.audioEngineRefreshFlowGeneration = nil
                self.audioEngineRefreshShouldRetryPractice = false
                self.audioEngineRefreshShouldRetryTimingAlignment = false
                self.audioEngineRefreshPreservesAutomaticAttempt = false
                self.audioEngineRefreshWatchdogTask?.cancel()
                self.audioEngineRefreshWatchdogTask = nil
                self.isRefreshingAudioEngine = false
                self.audioEngineRecoveryMessage = "App audio refreshed."
                // Completion must always release its own busy flag, even if the
                // user cancelled the flow. Only an unchanged flow may auto-retry.
                guard self.activeAudioFlowGeneration == refreshGeneration else { return }
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

    func handleAudioRefreshTimeout(requestID: UUID) {
        guard audioEngineRefreshID == requestID else { return }
        let refreshGeneration = audioEngineRefreshFlowGeneration
        let retryPractice = audioEngineRefreshShouldRetryPractice
        let retryTimingAlignment = audioEngineRefreshShouldRetryTimingAlignment
        let preserveAutomaticRecoveryAttempt = audioEngineRefreshPreservesAutomaticAttempt
        audioEngineRefreshID = nil
        audioEngineRefreshFlowGeneration = nil
        audioEngineRefreshShouldRetryPractice = false
        audioEngineRefreshShouldRetryTimingAlignment = false
        audioEngineRefreshPreservesAutomaticAttempt = false
        audioEngineRefreshWatchdogTask?.cancel()
        audioEngineRefreshWatchdogTask = nil
        isRefreshingAudioEngine = false
        let flowIsStillCurrent = refreshGeneration == activeAudioFlowGeneration
        if replaceMetronomeEngine() {
            audioEngineRecoveryMessage = "The old audio engine stopped responding, so the app replaced it without requiring a relaunch."
            guard flowIsStillCurrent else { return }
            if retryPractice {
                startPractice()
                if preserveAutomaticRecoveryAttempt { metronomeStallRecoveryAttempts = 1 }
            } else if retryTimingAlignment {
                startTimingAlignment()
                if preserveAutomaticRecoveryAttempt { metronomeStallRecoveryAttempts = 1 }
            }
        } else {
            audioEngineRecoveryMessage = "Audio refresh did not respond within six seconds. Controls are unlocked."
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

    func testKickMonitor() {
        guard kickMonitorEnabled else { return }
        metronomeEngine.triggerKick(
            velocity: 1,
            eventHostTime: clock.currentHostTime(),
            respectsRetriggerLockout: false
        )
    }

    private func updateKickMonitorAudioConfiguration() {
        metronomeEngine.updateKickMonitoring(
            enabled: kickMonitorEnabled,
            sound: kickMonitorSound,
            gainDecibels: kickMonitorGainDecibels,
            velocitySensitive: kickMonitorVelocitySensitive,
            retriggerMilliseconds: kickMonitorRetriggerMilliseconds,
            startAudioIfNeeded: hasStartedHardwareMonitoring
        )
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
        monitorKickIfNeeded(event)
        recordPracticeEvent(event)
        let snapshot = await eventStream.append(event)
        events = snapshot.events
        droppedEventCount = snapshot.droppedCount
    }

    /// Accepts normalized player events, including the short pre-roll needed
    /// while external audio onset confirmation is still in flight.
    func recordPracticeEvent(_ event: PerformanceEvent) {
        if case .waitingForPlayback = practicePhase, event.source != .metronome {
            playbackPreRoll.append(event)
            if playbackPreRoll.count > 512 {
                let removed = playbackPreRoll.removeFirst()
                latestDroppedPlaybackEventTime = max(latestDroppedPlaybackEventTime ?? Int64.min, removed.sessionTimeNanoseconds)
            }
        }
        practiceRecording?.record(event)
        practiceRecordedHitCount = practiceRecording?.scoredActualEventCount ?? practiceRecordedHitCount
    }

    private func monitorKickIfNeeded(_ event: PerformanceEvent) {
        guard kickMonitorEnabled,
              event.voice == .kick,
              kickMonitorSource.accepts(event.source),
              !isCollectingCalibration,
              !timingAlignmentPhase.isActive else { return }

        let velocity: Double
        if let eventVelocity = event.velocity {
            velocity = eventVelocity
        } else if case let .microphone(amplitude, threshold, _) = event.rawMetadata {
            let usableRange = max(1 - threshold, 0.000_001)
            velocity = min(max((amplitude - threshold) / usableRange, 0), 1)
        } else {
            velocity = event.confidence
        }
        metronomeEngine.triggerKick(velocity: velocity, eventHostTime: event.hostTime)
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
        let flowGeneration = activeAudioFlowGeneration
        let event = timeline.makeEvent(
            source: .metronome,
            voice: .metronome,
            hostTime: tick.hostTime,
            confidence: 1,
            metadata: .metronome(beat: tick.beat, subdivision: 0)
        )
        await publish(event)
        guard activeAudioFlowGeneration == flowGeneration else { return }
        recordMetronomeHeartbeat()
        handleTimingAlignmentTick(tick)
        handlePracticeTick(tick)
    }

    private func handleTimingAlignmentTick(_ tick: MetronomeTick) {
        switch timingAlignmentPhase {
        case .countIn, .collecting:
            showTimingAlignmentVisualBeat(tick.beat)
        case .idle, .starting, .review, .saved, .error:
            break
        }

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
            clearTimingAlignmentVisualBeat()
            timingAlignmentStartWatchdogTask?.cancel()
            timingAlignmentStartWatchdogTask = nil
            timingAlignmentFinishTask?.cancel()
            timingAlignmentFinishTask = nil
            cancelMetronomeHeartbeat()
            timingAlignmentPhase = .error(message)

        case let .disconnected(name):
            guard timingAlignmentPhase.isActive else { return }
            clearTimingAlignmentVisualBeat()
            timingAlignmentStartWatchdogTask?.cancel()
            timingAlignmentStartWatchdogTask = nil
            timingAlignmentFinishTask?.cancel()
            timingAlignmentFinishTask = nil
            cancelMetronomeHeartbeat()
            timingAlignmentPhase = .error("\(name) disconnected. Choose an available output and retry.")

        case .stopped, .ready, .monitoringKicks:
            break
        }
    }

    private func handlePracticeMetronomeStatus(_ status: MetronomeStatus) {
        guard practicePhase.isActive, !isRefreshingAudioEngine, !isExternalPlaybackRun else { return }
        switch status {
        case let .error(message):
            failPractice(message)
        case let .disconnected(name):
            failPractice("\(name) disconnected. Choose an available output, then retry.")
        case .stopped, .ready, .running, .monitoringKicks:
            // A queued stop from the completed run may arrive just before a rapid replay starts.
            // Tick heartbeat monitoring, rather than this transitional status, detects a true stall.
            break
        }
    }

    private func failPractice(_ message: String) {
        stopWaitingForPlayback()
        discardActivePracticeAudio()
        activeAudioFlowGeneration &+= 1
        cancelMetronomeHeartbeat()
        practiceFinishTask?.cancel()
        practiceFinishTask = nil
        practiceRecording = nil
        pendingPracticeBounds = nil
        practiceActivePattern = nil
        practiceExpectedEvents = []
        practiceRecordedHitCount = 0
        practicePhase = .error(message)
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

    private func showTimingAlignmentVisualBeat(_ beat: Int) {
        timingAlignmentBeatClearTask?.cancel()
        timingAlignmentVisibleBeat = min(max(beat, 1), 4)
        timingAlignmentBeatClearTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.timingAlignmentVisibleBeat = nil
            self.timingAlignmentBeatClearTask = nil
        }
    }

    private func clearTimingAlignmentVisualBeat() {
        timingAlignmentBeatClearTask?.cancel()
        timingAlignmentBeatClearTask = nil
        timingAlignmentVisibleBeat = nil
    }

    func recoverFromMetronomeStall() {
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
            failPractice(
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
        clearTimingAlignmentVisualBeat()
        timingAlignmentStartWatchdogTask?.cancel()
        timingAlignmentStartWatchdogTask = nil
        timingAlignmentFinishTask = nil
        metronomeEngine.stop()
        guard let measurement = timingAlignmentCollector.measurement(),
              measurement.sampleCount >= 8 else {
            timingAlignmentPhase = .error(
                timingAlignmentSource == .midi
                    ? "Not enough MIDI hits were detected. Play one e-kit pad once on each click, then retry."
                    : "Not enough kick hits were detected. Play the kick once on each click, then retry."
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
            voice: timingAlignmentSource == .microphone ? .kick : .unknown,
            compensationMilliseconds: correction,
            medianAbsoluteDeviationMilliseconds: measurement.medianAbsoluteDeviationMilliseconds,
            sampleCount: measurement.sampleCount,
            createdAt: Date()
        )
        timingAlignmentPhase = .review(profile)
    }

    func handlePracticeTick(_ tick: MetronomeTick) {
        guard !isRefreshingAudioEngine, tick.hostTime >= earliestPracticeTickHostTime,
              case let .countIn(beatsRemaining) = practicePhase else { return }
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
                exerciseEndSessionTimeNanoseconds: endSessionTime,
                scoringConfiguration: PracticeScoringConfiguration(gradeKicks: practiceGradeKicks)
            )
            let sessionID = UUID()
            activePracticeSessionID = sessionID
            schedulePracticeAudio(
                sessionID: sessionID,
                startHostTime: startHostTime,
                endHostTime: timeline.hostTime(
                    addingNanoseconds: durationNanoseconds,
                    to: startHostTime
                )
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

    private func schedulePracticeAudio(
        sessionID: UUID,
        startHostTime: UInt64,
        endHostTime: UInt64
    ) {
        guard practiceAudioRecordingEnabled else { return }
        guard let recordingDevice = selectedPracticeAudioInputDevice else {
            practiceAudioStatusMessage = "Audio was not recorded because no practice recording input is available."
            return
        }
        guard isPracticeAudioInputMonitoring else {
            practiceAudioStatusMessage = "Audio was not recorded because \(recordingDevice.name) was not monitoring."
            return
        }
        guard let channelCount = practiceAudioInputChannelCount,
              practiceAudioChannelSelection.isAvailable(channelCount: channelCount) else {
            practiceAudioStatusMessage = "Audio was not recorded because \(practiceAudioChannelSelection.displayName) is unavailable on \(recordingDevice.name)."
            return
        }
        do {
            try practiceAudioRecorder.start(
                sessionID: sessionID,
                sourceDeviceID: recordingDevice.id,
                channelIndices: practiceAudioChannelSelection.channelIndices,
                startHostTime: startHostTime,
                endHostTime: endHostTime
            )
            isPracticeAudioScheduled = true
            practiceAudioStatusMessage = "Recording \(recordingDevice.name) · \(practiceAudioChannelSelection.displayName)."
        } catch {
            isPracticeAudioScheduled = false
            practiceAudioStatusMessage = "Practice scoring will continue, but audio recording could not start: \(error.localizedDescription)"
        }
    }

    private func finishActivePracticeAudio() {
        guard isPracticeAudioScheduled else {
            activePracticeSessionID = nil
            return
        }
        isPracticeAudioScheduled = false
        activePracticeSessionID = nil
        practiceAudioRecorder.finish { [weak self] asset, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                practiceAudioLibraryRevision &+= 1
                if let asset {
                    practiceAudioStatusMessage = "Saved practice audio (\(ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file)))."
                } else if let error {
                    practiceAudioStatusMessage = "Practice was saved without audio: \(error)"
                }
            }
        }
    }

    private func discardActivePracticeAudio() {
        if isPracticeAudioScheduled {
            practiceAudioRecorder.cancel()
        }
        isPracticeAudioScheduled = false
        activePracticeSessionID = nil
    }

    func finishPractice() {
        cancelMetronomeHeartbeat()
        guard practicePhase.isActive, let practiceRecording else { return }
        practiceFinishTask?.cancel()
        let outcome = practiceRecording.finish(matcher: currentEventMatcher)
        practiceOutcome = outcome
        if isExternalPlaybackRun {
            // An onset trigger is not verified song synchronization. Keep prototype
            // scores out of history, clean-tempo records, and ceiling progression.
            self.practiceRecording = nil
            pendingPracticeBounds = nil
            practiceFinishTask = nil
            practicePhase = .results
            schedulePracticeAutoGo()
            return
        }
        let sessionID = activePracticeSessionID ?? UUID()
        let summary = PracticeSessionSummary(
            id: sessionID,
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
            let removedIDs = Set(practiceHistory.dropFirst(2_000).map(\.id))
            practiceHistory.removeLast(practiceHistory.count - 2_000)
            let retainedIDs = Set(practiceHistory.map(\.id))
            practiceSessionRecords.removeAll { !retainedIDs.contains($0.id) }
            for id in removedIDs { try? practiceAudioStore.deleteRecording(for: id) }
            practiceAudioLibraryRevision &+= 1
        }
        updateTempoProgression(after: summary)
        updateCeilingRun(after: summary)
        persistPracticeData()
        finishActivePracticeAudio()
        self.practiceRecording = nil
        pendingPracticeBounds = nil
        practiceFinishTask = nil
        practicePhase = .results
        metronomeEngine.stop()
        schedulePracticeAutoGo()
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
        case .custom:
            if practiceCustomMeasure.isSequence {
                let measures = practiceCustomMeasure.expandedSequence
                return measures.isEmpty ? 0 : measures.reduce(0) { $0 + $1.hits.count } / measures.count
            }
            return practiceCustomMeasure.hits.count
        case .importedSong:
            guard let pattern = practicePreviewPattern, pattern.measures > 0 else { return 0 }
            return Int((Double(pattern.expectedEvents.count) / Double(pattern.measures)).rounded())
        }
    }

    var practiceGuidance: String {
        switch practiceExerciseMode {
        case .builtIn: practiceExercise.guidance
        case .custom: practiceCustomMeasure.isSequence
            ? "Arrange saved measures, choose repeats for each step, then play through every transition at one tempo."
            : "Click the grid to place exact drum voices. The authored measure repeats for the selected measure count."
        case .importedSong: "Choose the drum track, verify every MIDI-note mapping, then loop a measure range. The click follows the scaled MIDI tempo and meter map."
        }
    }

    var nextTempoProgressionBPM: Double {
        min(practiceBPM + tempoProgressionSettings.stepBPM, 240)
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
                measures: practiceMeasures,
                accentVelocityThreshold: practiceAccentVelocityFloorEnabled
                    ? Double(practiceAccentVelocityThreshold) / 127
                    : nil,
                accentVelocityContrast: Double(practiceAccentContrastPoints) / 127,
                ghostVelocityCeiling: practiceGhostVelocityCeilingEnabled
                    ? Double(practiceGhostVelocityCeiling) / 127 : nil,
                ghostVelocityContrast: Double(practiceGhostContrastPoints) / 127
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

    var importedSectionMappedHitCount: Int {
        selectedImportedSong?.scorableNoteCount(
            fromMeasure: importedSectionStartMeasure,
            throughMeasure: importedSectionEndMeasure
        ) ?? 0
    }

    var importedSectionEligibleHitCount: Int {
        selectedImportedSong?.scorableNoteCount(
            fromMeasure: importedSectionStartMeasure,
            throughMeasure: importedSectionEndMeasure,
            includeKicks: practiceGradeKicks
        ) ?? 0
    }

    var firstGradableImportedMeasure: Int? {
        selectedImportedSong?.firstMeasureWithScorableNote(includeKicks: practiceGradeKicks)
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
            let firstPlayableMeasure = song.firstMeasureWithScorableNote(includeKicks: practiceGradeKicks)
                ?? song.firstMeasureWithScorableNote(includeKicks: true)
                ?? 1
            importedSectionStartMeasure = firstPlayableMeasure
            importedSectionEndMeasure = min(firstPlayableMeasure + 3, max(measures.count, 1))
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
        // Keep archived suggestions in sync, but never use them to choose a raise.
        tempoProgressions[index].suggestedBPM = summary.bpm
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
                    summary.bpm + tempoProgressionSettings.stepBPM,
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

    var selectedPracticeAudioInputDevice: AudioInputDevice? {
        if let practiceAudioInputUID {
            return audioDevices.first(where: { $0.uid == practiceAudioInputUID })
        }
        return selectedAudioInputDevice
    }

    var effectivePracticeAudioInputStatus: AudioInputStatus {
        guard practiceAudioRecordingEnabled else { return .stopped }
        guard let recordingDevice = selectedPracticeAudioInputDevice else {
            return practiceAudioInputUID == nil
                ? .ready
                : .disconnected("Saved practice recording input")
        }
        if recordingDevice.id == selectedAudioInputID {
            return audioStatus
        }
        return practiceAudioInputStatus
    }

    var isPracticeAudioInputMonitoring: Bool {
        effectivePracticeAudioInputStatus.isMonitoring
    }

    var practiceAudioInputChannelCount: Int? {
        if case let .monitoring(_, _, channels) = effectivePracticeAudioInputStatus {
            return channels
        }
        return nil
    }

    private func configurePracticeAudioInputCapture() {
        guard hasStartedHardwareMonitoring else { return }
        guard practiceAudioRecordingEnabled else {
            if activePracticeRecordingCaptureDeviceID != nil {
                activePracticeRecordingCaptureDeviceID = nil
                practiceRecordingInputService.select(device: nil)
            }
            practiceAudioInputStatus = .stopped
            return
        }
        guard let recordingDevice = selectedPracticeAudioInputDevice else {
            if activePracticeRecordingCaptureDeviceID != nil {
                activePracticeRecordingCaptureDeviceID = nil
                practiceRecordingInputService.disconnect(
                    deviceName: "Saved practice recording input"
                )
            } else if practiceAudioInputUID != nil {
                practiceAudioInputStatus = .disconnected("Saved practice recording input")
            } else {
                practiceAudioInputStatus = .ready
            }
            return
        }

        // The kick-detection service already owns this device and forwards its
        // buffers to the recorder, so opening a second engine would be redundant.
        if recordingDevice.id == selectedAudioInputID {
            if activePracticeRecordingCaptureDeviceID != nil {
                activePracticeRecordingCaptureDeviceID = nil
                practiceRecordingInputService.select(device: nil)
            }
            return
        }

        guard activePracticeRecordingCaptureDeviceID != recordingDevice.id else { return }
        activePracticeRecordingCaptureDeviceID = recordingDevice.id
        practiceRecordingInputService.select(device: recordingDevice)
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

    private func currentTimingAlignmentProfile(
        for source: TimingAlignmentSource
    ) -> TimingAlignmentProfile? {
        guard let identity = currentTimingAlignmentIdentity(for: source) else { return nil }
        let voice = source == .microphone ? DrumVoice.kick : DrumVoice.unknown
        let key = TimingAlignmentProfile.key(
            source: source,
            inputID: identity.inputID,
            outputUID: identity.outputUID,
            voice: voice
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
