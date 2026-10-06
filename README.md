# Drum Performance Trainer

Native macOS timing trainer for a hybrid e-kit and acoustic double-kick practice setup. Milestone 1 now includes the common timing model, bounded unified event stream, simulation, real CoreMIDI input, real Core Audio microphone capture, persistent per-device MIDI mapping, kick-onset detection from PCM buffers, and an ahead-scheduled metronome with explicit output routing, five click voices, gain control, optional low-latency kick reinforcement, a configurable dynamics limiter, and an app-output dBFS meter.

Milestone 2 now includes a fifteen-exercise library spanning double-bass technique, full-kit grooves, and blast beats; scrolling drum notation with an output-latency-compensated playhead; a scheduled eight-beat/two-bar count-in; bounded practice-session recording; deterministic one-to-one event matching; wrong/missed/extra/ambiguous classification; annotated performance notation and timing results; and guided, per-microphone input calibration. Milestone 3 now adds per-voice precision, recall, timing bias/error/consistency, simultaneous-limb spread with each voice measured against the group center, a filterable voice-lane timeline with a detailed expected-versus-played event ledger, and a manual custom-measure editor whose authored notes use the same scoring pipeline as built-in exercises. Milestone 4 now adds a schema-versioned local repository, a persistent named custom-exercise library, complete rescorable session evidence, calibration/device snapshots, editable notes and tags, historical drill-down with optional local microphone-audio playback, progress trends, clean-tempo records, automatic tempo advancement, a persistent Find My Ceiling mode, and validated JSON export/import. The first Milestone 5 wave adds persistent Standard MIDI format 0/1 song imports, tempo/meter parsing, automatic drum-track selection, editable General MIDI drum mapping, section looping, tempo scaling, notation preview, and the complete scoring/history/progression pipeline. Custom exercises also support authored `>` accents, local same-voice MIDI-velocity contrast grading, an optional absolute velocity floor, accent-aware results/notation, and clean-run qualification.

## Requirements

- macOS 15 or newer (the initial deployment target; revise after hardware validation)
- Xcode 26.3 or a compatible newer Xcode
- An e-drum module connected over USB MIDI for hardware testing
- A Blue Snowball or another USB microphone for kick detection testing
- Optionally, a Focusrite Solo as the selected monitoring output

The development Mac used for the initial scaffold has Xcode installed at `/Applications/Xcode.app`, while `xcode-select` points to Command Line Tools. Commands below therefore set `DEVELOPER_DIR` for that invocation only.

Before the first Xcode build on a new machine, open Xcode once or review the license from Terminal with `sudo xcodebuild -license`, then complete any requested first-launch setup. The development machine used for this scaffold has completed that setup successfully.

## Build and test

Open `DrumTrainer.xcodeproj` in Xcode, select the **DrumTrainer** scheme and **My Mac**, then Run. Or use:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project DrumTrainer.xcodeproj \
  -scheme DrumTrainer \
  -destination 'platform=macOS' \
  build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project DrumTrainer.xcodeproj \
  -scheme DrumTrainer \
  -destination 'platform=macOS' \
  test
