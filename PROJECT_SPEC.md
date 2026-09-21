# Drum Performance Trainer — Project Specification

Status: implementation-ready product and technical specification  
Initial platform: native macOS  
Initial implementation: Swift and SwiftUI  
Primary instruction to Codex: **Begin with Milestone 1 only. Preserve the boundaries and extension points described here.**

## 1. Product vision

Build a native macOS practice application that measures a drummer's performance with millisecond-level timing feedback.

The initial hardware setup is intentionally hybrid:

- An electronic drum kit supplies MIDI events for snare, toms, hi-hat, ride, and cymbals.
- A physical double-bass pedal strikes an acoustic practice pad that has no electronic connection to the drum module.
- A Blue Snowball USB microphone placed near that kick practice pad detects kick impacts as audio transients.
- The Mac generates the metronome and owns the practice timeline.
- A Focusrite Solo is used for low-latency headphone or speaker monitoring, not as the primary source of note-identification data in V1.

The application converts all input and reference events onto one monotonic, high-resolution clock. It can then report what was played, whether the correct voice was played, how early or late it was, how tightly simultaneous limbs aligned, and how performance changes over time.

The first useful product is a technique trainer, not a Songsterr client. Song and tab practice is a later feature built on top of the same expected-event and scoring engine.

## 2. Goals

### Primary goals

- Reliably receive and identify e-kit MIDI hits.
- Reliably detect individual kick-pad impacts with the Blue Snowball.
- Run an internal, adjustable metronome.
- Timestamp MIDI hits, detected kicks, metronome ticks, and expected notes on a common host-time timeline.
- Provide calibration instead of pretending that device and detection latency is zero.
- Support deterministic practice patterns such as double-bass subdivisions and blast beats.
- Score note correctness, early/late timing, consistency, missed notes, extra notes, and synchronization between limbs.
- Save practice sessions and make progress visible over days and months.
- Keep input sources interchangeable so microphone kick detection can later be replaced or supplemented by hardware triggers.

### Non-goals for the first release

- General-purpose drum transcription from a full musical mix.
- Identifying left versus right foot from one microphone.
- Scraping or depending on undocumented Songsterr internals.
- Shipping a mobile companion app.
- Replacing the drum module's sounds or becoming a DAW.
- Claiming medically or scientifically exact biomechanical measurement.

## 3. User and core use cases

The initial user is a drummer practicing on an e-kit while using an acoustic double-kick practice pad.

Core use cases:

1. Connect the e-kit by USB MIDI, select the Blue Snowball, select the Focusrite Solo as audio output, and confirm all devices are working.
2. Calibrate the microphone by sampling room noise and approximately 20 deliberate kick hits, then tune threshold and retrigger lockout.
3. Start a metronome and view a unified live event log containing MIDI hits, detected kick hits, and reference beats.
4. Practice double-bass 8ths, 16ths, triplets, or a custom pattern and see early/late timing in milliseconds.
5. Practice blast-beat patterns and see whether cymbal, snare, and kick land on the intended grid and with each other.
6. Automatically increase tempo after repeated clean runs.
7. Review session history, per-limb/voice trends, timing bias, timing spread, and maximum clean tempo.
8. Later, import a drum part from MIDI, MusicXML, or a Guitar Pro-derived file, loop a section, change tempo, and compare playing with the expected notes.

## 4. Setup assumptions

### Required for V1

- A Mac supported by the chosen Xcode/macOS deployment target.
- An e-drum module with USB MIDI, or a 5-pin MIDI output plus a USB-MIDI interface.
- E-kit pads/cymbals already connected to that module.
- A double pedal and acoustic kick practice pad.
- A Blue Snowball connected directly to the Mac by USB and placed roughly 6–18 inches from the practice pad.
- Microphone permission granted to the app.

### Monitoring

- The Focusrite Solo connects to the Mac by USB.
- Headphones or speakers connect to the Focusrite.
- The app sends metronome audio to the selected system/output device, normally the Focusrite.
- The e-kit module may be monitored separately or routed as audio according to the user's existing setup. Note detection must use MIDI, not the module's mixed analog audio.
- Because the Snowball and Focusrite are separate USB audio devices, input and output device selection must be handled explicitly. Do not assume the selected input and output are the same device. If the initial audio API cannot safely use separate devices, document a temporary macOS Aggregate Device setup; do not silently select the wrong device.

### Unknowns to verify during development

- Exact e-drum module and its MIDI note map.
- Blue Snowball model, supported sample rates, and channel layout.
- Desired minimum macOS version.
- Whether the user monitors module audio separately or through the Focusrite.

These unknowns must be configurable or documented; they should not block Milestone 1 scaffolding.

## 5. Product principles

