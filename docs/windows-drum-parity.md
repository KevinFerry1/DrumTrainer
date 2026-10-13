# Windows drum parity requirement

User requirement, October 13, 2026: the complete drum section must work the same as the Mac app. Guitar and piano are outside the Windows scope. The initial portable browser edition is a preview and does **not** satisfy this requirement.

The Swift drum implementation is the behavior reference. Matching exercise names alone is insufficient: detector decisions, event matching, clean-run rules, progression, authored content, saved evidence, and replay workflows must be carried over and verified.

## Current gaps

| Drum workflow | Current Windows preview | Required before claiming parity |
| --- | --- | --- |
| USB MIDI, mapping, unified live input | Browser MIDI; device-specific map; simpler live log | Preserve MIDI event metadata, timing normalization, ordering, filtering, and device-loss behavior |
| Kick detection and calibration | Sample-level transient threshold and noise sampling | Port the native spectral/decay fingerprint, guided isolated/mixed-hit calibration, similarity control, MIDI crosstalk grace/veto, and rejection counters |
| Metronome and kick monitoring | Scheduled accented click and volume | Five click sounds, output controls, independent synthesized kick reinforcement, velocity following, source/dedup controls, limiter, peak/RMS meter, and scheduling diagnostics |
| Built-in exercises | All 15 musical patterns | Verify generated nanosecond targets and simultaneous groups against native fixtures at the same tempo/repeats |
| Practice notation | Scrolling voice lanes | Native drum notation, counting guides, beat/measure cues, audible-output compensation, annotated results, and timing timeline |
| Custom measures | New measure editor; fixed dynamics rules | Load/update/copy/delete library, configurable accent/ghost thresholds and local contrast, and native rules for missing baseline/evidence |
| Measure sequences | Imported snapshots can be practiced | Full step authoring, repeats, ordering, save/update/copy/delete and mixed-grid notation |
| Matching and scoring | A different one-to-one matcher and simplified metrics | Port native ordered minimum-cost matching, 35 ms voice clusters, tie/ambiguity decisions, compensation, per-voice metrics, streaks, limb offsets, coaching, and accent/ghost evaluations |
| Auto go / advancement | Fixed 7-second repeats and +5 BPM / 3-clean-run rule | Configurable persistent settings, native clean qualification, scoped streaks/records, cancellation rules and next-tempo behavior |
| Find My Ceiling | Absent | Persistent active search, resume/next round, first-failure stopping, verified ceiling records and history |
| MIDI song practice | Original imported songs preserved only | Standard MIDI 0/1 import, track/voice mapping, tempo/meter changes, section looping, tempo scaling, previews, and normal scoring/history/progression |
| Songsterr companion | Absent | Reproduce the Mac companion workflow and its documented start-alignment limitations |
| Session recordings | Original `.m4a` files preserved separately | Independent recording input/channel selection, completed-session capture, interruption policy, attached playback/scrubbing/deletion, and input isolation |
| History and progress | Windows session details; Mac summary rows | Full native saved evidence migration, details/rescoring, notes/tags, filters, trends, clean-tempo/ceiling records, and associated recordings |
| Backup | Windows wrapper retains original Mac archives | Preserve supported native schemas and IDs, merge behavior, full original evidence, authored dynamics/sequences/songs, device/calibration snapshots and recoverable recordings |

## Verification gates

1. Run identical fixture inputs through Swift and the Windows implementation. Compare targets, classifications, match IDs, offsets, dynamic evaluations, aggregate/per-voice metrics, simultaneous-limb metrics, clean qualification, progression, and backup migrations. Cover dense/adjacent notes, reversed simultaneous arrivals, exact ties, wrong voices, tolerance boundaries, missing velocity/baselines, ignored kicks, and device corrections.
2. Exercise every drum workflow on Windows 10: create a measure and sequence, import a MIDI song, loop sections, calibrate kicks, play/score, record a take, review/replay/rescore history, run Auto go and ceiling search, export/import, and reopen with the saved state intact.
3. Test the actual e-kit, Snowball, and Focusrite on Windows. Check isolated and simultaneous kicks, false positives, rapid retriggers, audio/MIDI timestamps, output latency, routing, recordings, disconnect/reconnect, cancellation, sleep/wake, and scheduling health. A Mac browser simulation does not pass this gate.
4. Verify the Windows launcher or packaged application on a clean Windows 10 machine. Document any browser/driver restrictions that prevent matching native behavior. If browser constraints prevent a workflow, replace the relevant transport or use a desktop package rather than silently dropping the feature.

Different operating systems and drivers require separate timing calibration. Parity means the same drum features and grading rules, verified with real Windows hardware; it does not mean identical raw device latency. Until the gates above pass, label the Windows build **preview**, and do not describe it as equivalent to the Mac drum app.
