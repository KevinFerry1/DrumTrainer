# Future implementation ideas

These are proposed improvements, not a committed implementation schedule. Partial prototypes are noted explicitly below; they do not mean the full idea is complete.

## 1. Multi-measure custom exercises

Expand the custom editor beyond one repeated 4/4 measure. Support longer phrases, copying and pasting bars, and authoring fills and groove transitions. Preserve accents, ghost notes, saving, and grading across the entire phrase.

Implemented September 14, 2026: named sequences built from saved measure snapshots, step reordering/removal, per-step and whole-sequence repeats, mixed note grids, continuous grading, measure labels and per-measure results, plus persistence and history. Direct note editing within an arrangement and custom meters remain possible refinements.

## 2. “Hear the exercise” playback

Play a drum-sound demonstration of the authored pattern before practicing. Make accents and ghost notes audible, support slower demonstrations, and highlight the notes as they play.

## 3. Per-pad dynamics calibration

Collect examples of ghost, normal, and accented strokes separately for each MIDI drum voice. Suggest velocity targets and relative contrasts that fit the player's kit, while retaining manual adjustments and clearly identifying overlapping ranges.

## 4. “Practice my mistakes”

After a session, offer focused practice on troublesome passages. Loop the selected measures at a slower tempo and gradually return to the target speed. Distinguish timing, missed-note, and dynamics problems so the player knows what to work on.

## 5. Per-drum grading controls

Extend the existing kick-grading switch to individual drum voices. Allow focused work on hi-hat dynamics, snare timing, or selected limb combinations while keeping the complete score visible. Clearly distinguish ignored voices from missed notes in results and history.

## 6. Backing-track playback

Load a local audio file and align it with an imported MIDI chart. Support song playback alongside grading, with shared start, pause, section looping, and playback-speed controls. Account for playback latency and arrangements whose timing does not match the MIDI exactly.

### Preferred companion workflow: Songsterr playback with DrumTrainer grading

The user prefers Songsterr's scrolling notation and playback interface. Explore an external-playback grading mode as an alternative to, or companion for, local backing-track playback:

- Import a lawfully obtained MIDI file matching the Songsterr chart and select its drum track.
- Keep Songsterr responsible for audio and notation; capture the player's drum inputs in DrumTrainer while it is in the background.
- Match the chart revision, section, playback speed, tempo changes, and repeats—not just the starting BPM.
- Provide explicit start alignment and offset adjustment, with a clear synchronization-confidence indicator. Do not assume two independent Play buttons start together.
- Require re-alignment after external pauses, seeks, loops, or speed changes unless a supported synchronization mechanism can communicate them.
- Investigate playback-based synchronization separately. Do not continuously align the reference to the player's hits in a way that hides genuine timing errors.
- Treat original-recording timing differences and drift as synchronization problems, not player mistakes; flag unreliable grading.
- Silence DrumTrainer's own click in this mode without stopping its scoring clock.
- Keep microphone bleed from the backing track out of the player's hit evidence where possible; MIDI input is the cleaner path for e-kit grading.
- Do not scrape Songsterr or depend on undocumented private APIs. Automatic shared playback control is not established and needs a supported integration before it can be promised.
- Make clear that DrumTrainer's output meter and limiter do not control audio played by Songsterr.

Current status: MIDI import and grading exist. An experimental browser-audio onset trigger now arms, waits for quiet and sound, applies a manual start offset, and runs a single imported section without DrumTrainer's click. It has timeout/cancel/re-arm controls, keeps early player hits during onset confirmation, and deliberately excludes unverified scores from saved progress. Actual browser/hardware alignment needs validation. Continuous Songsterr playback synchronization, automatic pause/seek following, and drift tracking remain unimplemented. Songsterr currently lists MIDI and Guitar Pro downloads among its Plus features; MIDI is the directly supported format in DrumTrainer. See [Songsterr's feature description](https://www.songsterr.com/terms), checked September 8, 2026.

## 7. Gap-click training

Alternate audible metronome bars with silent bars while the timing reference and grading continue uninterrupted. Let the player configure the audible/silent pattern and review how their timing holds up without the click.

## 8. Exportable freeze diagnostic report

Build on existing recovery protections with a bounded record of exercise starts/stops, count-in progress, output-device changes, timeouts, and recovery attempts. Offer an exportable report when a session becomes stuck, without recording microphone audio or unnecessarily collecting personal data.

## Suggested priorities

The initial recommendation was multi-measure editing, exercise previews, and per-pad dynamics calibration. The user's newer preference makes Songsterr companion grading worth a synchronization feasibility prototype before committing to a full local backing-track player. Reliability diagnostics remain useful alongside either direction.
