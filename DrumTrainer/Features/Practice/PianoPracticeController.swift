import Combine
import Foundation

enum PianoPracticePhase: Equatable {
    case idle, countIn(Int), running, results, error(String)
    var isActive: Bool {
        switch self { case .countIn, .running: true; default: false }
    }
}

@MainActor
final class PianoPracticeController: ObservableObject {
    @Published private(set) var phase: PianoPracticePhase = .idle
    @Published private(set) var input = PianoNoteTracker()
    @Published private(set) var recentMessages: [PianoInputEvent] = []
    @Published private(set) var pattern: PianoPracticePattern?
    @Published private(set) var outcome: PianoPracticeOutcome?
    private let clock: any ClockProviding
    private let timeline: SessionTimeline
    private var finishTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var earliestHostTime: UInt64 = 0
    private var lastTickHostTime: UInt64?
    private var startHostTime: UInt64?
    private var startNanoseconds: Int64?
    private var configuration = PianoScoringConfiguration()
    private var selectedChannel: UInt8?
    private var lastInputHostTime: UInt64 = 0
    private var sessionID: UUID?
    private var rawEvents: [PianoInputEvent] = []
    var onStopAudio: (() -> Void)?
    var onCancelled: (() -> Void)?
    var onScheduled: ((UUID, UInt64, UInt64, PianoPracticePattern) -> Void)?
    var onCompleted: ((UUID, PianoPracticeOutcome, [PianoInputEvent]) -> Void)?

    init(clock: any ClockProviding, timeline: SessionTimeline) {
        self.clock = clock
        self.timeline = timeline
    }

    var playheadNanoseconds: Int64? {
        guard phase.isActive, let startNanoseconds else { return nil }
        return timeline.sessionTimeNanoseconds(for: clock.currentHostTime()) - startNanoseconds
    }

    func start(preferences: PianoPracticePreferences, bpm: Double, configuration: PianoScoringConfiguration, pattern suppliedPattern: PianoPracticePattern? = nil) {
        guard !phase.isActive else { return }
        guard preferences.isValid, configuration.isValid else {
            fail("Piano practice settings are out of range. Reset your settings and try again.")
            return
        }
        guard !input.hasActiveNotes, input.sustainChannels.isEmpty else {
            phase = .error("Release all keys and the sustain pedal before starting. Use Reset keys if a release was lost.")
            return
        }
        let nextPattern = suppliedPattern ?? PianoPracticePattern.make(exercise: preferences.exercise, bpm: bpm, repeats: preferences.repeats)
        guard nextPattern.isValid else { fail("This piano exercise is invalid or exceeds the supported limits."); return }
        cancel(clearInput: false)
        sessionID = UUID()
        rawEvents = []
        selectedChannel = preferences.channel
        self.configuration = configuration
        input = PianoNoteTracker(capacity: 10_000, retainsSessionEvidence: true)
        pattern = nextPattern
        earliestHostTime = clock.currentHostTime()
        phase = .countIn(8)
        armWatchdog()
    }

    func receive(_ events: [PianoInputEvent], droppedCount: Int = 0, channel: UInt8? = nil) {
        input.markDropped(droppedCount)
        for event in events {
            guard event.effectiveHostTime >= earliestHostTime,
                  (phase.isActive ? selectedChannel : channel).map({ $0 == event.message.channel }) ?? true else { continue }
            lastInputHostTime = max(lastInputHostTime, event.effectiveHostTime)
            input.process(event)
            if phase.isActive {
                if rawEvents.count < 20_000 { rawEvents.append(event) }
                else { input.markDropped(1) }
            }
            recentMessages.append(event)
        }
        if recentMessages.count > 100 { recentMessages.removeFirst(recentMessages.count - 100) }
    }

