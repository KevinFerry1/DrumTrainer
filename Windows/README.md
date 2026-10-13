# DrumTrainer for Windows 10 — portable practice edition

1. Copy **DrumTrainer-Windows.zip** onto the Windows computer and **Extract All**. Do not run the launcher from inside the ZIP.
2. Open the extracted folder and double-click **Start DrumTrainer.cmd**. It opens an app window in Microsoft Edge or Chrome. Keep the small launcher window open while practicing.
3. Connect the drum module, Blue Snowball, and your headphone output. Click **Connect MIDI**, select your kit, and grant MIDI permission. Strike each pad; use **Pad mapping** to correct its voice.
4. Click **Enable microphone**, grant microphone permission, select the Snowball, and click **Sample noise** while the room is quiet. Test kicks in the live log. Adjust the threshold and lockout if necessary. This edition uses basic transient detection: test it with simultaneous snare/cymbal hits before relying on its scores.
5. Select the Focusrite/headphones under **Click output**. If output selection is unavailable, choose it in Windows sound settings. Use headphones to keep the click out of the kick microphone.
6. Run **Align MIDI** and **Align mic** for each input/output setup. After eight count-in clicks, play one hit per click for 12 clicks. Alignment includes personal playing bias; it is not a laboratory latency measurement.
7. Choose an exercise, tempo, and repeat count, then **Start exercise**. Begin after the eight count-in clicks. Keep the app visible; hiding it cancels the attempt to prevent unreliable timing. Space starts/pauses practice when you are not editing a control.

No Xcode, Python, Node.js, paid account, installation, or administrator access is required. Windows PowerShell 5.1 and a current Chromium-based Microsoft Edge or Google Chrome are required. This uses browser MIDI and audio APIs on a server bound only to this computer at `http://localhost:8765`. It has no external libraries, network assets, analytics, or uploads. The included server serves only six allowlisted app files; personal backup files are imported directly from your computer.

## Move your Mac data

The transfer ZIP may include **Mac-practice-backup.json**, copied from the Mac app’s saved practice archive. In the Windows app choose **Import Mac / Windows backup** and select that file. Alternatively, use **History → Export JSON** in the Mac app before returning it, then import the exported file on Windows.

This transfer also includes **Mac-source-backup.zip**, a snapshot of the native Mac source and project documents, including the current uncommitted edits. Keep it alongside your practice backup if you may continue development on another computer. It is a source snapshot, not an installed Mac application.

- Saved drum measures and sequences become playable exercises, including authored accents and ghosts. Dynamics need MIDI velocity evidence; microphone hits do not supply velocity.
- Mac drum history appears as summary rows. Original songs, scores, raw event evidence, profiles, and other native archive fields are preserved unchanged inside the imported archive. **Download original Mac backups** retrieves them. Mac imported-song playback and detailed history rescoring are not implemented in this edition.
- Mac recorded audio is stored separately from the JSON backup. This transfer package includes the available takes in **Mac-recordings**. Keep that folder. If making a new transfer yourself, copy `~/Library/Application Support/DrumTrainer/Practice Audio` as well. These takes cannot be played from this edition, but individual `.m4a` files can be opened in a media player.
- This edition's **Export backup** includes Windows exercises and sessions plus original imported Mac archives. Its format is different from the native Mac app's format. Do not import the Windows wrapper into the Mac app; download the original Mac backup instead.

Practice data is stored in this browser's local database. Always use the same browser and address. Export after important sessions, before changing computers, or before clearing browser data. Moving the extracted folder does not move browser history. MIDI mappings and device timing corrections are kept in that browser's settings and should be configured again on a new computer. Each source's correction belongs to the selected input/output pairing; when changing the Windows default device, run alignment again.

## Included

All 15 built-in drum exercises; a custom-measure editor; saved-measure/sequence imports; device-specific MIDI pad mapping; sample-level microphone transient detection in an audio worklet; quiet-room threshold calibration; ahead-scheduled accented metronome; eight-beat count-in; scrolling voice lanes; one-to-one correct/wrong/missed/extra matching; local accent/ghost velocity contrast; per-voice results; early/late bias and consistency; simultaneous-limb spread; raw Windows session evidence; persistent history; portable JSON backup; optional automatic repeats and tempo advancement after three clean runs; simulation without hardware.

The port uses its own matcher and scoring version. It does not claim identical scores to the native app. Clean runs require at least 95% recall and precision, median timing error ≤25 ms, sufficient dynamics where authored, and no dropped events or missed click deadlines. Microphone input/output latency needs the alignment step. Basic transient detection cannot reliably distinguish kick-pad sound from every other sound in the room.

## Not yet ported

The Mac learned kick fingerprint and MIDI crosstalk guard; audio recording/playback; kick sound reinforcement; native notation; imported MIDI/Songsterr playback; Find My Ceiling; electric piano/guitar workflows; sequence authoring and full saved-exercise editing. Mac history is preserved and displayed as summaries, not rescored. This is a usable drum-practice bridge, not full feature parity.

## Troubleshooting

- **No MIDI input:** use current Edge or Chrome, install the module manufacturer's Windows MIDI driver if required, reconnect the kit, close DAWs that may hold its MIDI input, and click Connect MIDI again.
- **No microphone:** allow browser microphone permission and Windows Settings → Privacy → Microphone → desktop app access. Re-enable the microphone after changing devices.
- **Wrong output:** select the Focusrite in Windows sound settings if the browser cannot select an output. Repeat timing alignment when changing outputs.
- **False kicks:** use headphones, move the Snowball closer to the kick pad, sample room noise, and raise the threshold. To practice hands without acoustic-kick grading, clear Grade kicks and select a full-kit exercise.
- **Launcher does not start:** extract the entire ZIP first. If another copy is running, close its launcher window. A company-managed computer may block PowerShell scripts; the error will appear in the launcher window. The app does not change the computer's permanent execution policy.

## Development / verification

From the repository root, run `node --test Windows/core.test.mjs`. To preview on Mac, serve `Windows` on localhost using any static server (for example `python3 -m http.server 8765 --bind 127.0.0.1 --directory Windows`) and open it in Chrome. This does not modify the Swift app. The Windows launcher and physical Windows devices must still be validated on Windows; a Mac browser preview cannot prove hardware compatibility or latency there.
