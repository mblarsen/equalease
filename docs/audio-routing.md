# Audio routing architecture

EqualEase is a system-wide macOS equalizer. To affect audio from browsers, music apps, calls, games, and system sounds, it needs more than a menu bar UI: it needs a routing path that can receive system output audio, process it locally, and render the processed stream to the selected real output device.

## Chosen approach

EqualEase uses Core Audio process taps with a HAL aggregate-device routing path.

At a high level:

1. EqualEase creates a Core Audio process tap for system output audio while excluding EqualEase's own process.
2. The tap is attached to an aggregate-device routing path.
3. EqualEase processes floating-point audio buffers through its EQ engine.
4. Processed audio is rendered to the chosen real output device, such as built-in speakers, headphones, HDMI, AirPods, or another output.
5. Turning EqualEase off stops the routing path and restores normal playback.

## Why this approach

This is the preferred v1 architecture because it:

- uses Apple Core Audio APIs instead of requiring a bundled third-party virtual audio driver;
- supports native macOS system-audio permission prompts;
- keeps audio processing local to the Mac;
- gives EqualEase control over duplicate-playback avoidance, output selection, cleanup, and recovery;
- avoids the installation and support burden of a custom audio driver for the first release.

## Alternatives considered

### Third-party virtual audio driver

A virtual loopback driver such as BlackHole is a known way to route audio between macOS apps. EqualEase does not use this as the default v1 path because it would require users to install and authorize an additional driver and would make the core product depend on an external routing component.

It remains a useful fallback or troubleshooting reference if Core Audio process taps are not available in a future environment.

### Custom Audio Server Plug-in or AudioDriverKit driver

A custom virtual audio device could provide deeper product ownership, but it brings substantially more complexity: driver architecture, installation, signing, permissions, packaging, and support. This is deferred beyond the first release unless the Core Audio tap approach proves insufficient.

## Privacy and permissions

EqualEase processes audio locally in memory so it can apply the selected equalizer settings. It does not record, save, upload, transcribe, or share audio.

macOS may request system audio capture permission because EqualEase needs access to the system output stream before it can apply EQ and render the processed result.

## Cleanup and recovery

Audio routing must fail safely. EqualEase cleans up EqualEase-owned Core Audio taps and aggregate devices during launch, start, stop, termination, and failure recovery. The repository also includes `scripts/reset-audio-routing.swift` for troubleshooting stale EqualEase-owned audio routing state.

## Limitations

- EqualEase requires macOS support for Core Audio process taps.
- Users must grant required macOS audio permissions.
- Output device behavior can vary by hardware and macOS version, so routing changes are handled conservatively and recoverably.