    func handleTick(_ tick: MetronomeTick) {
        guard phase.isActive, tick.hostTime >= earliestHostTime,
              lastTickHostTime.map({ tick.hostTime > $0 }) ?? true else { return }
        lastTickHostTime = tick.hostTime
        armWatchdog()
        guard case let .countIn(remaining) = phase, let pattern else { return }
        if remaining == 0 { phase = .running; return }
        if remaining > 1 { phase = .countIn(remaining - 1); return }
        let interval = MetronomeTimeline.intervalNanoseconds(bpm: pattern.bpm)
        let start = timeline.hostTime(addingNanoseconds: interval, to: tick.hostTime)
        startHostTime = start
        startNanoseconds = timeline.sessionTimeNanoseconds(for: start)
        phase = .countIn(0)
        if let sessionID {
            onScheduled?(sessionID, start, timeline.hostTime(addingNanoseconds: UInt64(pattern.durationNanoseconds), to: start), pattern)
        }
        let grace = max(configuration.onsetToleranceNanoseconds, configuration.durationToleranceNanoseconds)
            + abs(configuration.timingCompensationNanoseconds)
        let deadline = timeline.hostTime(addingNanoseconds: UInt64(pattern.durationNanoseconds + grace), to: start)
        let token = generation
        finishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let now = clock.currentHostTime()
            let delay = deadline > now ? timeline.converter.nanoseconds(forHostTimeDuration: deadline - now) : 0
            do { try await Task.sleep(for: .nanoseconds(Int64(min(delay, UInt64(Int64.max))))) }
            catch { return }
            guard generation == token, !Task.isCancelled else { return }
            finish()
        }
    }

    func finish() {
        guard phase == .running, let pattern, let startNanoseconds else { return }
        stopTasks()
        let tolerance = max(configuration.onsetToleranceNanoseconds, configuration.durationToleranceNanoseconds)
        let correction = configuration.timingCompensationNanoseconds
        let actual = input.orderedNotes.filter {
            let time = Double($0.onsetNanoseconds) - Double(startNanoseconds) - Double(correction)
            return time >= -Double(tolerance) && time <= Double(pattern.durationNanoseconds + tolerance)
        }.map { note in
            PianoPlayedNote(id: note.id, input: note.input, pitch: note.pitch, velocity: note.velocity,
                onsetHostTime: note.onsetHostTime, onsetNanoseconds: note.onsetNanoseconds - startNanoseconds,
                keyReleaseNanoseconds: note.keyReleaseNanoseconds.map { $0 - startNanoseconds },
                soundingEndNanoseconds: note.soundingEndNanoseconds.map { $0 - startNanoseconds },
                isUncertain: note.isUncertain, isInterrupted: note.isInterrupted)
        }
        outcome = PianoEventMatcher().score(pattern: pattern, actual: actual, configuration: configuration,
                                           droppedCount: input.droppedCount, inputIssueCount: input.issueCount)
        phase = .results
        onStopAudio?()
        if let sessionID, let outcome {
            let evidence = rawEvents.map { PianoInputEvent(message: $0.message, endpointID: $0.endpointID,
                sessionTimeNanoseconds: $0.sessionTimeNanoseconds - startNanoseconds, effectiveHostTime: $0.effectiveHostTime) }
            onCompleted?(sessionID, outcome, evidence)
        }
    }

    func cancel(clearInput: Bool = true) {
        generation &+= 1
        stopTasks()
        sessionID = nil
        rawEvents = []
        pattern = nil
        outcome = nil
        startHostTime = nil
        startNanoseconds = nil
        lastTickHostTime = nil
        phase = .idle
        if clearInput { resetKeys() }
        onCancelled?()
        onStopAudio?()
    }

    func resetKeys() {
        if phase.isActive { fail("Input was reset; this attempt was discarded.") }
        earliestHostTime = max(clock.currentHostTime(), lastInputHostTime)
        input = PianoNoteTracker()
        recentMessages = []
    }

    func fail(_ message: String) {
        generation &+= 1
        stopTasks()
        outcome = nil
        phase = .error(message)
        onCancelled?()
        onStopAudio?()
    }

    func inputDisconnected() {
        if phase.isActive { fail("MIDI input disconnected; this attempt was discarded. Reconnect and start again.") }
        resetKeys()
    }

    private func armWatchdog() {
        watchdogTask?.cancel()
        let token = generation
        watchdogTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, generation == token, phase.isActive else { return }
            fail("The practice click stopped responding. Reset practice or check your audio output, then start again.")
        }
    }

    private func stopTasks() {
        finishTask?.cancel(); finishTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
    }
}