- **Timing comes first.** Never use wall-clock dates or UI callback arrival time for performance comparison.
- **Calibrate measured offsets.** USB, audio buffers, transient detection, and output monitoring introduce latency.
- **Keep raw evidence.** Store source timestamps and detector measurements so scoring can be recomputed when algorithms improve.
- **Deterministic core.** Input normalization, event matching, and scoring should be testable without attached hardware.
- **Graceful degradation.** Device loss or denial of microphone permission must produce clear UI, not a crash.
- **No premature Songsterr dependency.** Imported standard/local files are the supported path.
- **Privacy by default.** Process microphone buffers locally and do not retain audio unless the user explicitly enables local practice recording.

## 6. V1 hardware and signal flow

```text
E-kit pads/cymbals -> drum module -> USB MIDI ---------+
                                                       |
Double pedal -> acoustic practice pad -> Snowball USB -+-> Mac app
                                                       |   unified host-time events
Mac app -> internally scheduled metronome -------------+
Mac app -> selected audio output -> Focusrite -> headphones/speakers
```

MIDI communicates voice identity and velocity. Microphone audio supplies kick impact timing only. In V1, both beaters are represented as the same logical `.kick` voice.

## 7. Technical stack

- Swift using the version supplied by the current stable Xcode at project creation.
- SwiftUI for application UI.
- CoreMIDI for MIDI discovery, connection, and packet timestamps.
- AVFoundation/CoreAudio for input capture, output routing, metronome audio, buffer timing, and device inspection.
- XCTest for unit and integration tests.
- SwiftData or a simple Codable-backed repository may be introduced for history after the live foundation works. Persistence must be hidden behind a protocol.
- Avoid third-party dependencies in Milestone 1 unless a clear platform limitation requires one.

## 8. Shared timing model

This is the architectural center of the application.

### Requirements

- Use the macOS/Core Audio host-time domain (for example `AudioGetCurrentHostTime`, `AVAudioTime.hostTime`, and the corresponding conversion APIs) as the canonical monotonic clock.
- Confirm and document how CoreMIDI `MIDITimeStamp` maps to the host-time domain on the deployment target.
- Preserve the original source timestamp whenever the API supplies one.
- Translate audio buffer sample positions into host time using the render/capture timestamp, sample rate, and frame offset. A detected transient's timestamp is the buffer timestamp plus its in-buffer sample offset, not the time the callback finishes.
- Schedule the metronome ahead of playback and derive expected beats from the same timeline. Do not timestamp a tick from the moment a UI timer fires.
- Store session-relative nanoseconds or seconds for scoring and display. Store wall-clock `Date` only as session metadata.
- Represent source and calibration offsets explicitly; never bury unexplained constants in callbacks.

### Canonical event envelope

Every source produces a normalized event with at least:

```swift
struct PerformanceEvent: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID?
    let source: EventSource
    let voice: DrumVoice
    let hostTime: UInt64
    let sessionTimeNanoseconds: Int64
    let velocity: Double?
    let confidence: Double
    let rawMetadata: EventMetadata
}
```

The exact Swift shape may change, but source time, normalized time, voice, confidence, and raw metadata must remain distinguishable.

### Latency terms

Treat these separately:

- MIDI transport/input timestamp behavior.
- Microphone input device latency and safety offset.
- Audio buffer position and transient detector look-ahead or envelope delay.
- Metronome output device latency, relevant to what the drummer hears.
- Human calibration error and environmental variation.

Maintain per-device calibration profiles. A corrected time should be derived as:

```text
corrected event time = measured host time - configured source/detection offset
```

Do not automatically subtract an output latency from recorded playing unless the calibration workflow justifies it. Expose raw and corrected offsets in diagnostics.

## 9. Input subsystems

### 9.1 MIDI input

Responsibilities:

- Discover MIDI sources and react to connection/disconnection.
- Allow the user to select a source.
- Receive note-on messages; treat note-on with velocity zero as note-off.
- Ignore note-off for hit scoring.
- Preserve MIDI channel, note number, velocity, source endpoint, and source timestamp.
- Map device note numbers to canonical `DrumVoice` values.
- Support editable and saveable mappings per device.
- Show unmapped notes in diagnostics rather than dropping them.

Initial canonical voices should include kick, snare, cross-stick/rim, high/mid/low tom, closed/open/pedal hi-hat, ride/bell, crash 1/2, china, splash, other, and unknown. Scoring may group variants into broader voice families.

### 9.2 Microphone kick detection

V1 uses the Blue Snowball because it is direct, local, and avoids phone streaming/network/Bluetooth latency.

Initial detector pipeline:

1. Capture mono or downmixed PCM frames.
2. Remove DC bias and optionally apply a configurable high-pass or band-pass stage if testing shows it improves isolation.
3. Calculate a short-window energy/envelope or peak measure.
4. Estimate/adapt to the calibrated noise floor slowly enough that kick hits do not raise it immediately.
5. Detect an onset when the signal crosses the configured threshold with suitable attack/slope.
6. Locate the earliest defensible onset or local transient peak within the buffer.
7. Emit one `.kick` event with amplitude and confidence.
8. Apply a retrigger lockout, initially adjustable around 30–50 ms, to suppress pad ringing and echoes.

The detector must expose live waveform or envelope level, threshold, noise floor, hit markers, confidence, and lockout state for calibration. Audio processing must not allocate heavily or mutate SwiftUI state on the real-time callback. Pass compact results through a safe queue/actor boundary.

Known V1 limitations:

- It cannot inherently identify left versus right beater.
- Very fast double-bass playing may conflict with an overly long lockout.
- Room noise, stick impacts, monitor bleed, mic gain, placement, and pad resonance may cause false positives or misses.
- Automatic gain control, if present in the device/system path, can destabilize fixed thresholds and must be detected, disabled where possible, or documented.

### 9.3 Metronome

- Configurable BPM, time signature, subdivision, count-in, and accent.
- Audio scheduled with the audio engine rather than a UI timer.
- Expose exact expected host times for beats/subdivisions.
- Allow output device selection and a volume control.
- Offer distinct click timbres and enough digital gain range to remain audible during acoustic practice.
- Meter post-effect app output in peak/RMS dBFS and provide an enabled-by-default configurable dynamics ceiling. Clearly distinguish this from calibrated headphone dB SPL and system-wide audio monitoring.
- Optionally reinforce accepted MIDI or microphone kick events through the selected headphone output without adding generated audio to the event stream or scoring evidence.
- Continue stable scheduling when the UI is busy.
- Report an underrun or timing health warning if scheduling fails.

The training grid is conceptually separate from audible click events: not every expected 16th note must produce a click.

Current refinement: the app provides five synthesized click voices, −36 to +12 dB click gain, four synthesized kick-reinforcement voices with independent level, MIDI/microphone source selection, velocity response, retrigger protection, and six-voice polyphony, a persistent −12 to −0.5 dBFS dynamics ceiling, post-effect peak/RMS and gain-reduction metering, and the same controls in Live Monitor and Practice. Kick reinforcement is driven only by accepted canonical kick events, is suppressed during calibration/alignment, and never enters scoring evidence. The meter covers DrumTrainer-generated audio only. Practice notation uses exact event timestamps, alternating beat lanes, a moving playhead, and a live measure/beat/next-note cue. USB microphone capture explicitly requests the selected device's native format and retries the input-scope format for Core Audio format error -10868.

## 10. Architecture

Use modular boundaries so hardware I/O is replaceable and scoring can run in tests.

```text
App / SwiftUI
  |
  +-- Device & Calibration UI
  +-- Live Monitor UI
  +-- Practice UI / Results / History
  |
Application layer
  +-- AppState / dependency composition
  +-- SessionCoordinator
  +-- CalibrationCoordinator
  +-- PracticeCoordinator
  |
Domain layer (no hardware dependencies)
  +-- PerformanceEvent / ExpectedEvent / DrumVoice
  +-- Pattern and exercise generation
  +-- Event matcher
  +-- Scoring and metrics
  +-- Tempo progression rules
  |
Infrastructure layer
  +-- MIDIInputService (CoreMIDI)
  +-- AudioInputService (AVFoundation/CoreAudio)
  +-- KickTransientDetector
  +-- MetronomeEngine
  +-- HostClock / timestamp normalization
  +-- Persistence repository
  +-- Import adapters (future)
```

Suggested protocols:

- `ClockProviding`
- `MIDIInputProviding`
- `AudioInputProviding`
- `KickDetecting`
- `MetronomeProviding`
- `EventStreaming`
- `SessionRepository`
- `ExpectedTrackImporting`

Suggested project layout:

```text
DrumTrainer/
  App/
  Domain/
    Models/
    Patterns/
    Scoring/
  Services/
    Timing/
    MIDI/
    Audio/
    Metronome/
    Persistence/
  Features/
    Setup/
    Calibration/
    LiveMonitor/
    Practice/
    Results/
    History/
  SharedUI/
DrumTrainerTests/
  Fixtures/
  Timing/
  Detection/
  Scoring/
```

Concurrency rules:

- Hardware callbacks do minimal work and never block on UI or persistence.
- Domain events cross a bounded, observable stream into session coordination.
- UI model changes occur on the main actor.
- Session recording and scoring operate off the audio real-time thread.
- Define overflow/drop behavior and surface dropped-event counts in diagnostics.

## 11. Data model

The following are conceptual records, not a mandatory database schema.