```

Select **Start Test Simulation** to feed test events through the bounded, time-ordered stream. Simulation is optional, does not listen to hardware, and stops automatically when a real MIDI or microphone input is selected.

The automated suite does not require connected drum or audio hardware. It includes a synthetic 60-second run of 960 high-tempo 16th-note hits, along with dense timing, triplet-grid, tolerance-boundary, wrong-voice, ambiguity, and scoring fixtures.

## Test real inputs

1. Connect the drum module to the Mac over USB MIDI and connect the Snowball directly by USB.
2. Run the app, leave simulation stopped, and choose the drum module in the **MIDI** menu. If the menu only shows **None**, click **Rescan** after reconnecting or powering on the module; class-compliant endpoints without a reported CoreMIDI unique ID are still listed.
3. Strike each e-kit pad. Each note-on appears in the unified log with raw note, mapped voice, velocity, channel, endpoint, and normalized session time. Switch **Timestamp** to **Raw host ticks** to inspect the untouched CoreMIDI source timestamp.
4. If a voice is wrong, strike that pad, choose the right voice in **Pad map**, and click **Save for This Device**. The override remains after relaunch and does not affect other MIDI devices.
5. Choose the Snowball in the **Microphone** menu and allow microphone access when macOS asks. If access was denied previously, use **Open Settings** in the app. The capture path first requests the microphone's native output format and retries its input-scope format when Core Audio reports format error -10868; if neither is usable, set the Snowball to 44.1 or 48 kHz in Audio MIDI Setup and select it again.
6. Open **Calibration** and keep the room quiet for the three-second noise sample. Play the first 10 kick strikes by themselves; for the final 10, keep kicking while adding simultaneous snare, tom, and cymbal hits as prompted.
7. Review the suggested threshold, lockout, signal quality, and **Sound filter: Learned** result, then click **Save Calibration**. The profile stores a compact frequency/decay fingerprint for that microphone and pad; it never stores audio.
8. Return to **Live Monitor** and leave both **Kick sound filter** and **E-kit crosstalk guard** enabled. Speech, stick clicks, and non-kick pad/cymbal hits should not create kick rows; the two filtered counters show why a candidate was rejected.
9. Test isolated kicks and kick-plus-pad strikes. A quieter transient matching the calibrated kick fingerprint bypasses the MIDI crosstalk veto. If legitimate kicks are rejected, lower **Match** in small steps; if unrelated sounds pass, raise it. Use lockout only to tune duplicate versus rapid hits.

Calibration stores only detector settings and signal statistics. It never records or saves microphone audio.

## Test the metronome

1. Connect headphones or speakers to the desired output. If using the Focusrite Solo, connect it by USB and choose it in **Metronome > Output**. The interface's Direct Monitor switch affects its hardware input monitoring, not the app's generated click.
2. Choose a BPM, one of the five click sounds, and a gain from −36 to +12 dB, then click **Start Metronome** (or press Return). Cutting Electronic and Rimshot are the easiest starting points when acoustic drums mask the click.
3. Confirm that each audible click creates a metronome row in the unified log. Those rows carry the precomputed playback host time rather than the time a UI timer happened to run.
4. Leave **Limiter** enabled and choose a digital ceiling between −12 and −0.5 dBFS. The **App output** row shows post-limiter peak/RMS level and active gain reduction. This measures DrumTrainer's generated audio, not acoustic headphone loudness.
5. Try 40, 120, and 240 BPM. You can change output, tempo, sound, gain, and limiter settings without relaunching the app; those choices persist.
6. Watch **Metronome** in the diagnostics footer. It reports the minimum scheduling lead and counts ticks that reached the audio scheduler with less than 20 ms of lead time.

## Monitor registered kicks through headphones

1. In **Live Monitor > Metronome** or the Practice audio controls, enable **Reinforce registered kicks**. Choose **E-kit MIDI**, **Kick microphone**, or both. MIDI is the lowest-latency option; microphone reinforcement must wait for onset detection.
2. Choose Studio Punch, Deep Acoustic, Tight Trigger, or Electronic Sub and click **Test Kick**. Set the independent kick level conservatively before playing through headphones.
3. Leave **Follow hit velocity** enabled to use MIDI velocity or normalized microphone transient level. Disable it for a fixed reinforcement level.
4. Use the monitor lockout to prevent a MIDI and microphone event for the same physical strike from sounding twice. Six overlapping player voices preserve fast double-kick passages; when the pool wraps, the oldest voice is interrupted rather than delaying the new hit.
5. Kick reinforcement and click audio share the selected output, limiter, and app-output meter. Generated kick audio never becomes a performance event and is excluded from calibration, alignment, and scoring evidence.

The four kick voices are synthesized and preloaded at the selected output sample rate; no sample is read from disk while playing. The controls persist across relaunches. Headphones are strongly preferred when using microphone detection so output bleed cannot create another acoustic transient.

## Run a drum-set exercise

1. Open the **Practice** tab and choose **Built-in** for a foot exercise, full-kit groove, or blast beat. The library includes straight and displaced double-bass patterns, rock and open-hat grooves, a double-bass backbeat, and alternating, unison, and triplet blast beats.
2. To author your own part, choose **Custom measure**, name it, and select an 8th-note, 16th-note, or triplet grid. Click cells in the drum-voice lanes to add or remove notes; enable multiple voices in one column for a simultaneous hit. Turn on **Accents >** and click any note to add or remove its `>` accent. Set the required contrast (18 MIDI velocity points by default, or 20% above the local baseline when greater) and optionally keep the absolute minimum-velocity floor enabled. **Load Rock Example** provides an editable starting point. Use **Save Exercise**, **Update Saved**, or **Save Copy** to maintain a named local library that survives relaunches.
3. Read the live one-measure notation preview and counting guide, then set BPM, repeat count, output, click sound, gain, and limiter ceiling. If acoustic kick detection is temporarily unreliable, turn off **Grade kicks**: kick notes remain visible, while expected and detected kicks are excluded from captured-hit counts and every scoring, timing, progression, and ceiling metric. The setting persists across relaunches and is saved with each completed session so later rescoring uses the same rules. To keep an audible take with each new History entry, enable **Save played audio with completed sessions** and choose a recording input. The recording input is independent of the kick-detection microphone, so the Snowball can continue detecting kicks while Scarlett Input 1 or 2 records the module's analog output. On a Scarlett Solo 4th Gen, selecting **Loopback 3–4** can instead record the computer playback mix; enabling **Send Direct Monitor Mix to Loopback** in Focusrite Control 2 adds the analog module input so the take includes the drum sound and DrumTrainer click together.
4. Click **Start Exercise**. The app gives eight scheduled count-in clicks (two 4/4 bars); begin when the blue playhead starts moving after the final click. **Reset Practice** is always available if a countdown, run, or audio refresh becomes stuck; audio refreshes also unlock automatically after a six-second timeout and show why Start is unavailable.
   Enable **Auto go** in Exercise setup for hands-free repeats. Its slider chooses how long results stay visible (1–30 seconds, default 8), then the app follows Play Again into the next count-in. Results show a countdown and **Stop Auto go** button. New Exercise, Cancel, Reset Practice, manual replay, or leaving the Practice tab cancels the pending restart. Auto go follows automatic tempo advancement and Next Round in Find My Ceiling, stopping when the ceiling search is complete. In Songsterr companion mode it re-arms the listener; browser playback still needs to be started separately.
5. The score scrolls with the audible metronome timeline, compensates for the selected output device's presentation latency, and crosses each note at its scheduled time. Alternating beat lanes plus a live measure/beat/next-note cue make the current position easier to follow. Microphone kick events are captured only inside the exercise window; reference clicks are excluded from scoring.
6. The run ends automatically. Custom notes are graded by their exact authored voice through the same matcher and results used by built-in exercises, including wrong/missed/extra classifications, per-voice metrics, grouped-limb spread, and the detailed timing timeline. Each accented note is compared with the median of up to four nearby, correctly played non-accented notes of the same voice. It must clear the configured point contrast or 20%, whichever is greater, plus the optional absolute floor. Results show the baseline, target, played velocity, and whether contrast was sufficient; at least 90% must pass for the run to count as clean.
7. Optionally enable **Auto-advance tempo** and choose the number of clean runs and BPM step. The streak, suggested tempo, and best clean tempo persist across relaunches.
8. For a faster limit test, enable **Find My Ceiling** on any built-in or custom exercise. Set the starting tempo and per-round BPM increase. A clean round (at least 95% recall, no more than 25 ms median error, and no dropped events) unlocks the next faster round. The first non-clean round ends the search at the previous verified tempo. An interrupted search can resume after relaunch.
9. Each completed run automatically saves the pattern, normalized performed events and raw metadata, match decisions, metrics, selected devices, microphone calibration, and the MIDI/microphone timing corrections used. When practice-audio recording is enabled, it also saves a compressed local `.m4a` file keyed to that session. Open **History** to compare trends, ordinary highest-clean tempos, and verified ceilings, then open **Details** to play/scrub/delete the take, edit notes/tags, inspect the event ledger, or rescore the archived events. Deleting a session or clearing History also removes its recording.
10. Use **Export JSON** for a portable local backup. **Import JSON** validates and migrates the schema, then merges exercises and sessions by stable ID. Individual sessions or all history can be deleted from the same screen.
11. For trustworthy personal timing, open **Calibration > Hit timing alignment**. Choose e-kit MIDI or the kick microphone, keep the normal headphone output selected, then play once on each of 12 clicks. Save the measured median correction for that exact input/output pairing. The event log and saved evidence remain raw; the correction is applied only by scoring.

## Stitch saved measures into a sequence

In **Practice → Custom measure**, save the individual measures you want to learn, then switch to **Measure sequence**. Choose a saved measure and **Add to sequence** for each step. Set each step's repeat count and use the up/down buttons to change its position—for example, **Verse ×4 → Fill ×1 → Chorus ×4**. You can also repeat the whole arrangement. Name it and choose **Save Sequence**; it appears in the same saved library with a Sequence label and supports Update Saved, Save Copy, and Delete.

Each step keeps a copy of the source measure, including its grid, accents, and ghost notes. Changing or deleting the original saved measure leaves the sequence intact; remove and re-add a step to incorporate edits. Eighth-note, sixteenth-note, and triplet measures can be mixed, all in 4/4 at the selected tempo. Arrangements support up to 32 steps, 16 repeats per step or whole sequence, 128 total measures, and 10,000 notes per run.

There is one eight-beat count-in before the complete arrangement, with no extra delay between measures or whole-sequence repeats. The scrolling score labels each measure and uses its own grid. Results include a **Sequence review** showing correct/expected notes for each measure and highlighting changes between named measures, alongside the existing timing and dynamics results. History, auto-advance, Find My Ceiling, and JSON backups also work with named sequences. Repeat counts are fixed for the run; they do not wait for a specified number of successful measures before advancing.

## Practice ghost notes

In **Custom measure**, select **Ghost notes ( )** in the editor toolbar and click a cell. A normal or accented note becomes a ghost note; clicking an existing ghost removes the marking, while clicking an empty cell adds a ghost note. Ghost notes appear in parentheses in preview, playback, and results. Save the exercise as usual to preserve them.

**Ghost softness** defaults to 18 MIDI velocity points or 20% below the median of the nearest four correctly played normal MIDI notes of the same drum voice, whichever requires more contrast. Accents and other ghosts are excluded from both dynamics baselines. The optional **maximum velocity** defaults to 50. When enabled, both contrast and the maximum must pass. These settings persist and are captured in each session's expected notes for reproducible rescoring.

Without a normal-note baseline, the enabled maximum is used and labeled “ceiling only”; with no maximum enabled, the ghost is marked unavailable. Missed/wrong notes and missing velocity cannot earn ghost credit. A target below MIDI velocity 1 cannot pass—raise the ordinary-note baseline or reduce the contrast setting. Results show baseline, maximum target, played velocity, and the reason for failure. A clean run requires at least 90% ghost accuracy as well as the existing note/timing and accent criteria. Grade kicks off excludes kick ghosts too. Historical sessions without ghost markings keep their original behavior.

## Import and practice a MIDI song

1. Obtain a `.mid` or `.midi` file you are allowed to use. In **Practice**, choose **Imported song** and click **Import MIDI…**. Standard MIDI format 0 and 1 files using ticks-per-quarter-note timing are supported.
2. The app selects the first track using MIDI percussion channel 10 when possible. Otherwise, it selects the note-bearing track with the most events. Choose another track from **Track** when necessary.
3. Review **Drum mapping preview**. General MIDI percussion pitches are filled automatically. Change any nonstandard export pitch to its real drum voice, or choose **Ignore** to exclude it from notation and grading. Mappings save immediately; there is no confirmation button. The occurrence totals cover the complete track.
4. Choose the first and last measure plus a repeat count. The section-status row reports exactly how many notes in that range are eligible under the current grading settings. A newly loaded song starts at the first measure containing a gradable drum note rather than at a potentially silent measure 1; **Jump to first playable section** repairs an empty range. Set **Tempo** to scale the complete imported tempo map relative to the section's original starting tempo.
5. Start the exercise normally. It receives the same eight-click/two-bar count-in, moving notation, input capture, exact-voice grading, History record, auto-advance, and Find My Ceiling support as built-in and custom exercises. After count-in, the audible click follows every scaled MIDI tempo and meter change and accents the beginning of each imported measure.
6. The notation preview keeps readable 16th-note count markers but places each note at its exact tempo-map-derived position, so the drawing, moving playhead, click, and grader all use the same imported timing.

Song data, saved custom sequences, and authored dynamics are stored inside the schema-v9 local practice archive and are included in JSON backup/export. Existing archives migrate automatically. Importing a practice-data backup merges songs and custom exercises by stable ID. Deleting an imported song does not delete its completed historical sessions.

Do not run simulation while evaluating physical inputs, because simulated rows intentionally mix into the same diagnostic log.

### Experimental Songsterr audio-start mode

This prototype lets Songsterr provide audio and scrolling notation while DrumTrainer grades a matching imported MIDI chart. It detects the beginning of browser sound; it does **not** identify songs or continuously synchronize to Songsterr.

1. Import the matching MIDI and select its drum track, start/end measures, and tempo. Use **one repeat**. The chart revision, arrangement, tempo changes and playback speed must match Songsterr.
2. Under **Songsterr companion — experimental**, enable **Wait for browser audio instead of counting in**. Click **Load audio sources** and select your browser. Approve macOS **Screen & System Audio Recording** access if requested; the permission button opens its settings. A relaunch may be needed after changing permission.
3. Pause Songsterr at the selected starting measure. Turn off its count-in and looping, and silence other tabs in that browser. The listener is app-wide, not tab-specific. Your e-kit MIDI/microphone grading inputs remain separate.
4. Click **Arm for Songsterr**, wait for **Ready**, then press Play in Songsterr. There is no DrumTrainer count-in or metronome click in this mode. Capture waits for quiet (or an idle capture interval), then confirms 20 ms of sound and uses the beginning of that sound as its timestamp. A short, bounded player-event pre-roll preserves hits arriving during confirmation.
5. Use **Start offset** to place the score earlier (negative) or later (positive) than that sound, within ±5000 ms. First audible sound may not be measure beat one. Existing hit-timing calibration still applies; the offset is a residual correction, not an automatic measurement of Focusrite/headphone latency. Lower the detection threshold if quiet playback is missed.
6. If Songsterr pauses, seeks, loops, changes speed, or the timelines diverge, click **Sync lost / cancel**, return Songsterr to the selected measure, and re-arm. A 45-second wait timeout, capture errors, and Reset Practice all leave the controls retryable. Changing output through DrumTrainer invalidates an active external attempt.

Scores are explicitly **sync unverified** and are shown for review only: experimental attempts are not saved to History or used for progress, auto-advance, or Find My Ceiling. No browser audio or screen frames are stored; only transient audio levels/timestamps are analyzed, and capture stops after onset or cancellation. Songsterr playback is outside DrumTrainer's output meter and limiter. Start alignment and actual capture behavior still need hands-on validation with your browser and audio hardware. Automatic playback-position following remains future work.

## Hardware wiring and roles

```text
E-kit -> drum module -> USB MIDI -> Mac
Double pedal -> acoustic pad -> Blue Snowball USB -> Mac
Mac metronome -> selected audio output -> Focusrite Solo -> headphones/speakers
```

The Snowball is input only; the Focusrite is output only. Do not assume they are the same audio device. If separate input/output routing proves unreliable with the selected Core Audio approach, create a macOS Aggregate Device temporarily and document its clock source and drift correction.

## Microphone permission

The generated app Info.plist includes a microphone usage description. On first audio capture, allow access. If access was denied, enable **DrumTrainer** under **System Settings > Privacy & Security > Microphone**. MIDI, metronome, and simulation remain usable when microphone access is denied.

## Timing diagnostics

Repeated practice attempts reuse the configured output graph. The app pauses rendering before clearing queued clicks, then resumes the graph for the next run; a route change or explicit audio refresh rebuilds its connections. Reset Practice replaces the audio engine even after a failed or completed attempt. Selecting System Default explicitly rebinds the output to macOS's current default device.

Audio-refresh requests have their own identities and six-second watchdogs: cancelling practice cannot disable the watchdog or leave the refresh flag latched, and a late completion cannot restart a cancelled run or unlock a newer refresh. Old ticks are rejected when they predate the current start or cross a cancelled flow while being delivered. Regression tests exercise 60 consecutive simulated start/count-in/finish cycles, stale completions, cancelled refreshes, timeouts, and the one-retry stall limit. These tests exercise app state, not the physical USB audio driver. If Core Audio itself fails to return, the timeout restores the controls but cannot force its driver call to complete.

- `hostTime` is the canonical monotonic Core Audio host-time value.
- `sessionTimeNanoseconds` is relative to a captured session origin.
- The live log can switch between normalized session time and the original source `hostTime`; no calibration correction is silently applied.
- Audio detector events use buffer host time plus the detected frame offset; callback completion time is never used as the hit time.
- The unified stream is capped at 500 events and reports dropped/evicted events.
- Metronome scheduling health reports minimum lead time and at-risk scheduling counts; this is a scheduling diagnostic, not proof of acoustic output latency.
- MIDI note mapping begins with General MIDI percussion values; real module mappings remain configurable work.

## Known limitations at this stage

- MIDI voice names begin with a General MIDI percussion map and can be overridden and saved per selected device. The current editor maps the most recently struck note; bulk profile import/export is not implemented yet.
- CoreMIDI and microphone device paths are implemented but still need validation with the exact e-kit module and Snowball model.
- The output meter is digital dBFS for audio generated inside DrumTrainer. It cannot measure headphone dB SPL or see audio from other apps without a calibrated headphone/interface profile and a system-wide virtual audio route. The limiter therefore does not replace conservative physical interface/headphone volume settings.
- Imported-song clicks, grading, and the playhead share the same scaled tempo-map schedule. Saved hit-timing alignment is applied to grading for the current input/output pairing.
- Summaries created by older schema-v1 builds remain visible after migration but cannot gain event-level drill-down or rescoring retroactively because those builds did not retain the evidence. Newly completed sessions and imported song libraries use schema v5.
- Custom practice supports single 4/4 measures and ordered arrangements of saved measures with independent repeats. Different meters and direct editing of notes inside sequence steps are not yet supported; MusicXML and Guitar Pro import remain future waves.
- MIDI import supports PPQ-based Standard MIDI format 0/1. SMPTE time division, embedded audio, lyric/chord display, backing-audio synchronization, and automatic audio transcription are not supported yet.
- Automatic tempo progression supports both repeated-clean-run advancement and a dedicated Find My Ceiling sequence. Duration-specific ceiling records and adaptive step sizes remain future refinements.
- Microphone amplitude/sound calibration remains device-specific, while hit-timing profiles are stored separately for each MIDI-or-microphone input plus audio-output pairing.
- Guided hit timing alignment includes the drummer's normal response to the click; it is a practical personal correction, not a laboratory separation of hardware latency from human response. A physical loopback test would still be needed for hardware-only absolute latency.
- One microphone can identify kick impacts, not left versus right foot.
- Practice audio is never stored by default. If the user explicitly enables it, the independently selected recording input is saved locally as compressed AAC at roughly 0.7 MB/minute for mono or 1 MB/minute for stereo. MIDI contains no audio; recording the module's real sounds requires its analog output to reach an audio input such as the Scarlett. Audio files are not included in JSON export/import.

## Manual Milestone 1 checklist (as hardware lands)

- Confirm device lists update when MIDI and audio devices connect/disconnect.
- Deny microphone permission and confirm MIDI remains usable with recovery guidance.
- Verify one row per MIDI note-on, with note, canonical voice, velocity, and source/session timestamps.
- With MIDI and the microphone selected, strike non-kick pads and confirm the crosstalk-filter count increases without creating kick rows; then confirm simultaneous real kick-plus-pad strikes still register the kick.
- Adjust threshold until about 20 isolated pad strikes each create one kick row; test ringing and rapid doubles against lockout.
- Confirm live level graph stays responsive and no raw audio is retained.
- Run metronome at 40, 120, and 240 BPM for 60 seconds and inspect scheduling health.
- Disconnect each selected device while monitoring; confirm a recoverable state and no crash.
- Run dense mixed input for at least 60 seconds and inspect dropped-event diagnostics.
