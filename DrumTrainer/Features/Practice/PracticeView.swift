import SwiftUI
import UniformTypeIdentifiers

struct PracticeView: View {
    @ObservedObject var state: AppState
    @State private var timingTimelineFilter: TimingTimelineFilter = .all
    @State private var showsDeleteSavedExerciseConfirmation = false
    @State private var showsMIDIImporter = false
    @State private var midiImportError: String?
    @State private var pendingImportedSongDeletion: ImportedSong?
    @State private var customNoteTool: CustomNoteTool = .note
    @State private var sequenceSourceID: UUID?

    private enum CustomNoteTool: String, CaseIterable, Identifiable {
        case note = "Notes"
        case accent = "Accents >"
        case ghost = "Ghost notes ( )"
        var id: String { rawValue }
        var guidance: String {
            switch self {
            case .note: "Click a cell to add or remove a note."
            case .accent: "Click to toggle an accent. Empty cells create accented notes."
            case .ghost: "Click to toggle a ghost note. Empty cells create ghost notes. Ghost and accent markings replace each other."
            }
        }
    }

    private enum TimingTimelineFilter: String, CaseIterable, Identifiable {
        case all
        case problems

        var id: String { rawValue }
        var displayName: String { self == .all ? "All hits" : "Problems only" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let outcome = state.practiceOutcome, state.practicePhase == .results {
                    if let seconds = state.practiceAutoGoSecondsRemaining {
                        HStack(spacing: 12) {
                            Label("Auto go · next round in \(seconds)s", systemImage: "repeat")
                                .font(.headline)
                                .monospacedDigit()
                            Spacer()
                            Button("Stop Auto go") { state.practiceAutoGoEnabled = false }
                        }
                        .padding(12)
                        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    }
                    results(outcome)
                } else {
                    configuration
                    scorePlayer
                    runStatus
                }
            }
            .padding(20)
        }
        .navigationTitle("Practice")
        .task { state.startHardwareMonitoring() }
        .onAppear { state.setPracticeViewVisible(true) }
        .onDisappear { state.setPracticeViewVisible(false) }
        .alert(
            "Delete saved exercise?",
            isPresented: $showsDeleteSavedExerciseConfirmation,
            presenting: selectedSavedCustomExercise
        ) { exercise in
            Button("Delete \(exercise.definition.displayName)", role: .destructive) {
                state.deleteSavedCustomExercise(id: exercise.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { exercise in
            Text("The authored measure will be removed from your library. Existing practice-history summaries are kept.")
        }
        .fileImporter(
            isPresented: $showsMIDIImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "mid") ?? .data,
                UTType(filenameExtension: "midi") ?? .data
            ]
        ) { result in
            do {
                let url = try result.get()
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                try state.importStandardMIDI(Data(contentsOf: url), filename: url.lastPathComponent)
            } catch {
                midiImportError = error.localizedDescription
            }
        }
        .alert("MIDI import failed", isPresented: Binding(
            get: { midiImportError != nil },
            set: { if !$0 { midiImportError = nil } }
        )) {
            Button("OK") { midiImportError = nil }
        } message: {
            Text(midiImportError ?? "Unknown error")
        }
        .alert(
            "Delete imported song?",
            isPresented: Binding(
                get: { pendingImportedSongDeletion != nil },
                set: { if !$0 { pendingImportedSongDeletion = nil } }
            ),
            presenting: pendingImportedSongDeletion
        ) { song in
            Button("Delete \(song.displayName)", role: .destructive) {
                state.deleteImportedSong(id: song.id)
                pendingImportedSongDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingImportedSongDeletion = nil }
        } message: { _ in
            Text("The imported MIDI and its mappings will be removed. Existing scored sessions remain in History.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drum Set Practice")
                .font(.title.bold())
            Text("Choose an exercise, follow the moving drum score, then review every hit")
                .foregroundStyle(.secondary)
        }
    }