### DeviceProfile

- `id`, display name, stable device identifiers where available
- device kind: MIDI input, microphone input, audio output, trigger input
- MIDI mapping
- sample rate/channel preferences
- calibration references and last-seen date

### CalibrationProfile

- device/profile IDs and creation date
- microphone noise floor
- detection threshold or threshold multiplier
- minimum attack/slope if used
- retrigger lockout in milliseconds
- input/detection correction in nanoseconds
- optional MIDI correction
- metronome output latency estimate
- calibration sample statistics and quality/confidence

### PracticePattern

- `id`, name, category
- tempo, meter, length/count-in
- repeating or finite expected events
- canonical voices and subdivisions
- simultaneous-event group IDs
- difficulty and progression settings

### ExpectedEvent

- `id`, pattern/track ID
- musical position: measure, beat, subdivision/tick
- expected session time/host time after scheduling
- voice or allowed voice family
- optional expected velocity/accent
- matching tolerance
- simultaneous group ID

### PerformanceEvent

- normalized event envelope described above
- raw MIDI or detector metadata
- calibration profile/version used

### MatchResult

- expected event ID and/or actual event ID
- result: correct, wrong voice, missed, extra, ambiguous
- signed timing offset in milliseconds (negative = early; positive = late)
- absolute timing error
- voice match quality and confidence

### PracticeSession

- `id`, start/end wall-clock dates, duration
- selected devices and calibration versions
- exercise/imported-track reference and tempo
- expected events, actual events, and match results, or references to them
- aggregate metrics
- app/scoring algorithm version
- optional notes/tags

### AggregateMetrics

- note accuracy
- counts: correct, missed, extra, wrong voice, ambiguous
- signed mean timing offset (bias)
- mean absolute error
- median absolute error
- standard deviation and/or robust spread such as MAD
- early/late counts
- per-voice metrics
- simultaneous limb-spread metrics
- longest clean streak
- maximum clean tempo/progression outcome

## 12. Expected patterns and exercises

Built-in categories should eventually include:

- Plain metronome/free timing.
- Double-bass: 8ths, 16ths, triplets, bursts, alternating groups, and custom patterns.
- Traditional blast.
- Hammer blast.
- Bomb blast.
- Gravity blast (with configurable interpretation because technique/input mapping varies).
- Skank beat.
- Rudiments and user-created patterns.

Represent patterns as expected events on a musical grid, not bespoke scoring code per exercise. A pattern generator turns tempo, meter, subdivision, and voice sequence into scheduled expected events.

For V1 microphone input, double-bass patterns score a single kick stream. They must not claim to know foot identity.

## 13. Event matching and scoring

### 13.1 Matching

For each session or rolling window:

1. Normalize expected and actual events to corrected session time.
2. Group or map compatible voice variants.
3. Generate candidate matches within a configurable time window, initially ±100 ms for ordinary practice.
4. Produce a one-to-one assignment so one actual hit cannot satisfy two expected notes and one expected note cannot consume two actual hits.
5. Prefer the compatible match with the smallest absolute timing error. For dense/ambiguous passages, use a sequence-aware or minimum-cost assignment rather than naïve independent nearest-neighbor matching.
6. Classify unmatched expected events as missed and unmatched actual events as extra.
7. Classify an incompatible nearby actual event as wrong voice only when doing so does not create misleading double penalties; define this policy in tests.

The matcher must be a pure, deterministic domain component with fixture-based tests covering dense 16ths, flams, simultaneous notes, boundary tolerances, missed hits, and extras.

### 13.2 Timing semantics

- Signed offset: `actual corrected time - expected time`.
- Negative values mean early.
- Positive values mean late.
- Mean signed offset indicates bias.
- Mean/median absolute error indicates accuracy.
- Standard deviation or MAD indicates consistency.
- Report sample counts with all aggregates.

Do not use signed average alone; early and late errors can cancel out.

### 13.3 Note accuracy

Keep component metrics visible rather than hiding everything inside one score:

```text
recall = correct expected notes / total expected notes
precision = correct expected notes / total played/scored notes
```

Current refinement: Practice provides a persistent **Grade kicks** switch. When disabled, kick expectations remain visible in notation for manual playing, but both expected and detected `.kick` events are filtered before matching. Recall, precision, hit classifications, timing aggregates, per-voice metrics, simultaneous-limb spread, clean-run progression, and Find My Ceiling therefore use only the remaining e-kit voices. Raw detected kicks remain in saved evidence, and each session persists the scoring configuration so historical rescoring is reproducible.

The UI may call recall “note accuracy” if clearly defined. A combined overall score may be added later but must show its formula and must not replace raw metrics.

Suggested timing bands, configurable by exercise:

