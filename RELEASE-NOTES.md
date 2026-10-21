# DrumTrainer — free desktop beta

This beta is free, with no account, payment, or expiry. A seven-day trial and $29.99 one-time purchase are deferred; no paid license is required for these downloads.

## Downloads and setup

**Windows:** Download `DrumTrainer-Windows.zip`, choose **Extract All**, and open `Start DrumTrainer.cmd` inside the extracted folder. Requires Windows 10 or 11, Windows PowerShell 5.1, and current Edge or Chrome. It runs in a local browser app window. Use the same browser and local address to retain your history. No developer tools or installer required. See the included README for setup and troubleshooting.

**Mac:** Download `DrumTrainer-Mac.zip`, extract it, and move `DrumTrainer.app` to Applications. Requires macOS 15 or later. Includes Apple silicon and Intel code. This beta has an ad-hoc signature, not an Apple Developer ID signature, and is **not notarized**. macOS may block downloaded builds. Developer ID signing and notarization remain necessary for a smoother public distribution experience; this release does not claim Apple verification. If macOS prevents opening it, report the message and your macOS version to the maintainer.

Connect an electronic drum kit using USB MIDI, select the input, and check pad mapping in Live Monitor. Use headphones and run timing alignment for the selected input/output pairing before relying on scores. Optional microphone kick detection needs its own setup. Start at a comfortable tempo and export your history regularly, especially before updating.

## Included

- Drum exercises, custom measures and sequences, per-voice timing and dynamics review, and local practice history.
- Accented beat clicks on both platforms, plus eighth-note and sixteenth-note click choices on Windows.
- A local practice coach on Mac and Windows. Ask about Moeller hi-hat history, a particular exercise, tempo, instrument, or recent runs. Open the evidence sessions behind the findings.
- Comparisons across compatible saved sessions, technique-related timing/velocity observations, calibration flags, and a suggested drill and tempo.

The coach is a focused history analyzer, not a general conversational model. It does not observe your physical motion. Summary-only history, missing velocities, insufficient comparable sessions, and unreliable input limit the conclusions available.

## Data and privacy

These download packages contain no personal practice backups, session recordings, or development source snapshots. Practice history and optional recordings stay on the computer. The coach makes no network requests and needs no API key. There is no app analytics or cloud sync. Browser data clearing can erase Windows history; export backups and store them outside the app. Windows backups and native Mac backups are different formats; follow the import/export instructions in the app and included documentation.

GitHub hosts the project page and downloads. Any issue or attachment you submit to the public repository is public. Remove personal information from feedback and backups before sharing them.

## Beta limits

Hardware compatibility and real-world timing still need broader validation. Automated scoring, launcher, and native build checks do not replace testing with actual kits and audio devices. Calibration includes playing bias; it is not a laboratory latency measurement. Device changes require renewed alignment.

Mac and Windows differ in audio routing, channel access, and limiter implementation. Windows uses browser audio/MIDI permissions and must stay visible during a run. Guitar and piano are outside the Windows drum beta scope. The microphone path does not transcribe an entire acoustic kit. This release does not include copyrighted song audio.

## Feedback

Report issues at https://github.com/KevinFerry1/DrumTrainer-Website/issues/new. Include your OS, kit/module, connection type, input/output devices, steps to reproduce, and the expected and actual result. For timing concerns, include calibration context and whether the issue repeats at a slower tempo. Share only data you intend to make public.

`SHA256SUMS.txt` accompanies the downloads so their integrity can be checked.
