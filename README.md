# DrumTrainer

Deliberate drum practice for Mac and Windows: timing, dynamics, local session history, and feedback grounded in saved practice evidence.

**[Download the free desktop beta](https://kevinferry1.github.io/DrumTrainer-Website/#download)** · [Setup and release notes](RELEASE-NOTES.md) · [Report a problem](https://github.com/KevinFerry1/DrumTrainer-Website/issues/new/choose)

The beta is free, with no account, payment, or expiry. Mac requires macOS 15 or later; the beta is not Apple-notarized. Windows requires Windows 10 or 11 and current Edge or Chrome. The Mac ZIP includes Apple silicon and Intel code. Extract the Windows ZIP before opening `Start DrumTrainer.cmd`.

## About this repository

This is the public home for the website, documentation, beta downloads, and feedback. Application development is maintained in a private repository. The automatic source archives attached to this repository's releases contain this public website and documentation only.

## What the app does

- Practice built-in exercises or authored measures and sequences at a chosen tempo.
- Review early and late hits, missed and extra notes, per-voice results, and dynamics where MIDI velocities are available.
- Ask the local practice coach about an exercise, instrument, tempo, or recent sessions, then open the evidence supporting its findings.
- Export local practice history and optional recordings as backups.

USB MIDI supplies pad-by-pad evidence. Optional microphone input can detect kick impacts and record takes; it does not transcribe a full acoustic kit. The app measures hit timing and velocity, not physical grip, movement, or tension.

## Engineering overview

The native Mac app uses SwiftUI, CoreMIDI, Core Audio, and JavaScriptCore for the shared history analyzer. The portable Windows edition uses browser MIDI and audio APIs, audio worklets, local browser storage, and a local PowerShell launcher.

Timestamped input events are compared with generated exercise targets. Matching classifies correct, wrong, missed, extra, and ambiguous evidence. Results preserve the device and timing-correction context needed to interpret a session. The coach compares compatible patterns and setups and distinguishes spacing, dynamics, and missed-note findings while flagging insufficient evidence and possible alignment issues.

Validation includes Swift reference fixtures for the Windows scoring and audio ports, 462 JavaScript tests at the initial beta release, desktop workflow checks, launcher checks, native Mac build/tests, and verification of the universal Mac executable. Automated checks do not establish hardware compatibility or replace calibration and physical-device testing.

## Privacy and feedback

Sessions and optional recordings stay on the user's computer. The practice coach runs locally without an API key or paid AI service. There is no app analytics or cloud sync. Export backups regularly, especially before updates or clearing browser data.

GitHub hosts this website and the downloads. Issues and attachments submitted here are public. Remove personal information and share only data you intend to publish.

For useful bug reports, include the operating system, kit/module, input/output devices, what you did, and what happened. Timing reports should include calibration context and whether the problem repeats at a slower tempo.
