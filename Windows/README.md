# DrumTrainer for Windows 10 — portable practice edition

1. Copy **DrumTrainer-Windows.zip** onto the Windows computer and **Extract All**. Do not run the launcher from inside the ZIP.
2. Open the extracted folder and double-click **Start DrumTrainer.cmd**. It opens an app window in Microsoft Edge or Chrome. Keep the small launcher window open while practicing.
3. Open **Live Monitor**. Connect the drum module, Blue Snowball, and your headphone output. Click **Connect MIDI**, select your kit, and grant MIDI permission. Strike each pad; use **Pad mapping** to correct its voice.
4. Click **Enable microphone**, grant microphone permission, select the Snowball, and click **Sample noise** while the room is quiet. Test kicks in the live log. Adjust the threshold and lockout if necessary. In **Calibration**, choose **Start Calibration**: after the quiet-room sample, play 10 isolated kicks and 10 kicks while adding other pads, then **Save Calibration**. The learned spectral/decay filter and MIDI crosstalk guard now use the native algorithms; test them with your hardware before relying on scores.
5. Select the Focusrite/headphones under **Output**. If output selection is unavailable, choose it in Windows sound settings. Use headphones to keep the click out of the kick microphone.
6. Open **Calibration** and run **Align E-kit MIDI** and **Align Kick Microphone** for each input/output setup. At the fixed 60 BPM, listen to eight count-in clicks, then play one hit per click for 12 clicks. Review the compensation and spread, then choose **Save & Apply**. Alignment includes personal playing bias; it is not a laboratory latency measurement.
7. Open **Practice**. Choose an exercise, tempo, and repeat count, then **Start exercise**. Begin after the eight count-in clicks. Keep the app visible; hiding it cancels the attempt to prevent unreliable timing. Space starts/pauses practice when you are not editing a control.

No Xcode, Python, Node.js, paid account, installation, or administrator access is required. Windows PowerShell 5.1 and a current Chromium-based Microsoft Edge or Google Chrome are required. This uses browser MIDI and audio APIs on a server bound only to this computer at `http://127.0.0.1:8765`. It has no external libraries, network assets, analytics, or uploads. The included server serves only allowlisted app files; personal backup files are imported directly from your computer.

The dark interface follows the native Mac drum app: **Live Monitor**, **Calibration**, **Practice**, **History**, and **Settings**. Practice has the same exercise setup rows, custom-measure/sequence modes, score, and result review. Shared sound/device controls stay synchronized between tabs. Auto go is under Settings.

## Launch the latest code after updates

Double-click **Run latest DrumTrainer.cmd** in this project or the portable app folder. It opens the current code directly and reuses the local server when it belongs to this folder. No rebuild or ZIP extraction is needed after edits here. An older copy serving from another folder must be closed first so it cannot silently show an outdated version.

Run **Create DrumTrainer Shortcut.cmd** once to put **DrumTrainer** on the desktop with **Ctrl+Alt+R** as its launch shortcut. Once the app is open, **Ctrl+R** reloads code changes. Finish or cancel the current attempt before reloading. Always use the same browser to keep your saved practice database. Updating the local source does not automatically download GitHub changes; changes made here are available immediately.

The one-click launcher keeps its small local server in the background. The original **Start DrumTrainer.cmd** remains available if you prefer a visible server window or need to diagnose a startup error.

## Move your Mac data

The transfer ZIP may include **Mac-practice-backup.json**, copied from the Mac app’s saved practice archive. In the Windows app choose **History → Import JSON** and select that file. Alternatively, use **History → Export JSON** in the Mac app before returning it, then import the exported file on Windows.

The private transfer also includes **Mac-setup-backup.json**. In **Calibration**, open **Transferred Mac setup** and import it to restore sound/gain and dynamics choices. After enabling the correct Windows microphone, select the transferred kick profile and apply it. Test kicks in the new room and run fresh timing alignment. Mac device IDs and latency corrections are preserved for reference; they are not assigned to Windows devices.

This transfer also includes **Mac-source-backup.zip**, a snapshot of the native Mac source and project documents, including the current uncommitted edits. Keep it alongside your practice backup if you may continue development on another computer. It is a source snapshot, not an installed Mac application.