- Tight: absolute error <= 20 ms
- Good: >20 ms and <= 40 ms
- Acceptable: >40 ms and <= 70 ms
- Loose: >70 ms and within the match window
- Miss/extra: no one-to-one match

These are starting defaults, not scientific truths. Tempo-relative tolerances may be added later.

### 13.4 Limb synchronization

Expected events intended to land together share a simultaneous group ID. For their matched actual events:

```text
limb spread = latest corrected actual time - earliest corrected actual time
```

Report average, median, worst, and distribution of group spread. Also report each voice's offset relative to the group center or a configured anchor. Example: cymbal -3 ms, snare +4 ms, kick +19 ms yields a 22 ms spread.

### 13.5 Tempo progression

A configurable rule can advance tempo, for example:

- Increase by 5 BPM after three consecutive runs with at least 95% note recall and <=25 ms median absolute timing error.
- Hold tempo if the threshold is not met.
- Optionally decrease after repeated failures.
- Never advance on a session with too few valid notes, a device disconnect, excessive dropped events, or poor calibration confidence.

Track clean-tempo records by exercise and duration. A later “find my ceiling” mode can raise tempo until a configured performance threshold fails.

## 14. Calibration and diagnostics

### Microphone calibration workflow

1. Select the Blue Snowball and verify format/sample rate.
2. Observe several seconds of room noise and estimate a stable noise floor.
3. Ask the user to play approximately 20 isolated kick hits across realistic strengths.
4. Display envelope/waveform, noise floor, threshold, and detected markers.
5. Suggest a threshold while allowing manual adjustment.
6. Test the retrigger lockout with single and rapid alternating hits.
7. Report detected/expected calibration hits, suspected duplicates, and missed weak hits.
8. Save the profile for this device and configuration.

The calibration UI should include a live “hit detected” indicator and make false triggers obvious. It must warn if the signal-to-noise ratio is insufficient.

### Timing offset calibration

Amplitude calibration does not prove cross-device timing alignment. The implemented guided workflow schedules 12 audible clicks through the selected output, records repeated hits from either a chosen MIDI voice or the kick microphone, estimates median signed offset and median absolute deviation, and stores the correction for that exact input/output combination. Raw event timestamps remain unchanged; only the scoring matcher derives corrected times. Each session records the corrections it used.

This listen-and-play workflow intentionally includes normal human response bias along with the output and input paths. The UI describes it as personal/device alignment rather than a hardware-only absolute latency measurement. A known physical loopback/reference remains the future refinement for separating hardware latency from player response.

### Diagnostics

Expose a developer/user diagnostics panel containing:

- device names and identifiers
- sample rate, buffer size, input/output latency information
- current host time and session origin
- raw versus corrected timestamps
- MIDI note/channel/velocity
- audio peak/envelope/noise floor/threshold
- detector confidence and lockout state
- dropped events/buffers, audio route changes, and engine restarts
- active calibration profile/version

Allow export of a compact JSON or CSV diagnostic session later. Raw audio capture must be opt-in.

## 15. UI screens

### Setup / Devices

- MIDI input selector and connection status.
- MIDI mapping editor with learn mode.
- Audio input selector, with Blue Snowball expected in V1.
- Audio output selector, normally Focusrite Solo.
- Microphone permission and device-error guidance.
- Per-device calibration status.

### Kick Calibration

- Live waveform or envelope graph.
- Noise floor and threshold line.
- Detected-hit markers and count.
- Sensitivity/threshold control.
- Retrigger lockout control.
- Guided noise and 20-hit sequence.
- Save/reset profile and confidence summary.

### Live Monitor

- Metronome controls: BPM, meter, subdivision, volume, start/stop.
- Live unified event list with session time, source, voice, velocity/amplitude, confidence, and raw/corrected timing toggle.
- Clear/pause controls and device health indicators.
- Lightweight visualization that remains responsive under fast playing.

Example:

```text
00:12.501  MIDI        SNARE       velocity 104
00:12.503  MIDI        CRASH       velocity 87
00:12.516  MICROPHONE  KICK        confidence 0.96
00:12.750  METRONOME   SUBDIVISION
```

### Exercise Library / Builder

- Category and pattern selection.
- BPM, duration/measures, count-in, and progression rule.
- Visual grid showing expected voices.
- Custom pattern editing in a later milestone.

### Practice

- Clear count-in and running state.
- Current BPM and elapsed/remaining duration.
- Scrolling grid or compact lane display.
- Optional restrained live feedback; avoid distracting the player.
- Stop/cancel and device-health warnings.

### Results

- Correct/missed/extra/wrong counts.
- Note recall/precision.
- Mean signed offset and median/mean absolute error.
- Early/late distribution.
- Per-voice breakdown.
- Limb synchronization/spread for simultaneous groups.
- Clean streak and progression result.
- Timeline visualization for inspecting failures.

