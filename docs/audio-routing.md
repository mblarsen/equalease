# Audio routing architecture

EqualEase is a system-wide macOS equalizer. To affect audio from browsers, music apps, calls, games, and system sounds, it needs more than a menu bar UI: it needs a routing path that can receive system output audio, process it locally, and render the processed stream to the selected real output device.

## Core architecture

EqualEase uses Core Audio process taps with a HAL aggregate-device routing path.

At a high level:

1. EqualEase creates Core Audio process taps for system output audio while excluding EqualEase's own process.
2. The taps are attached to an aggregate-device routing path.
3. EqualEase processes floating-point audio buffers through its EQ engine.
4. Processed audio is rendered to the chosen real output device, such as built-in speakers, headphones, HDMI, AirPods, or another output.
5. Turning EqualEase off stops the routing path and restores normal playback.

## Multi-tap architecture (per-app volume)

Starting from EqualEase **1.4**, audio routing uses a multi-tap model that enables per-app volume control. Instead of a single global tap, EqualEase creates:

- **One per-app tap** for each audio-emitting app that has explicit per-app audio settings, such as reduced gain, bypass, or mute. Each tap captures only that app's audio stream (`CATapDescription` with `isExclusive = false` and the app's process object ID).
- **One fallback tap** for all remaining system audio not captured by per-app taps. This includes default/unmodified apps at unity gain, and is equivalent to the original single global tap (`CATapDescription` with `isExclusive = true`, excluding all per-app PIDs and EqualEase's own PID).

All taps are added to the aggregate device's tap list. The IOProc receives separate audio buffers for each tap, maps them to the correct app, and mixes them according to each app's volume, bypass, and mute settings.

### Signal path

```
Per-app taps (non-bypassed apps)
  → per-app volume multiplier (0–100%, default 100%)
  → mix gained streams into a combined buffer
  → global EQ (10-band peaking filters)
  → global preamp
  → clipping protection
  ┌──────────────────────────────────────┐
  │ mix with bypass pass-through streams │
  └──────────────────────────────────────┘
  → output device

Bypassed app streams (verbatim pass-through)
  → copy input directly to output, mixing into the EQ'd combined buffer
  → (no gain, no EQ, no preamp, no clipping)

Muted app streams
  → silently dropped, not mixed into output
```

### Tap lifecycle

- **AudioProcessDiscovery** polls `kAudioHardwarePropertyProcessObjectList` every 2 seconds, filtering for processes with `kAudioProcessPropertyIsRunningOutput == true`. This detects apps currently emitting audio.
- When discovered apps with explicit per-app audio settings change, the aggregate device is restarted with an updated tap list after a short restart debounce coalesces multiple discovery changes.
- Default/unmodified app churn does not restart the route; those apps remain covered by the fallback tap.
- Newly discovered customized apps must remain visible for a short stability window before EqualEase adds a dedicated tap, avoiding restarts for one-poll process churn.
- Existing customized app taps are sticky during short absences and are removed only after an 8-second absence grace period.
- Gain, bypass, and mute changes for already-tapped customized apps update the running stream configuration promptly without waiting for discovery hysteresis.
- The fallback tap always excludes EqualEase's own process ID.

### Per-app modes

Each discovered app has three modes:

| Mode | Behaviour |
|------|-----------|
| **On** | Per-app volume applied, then global EQ/preamp, then clip protection. |
| **Off** (bypass) | Stream copied verbatim to output — no gain, no EQ, no preamp, no clamping. Still goes through EqualEase's output device. |
| **Mute** | Stream silently dropped. |

Apps in bypass mode are still tapped so their audio routes through EqualEase's selected output device. Default/unmodified apps do not need dedicated taps because the fallback tap captures them through the same selected output path.

### Persistence

Per-app volume and mode preferences persist across app restarts via `AppVolumeStore`, stored as JSON in Application Support (`EqualEase/app-volumes.json`). Preferences are keyed by bundle ID.

## Implementation files

- `Audio/CoreAudioRoutingHost.swift` — tap creation, aggregate device management, per-app tap lifecycle, fallback tap
- `Audio/CoreAudioLoopback.mm` — real-time IOProc: stream-to-app mapping, per-app gain, bypass, mute, mix, EQ
- `Audio/AudioProcessDiscovery.swift` — polling discovery of audio-emitting Core Audio processes
- `Audio/CoreAudioRouter.swift` — router state machine, per-app config propagation, debounced restart
- `Presets/AppVolumeStore.swift` — persistence for per-app volume and mode preferences

## Why this approach

This is the preferred v1 architecture because it:

- uses Apple Core Audio APIs instead of requiring a bundled third-party virtual audio driver;
- supports native macOS system-audio permission prompts;
- keeps audio processing local to the Mac;
- gives EqualEase control over duplicate-playback avoidance, output selection, cleanup, and recovery;
- avoids the installation and support burden of a custom audio driver for the first release.

## Alternatives considered

### Per-process gain API

macOS has no public per-process gain/volume property on `AudioHardwareProcess`. The class exposes `pid`, `bundleID`, `isRunning`, `isRunningOutput`, and `devices`, but no volume or gain selector. `AudioHardwareDevice.setIsProcessOutputMuted(_:)` only mutes the calling process's own output. Per-app volume must go through process taps.

### Third-party virtual audio driver

A virtual loopback driver such as BlackHole is a known way to route audio between macOS apps. EqualEase does not use this as the default v1 path because it would require users to install and authorize an additional driver and would make the core product depend on an external routing component.

It remains a useful fallback or troubleshooting reference if Core Audio process taps are not available in a future environment.

### Custom Audio Server Plug-in or AudioDriverKit driver

A custom virtual audio device could provide deeper product ownership, but it brings substantially more complexity: driver architecture, installation, signing, permissions, packaging, and support. This is deferred beyond the first release unless the Core Audio tap approach proves insufficient.

## Privacy and permissions

EqualEase processes audio locally in memory so it can apply the selected equalizer settings. It does not record, save, upload, transcribe, or share audio.

macOS may require system audio capture permission because EqualEase needs access to the system output stream before it can apply EQ and render the processed result.

## Cleanup and recovery

Audio routing must fail safely. EqualEase cleans up EqualEase-owned Core Audio taps and aggregate devices during launch, start, stop, termination, and failure recovery. The repository also includes `scripts/reset-audio-routing.swift` for troubleshooting stale EqualEase-owned audio routing state.

## Limitations

- EqualEase requires macOS support for Core Audio process taps.
- Users must grant required macOS permissions.
- Output device behaviour can vary by hardware and macOS version, so routing changes are handled conservatively and recoverably.
- Per-app volume is attenuation-only (0–100%). Global Preamp remains the boost control.
- Per-app EQ presets (different EQ curves per app) are not yet supported — that would require separate biquad filter state per app in the real-time audio path.
