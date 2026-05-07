# EqualEase Privacy Policy

Last updated: 2026-05-07

EqualEase is a local macOS audio utility. It is designed to adjust audio on your Mac without accounts, cloud processing, analytics, advertising, or tracking.

## Summary

- EqualEase processes system audio locally on your Mac so it can apply equalizer settings.
- EqualEase does not record, save, upload, sell, or share audio.
- EqualEase does not record, save, upload, sell, or share microphone audio.
- EqualEase does not require an account.
- EqualEase stores presets, app rules, settings, and paired local-network remote credentials locally on your Mac.
- The optional phone remote works only on your local network and must be enabled and paired by you.

## System audio

EqualEase needs macOS audio capture permission to receive the system audio stream, apply equalizer processing, and play the processed result to your selected output device.

System audio is processed locally in memory on your Mac. EqualEase does not save audio files, transcribe audio, send audio to a server, or use audio for advertising or analytics.

## Microphone and input volume

EqualEase can show and adjust the current macOS input volume for convenience. It can also notify you when input volume becomes low and, on supported devices, raise the macOS input volume back to your configured minimum.

EqualEase only watches the macOS input volume level. It does not capture, route, process, boost, equalize, save, or upload microphone audio.

## Local notifications

If you enable low microphone volume notifications, EqualEase uses macOS local notifications to warn you when input volume drops below your configured threshold. These notifications are generated locally on your Mac.

## Local-network remote control

EqualEase includes an optional local-network remote. It is disabled by default. When enabled, EqualEase starts a small HTTP/WebSocket server on your Mac so a phone browser on the same trusted Wi-Fi can control volume, preamp, and presets.

The remote uses pairing codes and client tokens. Pairing tokens are stored by the phone browser; EqualEase stores only salted token hashes locally under Application Support. Pairing codes and tokens are not sent to any EqualEase server because there is no EqualEase server.

The remote is intended for trusted local networks only. Do not expose it to the internet or untrusted networks.

## Local data storage

EqualEase stores app settings locally on your Mac, including presets, selected output behavior, app preset rules, local-network remote pairings, and feature preferences. Deleting EqualEase settings removes this local data.

## Data sharing

EqualEase does not share personal data with third parties. It does not include advertising SDKs, analytics SDKs, or cloud sync.

## Support and privacy contact

For support or privacy questions, use the public support page:

https://github.com/mblarsen/equalease/issues