### History

- Sessions by date, exercise, tempo, and duration.
- Trend charts for timing error, consistency, note accuracy, limb spread, and maximum clean tempo.
- Drill-down into an individual session.
- Optional, explicitly enabled compressed audio recording for each completed session, with a recording input independent of the kick-detection microphone plus playback, scrubbing, file size, and deletion controls.

## 16. Phased milestones

### Milestone 1 — Live timing foundation

Objective: prove the complete real-time input/timing path before building scoring.

Deliverables:

- Create the native macOS SwiftUI project and a concise README.
- Define domain event models and the shared host-time abstraction.
- List available MIDI inputs and allow selection.
- Receive note-on events and show note number, mapped name, velocity, source timestamp, and normalized session timestamp.
- List available audio inputs and allow selection of the Blue Snowball.
- Show a live microphone level/envelope view.
- Implement initial threshold/onset kick detection with adjustable sensitivity and 30–50 ms default retrigger lockout.
- Log detected kick events with in-buffer-derived host timestamps and confidence/amplitude.
- Implement an internally scheduled metronome with adjustable BPM and start/stop.
- Put MIDI, kick, and metronome/reference events in one bounded live event stream and unified log.
- Handle permissions, missing devices, disconnection, and audio route change without crashing.
- Add unit tests for timestamp conversion, MIDI mapping, detector logic using synthetic buffers/envelopes, and event-stream ordering.
- Document how to launch, grant microphone access, connect hardware, and interpret diagnostics.

Explicitly out of scope for Milestone 1:

- Practice scoring and result summaries.
- Persistence/history.
- Song or notation import.
- Left/right foot classification.
- Polished scrolling notation.
- Automatic tempo progression.

Milestone 1 is complete only when all acceptance criteria in Section 17 pass.

### Milestone 2 — Calibration and double-bass exercise

- Guided microphone noise/20-hit calibration.
- Saved device calibration profile.
- [x] Guided per-input/output hit-timing alignment with median correction and variability.
- 8th/16th/triplet kick pattern generator.
- Count-in and fixed-duration practice session.
- One-to-one event matcher and early/late scoring.
- Results for accuracy, misses, extras, bias, absolute error, and consistency.
- Fixture-driven scoring tests.

### Milestone 3 — Multi-limb and blast-beat trainer

- MIDI mapping UI and canonical voice families.
- Built-in blast/skank patterns.
- Simultaneous group scoring and limb-spread analytics.
- Per-voice results and detailed timing timeline.
- Custom exercise parameters.

### Milestone 4 — Progression and practice history

- [x] Persistent sessions and calibration versions.
- [x] Repeated-clean-run tempo advancement rules.
- [x] Dedicated ceiling-finding mode for built-in and custom exercises.
- [x] Trend charts and personal bests.
- [x] Validated, schema-versioned JSON export/import of user data.
- [x] Opt-in local AAC practice recordings linked to History sessions, including playback and automatic cleanup when sessions are deleted.

The schema-v8 implementation retains expected and performed events, raw event metadata, match results, scoring metrics, authored custom-note accents and their velocity targets, per-session kick-grading configuration, selected-device context, the exact microphone calibration profile used by each new session, and persistent imported-song libraries. History supports event-level drill-down, editable notes/tags, rescoring, individual/all deletion, and backward migration of schema-v1/v2/v3/v4/v5/v6/v7 data. Find My Ceiling runs repeat the selected exercise, advance after each clean round, stop on the first failed round, and persist the highest verified clean tempo. Accent results remain separate from note/timing matching. New custom accents use the median of up to four nearby correctly played non-accented events of the same voice as their baseline, require the configured MIDI-velocity-point contrast or 20% of that baseline (whichever is greater), and can additionally require an optional absolute velocity floor. Older schema-v6 accent evidence retains its original floor-only behavior during rescoring. At least 90% of authored accents must pass for a clean run. Legacy summaries remain usable for trends but cannot be made rescorable retroactively because their events were never stored.

### Milestone 5 — Song and tab import

- [x] Import PPQ-based Standard MIDI format 0 and 1 files first.
- [x] Parse tempo maps, meter changes, running status, track names, and percussion-channel notes into expected events.
- Add local MusicXML support where drum/percussion semantics are recoverable.
- Add Guitar Pro support through a lawful, maintainable parser/library or an explicit conversion workflow.
- [x] Map imported notes to canonical drum voices with editable per-song mapping and explicit Ignore states.
- [x] Persist, rename, select, and delete imported songs through schema-v8 data storage and JSON transfer.
- [x] Author and persist ghost notes in custom measures, render parenthesized noteheads, grade relative softness against normal notes of the same voice with an optional maximum velocity, and save results for history, clean runs, and rescoring.
- [x] Author and persist `>` accents in custom measures; grade their local same-voice velocity contrast with an optional absolute floor; annotate baseline, target, and result; and include accent accuracy in clean-run decisions.
- [x] Section selection, looping, count-in, tempo-map scaling, notation preview, scoring, history, automatic progression, and Find My Ceiling.
- [x] Schedule the audible click from the imported, scaled tempo map with per-measure accents and output-presentation-latency compensation.
- Optional backing-audio alignment with an explicit calibration/sync workflow.