- Saved drum measures and sequences become playable exercises, including authored accents and ghosts. Dynamics need MIDI velocity evidence; microphone hits do not supply velocity.
- Mac drum sessions with archived evidence have complete results, raw evidence, saved device/correction context, editable notes/tags, and rescoring. Summary-only legacy entries remain available when no evidence record exists. Original songs, scores, raw event evidence, profiles, and other native archive fields are preserved unchanged inside the imported archive. **Download original Mac backups** retrieves them. Imported drum songs can be practiced through track mapping, section loops, tempo scaling and their saved tempo/meter maps.
- Mac recorded audio is stored separately from the JSON backup. This transfer package includes the available takes in **Mac-recordings**. Keep that folder. If making a new transfer yourself, copy `~/Library/Application Support/DrumTrainer/Practice Audio` as well. In **History → Recordings and complete backups**, choose **Import Recordings Folder** and select **Mac-recordings**. Takes attach by session ID and can be replayed, scrubbed, downloaded or deleted from session details. Original files remain in your transferred folder.
- This edition's **Export JSON** includes Windows exercises and sessions plus original imported Mac archives. Its format is different from the native Mac app's format. Do not import the Windows wrapper into the Mac app; download the original Mac backup instead.

Practice data is stored in this browser's local database. Always use the same browser and address. Export after important sessions, before changing computers, or before clearing browser data. Moving the extracted folder does not move browser history. MIDI mappings and device timing corrections are kept in that browser's settings and should be configured again on a new computer. Each source's correction belongs to the selected input/output pairing; when changing the Windows default device, run alignment again.

## Included

All 15 built-in drum exercises; a custom-measure editor; saved-measure/sequence imports; device-specific MIDI pad mapping; sample-level microphone transient detection in an audio worklet; guided noise/20-kick calibration; the native spectral/decay kick fingerprint and MIDI crosstalk guard; ahead-scheduled accented metronome; eight-beat count-in; five native click sounds; four native kick sounds with velocity following and six overlapping voices; limiter and peak/RMS meter; independent session recording input/channel selection; attached Mac/Windows take replay; native drum staff notation with beams, triplet counts, accents/ghosts and annotated results; scrolling voice lanes; detailed timing charts, problems/voice filters and paginated complete ledger; native coaching advice; native ordered minimum-cost correct/wrong/missed/extra/ambiguous matching; local accent/ghost velocity contrast; per-voice results; early/late bias and consistency; simultaneous-limb spread; raw Windows session evidence; persistent history; portable JSON backup; configurable Auto go and clean-run tempo advancement; persistent Find My Ceiling search and records; simulation without hardware.

The matching, metrics, accent/ghost rules, stable timing-bias adjustment, and clean-run qualification now use ports of the native Swift algorithms (scoring version 5), checked against generated Swift reference cases. Clean runs follow the Mac rule: at least 95% recall, timing error ≤25 ms (centered for an eligible stable common bias), sufficient authored dynamics, and no dropped evidence. Output scheduling interruptions also disqualify Windows runs. MIDI/input/output latency still requires hardware alignment and validation on Windows.

## Recording and output

Enable **Record completed practice sessions**, select a recording input independently of the kick microphone, and select Input 1, Input 2 or Loopback 3–4. Count-in is excluded. Completed audio windows are saved as PCM WAV; interrupted captures are discarded. Mac takes retain their original `.m4a` format. The browser must expose the requested input channels; a two-channel device cannot provide channels 3–4 through this path. Separate loopback devices can be selected as Input 1. Hardware channel routing still needs verification on Windows.

**Export JSON** contains evidence and settings. **Backup with recordings** creates a complete portable ZIP with the JSON, attached takes and restore instructions. Extract All, import `Practice-backup.json`, then import its `Recordings` folder. Keep the ZIP outside the browser before clearing browser data. The bundle has a 2 GB limit; larger libraries can download takes separately. The synthesized click/kick sample formulas match the native generator in 72 Swift reference cases. The Windows limiter is a separate peak limiter with a 50 ms release; it enforces the selected ceiling but is not Apple’s Audio Unit DSP.

## Songsterr companion

