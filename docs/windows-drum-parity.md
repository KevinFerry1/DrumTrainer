# Windows drum parity requirement

User requirement, October 13, 2026: the complete drum section must work the same as the Mac app. Guitar and piano are outside the Windows scope. The initial portable browser edition is a preview and does **not** satisfy this requirement.

The Swift drum implementation is the behavior reference. Matching exercise names alone is insufficient: detector decisions, event matching, clean-run rules, progression, authored content, saved evidence, and replay workflows must be carried over and verified.

## Current gaps

| Drum workflow | Current Windows preview | Required before claiming parity |
| --- | --- | --- |
| USB MIDI, mapping, unified live input | Browser MIDI; device-specific map; simpler live log | Preserve MIDI event metadata, timing normalization, ordering, filtering, and device-loss behavior |
| Kick detection and calibration | Native transient threshold, feature fingerprint, 20-kick calibration and crosstalk guard ported; Windows hardware check pending | Port the native spectral/decay fingerprint, guided isolated/mixed-hit calibration, similarity control, MIDI crosstalk grace/veto, and rejection counters |
| Metronome and kick monitoring | Scheduled accented click and volume | Five click sounds, output controls, independent synthesized kick reinforcement, velocity following, source/dedup controls, limiter, peak/RMS meter, and scheduling diagnostics |
| Built-in exercises | All 15 musical patterns | Verify generated nanosecond targets and simultaneous groups against native fixtures at the same tempo/repeats |
| Practice notation | Scrolling voice lanes | Native drum notation, counting guides, beat/measure cues, audible-output compensation, annotated results, and timing timeline |
| Custom measures | New measure editor; fixed dynamics rules | Load/update/copy/delete library, configurable accent/ghost thresholds and local contrast, and native rules for missing baseline/evidence |
| Measure sequences | Full snapshot sequence editor now available | Step authoring, repeats, ordering and save/update/copy/delete implemented; staff-notation verification remains |
| Matching and scoring | Native ordered matcher, metrics, dynamics and stable-bias clean qualification ported; Swift reference checks passing | Port native ordered minimum-cost matching, 35 ms voice clusters, tie/ambiguity decisions, compensation, per-voice metrics, streaks, limb offsets, coaching, and accent/ghost evaluations |
| Auto go / advancement | Configurable native progression and Auto go controls implemented | Configurable persistent settings, native clean qualification, scoped streaks/records, cancellation rules and next-tempo behavior |
| Find My Ceiling | Native decision/state rules and UI implemented; seven progression tests passing | Persistent active search, resume/next round, first-failure stopping, verified ceiling records and history |
| MIDI song practice | MIDI 0/1 parsing, track/mapping editor, section looping and variable tempo/meter click plans implemented | Standard MIDI 0/1 import, track/voice mapping, tempo/meter changes, section looping, tempo scaling, previews, and normal scoring/history/progression |
| Songsterr companion | Absent | Reproduce the Mac companion workflow and its documented start-alignment limitations |
| Session recordings | Original `.m4a` files preserved separately | Independent recording input/channel selection, completed-session capture, interruption policy, attached playback/scrubbing/deletion, and input isolation |
| History and progress | Full Mac session-evidence migration, device snapshots, notes/tags, filters and rescoring implemented | Full native saved evidence migration, details/rescoring, notes/tags, filters, trends, clean-tempo/ceiling records, and associated recordings |
| Backup | Windows wrapper retains original Mac archives | Preserve supported native schemas and IDs, merge behavior, full original evidence, authored dynamics/sequences/songs, device/calibration snapshots and recoverable recordings |

## Verification gates

1. Run identical fixture inputs through Swift and the Windows implementation. Compare targets, classifications, match IDs, offsets, dynamic evaluations, aggregate/per-voice metrics, simultaneous-limb metrics, clean qualification, progression, and backup migrations. Cover dense/adjacent notes, reversed simultaneous arrivals, exact ties, wrong voices, tolerance boundaries, missing velocity/baselines, ignored kicks, and device corrections.
2. Exercise every drum workflow on Windows 10: create a measure and sequence, import a MIDI song, loop sections, calibrate kicks, play/score, record a take, review/replay/rescore history, run Auto go and ceiling search, export/import, and reopen with the saved state intact.
3. Test the actual e-kit, Snowball, and Focusrite on Windows. Check isolated and simultaneous kicks, false positives, rapid retriggers, audio/MIDI timestamps, output latency, routing, recordings, disconnect/reconnect, cancellation, sleep/wake, and scheduling health. A Mac browser simulation does not pass this gate.
4. Verify the Windows launcher or packaged application on a clean Windows 10 machine. Document any browser/driver restrictions that prevent matching native behavior. If browser constraints prevent a workflow, replace the relevant transport or use a desktop package rather than silently dropping the feature.

Different operating systems and drivers require separate timing calibration. Parity means the same drum features and grading rules, verified with real Windows hardware; it does not mean identical raw device latency. Until the gates above pass, label the Windows build **preview**, and do not describe it as equivalent to the Mac drum app.

## Verified implementation progress

October 13: 135 checks pass, including 62 scoring cases generated by the actual Swift algorithms, 45 generated patterns (15 exercises at 40/113/240 BPM), ten reference audio windows and a learned signature. The Windows scorer now matches the native decisions and metrics for those cases. Guided kick calibration, the classifier, and the crosstalk guard are connected to the Windows microphone path. This closes the initial algorithm substitutions; the remaining workflows and physical-device validation above are still required.

The Windows hosted-runner check now passes the portable PowerShell launcher, module content types, HEAD handling and isolation of personal/non-app files, in addition to the algorithm comparisons. Local checks now total 150 with MIDI parsing/timelines, migration, compact evidence backup and progression coverage. A browser inspection confirmed full details for the imported Mac sessions and the imported song’s track/tempo data. Staff notation, timing/coaching displays, recordings/replay, sound reinforcement/limiter/meters, companion playback and Windows 10 physical hardware remain open.