### Milestone 6 — Hardware kick triggers and foot analysis

- Add one trigger as a more precise replacement for microphone kick detection.
- Add optional two-sensor input for left/right analysis.
- Guided calibration: isolated left hits, isolated right hits, then alternating hits.
- Classify left/right using relative sensor amplitude and timing only when confidence is adequate.
- Report each foot's timing bias, spread, accuracy, and alternating-spacing consistency.
- Preserve `.kick` fallback when classification is ambiguous.

## 17. Milestone 1 acceptance criteria

The implementation must satisfy all of the following:

1. The app builds and launches from a clean checkout using documented steps.
2. Denying microphone permission produces an actionable message and leaves MIDI functionality usable.
3. The app lists currently available MIDI inputs and audio inputs and reflects connection changes.
4. Selecting an e-kit MIDI source produces one visible hit row per note-on, with raw note, mapped voice, velocity, and a monotonic session timestamp.
5. Selecting the Snowball produces a responsive live level/envelope visualization without storing audio by default.
6. Approximately 20 isolated kick-pad strikes can be detected and shown individually after threshold adjustment; lockout prevents obvious ring-induced duplicate hits.
7. Sensitivity/threshold and retrigger lockout are adjustable while monitoring.
8. The metronome starts/stops cleanly, supports at least 40–240 BPM, and is scheduled from the audio/host timeline rather than a UI timer.
9. MIDI, microphone kick, and metronome/reference events appear in a unified time-ordered log using the common host-time domain.
10. Audio transient timestamps use buffer/sample position, not callback completion time.
11. Disconnecting a selected device does not crash the app and shows a recoverable disconnected state.
12. The UI remains responsive during at least 60 seconds of dense MIDI input and rapid kick-pad playing; dropped-event diagnostics remain visible.
13. Automated tests cover host-time/session-time conversion, MIDI note mapping, detector threshold/lockout behavior, and ordering of simulated mixed-source events.
14. README documentation explains the hardware wiring, permissions, selected input/output roles, run steps, known limitations, and how to test without every physical device.

Where exact hardware cannot be used in automated tests, include simulators/fixtures and provide a short manual test checklist.

## 18. Future hardware trigger design

Microphone detection is the correct zero-additional-cost V1. Later options:

- **One contact/piezo or purpose-built kick trigger:** detects either beater as a kick, likely with better isolation and onset precision. It still does not identify the foot.
- **Two contact sensors, one nearer each impact area:** may enable left/right classification by comparing both sensors. Since the whole pad vibrates, both sensors may respond; physical placement and per-user calibration are mandatory.
- **Electronic kick tower or trigger-to-MIDI device:** simplest digital event path if compatible with the module or a separate interface.

The trigger subsystem must implement the same normalized event interface as the microphone detector. Do not couple scoring to a particular kick sensor.

Two sensors should emit one logical hit, not two. A classifier combines near-simultaneous sensor peaks and assigns left, right, or unknown with a confidence value. Expensive dual triggers are not assumed to guarantee foot separation.

## 19. Songsterr and imported tab strategy

Custom practice now also supports named arrangements of saved 4/4 measures, with step order, independent repeats, whole-sequence repeats, preserved dynamics, mixed subdivision grids, continuous scoring, and per-measure review. Schema v9 stores sequence snapshots and score labels/grids while migrating older archives. Limits are 32 steps, 16 repeats, 128 total measures, and 10,000 expected notes. Each run uses one count-in for the entire arrangement.

Songsterr is a possible source and practice companion, not an architectural dependency.

An experimental audio-start companion mode is available for imported MIDI sections: select a browser, arm while paused, wait for quiet then audio onset, and grade one pass against a manually offset MIDI timeline without the app's count-in/click. It does not read Songsterr's playback position or follow pauses, seeks, loops, speed changes, or drift. Unverified prototype scores are review-only and excluded from persisted progress; physical browser/headphone alignment remains to be validated. See README for setup and limitations.

