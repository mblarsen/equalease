# EqualEase Manual Validation Checklist

Use this checklist before calling a local MVP build ready. Prefer testing with real audio playing and at least two output devices when available.

## Build, install, and launch

- [ ] Debug build succeeds with:

  ```sh
  xcodebuild -project EqualEase/EqualEase.xcodeproj -scheme EqualEase -configuration Debug build
  ```

- [ ] Local install succeeds with:

  ```sh
  scripts/install-local.sh
  ```

- [ ] `/Applications/EqualEase.app` launches.
- [ ] On a fresh install, the native macOS audio capture permission dialog does not appear before EqualEase shows its own first-run explanation.
- [ ] Menu bar extra appears.
- [ ] Menu bar icon opens a compact draggable quick-control panel with the first-run “Turn On EqualEase” explanation before any native macOS audio capture permission prompt.
- [ ] The first-run “Start audio routing automatically on future launches” checkbox is checked by default.
- [ ] After clicking Turn On EqualEase, macOS may show the native audio capture permission dialog.
- [ ] After first-run setup, the menu bar icon opens a compact draggable quick-control panel with Active, routing, output, preset, and a gear menu that hides Manage/About/Quit.
- [ ] Quick-control panel closes when clicking outside EqualEase.
- [ ] Settings > General and the standard macOS About panel show the current version/build.

## Routing lifecycle

- [ ] Start Audio Routing while audio is playing.
- [ ] Audio remains audible through the selected real output.
- [ ] Stop Audio Routing restores normal macOS audio.
- [ ] Start/stop can be repeated three times without silence or stale devices.
- [ ] Restart works while routing is active.
- [ ] Changing output while routing is active shows a restart status and does not freeze the menu bar UI.
- [ ] Quit EqualEase while routing is active; audio returns to normal.
- [ ] Relaunch EqualEase; no stale EqualEase aggregate/tap breaks audio.

## Equalizer and presets

- [ ] Menu bar Active toggle stops routing when turned off and starts routing when turned on.
- [ ] Active toggle is disabled while routing is starting, stopping, or switching outputs.
- [ ] Menu-bar icon appears muted/dimmed when EqualEase is inactive/off and returns to full opacity when Active is on.
- [ ] Preset editor Preamp changes are audible and are explained with readable, non-truncated per-preset output-level help text.
- [ ] Each built-in preset can be selected:
  - [ ] Flat
  - [ ] Call Clarity
  - [ ] Bass Boost
  - [ ] Treble Boost
  - [ ] Warm
  - [ ] Muffled
- [ ] Selecting a preset while Safari or Spotify is active shows a subtle inline smart-switching suggestion.
- [ ] Accepting the suggestion remembers the preset for that app.
- [ ] Dismissing the suggestion with the x button leaves app rules unchanged and does not ask again until the menu-bar window is reopened.
- [ ] Save Current creates a custom preset.
- [ ] Duplicate creates a selected custom copy.
- [ ] Settings > Presets can rename a custom preset and the name persists after app restart.
- [ ] Settings > Presets can update a custom preset from the live EQ and the update persists after app restart.
- [ ] Settings > Presets can delete a custom preset; it disappears from the picker and clears related rules.

## Device behavior

- [ ] Current output device name matches the macOS output.
- [ ] Follow system output is disabled while Active is off.
- [ ] Follow system output updates EqualEase when macOS output changes from System Settings or the menu-bar Sound dashboard.
- [ ] Changing macOS output volume outside EqualEase updates the EqualEase Volume slider/state.
- [ ] Manually selecting an output disables Follow system output.
- [ ] Output picker does not list EqualEase Aggregate Audio Device or other EqualEase-owned internal routing devices.
- [ ] If routing is active, changing output restarts routing to the new output.
- [ ] Device-specific preset rule controls are not visible in the first-release UI.

## Active-app and website behavior

