# Electric guitar and electric piano support

Accepted proposal • October 12, 2026 • Shared foundation and MIDI piano core implemented

## Implementation status

The first foundation increment adds the persistent instrument selector, instrument-specific tempo/device profiles, preservation of the drum editor and selected song section, schema-10 migration with explicit drum labels, pitched-note identities/duration/chord targets, and an extracted session-evidence controller. Switching cancels active transport and calibration, discards partial recordings, invalidates old refresh callbacks, clears event evidence, and stops Auto go. Guitar and piano show setup screens with practice clearly marked as upcoming.

The MIDI piano core now adds batched CoreMIDI channel messages with connection-generation checks, note-on/off and velocity-zero releases, sustain and controller-reset handling, distinct endpoint/group/channel identities, bounded note evidence, exact-octave/chord assignment, optional key-release duration grading, five exercises, a live keyboard, scrolling piano roll, and piano-specific timing alignment. Results are currently kept in memory. Piano setup preferences remain compatible with schema 10 through an optional profile field.

Existing drum scoring and notation remain on their compatibility path. Piano saved history/custom exercises/imports/recordings/progression, richer notation, and guitar audio pitch detection are subsequent phases. Hardware feasibility work remains pending the user's actual connections; this increment does not claim guitar recognition or full piano workflow parity. Controller semantics follow the MIDI Association's [control-change reference](https://midi.org/midi-1-0-control-change-messages), and UMP packet walking follows the installed CoreMIDI SDK declarations.

Validation: the build and all 198 tests pass, including 32 piano-core tests, native CoreMIDI delivery of a 96-word packet, timestamp fallback and stale-connection checks, pedal/release fixtures, chord assignment, cancellation, and drum regressions. The piano-roll/keyboard render was inspected. Physical keyboard, pedal, and output-latency validation is still required before declaring the hardware completion gate satisfied.

## Product direction

Extend the existing native macOS app with a persistent **Drums / Electric Guitar / Electric Piano** selector. Each instrument gets its own exercises, input setup, notation, grading rules, and progress, while sharing the current practice workflow and timing infrastructure.

The intended experience is: choose an instrument, select an exercise or imported part, calibrate the input, practice against scrolling notation, inspect results, and review recordings and progress. Count-in, repeats, Auto go, tempo advancement, Find My Ceiling, custom exercises, measure sequences, history, and JSON backups should work in all three modes.

This is a substantial extension. Pitched instruments need pitch, note releases, and chord handling; adding two values to the current drum-voice list would not provide those capabilities.

## Working hardware assumptions

Until the user's connection details are confirmed, plan around:

- Drums: existing e-kit MIDI plus optional acoustic kick detection.
- Electric piano: USB MIDI or an interface MIDI connection for grading; optional separate audio input for recording the piano's actual sound.
- Electric guitar: a clean, isolated instrument input through an audio interface. MIDI guitar is an optional alternative when suitable hardware is already available.
- Headphone output: reuse the selected audio output and metronome.

An audio interface supplies guitar audio, not automatically MIDI notes. A piano connected only by its audio output also needs audio note recognition. If both instruments will use audio alone, add a piano recognition feasibility milestone before promising full piano grading.

Apple's [Core MIDI framework](https://developer.apple.com/documentation/coremidi) supports communication with hardware keyboards and synthesizers, so the existing device transport is a useful foundation for MIDI piano.

## Instrument switching and screens

Place the instrument selector above the existing Live Monitor, Calibration, Practice, History, and Settings tabs. Keep it visible throughout the app and remember the last selected instrument.

Each mode remembers its own input device/channel, output preference, calibration, selected exercise/song/section, tempo, grading settings, and progression state. Common controls such as Auto go can remain shared initially; instrument-specific settings live in their respective profiles.

Switching during count-in, practice, calibration, or an armed external-playback session must first end that flow as an interrupted attempt. Cancel scheduled restarts, drain stale events, clear active notes and pedal state, finish/discard partial audio using the existing interrupted-recording policy, then activate the new profile. Show a brief explanation before discarding an unsaved exercise edit. Changing the instrument must never award a completed score or carry a held piano note into guitar mode.

History defaults to the selected instrument. An optional All instruments view shows explicit labels; progress and personal bests remain separate. Opening a historical session uses that session's instrument and saved rules, regardless of the current selector.

## Feature parity

| Existing capability | Electric piano version | Electric guitar version |
| --- | --- | --- |
| Live Monitor | Keyboard, note names, velocities, held keys, sustain state | Input level, detected pitch, tuning deviation, onset and confidence; MIDI events when available |
| Guided calibration | MIDI timing alignment and optional velocity range | Noise/gain, tuning reference, supported pitch range, onset/pitch reliability and timing alignment |
| Built-in exercises | Scales, intervals, arpeggios, chord changes, rhythm and two-hand coordination | Picking rhythms, scales, string-crossing phrases, arpeggios and later chord/strum drills |
| Custom measure editor | Piano roll with pitch, start, duration, simultaneous notes and optional hand labels | Pitch/duration editor plus editable string/fret targets and tuning |
| Saved measure sequences | Existing arrangement workflow with pitched-note snapshots | Same workflow with guitar-note and tuning snapshots |
| Scrolling practice score | Piano roll first; grand staff later | Tab and rhythmic note durations; optional staff later |
| Correct/wrong/missed/extra results | Exact pitch and octave, timing, chord completeness, optional key-release accuracy | Pitch and timing; later chord completeness, strum timing and bend targets |
| Per-voice and limb spread | Per-pitch/part results and labeled left/right coordination | Per-note/phrase results and chord/strum spread where evidence supports it |
| Accents and ghost notes | Optional loud/soft MIDI-velocity targets with piano-specific settings | Optional relative attack-level targets when reliable; MIDI velocity if supplied |
| Metronome, count-in, repeats, Auto go | Shared transport | Shared transport |
| Tempo advancement and Find My Ceiling | Piano-specific clean-run rules and records | Guitar-specific rules; only verified detection qualifies |
| MIDI song import and section looping | Select pitched parts; retain durations and pedal data | Select pitched part; author/review tab assignments and tuning |
| Optional session recordings | Capture analog/digital piano audio separately from grading MIDI | Save isolated guitar input; processed monitoring is a separate later option |
| History, notes, tags, rescoring, JSON | Instrument-labeled sessions and evidence | Same, including detector version and confidence |
| Experimental Songsterr companion | Matching MIDI part and existing start-alignment limitations | Same; backing audio must not enter the guitar grading input |

Parity means a comparable practice workflow with rules that fit each instrument. Drum-specific kick filtering, reinforcement, and limb terminology remain in drum mode. Proposed exercise demonstration playback and local backing-track playback are separate future features, not prerequisites for this extension.

## What the current code establishes

- `PerformanceEvent` and `ExpectedEvent` identify notes through `DrumVoice`; expected events have attack times but no pitched-note duration.
- `MIDI1UMPParser` emits positive-velocity note-on events only. Releases, sustain, and pitch bend are not captured as performance evidence.
- `ImportedMIDINoteEvent` stores tick, pitch number, velocity, and channel, but no release/duration. The file parser chooses percussion preferentially and constructs drum mappings.
- `EventMatcher` uses a globally ordered, one-to-one dynamic-programming match. Reversed arrival order within a piano chord needs explicit group matching.
- `PracticeScoreView` draws drum notation. The editor and result lanes also assume drum voices.
- `AppState.swift` currently contains roughly 3,400 lines; transport, settings, input interpretation, and exercise selection are closely connected.
- `PracticeSessionRecording.swift` declares persistence schema version **9**. Migration must follow the implemented schema rather than older version references in the README.
- The README and `docs/audio-transport-deadlock.md` document audio callback and transport constraints that must survive the extension.

Existing uncommitted work in app state, practice views, settings, tests, and the Xcode project is part of the baseline. Implementation must integrate with it without reverting it.

## Shared architecture

### Instrument-aware models

Introduce an `InstrumentKind` and instrument profiles. Use a tagged note identity such as `MusicalTarget.drum(DrumVoice)` or `.pitched(MIDIPitch)` rather than encoding piano keys as drum voices. Keep octave-exact pitch distinct from optional pitch-class grading.

Add a pitched expected-note representation with onset, duration, chord/group identifier, velocity target, optional hand/part, and optional guitar string/fret and bend metadata. Pitch spelling, hand assignment, and tablature are authored display information; they are not automatically observed performance facts.

Separate raw input messages from normalized performance notes. Preserve note-on, note-off, controller and bend events with source timestamps. Pair them into performed notes with onset, key release, pedal-aware sustained interval when applicable, and confidence. Store audio onset and pitch-confirmation times separately: processing completion is not the player's attack time.

Use one canonical channel convention across live and imported MIDI; the current live parser uses 1–16 while imported notes use 0–15. Include endpoint and channel in note pairing so identical notes from different inputs do not collide.

### Services and state

Extract a shared `PracticeSessionController` incrementally from `AppState`, plus profile storage and instrument-specific exercise/editor state. Reuse the timing clock, bounded event transport, metronome, optional recording, and repository. Keep the existing drum path behind a compatibility adapter until regression checks pass.

Give each instrument an input interpreter, exercise provider, notation renderer, and scoring policy. Start with concrete implementations behind small interfaces; avoid a wholesale rewrite or three copied applications.

For guitar audio, separate PCM capture from onset and pitch analysis. Share capture with optional recording where the same input is selected. Analyze bounded buffers on a worker queue; keep audio callbacks free of model inference, file writing, UI updates, and engine graph access. Expose dropped buffers and analysis backlog as reliability evidence.

### Persistence and compatibility

Create the next schema migration with explicit instrument fields and backward-compatible decoding. Existing sessions, exercises, songs and progress default to drums without changing IDs or historical scores. Old imported songs keep their existing drum mappings.

Namespace exercise/progression keys by instrument, exercise content, and grading configuration so similarly named drills or differing tolerances do not share a clean-run streak. Save instrument profile, tuning, source/channel, calibration, scoring version, detector version and enabled grading dimensions with each session.

Preserve original archived results. Offer rescoring explicitly with identifiable rules. Legacy MIDI imports cannot recover releases from stored onset-only data; offer reimport of the original file for duration grading. Likewise, archived MIDI does not reveal actual hand or string usage.

Keep audio optional and local. JSON remains metadata/event evidence; recordings need a separate bundle/export feature if portability is desired. Audio sessions can rescore stored detected notes without raw PCM, but rerunning a new detector requires retained source audio and must be described separately.

## Electric piano implementation

Extend live MIDI handling with note-off, velocity-zero note-on releases, sustain controller events, pitch bend capture, and reset/all-notes-off behavior. Clear active notes on disconnect, stop, profile switch, and event loss. Repeated attacks at the same pitch must remain distinct, including reattacks while sustain is down; ambiguous overlapping lifetimes must be flagged.

Keep key-release duration separate from pedal-sustained duration. Note-off is evidence of key release, not proof that an electric-piano patch has stopped sounding. Pedal grading is optional and uses explicit authored/imported targets; do not penalize an ordinary MIDI exercise simply because pedal targets are absent.

Grade pitch and attack timing first. Chords match as note sets within a configurable onset window, independent of MIDI arrival order. Each actual note earns at most one match. Report missing and extra chord tones and note spread. Add optional release/duration and velocity grading, with per-dimension results.

Support left/right labels in authored exercises and explicitly selected MIDI parts. Do not infer the player's hand from key pitch alone. A user can practice one part while displaying the other; ignored notes must not become missed or extra notes.

A MIDI-only keyboard can still be graded without an app sound engine. Initial sound can come from the piano or an existing instrument host. Built-in electric-piano sounds and software monitoring can follow as a separate milestone if needed; MIDI itself is not an audible recording.

## Electric guitar implementation

### First dependable release

Use a clean direct input to grade single-note exercises: pitch, octave, attack timing and cautiously assessed duration. Provide editable tuning and capo settings; validate the detector over the selected range rather than claiming all tunings immediately. Start with standard six-string guitar and expand after hardware checks.

Pair onset detection with pitch confirmation so repeated picks at the same pitch create separate notes, while a sustained tone or vibrato does not create repeated attacks. Distinguish silence, low-confidence pitch, overlapping ringing notes, clipping and unsupported technique passages. Low-confidence evidence is marked unverified, excluded from clean-tempo advancement, and never silently credited as correct.

Show tablature from authored string/fret targets. Imported MIDI gives pitch but does not uniquely determine string/fret; require review of suggested fingering. Ordinary mixed guitar audio also does not establish which string played an equivalent pitch, so score pitch while displaying the intended fingering. Score actual string only when a validated source provides it.

Keep the detection feed isolated from backing tracks and click output. Prefer hardware direct monitoring initially; adding an amp/effects chain is separate work. Distortion, delay, ringing strings and muted notes enter the validation matrix rather than being assumed equivalent to clean single-note input.

### Full guitar support

Chord recognition and deliberate strum spread, power chords, muted attacks, hammer-ons/pull-offs, slides, vibrato and bends need explicit targets and suitable evidence. Rolled/strummed chords cannot use the same simultaneity rule as tightly aligned piano chords. Bend grading requires a continuous pitch contour; rounding every frame to a new semitone would invent wrong notes.

Investigate polyphonic audio as a separate feasibility track. Spotify's [Basic Pitch repository](https://github.com/spotify/basic-pitch) provides polyphonic transcription, pitch bends and a CoreML model, and says it works best with one instrument at a time. That establishes a candidate for evaluation, not demonstrated low-latency suitability for this app. Compare accuracy, onset delay, CPU use and licensing before choosing any detector. [aubio's pitch documentation](https://aubio.org/manual/latest/cli.html#aubiopitch) also provides algorithms to evaluate for the single-note prototype; no new dependency is selected by this plan.

If live chord detection fails the agreed validation targets, ship the bounded single-note mode with explicit unsupported exercises, then pursue post-session analysis or validated MIDI-guitar hardware for broader scoring. Full guitar parity remains unfinished until those capabilities are verified.

## Matching, results and progression rules

Retain the current drum scoring behavior. For pitched modes, perform deterministic assignment inside bounded temporal/chord groups; allow pitch-aware assignment without imposing arbitrary order on simultaneous notes. Benchmark the current full-session matrix before extending it to dense piano passages, and move to bounded windows/groups where needed.

Results show separate pitch, onset, release/duration, dynamics and chord metrics. Do not collapse all errors into a single timing number. Wrong octave is a pitch error unless octave equivalence is explicitly enabled. Unknown evidence differs from missed notes.

Reuse the concept of a clean run, with instrument-specific thresholds saved in the session. Begin by proposing the drum app's 95% note recall and 25 ms median attack-error targets for MIDI piano, while additionally bounding wrong/extra notes and requiring enabled duration/chord criteria to pass. Confirm these through playing trials. Guitar thresholds follow measured detection uncertainty; do not reuse them uncritically.

Dropped evidence, failed synchronization, or insufficient detection confidence disqualifies automatic advancement and verified ceilings. Compensate known input/output and analysis latency while preserving raw timestamps. Do not continuously fit the reference clock to the player's notes or widen tolerances to conceal detector errors.

## Delivery milestones and completion gates

| Milestone | Deliverable | Completion gate |
| --- | --- | --- |
| 0. Input and scoring feasibility | Confirm connections; collect isolated real piano/guitar fixtures; prototype guitar onset/pitch detection | Record measured pitch accuracy, onset error, duplicate/missed attacks and processing delay across the chosen range; agree supported techniques and budgets before guitar integration |
| 1. Shared foundation | Profiles, selector, note identities, migration, safe switching and extracted session controller | Existing drum tests/recordings/history work; old backups round-trip; mid-run switches and stale callbacks cannot cross instruments |
| 2. MIDI piano core | Notes/releases/pedal capture, pitch and chord grading, piano roll, initial exercises | Repeated notes, chord arrival permutations, pedal changes, disconnects and duration rules pass deterministic fixtures and a real keyboard session |
| 3. Piano workflow parity | Custom measures/sequences, pitched MIDI imports, optional recordings, history, Auto go and progression | A piano exercise can be authored/imported, looped, recorded, graded, saved, reopened, rescored and exported; progress stays separate from drums |
| 4. Guitar single-note core | Interface channel selection, calibration, pitch/onset evidence, tuning and tab | Real clean-input fixtures meet milestone 0 targets, including low notes, fast reattacks and ringing-note rejection; unsupported evidence cannot advance tempo |
| 5. Guitar workflow parity | Guitar editor/library/imports, recording, detailed results and progression | Complete the same end-to-end workflow as piano on the declared single-note scope; verify input isolation during backing playback |
| 6. Advanced guitar and notation | Polyphony/strums/techniques, grand staff, richer notation and optional sound engines | Each technique has targets, evidence, fixtures and hardware validation before enabling grading; release scope is documented |

Milestone 0 can establish guitar feasibility while piano planning proceeds. Build the shared foundation first, then piano as the first complete new instrument, then guitar. Estimate calendar time after the hardware and prototype results are known; guitar recognition is the largest uncertainty.

## Validation during implementation

- Preserve the current hardware-independent drum suite, timing/ordering tests, migration fixtures and native audio transport stress checks.
- Add meaningful MIDI lifecycle fixtures: velocity-zero releases, repeated pitches, pedal-held reattacks, controllers, overlapping channels, disconnects, and missing release events.
- Import fixtures must cover format 0/1, pitched track/channel selection, tempo/meter changes, release pairing, pedal targets, transposition and section-boundary held notes. Repeated loops must reset note state correctly.
- Verify chord matching on reversed arrival order, duplicate pitches, rolled attacks, extra/missing tones and adjacent chords.
- Verify migration from existing supported schemas to the new schema, instrument-scoped IDs/records, and history rescoring. Do not fabricate duration data for legacy imports.
- Evaluate guitar against independently labeled isolated recordings. Measure note precision/recall, octave errors, onset bias/spread, false reattacks, confidence coverage and processing latency at several tempos and gain settings. Set numerical acceptance targets before declaring the prototype successful.
- Exercise count-in, Auto go, cancellation, Reset Practice, sleep/wake, input/output changes, lost devices and repeated instrument switching with physical hardware. Recordings must retain the selected source rather than accidentally recording backing playback.
- Check dense piano/guitar sessions for bounded memory, analysis backlog and scheduling health. Render/inspect notation for chords, long notes, rests, mixed grids, transposition and narrow windows; provide meaningful accessibility labels.

## Decisions to confirm before implementation

1. Exact guitar connection and available interface channel; piano model and whether it supplies MIDI.
2. Whether the first guitar release should focus on single-note lead practice or whether chord/strum grading is required before it is useful.
3. Whether piano-roll practice notation is sufficient initially or grand staff is a first-release requirement.
4. Whether instrument sounds already come from hardware/another app, or built-in electric-piano sound and guitar monitoring are required.

Default proposal: preserve the current app name and drum behavior; add MIDI piano with full workflow support first; add clean-input single-note guitar next; complete chord/technique support after its feasibility gate. The end goal remains three instrument modes in one app.