- Do not scrape the Songsterr player or depend on undocumented private APIs.
- Prefer user-imported Standard MIDI, Guitar Pro, or MusicXML files obtained lawfully.
- If a Songsterr subscription/export is used, the user imports the resulting local file; the application remains file-source agnostic.
- Keep import adapters separate from the canonical expected-event model.
- Preserve tempo maps, time signatures, measure positions, and drum mappings.
- Clearly report unsupported or ambiguous notation instead of guessing silently.
- Review licensing and distribution constraints before shipping any direct third-party integration.

The first song importer should be Standard MIDI because its timed events and tempo map align naturally with the domain model. Guitar Pro/MusicXML can follow once conversion fidelity is characterized.

## 20. Persistence, privacy, and export

- Store practice data locally by default.
- Save calibration profiles separately from sessions and record which version each session used.
- Store normalized events and enough raw metadata to allow rescoring after algorithm updates.
- Version the persistence schema and scoring algorithm.
- Provide deletion and export controls before treating history as production-ready.
- Do not record or retain live microphone audio by default.
- Any practice or diagnostic audio recording must be explicit, visibly active, local-only by default, and easy to delete. Practice audio remains outside the JSON archive so large media never enters preferences-backed persistence.

## 21. Quality requirements

- No blocking work, logging flood, heap-heavy transformations, or persistence on audio/MIDI callbacks.
- Bounded memory for live event history and diagnostic graphs.
- Unit tests use injected clocks and synthetic events; they must not require real time or connected hardware.
- Detector tests include noise, one hit with ringing, two legitimate rapid hits, threshold-boundary cases, and clipped input.
- Scoring tests include dense subdivisions, simultaneous groups, equal-distance ambiguity, extras, misses, wrong voices, and early/late sign conventions.
- Accessibility: keyboard-operable primary controls, meaningful labels, sufficient contrast, and non-color-only score states.
- Errors name the affected device/action and offer a recovery step.
- Debug logs must not expose raw audio or grow without bound.

## 22. Key risks and mitigations

| Risk | Mitigation |
|---|---|
| Snowball hears sticks, module audio, or room noise | Close placement, headphones, calibration, threshold/slope filtering, confidence, optional band-pass |
| Pad ringing creates duplicates | Adjustable retrigger lockout and onset hysteresis |
| Lockout drops very fast legitimate kicks | Tune with rapid-hit calibration; make lockout configurable; evolve to peak-pair logic |
| MIDI/audio/metronome appear aligned but have fixed offsets | Preserve host timestamps, expose raw/corrected values, add repeatable cross-device calibration |
| UI timers create metronome jitter | Schedule through the audio engine and derive the practice grid from host time |
| Separate Snowball input and Focusrite output complicate routing | Explicit device model; document Aggregate Device fallback; test route changes |
| Naïve matching fails on dense patterns | One-to-one, sequence-aware/minimum-cost matching with fixtures |
| One microphone cannot identify foot | Treat all V1 impacts as kick; add optional two-sensor subsystem later |
| Imported notation uses inconsistent drum mappings | Canonical voice map, import preview, editable mapping, explicit unsupported states |
| Songsterr changes or disallows access | Use local standard-file imports and no undocumented dependency |

## 23. Initial Codex implementation brief

When beginning work, Codex should:

1. Read this entire specification.
2. Inspect the available Xcode/macOS toolchain and choose a documented deployment target.
3. Create only the Milestone 1 project and supporting tests.
4. Establish the host-time abstraction and normalized domain event before wiring UI features independently.
5. Build a thin vertical slice: simulated event -> unified stream -> live log, then replace simulation with CoreMIDI, audio detection, and metronome sources.
6. Keep hardware services behind protocols and supply simulation/fixture implementations so development is possible without the full drum setup attached.
7. Verify builds and tests, then run the manual hardware checklist where devices are available.
8. Record unresolved hardware-specific assumptions in the README instead of inventing them.

The first visible success is a stable screen that, while the metronome runs, shows e-kit MIDI hits and Blue Snowball kick transients in correct common-clock order. Scoring comes after that foundation is proven.

## 24. Definition of the longer-term successful product

A mature version lets the drummer choose a technique exercise or imported song section, hear a precisely scheduled click/backing track through the Focusrite, play e-kit pads plus the acoustic double-kick pad, and receive trustworthy feedback such as:

```text
BLAST BEAT — 160 BPM — 30 seconds

Note recall             94.7%
Median absolute error   14 ms

Cymbal  mean offset     -6 ms   consistency 96%
Snare   mean offset    +11 ms   consistency 93%
Kick    mean offset    +24 ms   consistency 87%

Median limb spread      18 ms
Primary issue           kick consistently late
Next action             repeat at 160 BPM
```

With two calibrated kick sensors, it may additionally report left/right foot differences. Across saved sessions, it should show whether maximum clean double-bass tempo, blast-beat accuracy, foot balance, and limb synchronization are improving.
