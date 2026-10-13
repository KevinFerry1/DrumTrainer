# DrumTrainer for Windows 10 — portable practice edition

1. Copy **DrumTrainer-Windows.zip** onto the Windows computer and **Extract All**. Do not run the launcher from inside the ZIP.
2. Open the extracted folder and double-click **Start DrumTrainer.cmd**. It opens an app window in Microsoft Edge or Chrome. Keep the small launcher window open while practicing.
3. Connect the drum module, Blue Snowball, and your headphone output. Click **Connect MIDI**, select your kit, and grant MIDI permission. Strike each pad; use **Pad mapping** to correct its voice.
4. Click **Enable microphone**, grant microphone permission, select the Snowball, and click **Sample noise** while the room is quiet. Test kicks in the live log. Adjust the threshold and lockout if necessary. Use **Calibrate kicks**: after the quiet-room sample, play 10 isolated kicks and 10 kicks while adding other pads, then **Save calibration**. The learned spectral/decay filter and MIDI crosstalk guard now use the native algorithms; test them with your hardware before relying on scores.
5. Select the Focusrite/headphones under **Click output**. If output selection is unavailable, choose it in Windows sound settings. Use headphones to keep the click out of the kick microphone.
6. Run **Align MIDI** and **Align mic** for each input/output setup. After eight count-in clicks, play one hit per click for 12 clicks. Alignment includes personal playing bias; it is not a laboratory latency measurement.
7. Choose an exercise, tempo, and repeat count, then **Start exercise**. Begin after the eight count-in clicks. Keep the app visible; hiding it cancels the attempt to prevent unreliable timing. Space starts/pauses practice when you are not editing a control.

No Xcode, Python, Node.js, paid account, installation, or administrator access is required. Windows PowerShell 5.1 and a current Chromium-based Microsoft Edge or Google Chrome are required. This uses browser MIDI and audio APIs on a server bound only to this computer at `http://localhost:8765`. It has no external libraries, network assets, analytics, or uploads. The included server serves only allowlisted app files; personal backup files are imported directly from your computer.

## Move your Mac data

The transfer ZIP may include **Mac-practice-backup.json**, copied from the Mac app’s saved practice archive. In the Windows app choose **Import Mac / Windows backup** and select that file. Alternatively, use **History → Export JSON** in the Mac app before returning it, then import the exported file on Windows.

This transfer also includes **Mac-source-backup.zip**, a snapshot of the native Mac source and project documents, including the current uncommitted edits. Keep it alongside your practice backup if you may continue development on another computer. It is a source snapshot, not an installed Mac application.

- Saved drum measures and sequences become playable exercises, including authored accents and ghosts. Dynamics need MIDI velocity evidence; microphone hits do not supply velocity.
- Mac drum sessions with archived evidence have complete results, raw evidence, saved device/correction context, editable notes/tags, and rescoring. Summary-only legacy entries remain available when no evidence record exists. Original songs, scores, raw event evidence, profiles, and other native archive fields are preserved unchanged inside the imported archive. **Download original Mac backups** retrieves them. Imported drum songs can be practiced through track mapping, section loops, tempo scaling and their saved tempo/meter maps.
- Mac recorded audio is stored separately from the JSON backup. This transfer package includes the available takes in **Mac-recordings**. Keep that folder. If making a new transfer yourself, copy `~/Library/Application Support/DrumTrainer/Practice Audio` as well. Choose **Import recordings folder** and select **Mac-recordings**. Takes attach by session ID and can be replayed, scrubbed, downloaded or deleted from session details. Original files remain in your transferred folder.
- This edition's **Export backup** includes Windows exercises and sessions plus original imported Mac archives. Its format is different from the native Mac app's format. Do not import the Windows wrapper into the Mac app; download the original Mac backup instead.

Practice data is stored in this browser's local database. Always use the same browser and address. Export after important sessions, before changing computers, or before clearing browser data. Moving the extracted folder does not move browser history. MIDI mappings and device timing corrections are kept in that browser's settings and should be configured again on a new computer. Each source's correction belongs to the selected input/output pairing; when changing the Windows default device, run alignment again.

## Included