For an imported MIDI song, expand **Songsterr companion — experimental**, enable the browser-audio start option, and set one repeat. Match the selected section and tempo in Songsterr and turn its looping/count-in off. **Arm Songsterr companion** opens the browser sharing picker. Select the Songsterr tab and enable **Share tab audio**. Wait for Ready, then press Play there. Detection follows the Mac rule: 300 ms quiet followed by 20 ms sustained sound, anchored to the first loud window. Use the start offset for residual capture delay or intro offsets; hit timing corrections still apply independently.

This is start detection only. It does not follow pause/seek/loop/drift or recognize a particular song. Experimental runs are not saved to history, progression or audio. No shared audio/video is saved or uploaded. Songsterr audio remains outside the app limiter. Tab capture and physical alignment still need Windows verification.

## Remaining scope

Electric piano/guitar workflows are outside this Windows drum port. Custom measures and sequences now support authoring, update/copy/delete. Imported MIDI songs and native session evidence are migrated and usable. The implemented drum workflows are still labeled preview until Windows 10 physical-device validation passes. Remaining differences include browser audio/channel access and the custom limiter implementation.

## Troubleshooting

- **No MIDI input:** use current Edge or Chrome, install the module manufacturer's Windows MIDI driver if required, reconnect the kit, close DAWs that may hold its MIDI input, and click Connect MIDI again.
- **No microphone:** allow browser microphone permission and Windows Settings → Privacy → Microphone → desktop app access. Re-enable the microphone after changing devices.
- **Wrong output:** select the Focusrite in Windows sound settings if the browser cannot select an output. Repeat timing alignment when changing outputs.
- **False kicks:** use headphones, move the Snowball closer to the kick pad, sample room noise, and raise the threshold. To practice hands without acoustic-kick grading, clear Grade kicks and select a full-kit exercise.
- **Launcher does not start:** extract the entire ZIP first. If another copy is running, close its launcher window. A company-managed computer may block PowerShell scripts; the error will appear in the launcher window. The app does not change the computer's permanent execution policy.

## Development / verification

From the repository root, run `node --test Windows/*.test.mjs`. To preview on Mac, serve `Windows` on localhost using any static server (for example `python3 -m http.server 8765 --bind 127.0.0.1 --directory Windows`) and open it in Chrome. This does not modify the Swift app. The Windows launcher and physical Windows devices must still be validated on Windows; a Mac browser preview cannot prove hardware compatibility or latency there.

The CI desktop integration check uses `jsdom@26` installed in a temporary directory, with `DRUMTRAINER_TEST_MODULES` pointing to its `node_modules`. Run `node Windows/validation/check-desktop-dom.mjs` with `builtIn`, `custom`, and `sequence`. It exercises the actual app startup, restored editors, tab navigation, shared controls, history details, and practice-type switching. This is a DOM check; it does not replace visual or physical-device validation. The packaged app has no npm dependencies.

Reference cases are generated by compiling the repository’s actual Swift drum algorithms with `sh Windows/validation/generate-fixtures.sh`. `native-parity.test.mjs` compares classifications, matched event IDs, timings, dynamics, complete metrics, stable bias, clean qualification, exercise targets, click references, and audio features. GitHub Actions runs the JS comparison tests and the included PowerShell launcher on a Windows runner. These checks do not replace Windows 10 physical-device validation.

Audio verification additionally compares 72 generated native click/kick waveforms and exercises recording window/channel selection, PCM WAV headers, limiter bounds, and actual worklet message processing. Regenerate sound reference cases with `python3 Windows/validation/generate-sound-fixtures.py` on the Mac.

Staff note positions compile against the actual `PracticeScoreTimeline` implementation. Timing entries and coaching compare with 67 generated Swift sessions, including synchronization priority, stable latency bias, and accent/ghost failure advice.

Playback detection compares all intermediate ready/trigger states against 13 actual Swift onset sequences. Hit timing alignment compares against eight actual Swift collector measurements (nearest unused hit within 400 ms, source/voice isolation, boundary inclusion, median and MAD). ZIP interoperability was also checked with Python’s independent ZIP reader, including a multi-chunk audio payload.

MIDI import and section timing now compare against ten cases generated by the actual Swift Standard MIDI parser and imported-song generator, including running status/releases, held-note uncertainty, control events, tempo and meter changes, fractional tick durations and malformed files.