- [ ] Active app label updates after switching to Safari.
- [ ] Active app label updates after switching to Spotify.
- [ ] Use When App Is Active assigns a preset to Safari.
- [ ] Use When App Is Active assigns a different preset to Spotify.
- [ ] Switching Safari ↔ Spotify changes the effective preset while the EqualEase popover is open.
- [ ] Switching Safari ↔ Spotify changes the effective preset while the EqualEase popover is closed.
- [ ] Switching away from an app with a rule returns to the selected default preset instead of leaving the app preset active.
- [ ] Pause app preset switching keeps the current preset active while switching to an app with a different remembered preset.
- [ ] Turning Pause app preset switching off resumes normal active-app rule switching.
- [ ] Opening EqualEase does not replace the target active app with EqualEase itself.
- [ ] Clear Active-App Rule removes the current app mapping.
- [ ] With Safari or Google Chrome foreground on `https://meet.google.com/` and no website rules, EqualEase does not prompt for browser Automation permission until the user clicks Use Preset for the current browser page in Settings > Rules.
- [ ] After the current browser page Use Preset action succeeds, Settings > Rules stores `meet.google.com` as a website rule and shows it above app rules.
- [ ] After granting the browser Automation prompt, the current app row still shows the browser rather than the transient macOS permission helper app.
- [ ] Assigning separate presets to a browser app and `meet.google.com` stores two rules in the unified Rules list, with the website rule above the app rule.
- [ ] When a customized audio app starts playing, EqualEase waits for a stable discovery confirmation before adding its dedicated per-app tap and restarting routing.
- [ ] When a customized audio app briefly stops emitting audio, EqualEase keeps its dedicated tap through the short absence and removes it only after the grace period.
- [ ] Changing Volume, Process/Bypass, or Mute for an already-tapped app updates the app's stream promptly without waiting for another discovery cycle.
- [ ] While Safari or Google Chrome is on `meet.google.com`, the website preset wins over the browser app preset.
- [ ] Switching the browser to an unmatched active tab falls back to the browser app preset.
- [ ] Switching away from the browser removes website matching and falls back to the foreground app/default preset.
- [ ] If browser automation permission is denied or revoked from the current browser page Use Preset action, website detection fails closed and app/default preset rules still work without prompting from background polling.
- [ ] Clearing the last website rule stops browser page polling.

## Settings window

- [ ] Menu bar > Settings… opens a native settings window.
- [ ] Settings opens with a General tab containing Launch at Login, Local Network Remote, External Automation, and Version; it does not contain runtime routing controls.
- [ ] Launch at Login can be enabled and disabled from the installed `/Applications/EqualEase.app`.
- [ ] External automation safety can be disabled; with it off, AppleScript/URL reads and built-in preset selection still work, while Volume, Preamp, Bypass, app-preset-switching pause, and custom-preset writes are rejected.
- [ ] Presets tab lists built-in and custom presets.
- [ ] Presets tab provides the detailed custom preset editor while the menu bar remains a quick selector.
- [ ] Rules tab creates active-app and supported-browser website rules, lists them with friendly names/icons after app restart, and can clear them.
- [ ] Rules tab does not show device-rule controls or device-rule explanatory copy.
- [ ] Diagnostics tab shows routing status, DSP bypass, available output devices with device icons, and recovery/development controls.
- [ ] Diagnostics DSP bypass explains that audio still routes through EqualEase while bypassed.
- [ ] Standard macOS About panel uses the current EqualEase orange/white app icon, not an old cached icon.

## Local-network remote control

- [ ] After a fresh install with no saved preference, `curl http://127.0.0.1:8787/health` fails because the local-network remote is disabled by default.
- [ ] Settings > General contains a Local Network Remote toggle and explains that paired authentication is required and the remote should only be enabled on trusted networks.
- [ ] Turning on Settings > General > Local Network Remote starts the server and logs the Mac’s primary local-network HTTP and WebSocket URLs, without link-local or virtual adapter addresses.
- [ ] On the Mac, `curl http://127.0.0.1:8787/health` returns a minimal success response while the toggle is on.
- [ ] Turning off Settings > General > Local Network Remote stops the server and `curl http://127.0.0.1:8787/health` no longer connects.
- [ ] On another same-Wi-Fi device, `GET http://<mac-lan-ip>:8787/health` succeeds.
- [ ] `GET http://<mac-lan-ip>:8787/info` returns app/protocol metadata and does not include local paths, user names, tokens, or device identifiers.
- [ ] A WebSocket client can connect to `ws://<mac-lan-ip>:8787/ws`, send `get_state`, and receive `state_snapshot` with `stateVersion`, Volume, Preamp, active preset, preset list, and routing status.
- [ ] Sending `command` messages for `set_volume`, `set_preamp`, and `select_preset` returns correlated `command_result` messages and updates the Mac app state.
- [ ] Opening `http://<mac-lan-ip>:8787/remote` on a phone shows large Volume/Preamp controls and one-tap preset buttons without dropdowns for core controls.
- [ ] The remote is used only on trusted local networks and requires pairing before detailed state or control commands are accepted.

## Recovery

- [ ] Cleanup Audio State reports no stale objects during a healthy run after routing is stopped.
- [ ] `scripts/reset-audio-routing.swift --dry-run` does not report stale EqualEase-owned taps/aggregates after a clean quit.
- [ ] If audio becomes silent during testing, Stop Audio Routing then Cleanup Audio State restores normal audio.

## Known acceptable warnings

- AppIntents metadata extraction warning is acceptable until EqualEase uses AppIntents.