    private var configuration: some View {
        GroupBox("Exercise setup") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Text("Type").frame(width: 72, alignment: .leading)
                    Picker("Exercise type", selection: $state.practiceExerciseMode) {
                        ForEach(PracticeExerciseMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 310)
                    Spacer()
                }

                if state.practiceExerciseMode == .builtIn {
                    HStack(alignment: .top, spacing: 12) {
                        Text("Exercise").frame(width: 72, alignment: .leading)
                        Picker("Exercise", selection: $state.practiceExercise) {
                            ForEach(exerciseCategories, id: \.self) { category in
                                Section(category.capitalized) {
                                    ForEach(KickExercise.allCases.filter { $0.category == category }) { exercise in
                                        Text(exercise.displayName).tag(exercise)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300)
                        difficultyLabel
                        Spacer()
                    }
                } else if state.practiceExerciseMode == .custom {
                    Picker("Custom practice", selection: Binding(
                        get: { state.practiceCustomMeasure.isSequence },
                        set: { state.setCustomSequenceMode($0) }
                    )) {
                        Text("Single measure").tag(false)
                        Text("Measure sequence").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 340)
                    customExerciseLibraryControls

                    HStack(spacing: 12) {
                        Text("Name").frame(width: 72, alignment: .leading)
                        TextField("My custom measure", text: $state.practiceCustomMeasure.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                        if !state.isCustomSequence {
                        Text("Grid")
                        Picker("Grid subdivision", selection: Binding(
                            get: { state.practiceCustomMeasure.subdivision },
                            set: { state.setCustomMeasureSubdivision($0) }
                        )) {
                            ForEach(KickSubdivision.allCases, id: \.self) { subdivision in
                                Text(subdivision.displayName).tag(subdivision)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        }
                        Spacer()
                    }
                } else {
                    importedSongControls
                    externalPlaybackControls
                }

                HStack(alignment: .top, spacing: 12) {
                    Text("How").frame(width: 72, alignment: .leading)
                    Label(state.practiceGuidance, systemImage: "music.note.list")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(alignment: .top, spacing: 12) {
                    Text("Scoring").frame(width: 72, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Grade kicks", isOn: $state.practiceGradeKicks)
                            .toggleStyle(.switch)
                        Text(state.practiceGradeKicks
                            ? "Kick notes and detected kicks count toward every accuracy metric."
                            : "Kick notes stay on the score, but expected and detected kicks are excluded from grading.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if state.practiceExerciseMode == .custom {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text("Accent contrast")
                                    Stepper(
                                        "+\(state.practiceAccentContrastPoints) velocity points",
                                        value: $state.practiceAccentContrastPoints,
                                        in: 1...127
                                    )
                                    .monospacedDigit()
                                    Text("or 20%, whichever is greater")
                                }
                                HStack(spacing: 8) {
                                    Toggle(
                                        "Also require minimum velocity",
                                        isOn: $state.practiceAccentVelocityFloorEnabled
                                    )
                                    .toggleStyle(.checkbox)
                                    if state.practiceAccentVelocityFloorEnabled {
                                        Stepper(
                                            "\(state.practiceAccentVelocityThreshold)",
                                            value: $state.practiceAccentVelocityThreshold,
                                            in: 1...127
                                        )
                                        .monospacedDigit()
                                        Text("or higher")
                                    }
                                }
                                Text("Accents use up to four nearby, correctly played normal notes of the same drum voice. Ghost notes are excluded.")
                                Divider()
                                HStack(spacing: 8) {
                                    Text("Ghost softness")
                                    Stepper(
                                        "−\(state.practiceGhostContrastPoints) velocity points",
                                        value: $state.practiceGhostContrastPoints, in: 1...127
                                    )
                                    Text("or 20% softer, whichever is greater")
                                }
                                HStack(spacing: 8) {
                                    Toggle("Also require maximum velocity", isOn: $state.practiceGhostVelocityCeilingEnabled)
                                        .toggleStyle(.checkbox)
                                    if state.practiceGhostVelocityCeilingEnabled {
                                        Stepper(
                                            "\(state.practiceGhostVelocityCeiling)",
                                            value: $state.practiceGhostVelocityCeiling, in: 1...127
                                        )
                                        Text("or lower")
                                    }
                                }
                                Text("Ghost notes use the same normal-note baseline. With no baseline, only the enabled maximum is checked; otherwise the result is unavailable.")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                if state.practiceExerciseMode == .custom {
                    if state.isCustomSequence { customSequenceEditor }
                    else { customMeasureEditor }
                }

                HStack(spacing: 12) {
                    Text("Tempo").frame(width: 72, alignment: .leading)
                    Text("\(Int(state.practiceBPM)) BPM")
                        .frame(width: 74, alignment: .trailing)
                        .monospacedDigit()
                    Slider(value: $state.practiceBPM, in: 40...240, step: 1)
                        .frame(maxWidth: 300)
                    Stepper("", value: $state.practiceBPM, in: 40...240, step: 1)
                        .labelsHidden()
                    if state.isCustomSequence {
                        Text("\(state.practiceCustomMeasure.sequenceMeasureCount) total measures")
                    } else if state.practiceExerciseMode != .importedSong {
                        Text("Measures")
                        Stepper("\(state.practiceMeasures)", value: $state.practiceMeasures, in: 1...16)
                            .monospacedDigit()
                    } else if let song = state.selectedImportedSong {
                        Text("Original \(Int(song.originalBPM.rounded())) BPM")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(alignment: .top, spacing: 12) {
                    Text("Repeat").frame(width: 72, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Auto go", isOn: $state.practiceAutoGoEnabled)
                            .toggleStyle(.switch)
                        if state.practiceAutoGoEnabled {
                            HStack(spacing: 12) {
                                Text("Show results for")
                                Slider(value: $state.practiceAutoGoDelaySeconds, in: 1...30, step: 1)
                                    .frame(maxWidth: 240)
                                    .accessibilityLabel("Auto go results delay")
                                Text("\(Int(state.practiceAutoGoDelaySeconds)) seconds")
                                    .monospacedDigit()
                                    .frame(width: 86, alignment: .trailing)
                            }
                            Text("Start the next round automatically after results, with the usual count-in. Stop Auto go on the results screen to take a break.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Progress").frame(width: 72, alignment: .leading)
                    Toggle("Auto-advance tempo", isOn: progressionEnabledBinding)
                        .toggleStyle(.switch)
                    Text("after")
                    Stepper(
                        "\(state.tempoProgressionSettings.requiredCleanSessions) clean runs",
                        value: requiredCleanRunsBinding,
                        in: 1...10
                    )
                    Text("raise")
                    Stepper(
                        "+\(Int(state.tempoProgressionSettings.stepBPM.rounded())) BPM",
                        value: progressionStepBinding,
                        in: 1...20,
                        step: 1
                    )
                    Spacer()
                }
                .font(.callout)

                if let progression = state.currentTempoProgression {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 72, height: 1)
                        Label(
                            "Next advance: \(Int(state.nextTempoProgressionBPM.rounded())) BPM · \(progression.consecutiveCleanSessions)/\(state.tempoProgressionSettings.requiredCleanSessions) clean runs" +
                                (progression.highestCleanBPM.map { " · best clean \(Int($0.rounded())) BPM" } ?? ""),
                            systemImage: "chart.line.uptrend.xyaxis"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Text("Ceiling").frame(width: 72, alignment: .leading)
                    Toggle("Find My Ceiling", isOn: ceilingModeEnabledBinding)
                        .toggleStyle(.switch)
                    Text("raise each clean round by")
                    Stepper(
                        "+\(Int(state.ceilingModeSettings.stepBPM.rounded())) BPM",
                        value: ceilingStepBinding,
                        in: 1...20,
                        step: 1
                    )
                    if state.activeCeilingRun != nil {
                        Button("Reset Search", role: .destructive) { state.resetCeilingRun() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                }
                .font(.callout)

                if state.ceilingModeSettings.isEnabled {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 72, height: 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Label(
                                "Each clean round requires ≥95% recall, ≤25 ms median error, no dropped events, and ≥90% accuracy for any marked accents or ghost notes.",
                                systemImage: "speedometer"
                            )
                            if let run = state.currentCeilingRun {
                                Text(ceilingRunDescription(run))
                            } else if let record = state.currentCeilingRecord {
                                Text("Personal verified ceiling: \(Int(record.highestVerifiedBPM.rounded())) BPM")
                            } else {
                                Text("The current tempo becomes the starting point.")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Text("Output").frame(width: 72, alignment: .leading)
                    Picker("Audio output", selection: Binding(
                        get: { state.selectedAudioOutputID },
                        set: { state.selectAudioOutput($0) }
                    )) {
                        Text("System Default").tag(Optional<UInt32>.none)
                        ForEach(state.audioOutputDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    Text(state.metronomeStatus.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(state.isRefreshingAudioEngine ? "Refreshing…" : "Refresh Audio") {
                        state.refreshAudioEngine()
                    }
                    .disabled(state.isRefreshingAudioEngine)
                    Spacer()
                }

                if let message = state.audioEngineRecoveryMessage {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 72, height: 1)
                        Label(message, systemImage: "arrow.clockwise.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Text("Recording").frame(width: 72, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "Save played audio with completed sessions",
                            isOn: $state.practiceAudioRecordingEnabled
                        )
                        .toggleStyle(.switch)

                        Picker(
                            "Recording input",
                            selection: Binding(
                                get: { state.practiceAudioInputUID },
                                set: { state.selectPracticeAudioInput(uid: $0) }
                            )
                        ) {
                            Text("Kick-detection microphone")
                                .tag(Optional<String>.none)
                            ForEach(state.audioDevices) { device in
                                Text(device.name).tag(Optional(device.uid))
                            }
                        }
                        .frame(maxWidth: 360)
                        .disabled(!state.practiceAudioRecordingEnabled)

                        Picker("Channels", selection: $state.practiceAudioChannelSelection) {
                            ForEach(PracticeAudioChannelSelection.allCases) { selection in
                                Text(selection.displayName)
                                    .tag(selection)
                                    .disabled(
                                        state.practiceAudioInputChannelCount.map {
                                            !selection.isAvailable(channelCount: $0)
                                        } ?? false
                                    )
                            }
                        }
                        .frame(maxWidth: 360)
                        .disabled(!state.practiceAudioRecordingEnabled)

                        Text("Choose Scarlett plus Input 1 or 2 for the raw Alesis cable. For the complete headphone mix, choose Loopback 3–4 and enable Send Direct Monitor Mix to Loopback in Focusrite Control 2. The Snowball remains the kick detector.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if state.practiceAudioRecordingEnabled,
                           !state.isPracticeAudioInputMonitoring {
                            Label(
                                state.effectivePracticeAudioInputStatus.message,
                                systemImage: "waveform.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else if state.practiceAudioRecordingEnabled {
                            Label(
                                state.effectivePracticeAudioInputStatus.message,
                                systemImage: "waveform"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        if state.practiceAudioStorageBytes > 0 {
                            Text("Saved recording storage: \(ByteCountFormatter.string(fromByteCount: state.practiceAudioStorageBytes, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                if let message = state.practiceAudioStatusMessage {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 72, height: 1)
                        Label(message, systemImage: "waveform.badge.mic")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Text("Click").frame(width: 72, alignment: .leading)
                    Picker("Click sound", selection: $state.metronomeSound) {
                        ForEach(MetronomeSound.allCases) { sound in
                            Text(sound.displayName).tag(sound)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    Text(state.metronomeSound.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Level").frame(width: 72, alignment: .leading)
                    Text(state.metronomeGainDecibels.formatted(.number.sign(strategy: .always()).precision(.fractionLength(0))) + " dB")
                        .frame(width: 58, alignment: .trailing)
                        .monospacedDigit()
                    Slider(
                        value: $state.metronomeGainDecibels,
                        in: MetronomeGain.minimumDecibels...MetronomeGain.maximumDecibels,
                        step: 1
                    )
                        .frame(maxWidth: 220)
                    Button("Max boost") {
                        state.metronomeGainDecibels = MetronomeGain.maximumDecibels
                    }
                    .controlSize(.small)
                    Toggle("Limiter", isOn: $state.metronomeLimiterEnabled)
                        .toggleStyle(.switch)
                    Text("Ceiling")
                    Slider(value: $state.metronomeLimiterCeilingDBFS, in: -12 ... -0.5, step: 0.5)
                        .frame(width: 100)
                        .disabled(!state.metronomeLimiterEnabled)
                    Text("\(state.metronomeLimiterCeilingDBFS, specifier: "%.1f") dBFS")
                        .monospacedDigit()
                    Spacer()
                }
                .font(.callout)

                if MetronomeGain.isExtremeBoost(state.metronomeGainDecibels) {
                    Label(
                        "High click boost is active. Keep the limiter on and raise the level gradually.",
                        systemImage: "speaker.wave.3.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                AppOutputMeterView(level: state.appOutputLevel)
                Divider()
                KickMonitorControls(state: state, labelWidth: 72)
            }
            .disabled(state.practicePhase.isActive)
        }
    }

    private var progressionEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.tempoProgressionSettings.isEnabled },
            set: { enabled in
                state.tempoProgressionSettings.isEnabled = enabled
                state.saveTempoProgressionSettings()
            }
        )
    }

    private var requiredCleanRunsBinding: Binding<Int> {
        Binding(
            get: { state.tempoProgressionSettings.requiredCleanSessions },
            set: { count in
                state.tempoProgressionSettings.requiredCleanSessions = count
                state.saveTempoProgressionSettings()
            }
        )
    }

    private var progressionStepBinding: Binding<Double> {
        Binding(
            get: { state.tempoProgressionSettings.stepBPM },
            set: { step in
                state.tempoProgressionSettings.stepBPM = step
                state.saveTempoProgressionSettings()
            }
        )
    }

    private var ceilingModeEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.ceilingModeSettings.isEnabled },
            set: { enabled in
                state.ceilingModeSettings.isEnabled = enabled
                state.saveCeilingModeSettings()
            }
        )
    }

    private var ceilingStepBinding: Binding<Double> {
        Binding(
            get: { state.ceilingModeSettings.stepBPM },
            set: { step in
                state.ceilingModeSettings.stepBPM = step
                state.saveCeilingModeSettings()
            }
        )
    }

    @ViewBuilder
    private var scorePlayer: some View {
        GroupBox("Score") {
            if let pattern = displayedPattern {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isRunning)) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        PracticeScoreView(
                            pattern: pattern,
                            playheadSessionTime: state.practicePlayheadSessionTime,
                            sessionStartTime: runningBounds?.start,
                            sessionEndTime: runningBounds?.end,
                            previewOnly: !isRunning
                        )

                        HStack(spacing: 18) {
                            if let liveGuide {
                                Label(liveGuide, systemImage: "scope")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                            Label(hitSummary, systemImage: "metronome")
                            Text("\(targetHitCount) total \(state.practiceGradeKicks ? "limb" : "graded") hits")
                            if let progress = runningProgress {
                                Text("Measure \(progress.measure) of \(state.practiceMeasures)")
                                    .foregroundStyle(.primary)
                                Text("\(progress.remainingSeconds)s remaining")
                            }
                            Spacer()
                            Text(countingGuide)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Score unavailable",
                    systemImage: "music.note",
                    description: Text("Choose a valid exercise configuration.")
                )
                .frame(height: 190)
            }
        }
    }

    private var usesExternalPlayback: Bool {
        state.practiceExerciseMode == .importedSong && state.waitForExternalPlayback
    }

    private var externalPlaybackControls: some View {
        GroupBox("Songsterr companion — experimental") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Wait for browser audio instead of counting in", isOn: $state.waitForExternalPlayback)
                if state.waitForExternalPlayback {
                    Text("Import the matching MIDI, select the same starting measure and tempo, and set repeats to 1. Pause Songsterr at that measure with its count-in and looping off. Silence other browser tabs.")
                        .font(.callout)
                    HStack {
                        Button(state.isLoadingPlaybackSources ? "Retry loading sources" : "Load audio sources") {
                            state.loadPlaybackAudioSources()
                        }
                        Picker("Listen to", selection: $state.selectedPlaybackSourceID) {
                            Text("Choose browser").tag(nil as Int32?)
                            ForEach(state.playbackAudioSources) { source in
                                Text("\(source.name) (\(source.id))").tag(Optional(source.id))
                            }
                        }
                        .frame(maxWidth: 350)
                        Button("Capture permission…") { state.openPlaybackCapturePrivacySettings() }
                    }
                    if let message = state.playbackSourceMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Start offset")
                        TextField("Milliseconds", value: $state.playbackStartOffsetMilliseconds, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 85)
                        Text("ms (−5000 to +5000)")
                        Stepper("", value: $state.playbackStartOffsetMilliseconds, in: -5000...5000, step: 10)
                            .labelsHidden()
                        Spacer()
                    }
                    Text("Positive starts the score later than the detected sound; negative starts it earlier. Use this for intro/count-in offsets and residual headphone delay. Existing hit-timing calibration still applies; do not add that correction twice.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Detection threshold")
                        Slider(value: $state.playbackDetectionThresholdDBFS, in: -80 ... -10, step: 1)
                            .frame(width: 180)
                        Text("\(Int(state.playbackDetectionThresholdDBFS)) dBFS").monospacedDigit()
                    }
                    Text("Arm, wait for Ready, then press Play in Songsterr. The app listens for quiet followed by sound—not a particular song. No audio/video is saved. Your MIDI supplies the notes to grade; the microphone is not used for synchronization.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Start detection only: no automatic pause, seek, loop or drift tracking. Experimental scores are not saved to history or progress. Songsterr audio is outside the app's limiter.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    @ViewBuilder
    private var runStatus: some View {
        GroupBox("Practice run") {
            HStack(spacing: 18) {
                switch state.practicePhase {
                case .idle:
                    statusLabel(
                        practiceStartBlocker == nil ? "Ready" : "Not ready",
                        detail: practiceStartBlocker ?? readyDetail,
                        color: practiceStartBlocker == nil ? .secondary : .orange
                    )
                    Spacer()
                    Button("Reset Practice") { state.resetPracticeTransport() }
                        .help("Clear a stuck countdown, run, or audio-refresh state")
                    Button(usesExternalPlayback ? "Arm for Songsterr" : "Start Exercise") { state.startPractice() }
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(practiceStartBlocker != nil)

                case .waitingForPlayback:
                    statusLabel("Waiting for browser audio", detail: state.playbackSyncMessage, color: .orange)
                    Text("\(Int(state.playbackInputLevelDBFS)) dBFS").monospacedDigit()
                    Spacer()
                    Button("Cancel") { state.cancelPractice() }
                    Button("Reset Practice") { state.resetPracticeTransport() }

                case let .countIn(beatsRemaining):
                    Text(beatsRemaining == 0 ? "GO" : "\(beatsRemaining)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 72)
                    statusLabel(
                        "Count in",
                        detail: beatsRemaining == 0
                            ? "The next click is beat 1; the playhead starts with it."
                            : "Begin when the playhead starts after 1.",
                        color: .orange
                    )
                    Spacer()
                    Button("Reset Practice") { state.resetPracticeTransport() }
                    Button("Refresh Audio & Retry") { state.refreshAudioEngineAndRetryPractice() }
                        .disabled(state.isRefreshingAudioEngine)
                    Button("Cancel") { state.cancelPractice() }

                case .running:
                    statusLabel(
                        state.isExternalPlaybackRun ? "Playing — sync unverified" : "Playing",
                        detail: state.isExternalPlaybackRun ? state.playbackSyncMessage : "\(state.practiceRecordedHitCount) captured · keep your eyes on the blue line",
                        color: state.isExternalPlaybackRun ? .orange : .green
                    )
                    Spacer()
                    Button("Reset Practice") { state.resetPracticeTransport() }
                    if state.isExternalPlaybackRun {
                        Button("Sync lost / cancel") { state.markExternalPlaybackSyncLost() }
                    }
                    Button("Stop and Cancel") { state.cancelPractice() }

                case let .error(message):
                    statusLabel("Could not start", detail: message, color: .red)
                    Spacer()
                    Button("Reset Practice") { state.resetPracticeTransport() }
                    if usesExternalPlayback {
                        Button("Re-arm") { state.startPractice() }
                            .disabled(state.isRefreshingAudioEngine)
                    } else {
                        Button("Refresh Audio & Retry") { state.refreshAudioEngineAndRetryPractice() }
                            .disabled(state.isRefreshingAudioEngine)
                    }
                    Button("Reset") { state.dismissPracticeResults() }

                case .results:
                    EmptyView()
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func results(_ outcome: PracticeSessionOutcome) -> some View {
        let metrics = outcome.metrics
        let accentEvaluation = outcome.accentEvaluation
        let ghostEvaluation = outcome.ghostEvaluation
        let stableTiming = outcome.stableTimingBiasEvaluation
        let coaching = PracticeResultCoach().summarize(outcome)
        return VStack(alignment: .leading, spacing: 16) {
            resultSummaryAndActions(outcome, coaching: coaching)

            GroupBox("Performance score") {
                VStack(alignment: .leading, spacing: 8) {
                    if !outcome.effectiveScoringConfiguration.gradeKicks {
                        Label(
                            "Kicks were visible but ungraded. Kick expectations and detected kick events were excluded from every result below.",
                            systemImage: "eye.slash"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal) {
                        PracticeScoreView(
                            pattern: outcome.pattern,
                            classifications: resultClassifications(outcome),
                            accentClassifications: accentClassifications(outcome),
                            ghostClassifications: ghostClassifications(outcome),
                            fixedMeasureWidth: 350
                        )
                        .frame(width: 58 + 350 * Double(outcome.pattern.measures))
                    }
                    HStack(spacing: 18) {
                        legend("Correct", color: .green)
                        legend("Missed", color: .orange)
                        legend("Wrong voice", color: .red)
                        legend("Ambiguous", color: .purple)
                        if !outcome.effectiveScoringConfiguration.gradeKicks {
                            legend("Ungraded kick", color: .secondary)
                        }
                        Spacer()
                    }
                    .font(.caption)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                metricCard("Note recall", percent(metrics.recall), "Correct expected notes")
                metricCard("Precision", percent(metrics.precision), "Correct played notes")
                metricCard(
                    stableTiming == nil ? "Median error" : "Groove error",
                    milliseconds(
                        stableTiming?.adjustedMedianAbsoluteErrorMilliseconds
                            ?? metrics.medianAbsoluteErrorMilliseconds
                    ),
                    stableTiming == nil ? "Absolute timing" : "After stable-bias adjustment"
                )
                metricCard("Timing bias", signedMilliseconds(metrics.meanSignedOffsetMilliseconds), "Negative is early")
            }

            if let stableTiming {
                Label(
                    "Stable \(signedMilliseconds(stableTiming.biasMilliseconds)) offset across \(stableTiming.sampleCount) hits. Groove grading used \(milliseconds(stableTiming.adjustedMedianAbsoluteErrorMilliseconds)); raw median error was \(milliseconds(stableTiming.rawMedianAbsoluteErrorMilliseconds)). This can indicate fixed audio/MIDI latency—re-run hit timing alignment for the active drums.",
                    systemImage: "waveform.badge.magnifyingglass"
                )
                .font(.callout)
                .foregroundStyle(.blue)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }

            dynamicsResults(
                accentEvaluation: accentEvaluation,
                ghostEvaluation: ghostEvaluation,
                pattern: outcome.pattern
            )

            GroupBox("Hit breakdown") {
                HStack(spacing: 30) {
                    countLabel("Correct", metrics.correctCount, color: .green)
                    countLabel("Missed", metrics.missedCount, color: .orange)
                    countLabel("Extra", metrics.extraCount, color: .purple)
                    countLabel("Wrong voice", metrics.wrongVoiceCount, color: .red)
                    countLabel("Ambiguous", metrics.ambiguousCount, color: .secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            GroupBox("Timing details") {
                HStack(spacing: 28) {
                    Label("Early: \(metrics.earlyCount)", systemImage: "arrow.left")
                    Label("Late: \(metrics.lateCount)", systemImage: "arrow.right")
                    Text("Mean absolute error: \(milliseconds(metrics.meanAbsoluteErrorMilliseconds))")
                    if stableTiming != nil {
                        Text("Raw median error: \(milliseconds(metrics.medianAbsoluteErrorMilliseconds))")
                    }
                    Text("Consistency (σ): \(milliseconds(metrics.timingStandardDeviationMilliseconds))")
                    Text("Longest clean streak: \(metrics.longestCleanStreak)")
                    Spacer()
                }
                .font(.callout.monospacedDigit())
                .padding(.vertical, 6)
            }

            timingTimelineResults(outcome)
            if outcome.pattern.measureLabels != nil { sequenceMeasureResults(outcome) }

            if !metrics.perVoice.isEmpty {
                perVoiceResults(
                    metrics.perVoice,
                    accentEvaluation: accentEvaluation,
                    ghostEvaluation: ghostEvaluation
                )
            }

            if let synchronization = metrics.limbSynchronization {
                synchronizationResults(synchronization)
            }

            if outcome.droppedEventCount > 0 {
                Label(
                    "\(outcome.droppedEventCount) session events were dropped; treat these results as incomplete.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            Divider()
                .padding(.top, 4)
            resultSummaryAndActions(outcome, coaching: coaching)
        }
    }

    private func resultSummaryAndActions(
        _ outcome: PracticeSessionOutcome,
        coaching: PracticeCoachingSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Results").font(.title2.bold())
                    Text("\(outcome.pattern.name) · \(Int(outcome.pattern.bpm)) BPM · \(outcome.pattern.measures) measures")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.isExternalPlaybackRun {
                    Button("Re-arm for Songsterr") {
                        state.dismissPracticeResults()
                        state.startPractice()
                    }
                } else {
                    ceilingResultActions
                }
                Button("New Exercise") { state.dismissPracticeResults() }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Quick take", systemImage: "text.bubble.fill")
                        .font(.headline)
                    Text(coaching.overview)
                        .font(.callout)
                    Text("Next try: \(coaching.nextStep)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            if state.isExternalPlaybackRun {
                Label("Experimental external-playback score: alignment was not verified. This attempt is not saved to history, progress or ceiling records. Adjust the start offset and retry if everything looks consistently early or late.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if let ceilingMessage = state.lastCeilingMessage, !state.isExternalPlaybackRun,
               state.ceilingModeSettings.isEnabled {
                Label(ceilingMessage, systemImage: "speedometer")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            }

            if let progressionMessage = state.lastTempoProgressionMessage {
                Label(progressionMessage, systemImage: "chart.line.uptrend.xyaxis")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func sequenceMeasureResults(_ outcome: PracticeSessionOutcome) -> some View {
        GroupBox("Sequence review") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Check the first measure after each transition. Correct hits include your existing timing tolerance; accent and ghost results are shown separately above.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(1...max(outcome.pattern.measures, 1), id: \.self) { measure in
                            let notes = outcome.pattern.expectedEvents.filter {
                                $0.measure == measure && outcome.effectiveScoringConfiguration.includes($0.voice)
                            }
                            let ids = Set(notes.map(\.id))
                            let matches = outcome.matchResults.filter { $0.expectedEventID.map(ids.contains) ?? false }
                            let correct = matches.filter { $0.classification == .correct }.count
                            HStack {
                                Text("\(measure). \(outcome.pattern.label(forMeasure: measure) ?? "Measure")")
                                if measure > 1, outcome.pattern.label(forMeasure: measure) != outcome.pattern.label(forMeasure: measure - 1) {
                                    Label("Transition", systemImage: "arrow.right").foregroundStyle(.tint)
                                }
                                Spacer()
                                Text(notes.isEmpty ? "Ungraded" : "\(correct)/\(notes.count) correct")
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    @ViewBuilder
    private var ceilingResultActions: some View {
        if state.ceilingModeSettings.isEnabled, let run = state.activeCeilingRun {
            switch run.phase {
            case let .readyForNext(bpm):
                Button("Next Round · \(Int(bpm.rounded())) BPM") { state.continueCeilingRun() }
                    .keyboardShortcut(.return, modifiers: [])
            case .found:
                Button("Done") { state.dismissPracticeResults() }
                    .keyboardShortcut(.return, modifiers: [])
            case .testing:
                Button("Play Again") {
                    state.dismissPracticeResults()
                    state.startPractice()
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        } else {
            Button("Play Again") {
                state.dismissPracticeResults()
                state.startPractice()
            }
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private func ceilingRunDescription(_ run: CeilingRun) -> String {
        switch run.phase {
        case let .testing(bpm):
            return "Active search · testing \(Int(bpm.rounded())) BPM · \(run.sessionIDs.count) completed rounds"
        case let .readyForNext(bpm):
            return "Ready for \(Int(bpm.rounded())) BPM · best clean \(run.highestCleanBPM.map { String(Int($0.rounded())) } ?? "—") BPM"
        case let .found(highest, failed):
            if let highest {
                return "Found \(Int(highest.rounded())) BPM" + (failed.map { " · stopped at \(Int($0.rounded())) BPM" } ?? "")
            }
            return "No clean round yet; lower the starting tempo and reset."
        }
    }

    private func timingTimelineResults(_ outcome: PracticeSessionOutcome) -> some View {
        let timeline = outcome.timingTimeline
        let entries = timeline.entries.filter {
            timingTimelineFilter == .all || $0.isProblem
        }

        return GroupBox("Detailed timing timeline") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Expected markers are outlined; played hits are filled. Connected markers are one matched event.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Timeline filter", selection: $timingTimelineFilter) {
                        ForEach(TimingTimelineFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }

                if entries.isEmpty {
                    ContentUnavailableView(
                        "No timing problems",
                        systemImage: "checkmark.circle",
                        description: Text("Every scored hit in this run was correct.")
                    )
                    .frame(height: 150)
                } else {
                    PracticeTimingTimelineChart(
                        pattern: outcome.pattern,
                        timeline: timeline,
                        entries: entries
                    )

                    HStack(spacing: 18) {
                        legend("Correct", color: .green)
                        legend("Missed", color: .orange)
                        legend("Extra", color: .purple)
                        legend("Wrong voice", color: .red)
                        legend("Ambiguous", color: .indigo)
                        Spacer()
                        Text("Showing \(entries.count) of \(timeline.entries.count) events")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    timingTimelineTable(entries, patternStart: outcome.pattern.startSessionTimeNanoseconds)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func timingTimelineTable(
        _ entries: [PracticeTimingTimelineEntry],
        patternStart: Int64
    ) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(entries) { entry in
                        timingTimelineRow(entry, patternStart: patternStart)
                            .padding(.vertical, 6)
                        Divider()
                    }
                } header: {
                    timingTimelineHeader
                        .padding(.vertical, 7)
                        .background(.background)
                }
            }
        }
        .frame(minHeight: 90, maxHeight: 280)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var timingTimelineHeader: some View {
        HStack(spacing: 14) {
            timelineCell("Position", width: 78)
            timelineCell("Expected", width: 112)
            timelineCell("Played", width: 112)
            timelineCell("Result", width: 104)
            timelineCell("Offset", width: 86, alignment: .trailing)
            timelineCell("Expected time", width: 100, alignment: .trailing)
            timelineCell("Played time", width: 100, alignment: .trailing)
            timelineCell("Input", width: 76)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }

    private func timingTimelineRow(
        _ entry: PracticeTimingTimelineEntry,
        patternStart: Int64
    ) -> some View {
        HStack(spacing: 14) {
            timelineCell(musicalPosition(entry), width: 78)
            timelineCell(entry.expectedVoice?.displayName ?? "—", width: 112)
            timelineCell(entry.playedVoice?.displayName ?? "—", width: 112)
            timelineCell(classificationName(entry.classification), width: 104)
                .foregroundStyle(classificationColor(entry.classification))
            timelineCell(signedMilliseconds(entry.signedOffsetMilliseconds), width: 86, alignment: .trailing)
            timelineCell(relativeTime(entry.expectedTimeNanoseconds, from: patternStart), width: 100, alignment: .trailing)
            timelineCell(relativeTime(entry.actualTimeNanoseconds, from: patternStart), width: 100, alignment: .trailing)
            timelineCell(entry.source?.displayName ?? "—", width: 76)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 10)
    }

    private func timelineCell(
        _ value: String,
        width: CGFloat,
        alignment: Alignment = .leading
    ) -> some View {
        Text(value)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func musicalPosition(_ entry: PracticeTimingTimelineEntry) -> String {
        guard let measure = entry.measure, let beat = entry.beat, let subdivision = entry.subdivision else {
            return "—"
        }
        return "\(measure).\(beat).\(subdivision + 1)"
    }

    private func relativeTime(_ time: Int64?, from start: Int64) -> String {
        guard let time else { return "—" }
        let seconds = Double(time - start) / 1_000_000_000
        return seconds.formatted(.number.sign(strategy: .always()).precision(.fractionLength(3))) + " s"
    }

    private func classificationName(_ classification: MatchClassification) -> String {
        switch classification {
        case .correct: "Correct"
        case .missed: "Missed"
        case .extra: "Extra"
        case .wrongVoice: "Wrong voice"
        case .ambiguous: "Ambiguous"
        }
    }

    private func classificationColor(_ classification: MatchClassification) -> Color {
        switch classification {
        case .correct: .green
        case .missed: .orange
        case .extra: .purple
        case .wrongVoice: .red
        case .ambiguous: .indigo
        }
    }

    @ViewBuilder
    private func dynamicsResults(
        accentEvaluation: AccentEvaluation?,
        ghostEvaluation: GhostEvaluation?,
        pattern: PracticePattern
    ) -> some View {
        if let accentEvaluation, let ghostEvaluation {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    accentResults(accentEvaluation, pattern: pattern)
                        .frame(minWidth: 560, maxWidth: .infinity)
                    ghostResults(ghostEvaluation, pattern: pattern)
                        .frame(minWidth: 560, maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 16) {
                    accentResults(accentEvaluation, pattern: pattern)
                    ghostResults(ghostEvaluation, pattern: pattern)
                }
            }
        } else if let accentEvaluation {
            accentResults(accentEvaluation, pattern: pattern)
        } else if let ghostEvaluation {
            ghostResults(ghostEvaluation, pattern: pattern)
        }
    }

    private func accentResults(
        _ evaluation: AccentEvaluation,
        pattern: PracticePattern
    ) -> some View {
        GroupBox("Accent dynamics") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                    spacing: 12
                ) {
                    metricCard(
                        "Accent accuracy",
                        percent(evaluation.metrics.accuracy),
                        "≥90% required for a clean run"
                    )
                    metricCard(
                        "Achieved",
                        "\(evaluation.metrics.achievedCount) / \(evaluation.metrics.expectedCount)",
                        "Enough same-voice dynamic contrast"
                    )
                    metricCard(
                        "Needs contrast",
                        "\(evaluation.metrics.belowThresholdCount)",
                        "Below the relative target or optional floor"
                    )
                    metricCard(
                        "Not evaluated",
                        "\(evaluation.metrics.notEvaluatedCount)",
                        "Missed note, missing velocity, or no baseline"
                    )
                }

                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 7) {
                        GridRow {
                            Text("Position")
                            Text("Voice")
                            Text("Baseline")
                            Text("Target")
                            Text("Played")
                            Text("Result")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                        ForEach(evaluation.results) { result in
                            let expected = pattern.expectedEvents.first { $0.id == result.expectedEventID }
                            GridRow {
                                Text(expected.map {
                                    "M\($0.measure) B\($0.beat).\($0.subdivision + 1)"
                                } ?? "—")
                                Text(result.voice.displayName)
                                Text(result.baselineVelocity.map { "\(midiVelocity($0))" } ?? "—")
                                Text(accentTargetDescription(result))
                                Text(result.actualVelocity.map { "\(midiVelocity($0))" } ?? "—")
                                Text(accentClassificationName(result.classification))
                                    .foregroundStyle(accentClassificationColor(result.classification))
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
            }
            .padding(.vertical, 6)
        }
    }

    private func midiVelocity(_ normalizedVelocity: Double) -> Int {
        Int((min(max(normalizedVelocity, 0), 1) * 127).rounded())
    }

    private func accentClassificationName(_ classification: AccentResultClassification) -> String {
        switch classification {
        case .achieved: "Achieved"
        case .belowThreshold: "Below minimum"
        case .insufficientContrast: "Not enough contrast"
        case .baselineUnavailable: "No same-voice baseline"
        case .missed: "Note not correct"
        case .velocityUnavailable: "No velocity"
        }
    }

    private func accentTargetDescription(_ result: AccentResult) -> String {
        guard let target = result.requiredVelocity else { return "—" }
        let targetValue = Int((target * 127).rounded())
        if result.didUseMinimumOnly {
            return "≥\(targetValue) floor only"
        }
        if let contrast = result.requiredContrast, result.baselineVelocity != nil {
            return "≥\(targetValue) (+\(midiVelocity(contrast)))"
        }
        return "≥\(targetValue)"
    }

    private func accentClassificationColor(_ classification: AccentResultClassification) -> Color {
        switch classification {
        case .achieved: .green
        case .belowThreshold, .insufficientContrast: .orange
        case .missed: .red
        case .velocityUnavailable, .baselineUnavailable: .secondary
        }
    }

    private func ghostResults(
        _ evaluation: GhostEvaluation,
        pattern: PracticePattern
    ) -> some View {
        GroupBox("Ghost dynamics") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                    spacing: 12
                ) {
                    metricCard(
                        "Ghost accuracy",
                        percent(evaluation.metrics.accuracy),
                        "≥90% required for a clean run"
                    )
                    metricCard(
                        "Achieved",
                        "\(evaluation.metrics.achievedCount) / \(evaluation.metrics.expectedCount)",
                        "Enough same-voice dynamic contrast"
                    )
                    metricCard(
                        "Too loud",
                        "\(evaluation.metrics.aboveThresholdCount)",
                        "Above the relative target or optional maximum"
                    )
                    metricCard(
                        "Not evaluated",
                        "\(evaluation.metrics.notEvaluatedCount)",
                        "Missed note, missing velocity, or no baseline"
                    )
                }

                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 7) {
                        GridRow {
                            Text("Position")
                            Text("Voice")
                            Text("Baseline")
                            Text("Target")
                            Text("Played")
                            Text("Result")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                        ForEach(evaluation.results) { result in
                            let expected = pattern.expectedEvents.first { $0.id == result.expectedEventID }
                            GridRow {
                                Text(expected.map {
                                    "M\($0.measure) B\($0.beat).\($0.subdivision + 1)"
                                } ?? "—")
                                Text(result.voice.displayName)
                                Text(result.baselineVelocity.map { "\(midiVelocity($0))" } ?? "—")
                                Text(ghostTargetDescription(result))
                                Text(result.actualVelocity.map { "\(midiVelocity($0))" } ?? "—")
                                Text(ghostClassificationName(result.classification))
                                    .foregroundStyle(ghostClassificationColor(result.classification))
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 260)
            }
            .padding(.vertical, 6)
        }
    }

    private func ghostClassificationName(_ classification: GhostResultClassification) -> String {
        switch classification {
        case .achieved: "Achieved"
        case .aboveThreshold: "Above maximum"
        case .insufficientContrast: "Not enough contrast"
        case .baselineUnavailable: "No same-voice baseline"
        case .missed: "Note not correct"
        case .velocityUnavailable: "No velocity"
        }
    }

    private func ghostTargetDescription(_ result: GhostResult) -> String {
        guard let target = result.requiredVelocity else { return "—" }
        let targetValue = Int(floor(target * 127 + 1e-9))
        if targetValue < 1 { return "No playable target — reduce contrast" }
        if result.didUseMaximumOnly {
            return "≤\(targetValue) ceiling only"
        }
        if let contrast = result.requiredContrast, result.baselineVelocity != nil {
            return "≤\(targetValue) (−\(midiVelocity(contrast)))"
        }
        return "≤\(targetValue)"
    }

    private func ghostClassificationColor(_ classification: GhostResultClassification) -> Color {
        switch classification {
        case .achieved: .green
        case .aboveThreshold, .insufficientContrast: .orange
        case .missed: .red
        case .velocityUnavailable, .baselineUnavailable: .secondary
        }
    }

    private func perVoiceResults(
        _ voices: [VoiceMetrics],
        accentEvaluation: AccentEvaluation?,
        ghostEvaluation: GhostEvaluation?
    ) -> some View {
        GroupBox("Per-voice results") {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                    GridRow {
                        Text("Voice")
                        Text("Expected / played")
                        Text("Correct")
                        Text("Missed")
                        Text("Extra")
                        Text("Wrong")
                        Text("Ambiguous")
                        Text("Recall")
                        Text("Precision")
                        Text("Accent accuracy")
                        Text("Ghost accuracy")
                        Text("Bias")
                        Text("Median error")
                        Text("Consistency σ")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    ForEach(voices, id: \.voice) { voice in
                        GridRow {
                            Text(voice.voice.displayName).fontWeight(.semibold)
                            Text("\(voice.totalExpected) / \(voice.totalPlayed)")
                            Text("\(voice.correctCount)").foregroundStyle(.green)
                            Text("\(voice.missedCount)").foregroundStyle(voice.missedCount == 0 ? Color.secondary : Color.orange)
                            Text("\(voice.extraCount)").foregroundStyle(voice.extraCount == 0 ? Color.secondary : Color.purple)
                            Text("\(voice.wrongVoiceCount)").foregroundStyle(voice.wrongVoiceCount == 0 ? Color.secondary : Color.red)
                            Text("\(voice.ambiguousCount)").foregroundStyle(voice.ambiguousCount == 0 ? Color.secondary : Color.purple)
                            Text(percent(voice.recall))
                            Text(percent(voice.precision))
                            Text(accentEvaluation?.voiceAccuracy(for: voice.voice).map { percent($0.accuracy) } ?? "—")
                            Text(ghostEvaluation?.voiceAccuracy(for: voice.voice).map { percent($0.accuracy) } ?? "—")
                            Text(signedMilliseconds(voice.meanSignedOffsetMilliseconds))
                            Text(milliseconds(voice.medianAbsoluteErrorMilliseconds))
                            Text(milliseconds(voice.timingStandardDeviationMilliseconds))
                        }
                        .monospacedDigit()
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func synchronizationResults(_ metrics: LimbSynchronizationMetrics) -> some View {
        GroupBox("Limb synchronization") {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    metricCard(
                        "Complete groups",
                        "\(metrics.completedGroupCount) / \(metrics.eligibleGroupCount)",
                        "All intended voices matched"
                    )
                    metricCard("Average spread", milliseconds(metrics.averageSpreadMilliseconds), "Latest minus earliest")
                    metricCard("Median spread", milliseconds(metrics.medianSpreadMilliseconds), "Typical limb alignment")
                    metricCard("Worst spread", milliseconds(metrics.worstSpreadMilliseconds), "Largest complete group")
                }

                if metrics.completedGroupCount < metrics.eligibleGroupCount {
                    Label(
                        "\(metrics.eligibleGroupCount - metrics.completedGroupCount) simultaneous group(s) were incomplete and excluded from spread statistics.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if !metrics.voiceOffsets.isEmpty {
                    Text("Voice position relative to each group's center")
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                        GridRow {
                            Text("Voice")
                            Text("Mean offset")
                            Text("Median offset")
                            Text("Groups")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        ForEach(metrics.voiceOffsets, id: \.voice) { offset in
                            GridRow {
                                Text(offset.voice.displayName).fontWeight(.semibold)
                                Text(signedMilliseconds(offset.meanOffsetFromGroupCenterMilliseconds))
                                Text(signedMilliseconds(offset.medianOffsetFromGroupCenterMilliseconds))
                                Text("\(offset.sampleCount)")
                            }
                            .monospacedDigit()
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var difficultyLabel: some View {
        HStack(spacing: 3) {
            Text("Difficulty").font(.caption).foregroundStyle(.secondary)
            ForEach(1...5, id: \.self) { level in
                Circle()
                    .fill(level <= state.practiceExercise.difficulty ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.top, 7)
    }

    private var customMeasureEditor: some View {
        GroupBox("Manual measure editor · 4/4") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(customNoteTool.guidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Note tool", selection: $customNoteTool) {
                        ForEach(CustomNoteTool.allCases) { tool in
                            Text(tool.rawValue).tag(tool)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 290)
                    Button("Load Rock Example") { state.loadCustomMeasureExample() }
                    Button("Clear") { state.clearCustomMeasure() }
                        .disabled(state.practiceCustomMeasure.isEmpty)
                }

                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 5) {
                        GridRow {
                            Text("Voice")
                                .frame(width: 108, alignment: .leading)
                            ForEach(0..<state.practiceCustomMeasure.slotsPerMeasure, id: \.self) { slot in
                                Text(customCountLabel(slot))
                                    .font(.caption2.bold().monospaced())
                                    .foregroundStyle(slot.isMultiple(of: state.practiceCustomMeasure.subdivision.notesPerBeat) ? Color.primary : Color.secondary)
                                    .frame(width: 28)
                            }
                        }

                        ForEach(customEditorVoices, id: \.self) { voice in
                            GridRow {
                                Text(voice.displayName)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .frame(width: 108, alignment: .leading)
                                ForEach(0..<state.practiceCustomMeasure.slotsPerMeasure, id: \.self) { slot in
                                    customMeasureCell(slot: slot, voice: voice)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Label("\(state.practiceCustomMeasure.hits.count) notes in the authored measure", systemImage: "music.note")
                    if state.practiceCustomMeasure.accentCount > 0 {
                        Label("\(state.practiceCustomMeasure.accentCount) accents", systemImage: "greaterthan")
                            .foregroundStyle(.orange)
                    }
                    if state.practiceCustomMeasure.ghostCount > 0 {
                        Text("\(state.practiceCustomMeasure.ghostCount) ghost notes ( )")
                            .foregroundStyle(.blue)
                    }
                    if state.practiceCustomMeasure.isEmpty {
                        Text("Add at least one note to enable practice.")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("This measure repeats \(state.practiceMeasures)× during the exercise.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
        }
    }

    private var customSequenceEditor: some View {
        GroupBox("Arrange measures") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Example: Verse ×4 → Fill ×1 → Chorus ×4. The transition happens immediately, with one count-in before the entire sequence.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("Saved measure", selection: $sequenceSourceID) {
                        Text("Choose a saved measure").tag(nil as UUID?)
                        ForEach(state.savedCustomExercises.filter { !$0.definition.isSequence && !$0.definition.isEmpty }) { saved in
                            Text(saved.definition.displayName).tag(Optional(saved.id))
                        }
                    }
                    .frame(maxWidth: 390)
                    Button("Add to sequence", systemImage: "plus") {
                        if let id = sequenceSourceID { state.addCustomSequenceStep(savedID: id) }
                    }
                    .disabled(sequenceSourceID == nil)
                }
                if state.savedCustomExercises.allSatisfy({ $0.definition.isSequence || $0.definition.isEmpty }) {
                    Text("Create and save measures in Single measure first, then add them here.")
                        .foregroundStyle(.secondary)
                }
                let steps = state.practiceCustomMeasure.sequenceSteps ?? []
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: 12) {
                        Text("\(index + 1).").monospacedDigit().frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(step.name).fontWeight(.medium)
                            let first = steps.prefix(index).reduce(1) { $0 + $1.repeats }
                            Text("Measures \(first)–\(first + step.repeats - 1) · \(step.subdivision.displayName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper("\(step.repeats)×", value: Binding(
                            get: { step.repeats },
                            set: { state.updateCustomSequenceStep(id: step.id, repeats: $0) }
                        ), in: 1...16).frame(width: 100)
                        Button { state.updateCustomSequenceStep(id: step.id, moveBy: -1) } label: {
                            Image(systemName: "arrow.up")
                        }.disabled(index == 0).help("Move \(step.name) earlier")
                        Button { state.updateCustomSequenceStep(id: step.id, moveBy: 1) } label: {
                            Image(systemName: "arrow.down")
                        }.disabled(index == steps.count - 1).help("Move \(step.name) later")
                        Button("Remove") { state.updateCustomSequenceStep(id: step.id, remove: true) }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                Stepper("Repeat whole sequence \(state.practiceCustomMeasure.sequenceRepeats ?? 1)×", value: Binding(
                    get: { state.practiceCustomMeasure.sequenceRepeats ?? 1 },
                    set: { state.setCustomSequenceRepeats($0) }
                ), in: 1...16).frame(maxWidth: 320)
                Text("\(state.practiceCustomMeasure.sequenceMeasureCount) total measures. Steps keep a copy of the saved notes, including accents and ghosts. To use later edits, remove and add that measure again.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = state.practiceCustomMeasure.sequenceValidationMessage {
                    Text(message).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var customExerciseLibraryControls: some View {
        HStack(spacing: 12) {
            Text("Saved").frame(width: 72, alignment: .leading)
            Picker("Saved custom exercise", selection: Binding(
                get: { state.selectedSavedCustomExerciseID },
                set: { id in
                    if let id {
                        state.loadSavedCustomExercise(id: id)
                    } else {
                        state.selectedSavedCustomExerciseID = nil
                    }
                }
            )) {
                Text(state.isCustomSequence ? "Unsaved sequence" : "Unsaved measure").tag(Optional<UUID>.none)
                ForEach(state.savedCustomExercises) { exercise in
                    Text(exercise.definition.displayName + (exercise.definition.isSequence ? " · Sequence" : "")).tag(Optional(exercise.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)

            Button(state.selectedSavedCustomExerciseID == nil ? (state.isCustomSequence ? "Save Sequence" : "Save Exercise") : "Update Saved") {
                state.saveCustomExercise()
            }
            .disabled(state.practiceCustomMeasure.isEmpty)

            if state.selectedSavedCustomExerciseID != nil {
                Button("Save Copy") { state.saveCustomExercise(asNew: true) }
                    .disabled(state.practiceCustomMeasure.isEmpty)
                Button("Delete", role: .destructive) {
                    showsDeleteSavedExerciseConfirmation = true
                }
            }

            if let message = state.practiceDataStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var importedSongControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Song").frame(width: 72, alignment: .leading)
                Picker("Imported song", selection: Binding(
                    get: { state.selectedImportedSongID },
                    set: { id in
                        if let id { state.loadImportedSong(id: id) }
                        else { state.selectedImportedSongID = nil }
                    }
                )) {
                    Text("Choose a song").tag(Optional<UUID>.none)
                    ForEach(state.importedSongs) { song in
                        Text(song.displayName).tag(Optional(song.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)

                Button("Import MIDI…", systemImage: "square.and.arrow.down") {
                    showsMIDIImporter = true
                }
                if let song = state.selectedImportedSong {
                    Button("Delete", role: .destructive) { pendingImportedSongDeletion = song }
                }
                Spacer()
            }

            if let song = state.selectedImportedSong {
                HStack(spacing: 12) {
                    Text("Name").frame(width: 72, alignment: .leading)
                    TextField("Song name", text: Binding(
                        get: { state.selectedImportedSong?.name ?? "" },
                        set: { state.renameSelectedImportedSong($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    Text(song.sourceFilename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Track").frame(width: 72, alignment: .leading)
                    Picker("MIDI track", selection: Binding(
                        get: { state.selectedImportedSong?.selectedTrackIndex ?? song.selectedTrackIndex },
                        set: { state.selectImportedTrack($0) }
                    )) {
                        ForEach(song.tracks.filter { !$0.notes.isEmpty }) { track in
                            Text("\(track.displayName) · \(track.notes.count) notes\(track.usesPercussionChannel ? " · drums ch. 10" : "")")
                                .tag(track.index)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 430)
                    Label(
                        "\(song.mappedNoteCount) mapped hits",
                        systemImage: song.mappedNoteCount > 0 ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(song.mappedNoteCount > 0 ? Color.secondary : Color.orange)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Section").frame(width: 72, alignment: .leading)
                    Text("Measure")
                    Stepper(
                        "\(state.importedSectionStartMeasure)",
                        value: Binding(
                            get: { state.importedSectionStartMeasure },
                            set: { state.setImportedSection(start: $0) }
                        ),
                        in: 1...max(state.importedSongMeasureCount, 1)
                    )
                    Text("through")
                    Stepper(
                        "\(state.importedSectionEndMeasure)",
                        value: Binding(
                            get: { state.importedSectionEndMeasure },
                            set: { state.setImportedSection(end: $0) }
                        ),
                        in: 1...max(state.importedSongMeasureCount, 1)
                    )
                    Text("repeat")
                    Stepper(
                        "\(state.importedSectionRepeats)×",
                        value: Binding(
                            get: { state.importedSectionRepeats },
                            set: { state.setImportedSection(repeats: $0) }
                        ),
                        in: 1...32
                    )
                    Text("· \(state.practiceMeasures) played measures")
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Color.clear.frame(width: 72, height: 1)
                    if state.importedSectionEligibleHitCount > 0 {
                        Label(
                            "\(state.importedSectionEligibleHitCount) notes eligible for grading in measures \(state.importedSectionStartMeasure)–\(state.importedSectionEndMeasure)",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else if state.importedSectionMappedHitCount > 0 {
                        Label(
                            "This section has \(state.importedSectionMappedHitCount) mapped notes, but they are all kicks and Grade kicks is off.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        Button("Turn on Grade kicks") { state.practiceGradeKicks = true }
                    } else {
                        Label(
                            "Measures \(state.importedSectionStartMeasure)–\(state.importedSectionEndMeasure) contain no mapped drum notes. The track can still have mapped notes later in the song.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        if state.selectedImportedSong?.firstMeasureWithScorableNote(includeKicks: true) != nil {
                            Button("Jump to first playable section") {
                                state.jumpToFirstGradableImportedSection()
                            }
                        }
                    }
                    Spacer()
                }
                .font(.callout)

                importedMappingEditor(song)
            } else {
                ContentUnavailableView(
                    "Import a Standard MIDI file",
                    systemImage: "music.note.list",
                    description: Text("Format 0 and 1 .mid files are supported. Files stay local in your saved practice data.")
                )
                .frame(height: 130)
            }
        }
    }

    private func importedMappingEditor(_ song: ImportedSong) -> some View {
        GroupBox("Drum mapping preview") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mappings save immediately—there is no confirmation button. Song exports sometimes use custom pitches; Ignore excludes a note from the score and grading. The occurrence totals cover the entire track, while the section status above covers only your selected measures.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if state.importedNoteSummaries.isEmpty {
                    Text("The selected track has no notes.")
                        .foregroundStyle(.orange)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.fixed(92), alignment: .leading),
                                GridItem(.fixed(90), alignment: .trailing),
                                GridItem(.flexible(minimum: 180), alignment: .leading)
                            ],
                            alignment: .leading,
                            spacing: 7
                        ) {
                            Text("MIDI note").font(.caption.bold()).foregroundStyle(.secondary)
                            Text("Occurrences").font(.caption.bold()).foregroundStyle(.secondary)
                            Text("Grade as").font(.caption.bold()).foregroundStyle(.secondary)
                            ForEach(state.importedNoteSummaries) { summary in
                                Text("\(summary.noteNumber)\(summary.channels.contains(9) ? " · ch. 10" : "")")
                                    .monospacedDigit()
                                Text("\(summary.count)").monospacedDigit()
                                Picker("Map MIDI note \(summary.noteNumber)", selection: Binding(
                                    get: { state.selectedImportedSong?.voice(for: summary.noteNumber) ?? .unknown },
                                    set: { state.mapImportedMIDINote(summary.noteNumber, to: $0) }
                                )) {
                                    Text("Ignore").tag(DrumVoice.unknown)
                                    ForEach(importMappingVoices, id: \.self) { voice in
                                        Text(voice.displayName).tag(voice)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 240)
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var importMappingVoices: [DrumVoice] {
        DrumVoice.allCases.filter { $0 != .unknown && $0 != .metronome }
    }

    private var selectedSavedCustomExercise: SavedCustomExercise? {
        guard let id = state.selectedSavedCustomExerciseID else { return nil }
        return state.savedCustomExercises.first { $0.id == id }
    }

    private func customMeasureCell(slot: Int, voice: DrumVoice) -> some View {
        let isOn = state.practiceCustomMeasure.contains(slot: slot, voice: voice)
        let isAccent = state.practiceCustomMeasure.isAccented(slot: slot, voice: voice)
        let isGhost = state.practiceCustomMeasure.isGhosted(slot: slot, voice: voice)
        let beginsBeat = slot.isMultiple(of: state.practiceCustomMeasure.subdivision.notesPerBeat)
        return Button {
            if customNoteTool == .accent {
                state.toggleCustomMeasureAccent(slot: slot, voice: voice)
            } else if customNoteTool == .ghost {
                state.toggleCustomMeasureGhost(slot: slot, voice: voice)
            } else {
                state.toggleCustomMeasureHit(slot: slot, voice: voice)
            }
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(isOn ? customVoiceColor(voice) : Color.secondary.opacity(beginsBeat ? 0.16 : 0.08))
                .overlay {
                    if isOn {
                        ZStack {
                            if isGhost {
                                Text("(   )").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            }
                            Image(systemName: "music.note")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                            if isAccent {
                                Text(">")
                                    .font(.system(size: 8, weight: .black, design: .rounded))
                                    .foregroundStyle(.yellow)
                                    .offset(x: 8, y: -7)
                            }
                        }
                    }
                }
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .help(customCellActionLabel(isOn: isOn, isAccent: isAccent, slot: slot, voice: voice))
        .accessibilityLabel(customCellActionLabel(isOn: isOn, isAccent: isAccent, slot: slot, voice: voice))
    }

    private func customCellActionLabel(
        isOn: Bool,
        isAccent: Bool,
        slot: Int,
        voice: DrumVoice
    ) -> String {
        let action: String
        if customNoteTool == .accent {
            action = isAccent ? "Remove accent from" : (isOn ? "Accent" : "Add accented")
        } else if customNoteTool == .ghost {
            action = state.practiceCustomMeasure.isGhosted(slot: slot, voice: voice)
                ? "Remove ghost marking from" : "Mark as ghost note"
        } else {
            action = isOn ? "Remove" : "Add"
        }
        return "\(action) \(voice.displayName) at \(customCountLabel(slot))"
    }

    private var customEditorVoices: [DrumVoice] {
        [
            .kick, .snare, .crossStick,
            .highTom, .midTom, .lowTom,
            .closedHiHat, .openHiHat, .pedalHiHat,
            .ride, .rideBell, .crash1, .crash2, .china, .splash
        ]
    }

    private func customCountLabel(_ slot: Int) -> String {
        let notesPerBeat = state.practiceCustomMeasure.subdivision.notesPerBeat
        let beat = slot / notesPerBeat
        let subdivision = slot % notesPerBeat
        switch state.practiceCustomMeasure.subdivision {
        case .eighths: return subdivision == 0 ? "\(beat + 1)" : "&"
        case .sixteenths: return ["\(beat + 1)", "e", "&", "a"][subdivision]
        case .triplets: return subdivision == 0 ? "\(beat + 1)" : (subdivision == 1 ? "trip" : "let")
        }
    }

    private func customVoiceColor(_ voice: DrumVoice) -> Color {
        switch voice {
        case .kick: .blue
        case .snare, .crossStick: .red
        case .highTom, .midTom, .lowTom: .orange
        case .closedHiHat, .openHiHat, .pedalHiHat: .teal
        case .ride, .rideBell: .yellow
        case .crash1, .crash2, .china, .splash: .purple
        default: .secondary
        }
    }

    private var displayedPattern: PracticePattern? {
        state.practiceActivePattern ?? state.practicePreviewPattern
    }

    private var runningBounds: (start: Int64, end: Int64)? {
        guard case let .running(start, end) = state.practicePhase else { return nil }
        return (start, end)
    }

    private var runningProgress: (measure: Int, remainingSeconds: Int)? {
        guard let bounds = runningBounds, let current = state.practicePlayheadSessionTime else { return nil }
        let duration = max(bounds.end - bounds.start, 1)
        let elapsed = min(max(current - bounds.start, 0), duration)
        let measure: Int
        if let pattern = displayedPattern,
           let offsets = pattern.measureStartOffsetsNanoseconds,
           offsets.count == pattern.measures + 1 {
            measure = min((offsets.lastIndex(where: { $0 <= elapsed }) ?? 0) + 1, pattern.measures)
        } else {
            let fraction = Double(elapsed) / Double(duration)
            measure = min(Int(fraction * Double(state.practiceMeasures)) + 1, state.practiceMeasures)
        }
        let remaining = Int(ceil(Double(bounds.end - current) / 1_000_000_000))
        return (measure, max(remaining, 0))
    }

    private var liveGuide: String? {
        guard isRunning,
              let pattern = displayedPattern,
              let current = state.practicePlayheadSessionTime,
              let start = runningBounds?.start else { return nil }
        let elapsed = max(current - start, 0)
        let beat = pattern.referenceBeats?
            .last(where: { $0.offsetNanoseconds <= elapsed })
        let nextEvent = pattern.expectedEvents.first(where: {
            $0.sessionTimeNanoseconds >= current && currentScoringConfiguration.includes($0.voice)
        })
        let position = beat.map { "Measure \($0.measure) · Beat \($0.beat)" + (pattern.label(forMeasure: $0.measure).map { " · \($0)" } ?? "") }
            ?? runningProgress.map { "Measure \($0.measure)" }
            ?? "Follow the playhead"
        guard let nextEvent else { return position + " · finish" }
        let milliseconds = max(nextEvent.sessionTimeNanoseconds - current, 0) / 1_000_000
        return position + " · next \(nextEvent.voice.displayName) in \(milliseconds) ms"
    }

    private var isRunning: Bool {
        if case .running = state.practicePhase { true } else { false }
    }

    private var exerciseCategories: [String] {
        KickExercise.allCases.reduce(into: []) { result, exercise in
            if !result.contains(exercise.category) { result.append(exercise.category) }
        }
    }

    private var targetHitCount: Int {
        scoredExpectedEvents.count
    }

    private var hitSummary: String {
        if state.isCustomSequence { return "\(targetHitCount) graded hits across the sequence" }
        if !state.practiceGradeKicks {
            if state.practiceExerciseMode == .importedSong {
                return "\(targetHitCount) graded mapped hits · kicks ungraded"
            }
            return "\(scoredHitsPerMeasure) graded kit hits per measure · kicks ungraded"
        }
        return state.practiceExerciseMode == .importedSong
            ? "\(targetHitCount) mapped limb hits"
            : "\(state.practiceHitsPerMeasure) limb hits per measure"
    }

    private var countingGuide: String {
        if state.isCustomSequence { return "Counts follow each measure’s grid" }
        if state.practiceExerciseMode == .importedSong {
            return "Exact imported timing · 16th-note count markers"
        }
        return switch state.practiceSubdivision {
        case .eighths: "Count: 1 & 2 & 3 & 4 &"
        case .sixteenths: "Count: 1 e & a 2 e & a"
        case .triplets: "Count: 1-trip-let 2-trip-let"
        }
    }

    private var readyDetail: String {
        if state.isCustomSequence {
            return state.practiceCustomMeasure.sequenceValidationMessage
                ?? "Eight count-in clicks, then play through \(state.practiceCustomMeasure.sequenceMeasureCount) measures in order."
        }
        if state.practiceExerciseMode == .custom, state.practiceCustomMeasure.isEmpty {
            return "Add notes to the custom measure grid, then follow the notation preview below."
        }
        if state.practiceExerciseMode == .importedSong {
            guard let song = state.selectedImportedSong else {
                return "Import a .mid file, select its drum track, and verify the note mappings."
            }
            if song.mappedNoteCount == 0 {
                return "Map at least one MIDI pitch to a drum voice before starting."
            }
            if state.importedSectionMappedHitCount == 0 {
                return "Measures \(state.importedSectionStartMeasure)–\(state.importedSectionEndMeasure) contain no mapped drum notes. Jump to the first playable section or change the range."
            }
            if state.importedSectionEligibleHitCount == 0 {
                return "This section contains only kicks and Grade kicks is off."
            }
            if usesExternalPlayback { return "Arm while Songsterr is paused. Wait for Ready, then press Play there. No DrumTrainer count-in or click." }
            return "Eight count-in clicks (two bars), then play measures \(state.importedSectionStartMeasure)–\(state.importedSectionEndMeasure)."
        }
        if scoredExpectedEvents.isEmpty {
            return "This exercise only contains kick notes. Turn Grade kicks on or choose a kit groove."
        }
        return "Eight count-in clicks (two bars), then the blue playhead starts moving."
    }

    private var practiceStartBlocker: String? {
        if state.isCustomSequence, let message = state.practiceCustomMeasure.sequenceValidationMessage { return message }
        if usesExternalPlayback && state.selectedPlaybackSourceID == nil {
            return "Load audio sources and select the browser playing Songsterr."
        }
        if usesExternalPlayback && state.importedSectionRepeats != 1 {
            return "Set repeats to 1; external looping is not supported yet."
        }
        if state.isRefreshingAudioEngine {
            return "The audio engine is refreshing. If this does not clear within six seconds, it will unlock automatically; Reset Practice is also always available."
        }
        switch state.practiceExerciseMode {
        case .builtIn:
            break
        case .custom where state.practiceCustomMeasure.isEmpty:
            return "Add at least one note to the custom measure before starting."
        case .importedSong where state.selectedImportedSong == nil:
            return "Import or select a MIDI song before starting."
        case .importedSong where state.selectedImportedSong?.mappedNoteCount == 0:
            return "Map at least one imported MIDI note to a drum voice before starting."
        default:
            break
        }
        if state.practiceExerciseMode == .importedSong, state.importedSectionMappedHitCount == 0 {
            return "The selected measures contain no mapped drum notes. Jump to the first playable section or change the range."
        }
        if state.practiceExerciseMode == .importedSong, state.importedSectionEligibleHitCount == 0 {
            return "The selected section contains only kicks and Grade kicks is off."
        }
        if scoredExpectedEvents.isEmpty {
            return "No notes are currently eligible for grading. If this is a kick-only part, turn Grade kicks on."
        }
        return nil
    }

    private var currentScoringConfiguration: PracticeScoringConfiguration {
        PracticeScoringConfiguration(gradeKicks: state.practiceGradeKicks)
    }

    private var scoredExpectedEvents: [ExpectedEvent] {
        displayedPattern?.expectedEvents.filter { currentScoringConfiguration.includes($0.voice) } ?? []
    }

    private var scoredHitsPerMeasure: Int {
        guard let pattern = displayedPattern, pattern.measures > 0 else { return 0 }
        return scoredExpectedEvents.count { $0.measure == 1 }
    }

    private func resultClassifications(_ outcome: PracticeSessionOutcome) -> [UUID: MatchClassification] {
        Dictionary(uniqueKeysWithValues: outcome.matchResults.compactMap { result in
            result.expectedEventID.map { ($0, result.classification) }
        })
    }

    private func accentClassifications(_ outcome: PracticeSessionOutcome) -> [UUID: AccentResultClassification] {
        Dictionary(uniqueKeysWithValues: outcome.accentEvaluation?.results.map {
            ($0.expectedEventID, $0.classification)
        } ?? [])
    }

    private func ghostClassifications(_ outcome: PracticeSessionOutcome) -> [UUID: GhostResultClassification] {
        Dictionary(uniqueKeysWithValues: outcome.ghostEvaluation?.results.map {
            ($0.expectedEventID, $0.classification)
        } ?? [])
    }

    private func legend(_ title: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    private func statusLabel(_ title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline).foregroundStyle(color)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func metricCard(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func countLabel(_ title: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + " ms"
    }

    private func signedMilliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + " ms"
    }

    private func signedMilliseconds(_ value: Double) -> String {
        value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + " ms"
    }
}

private struct PracticeTimingTimelineChart: View {
    let pattern: PracticePattern
    let timeline: PracticeTimingTimeline
    let entries: [PracticeTimingTimelineEntry]

    private let axisHeight: CGFloat = 30
    private let laneHeight: CGFloat = 42
    private let labelWidth: CGFloat = 112
    private let beatWidth: CGFloat = 140

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: axisHeight)
                ForEach(voices, id: \.self) { voice in
                    Text(voice.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(width: labelWidth - 10, height: laneHeight, alignment: .leading)
                }
            }

            ScrollView(.horizontal) {
                Canvas { context, size in
                    drawGrid(context: &context, size: size)
                    drawEntries(context: &context, size: size)
                }
                .frame(width: chartWidth, height: chartHeight)
            }
        }
        .frame(height: chartHeight)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timing timeline with \(entries.count) scored events across \(voices.count) drum voices")
    }

    private var voices: [DrumVoice] {
        let used = Set(entries.flatMap { [$0.expectedVoice, $0.playedVoice].compactMap { $0 } })
        return DrumVoice.allCases.filter { used.contains($0) }
    }

    private var chartWidth: CGFloat {
        max(720, CGFloat(max(pattern.measures * pattern.beatsPerMeasure, 1)) * beatWidth)
    }

    private var chartHeight: CGFloat {
        axisHeight + CGFloat(max(voices.count, 1)) * laneHeight
    }

    private var laneIndices: [DrumVoice: Int] {
        Dictionary(uniqueKeysWithValues: voices.enumerated().map { ($0.element, $0.offset) })
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        for (index, voice) in voices.enumerated() {
            let y = axisHeight + CGFloat(index) * laneHeight
            var lane = Path()
            lane.move(to: CGPoint(x: 0, y: y + laneHeight))
            lane.addLine(to: CGPoint(x: size.width, y: y + laneHeight))
            context.stroke(lane, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

            if index.isMultiple(of: 2) {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: laneHeight)),
                    with: .color(.secondary.opacity(0.035))
                )
            }
            _ = voice
        }

        guard pattern.bpm > 0 else { return }
        let beatNanoseconds = 60_000_000_000 / pattern.bpm
        let totalBeats = max(pattern.measures * pattern.beatsPerMeasure, 0)
        for beat in 0...totalBeats {
            let time = Double(pattern.startSessionTimeNanoseconds) + Double(beat) * beatNanoseconds
            let x = xPosition(for: time, width: size.width)
            let beginsMeasure = beat.isMultiple(of: max(pattern.beatsPerMeasure, 1))
            var line = Path()
            line.move(to: CGPoint(x: x, y: axisHeight - 4))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                line,
                with: .color(.secondary.opacity(beginsMeasure ? 0.42 : 0.16)),
                lineWidth: beginsMeasure ? 1.5 : 1
            )

            let label = beginsMeasure
                ? "M\(beat / max(pattern.beatsPerMeasure, 1) + 1)"
                : "\(beat % max(pattern.beatsPerMeasure, 1) + 1)"
            context.draw(
                Text(label).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: x + 4, y: 9),
                anchor: .leading
            )
        }
    }

    private func drawEntries(context: inout GraphicsContext, size: CGSize) {
        for entry in entries {
            let color = color(for: entry.classification)
            let expectedPoint = point(
                time: entry.expectedTimeNanoseconds,
                voice: entry.expectedVoice,
                width: size.width
            )
            let actualPoint = point(
                time: entry.actualTimeNanoseconds,
                voice: entry.playedVoice,
                width: size.width
            )

            if let expectedPoint, let actualPoint {
                var connection = Path()
                connection.move(to: expectedPoint)
                connection.addLine(to: actualPoint)
                context.stroke(connection, with: .color(color.opacity(0.55)), lineWidth: 2)
            }

            if let expectedPoint {
                let rect = CGRect(x: expectedPoint.x - 5, y: expectedPoint.y - 5, width: 10, height: 10)
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), lineWidth: 2)
                if entry.classification == .missed {
                    drawX(at: expectedPoint, color: color, context: &context)
                }
            }

            if let actualPoint {
                context.fill(
                    Path(ellipseIn: CGRect(x: actualPoint.x - 4, y: actualPoint.y - 4, width: 8, height: 8)),
                    with: .color(color)
                )
                if entry.classification == .extra {
                    context.stroke(
                        Path(ellipseIn: CGRect(x: actualPoint.x - 7, y: actualPoint.y - 7, width: 14, height: 14)),
                        with: .color(color.opacity(0.7)),
                        lineWidth: 1
                    )
                }
            }
        }
    }

    private func point(time: Int64?, voice: DrumVoice?, width: CGFloat) -> CGPoint? {
        guard let time, let voice, let lane = laneIndices[voice] else { return nil }
        return CGPoint(
            x: xPosition(for: Double(time), width: width),
            y: axisHeight + CGFloat(lane) * laneHeight + laneHeight / 2
        )
    }

    private func xPosition(for time: Double, width: CGFloat) -> CGFloat {
        let start = Double(timeline.startSessionTimeNanoseconds)
        let duration = max(Double(timeline.endSessionTimeNanoseconds) - start, 1)
        let progress = min(max((time - start) / duration, 0), 1)
        return CGFloat(progress) * max(width - 16, 1) + 8
    }

    private func drawX(at point: CGPoint, color: Color, context: inout GraphicsContext) {
        var x = Path()
        x.move(to: CGPoint(x: point.x - 6, y: point.y - 6))
        x.addLine(to: CGPoint(x: point.x + 6, y: point.y + 6))
        x.move(to: CGPoint(x: point.x + 6, y: point.y - 6))
        x.addLine(to: CGPoint(x: point.x - 6, y: point.y + 6))
        context.stroke(x, with: .color(color), lineWidth: 2)
    }

    private func color(for classification: MatchClassification) -> Color {
        switch classification {
        case .correct: .green
        case .missed: .orange
        case .extra: .purple
        case .wrongVoice: .red
        case .ambiguous: .indigo
        }
    }
}