All 15 built-in drum exercises; a custom-measure editor; saved-measure/sequence imports; device-specific MIDI pad mapping; sample-level microphone transient detection in an audio worklet; guided noise/20-kick calibration; the native spectral/decay kick fingerprint and MIDI crosstalk guard; ahead-scheduled accented metronome; eight-beat count-in; five native click sounds; four native kick sounds with velocity following and six overlapping voices; limiter and peak/RMS meter; independent session recording input/channel selection; attached Mac/Windows take replay; scrolling voice lanes; native ordered minimum-cost correct/wrong/missed/extra/ambiguous matching; local accent/ghost velocity contrast; per-voice results; early/late bias and consistency; simultaneous-limb spread; raw Windows session evidence; persistent history; portable JSON backup; configurable Auto go and clean-run tempo advancement; persistent Find My Ceiling search and records; simulation without hardware.

The matching, metrics, accent/ghost rules, stable timing-bias adjustment, and clean-run qualification now use ports of the native Swift algorithms (scoring version 5), checked against generated Swift reference cases. Clean runs follow the Mac rule: at least 95% recall, timing error ≤25 ms (centered for an eligible stable common bias), sufficient authored dynamics, and no dropped evidence. Output scheduling interruptions also disqualify Windows runs. MIDI/input/output latency still requires hardware alignment and validation on Windows.

## Recording and output

Enable **Record completed practice sessions**, select a recording input independently of the kick microphone, and select Input 1, Input 2 or Loopback 3–4. Count-in is excluded. Completed audio windows are saved as PCM WAV; interrupted captures are discarded. Mac takes retain their original `.m4a` format. The browser must expose the requested input channels; a two-channel device cannot provide channels 3–4 through this path. Separate loopback devices can be selected as Input 1. Hardware channel routing still needs verification on Windows.

**Export backup** contains evidence and settings but no audio files. Download important takes separately before clearing browser data. The synthesized click/kick sample formulas match the native generator in 72 Swift reference cases. The Windows limiter is a separate peak limiter with a 50 ms release; it enforces the selected ceiling but is not Apple’s Audio Unit DSP.

## Not yet ported

Native staff notation and richer timing displays; Songsterr companion; electric piano/guitar workflows. Custom measures and sequences now support authoring, update/copy/delete. Imported MIDI songs and native session evidence are migrated and usable. Full feature parity remains pending the remaining workflows and Windows 10 physical-device validation.

## Troubleshooting

- **No MIDI input:** use current Edge or Chrome, install the module manufacturer's Windows MIDI driver if required, reconnect the kit, close DAWs that may hold its MIDI input, and click Connect MIDI again.
- **No microphone:** allow browser microphone permission and Windows Settings → Privacy → Microphone → desktop app access. Re-enable the microphone after changing devices.
- **Wrong output:** select the Focusrite in Windows sound settings if the browser cannot select an output. Repeat timing alignment when changing outputs.
- **False kicks:** use headphones, move the Snowball closer to the kick pad, sample room noise, and raise the threshold. To practice hands without acoustic-kick grading, clear Grade kicks and select a full-kit exercise.
- **Launcher does not start:** extract the entire ZIP first. If another copy is running, close its launcher window. A company-managed computer may block PowerShell scripts; the error will appear in the launcher window. The app does not change the computer's permanent execution policy.

## Development / verification

From the repository root, run `node --test Windows/*.test.mjs`. To preview on Mac, serve `Windows` on localhost using any static server (for example `python3 -m http.server 8765 --bind 127.0.0.1 --directory Windows`) and open it in Chrome. This does not modify the Swift app. The Windows launcher and physical Windows devices must still be validated on Windows; a Mac browser preview cannot prove hardware compatibility or latency there.

Reference cases are generated by compiling the repository’s actual Swift drum algorithms with `sh Windows/validation/generate-fixtures.sh`. `native-parity.test.mjs` compares classifications, matched event IDs, timings, dynamics, complete metrics, stable bias, clean qualification, exercise targets, click references, and audio features. GitHub Actions runs the JS comparison tests and the included PowerShell launcher on a Windows runner. These checks do not replace Windows 10 physical-device validation.

Audio verification additionally compares 72 generated native click/kick waveforms and exercises recording window/channel selection, PCM WAV headers, limiter bounds, and actual worklet message processing. Regenerate sound reference cases with `python3 Windows/validation/generate-sound-fixtures.py` on the Mac.
