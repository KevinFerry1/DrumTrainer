# Repeated-practice audio deadlock

## Confirmed failure

On October 6, 2026, a four-second stack sample of the running, stalled DrumTrainer captured both sides of a lock inversion. The UI was responsive but practice reported that the count-in had stalled again after recovery.

The engine control queue was blocked in:

```text
MetronomeEngine.stop()
  stopMetronomePlayback(publishStatus:)
    AVAudioPlayerNode.stop()
      AVAudioPlayerNodeImpl::StopImpl()
        dispatch_sync / wait for queue ownership
```

AVFAudio's shared `RealtimeMessenger.mServiceQueue` was simultaneously blocked in:

```text
AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform()
  MetronomeEngine.measureOutput(_:)
    limiterReductionDecibels()
      AVAudioUnit.audioUnit
        AVAudioNodeImplBase::GetAttachAndEngineLock()
          sleep / retry
```

Stopping the player holds the engine lock while waiting for pending tap work. The tap tried to acquire that same lock to read the limiter's audio unit. Neither side could finish. A replacement engine's `select(deviceID:)` was also blocked in `AVAudioPlayerNode.stop()`: the tap-message queue is shared across engines, so replacing an engine in the same process did not escape the deadlock. Relaunching cleared the process-wide blocked queue, explaining the reported behavior.

## Correction and invariant

The output tap captures only an independent `MetronomeOutputMeter`. It reads the delivered PCM buffer, computes peak and RMS, and stores the result behind a small mailbox lock. It has no reference to the transport, graph, limiter, or client callbacks.

A 20 Hz timer on the engine control queue reads the mailbox, releases its lock, then reads limiter reduction and publishes the combined level. This keeps all audio-unit access serialized with graph operations and prevents the tap from waiting for an engine lock. The limiter getter asserts that it is on the control queue.

Each tap installation has its own mailbox. Late buffers from a removed graph cannot update the new graph's meter. The meter timer is cancelled before removing the tap and during transport destruction.

Do not move node property access, audio-unit queries, synchronous queue dispatch, or client callbacks into the tap. Even a property getter such as `audioUnit` may take the engine lock.

## Verification

The transport accepts an audio-engine factory so tests can use real AVAudioEngine offline rendering through the same graph, limiter, meter, and start/stop/rebuild paths without requiring connected hardware. The factory also applies to replacement graphs. Offline rendering skips hardware-device binding.

`MetronomeTimelineTests.testNativeAudioGraphRemainsResponsiveAcrossMeteredPracticeReplays` runs 100 attempts by default, checks non-silent rendered PCM and meter packets each time, alternates kick monitoring on/off, changes limiter settings, hands off to song tempo maps, and rebuilds every ten attempts. Each native operation has a three-second deadline. Extend the stress run with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
TEST_RUNNER_DRUMTRAINER_AUDIO_STRESS_CYCLES=1000 \
xcodebuild -project DrumTrainer.xcodeproj -scheme DrumTrainer \
  -destination 'platform=macOS' test
```

AppState replay/watchdog tests remain useful for flow cancellation and stale callbacks, but a fake metronome cannot detect this native lock inversion. The regression coverage must exercise PCM rendering and metering concurrently with actual player and engine lifecycle operations.

Physical USB disconnects, driver failures, and sleep/wake are separate failure modes. Offline rendering does not prove that every audio device will render indefinitely; the fix removes the specific deadlock observed in the live app.
