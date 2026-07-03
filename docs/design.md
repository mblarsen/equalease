# Design

## Overview

EqualEase is a macOS menu bar app that controls a system-wide audio processing path. The name combines “equalizer” and “ease”, reflecting the product goal: make system-wide audio EQ easy enough for daily Mac use. The user-facing model is simple: choose a device, choose or edit a preset, and hear all Mac audio change.

The technical model is split into two paths:

- Audio path: system audio is routed through EqualEase, processed by the EQ engine, then forwarded to the real output device.
- Control path: menu bar and settings UI update presets, active-app rules, and the active EQ state.

## Audio signal path

The intended signal path is linear:

    Any Mac app
      -> macOS system output set to EqualEase or routed through EqualEase
      -> EqualEase audio backend receives audio buffers
      -> 10-band EQ DSP processes audio
      -> processed audio is sent to the selected real output device

The Core Audio process-tap v1 route uses a global system tap that excludes EqualEase itself. The selected output device is the render target, not the capture filter. For example, if macOS is currently sending Spotify to a Bluetooth speaker, EqualEase should still be able to capture the system mix and render the processed result to MacBook speakers when the user explicitly selects that output. Output-device changes while routing is active are debounced and restarted outside the immediate SwiftUI picker setter path so UI state updates do not synchronously recreate Core Audio taps and aggregate devices.

The first implementation milestone must prove this path with a technical validation. The validation should compare a dependency-assisted virtual route with a first-party CoreAudio route and recommend the fastest reliable first-release backend.

## Core modules

### AudioRoutingBackend

Owns system-wide audio routing. It hides whether the implementation uses an existing virtual audio device, a CoreAudio Audio Server Plug-in, AudioDriverKit, or another local route.

Responsibilities:

- Start and stop the routing path.
- Report backend health.
- Select the real output device.
- Feed audio buffers through the EQ engine.
- Fail safe when routing or processing breaks.

### EqualizerEngine

Applies the current EQ state to audio buffers.

First-release behavior:

- Stereo processing.
- 10 fixed bands.
- Gain per band in decibels.
- Bypass support.
- Safety handling for clipping, likely preamp and/or limiter.

### AudioDeviceService

Observes real macOS output devices and the current selected device.

Responsibilities:

- List output devices with stable identifiers when available.
- Detect device changes, including default output, default system output, and device-list changes.
- Keep EqualEase's selected output in sync with macOS while Follow system output is enabled.
- Observe the selected output device's volume property so external macOS volume changes update EqualEase's Volume state.
- Notify preset resolution when the current output changes.

### PresetStore

Owns built-in and custom presets.

Built-in presets are immutable templates. Custom presets can be created, duplicated, renamed, edited, and deleted. The built-in set should include at least one speech-focused preset, such as Voice or Call Clarity, because the first motivating use case is understanding a colleague in calls. The built-in set should also include Muffled, a deliberately subdued/background preset that can be used manually now and later as the default treatment for non-focused sources in center-stage mode.

### DeviceSettingsStore

Maps output devices to explicit preset choices. This data is currently hidden and ignored for the first release while the product model is reconsidered as a possible device base profile plus app/source overlay. The store should preserve the friendly device name seen at assignment time so settings remain understandable if device rules are re-enabled later.

### ForegroundAppObserver

Reports the active foreground app by display name and bundle identifier. This should avoid Accessibility permission unless a future requirement needs deeper app inspection.

### BrowserPageObserver

Reports the active website while a supported browser is foreground, but only after the user has opted into website rules. The first implementation supports Safari and Google Chrome active-tab detection through macOS automation APIs, reads only the active tab URL, and fails closed when no supported browser is foreground, the page URL is unavailable, or permission is denied. EqualEase must not query a browser merely because it becomes foreground. The first permission-prompting read is triggered only by the user choosing Use Preset for the current browser page in Rules; background polling may read only when Automation permission is already granted and at least one website rule exists. Polling stops again after the last website rule is cleared. Because EqualEase is sandboxed, browser scripting requires both the Automation usage prompt entitlement and a Safari/Google Chrome Apple Events sandbox allowance. Website rule storage is browser-agnostic: a rule is keyed by normalized website host such as `meet.google.com`, not by browser.

### AppPresetRuleStore

Maps app bundle identifiers to remembered preset choices. Rules are created only after the user accepts an unobtrusive suggestion, not automatically on every preset change. In v1, an app rule changes the one active EQ when that app is foreground; it is not per-source processing for simultaneous app audio streams. The store should preserve the friendly app name seen at assignment time so rule management does not require the app to be frontmost.

### PresetResolutionService

Determines the effective preset using this first-release precedence:

1. Locked preset / paused preset switching.
2. Active website remembered preset, when website rules exist, a supported browser is foreground, and the active tab URL can be read.
3. Foreground app remembered preset.
4. Selected default preset.

Device-specific preset data is currently hidden and ignored while the product model is reconsidered as a possible device base profile plus app/source overlay. This is active-context preset resolution, not multi-stream mixing. Only one preset is effective at a time in v1.

Post-v1, EqualEase should support source-aware preset resolution for simultaneous streams. A “center stage source” mode should let one source use a clear preset while other active sources are routed through a Muffled/background preset, preserving awareness of music or ambient playback without letting it compete with the focused source.

This service should be independent of UI, CoreAudio, and persistence details so it can be unit tested.

## UI design

EqualEase uses a Hybrid menu bar model.

### Menu bar popover

The menu-bar quick panel is a compact, draggable floating surface, similar to Harvest's menu-bar app. It is opened from an `NSStatusItem` and hosted in a small `NSPanel` rather than SwiftUI's anchored `MenuBarExtra`, because the panel should be movable by dragging its background. It is for frequent actions only:

- Show routing state and current real output device.
- Start or stop routing.
- Toggle whether EqualEase is Active. When Active is off, EqualEase stops routing/capturing audio. The menu-bar icon appears muted/dimmed while EqualEase is inactive/off.
- Choose whether to follow the system output or target a specific output.
- Switch presets quickly.
- Offer a subtle inline “Remember this preset for App X?” prompt after a manual preset choice. If dismissed, do not ask again in the same menu-bar window session.
- Hide secondary actions behind a tucked-away gear menu, including Manage EqualEase, About, and Quit.

Full EQ editing, preset management, persistent rule management, diagnostics, recovery, launch-at-login preference, onboarding/permission explanation, and version/about information belong in Settings, not in the menu-bar popover. Runtime controls such as Active, output target, and quick preset selection remain in the menu-bar popover because they affect what EqualEase is doing right now rather than editing saved preferences. DSP bypass is diagnostics-only because it still routes audio through EqualEase and should not be presented as the everyday off switch.

### Settings window

The settings window is for management and editing:

- Full 10-band EQ editor.
- Built-in preset list.
- Custom preset management.
- Output-device selection for routing.
- Remembered app and website preset rules.
- Audio backend/setup diagnostics while the routing path is being productized.

The management window has four tabs: General, Presets, Rules, and Diagnostics. General is the first tab and contains Launch at Login, an optional app-language override, quick-panel visibility preferences, microphone protection, local-network remote pairing, an external automation safety toggle, concise first-use/permission guidance, and Version/About details. Presets lists and edits built-in/custom presets. Rules creates and clears active-app and website preset mappings in one unified list, with website rules shown before app rules because they have higher precedence. The Rules tab shows a user-initiated Use Preset action for the current browser page instead of reading the active browser page automatically; that explicit action is the first point where macOS may ask for Safari or Google Chrome Automation permission and it creates the website rule after a successful read. Device-specific preset rules are hidden and ignored for the first release while the product model is reconsidered as a possible base-device profile plus app/source overlay. Diagnostics shows routing status and development recovery controls. Rules and diagnostics should show recognizable icons where possible: real installed app icons for app rules, a website symbol for website rules, and stable SF Symbol fallbacks for devices based on Core Audio transport type/name. The menu-bar surface remains the quick daily control surface for runtime controls and labels the full window entry “Manage EqualEase…” because the window contains more than preferences. The quick panel refreshes output-device and volume state when opened and stays in sync with external macOS changes while visible. When Active is off, routing-only controls such as Follow system output, output selection, and Preamp are disabled to make the off state visually clear; Preset and Volume remain editable. Custom preset rename/update/delete and persistent app-rule/website-rule management live in the management window so the quick panel does not become a full preference editor.

### General page

The General page should be ordered as:

1. Login: Launch at Login toggle plus short first-use guidance explaining that EqualEase starts in the menu bar and macOS may ask for audio capture permission.
2. Language: a Settings-only app-language picker with System Default plus installed localizations. Language changes apply after quit and reopen; the quick panel does not show language status.
3. Quick Panel, Low Microphone Volume Protection, and Local Network Remote controls for secondary management preferences.
4. External Automation: a default-off toggle controlling whether `equalease://` and AppleScript may change sound settings. When off, automation can read state and select built-in presets, but cannot change Volume, Preamp, Bypass, or custom presets.
5. Support, Privacy, and Version: links plus app version/build and concise app information.

## Automation

EqualEase exposes local automation for personal workflows and external triggers.

The canonical URL scheme is `equalease`. Supported deep links are:

    equalease:///preset/<name>
    equalease:///preamp/<level>
    equalease:///volume/<level>
    equalease:///active/<on|off|toggle>
    equalease:///bypass/<yes|no|toggle>
    equalease:///lock/<on|off|toggle>
    equalease:///lock/on/<name>

Preset names are URL-decoded and matched case-insensitively. Level values are forgiving: preamp accepts `0...2`, `0...200`, or percent strings such as `125%`; output volume accepts `0...1`, `0...100`, or percent strings such as `45%`. Values are clamped to the valid range. For active, `on` starts audio routing, `off` stops audio routing, and `toggle` flips the routing state. For bypass, `yes` means “yes, bypass processing” and `no` means “no, process audio normally”; `on`/`off` are intentionally avoided because they are ambiguous. Bypass is a diagnostics/debug control because it leaves routing/capture active and only disables DSP; everyday on/off automation should use Active. Preset lock temporarily pauses app preset rules and keeps the locked preset effective until unlocked; `lock/on` without a preset name locks the current effective preset. Settings > General includes a default-off automation safety toggle. When disabled, external automation can still read state and select built-in presets, but it cannot alter Active, Volume, Preamp, Bypass, whether app preset switching is paused, or custom presets.

EqualEase also exposes command-style AppleScript terminology through `EqualEase.sdef` for `osascript` and Script Editor. The app supports listing presets, reading the current preset/preamp/volume/active/bypass/preset-lock state, selecting a preset, setting preamp or output volume, setting/toggling active routing, setting/toggling bypass, and locking/unlocking/toggling the preset lock. The implementation uses direct Apple event handlers registered in `EqualEaseAppDelegate` rather than fragile Cocoa Scripting property dispatch, while `EqualEaseAutomation` owns the shared command logic.

Usage examples are documented in `docs/automation.md`.

## Local-network remote control

EqualEase exposes an opt-in paired local-network remote-control path so a phone on the same trusted Wi-Fi can adjust frequent listening controls without turning EqualEase into an audio player. The remote is disabled by default and is enabled from Settings > General > Local Network Remote. When enabled, the remote server is a control-path module owned by the macOS app lifecycle. It binds to `0.0.0.0` on configurable port `8787`, serves public `GET /health`, safe public `GET /info`, a paired phone web remote at `/remote`, and authenticated `WebSocket /ws`.

WebSocket messages use a JSON envelope with `type`, optional `id`, and `payload`. New WebSocket connections start unauthenticated and receive `auth_required`. Before authentication, clients may only ping, pair with a temporary Mac-displayed six-digit code, or authenticate with an existing `clientID` and token. EqualEase rejects unauthenticated state requests, subscriptions, and commands with `auth_error` and does not send detailed state. Authenticated clients can request state snapshots, subscribe for updates, send heartbeat pings, and issue commands for output Volume, Preamp, and Preset switching. The state includes a monotonically increasing `stateVersion` so reconnecting clients can request a fresh snapshot if they detect stale state.

Pairing and client management live in the existing Settings > General > Local Network Remote section. The Mac can start a five-minute single-use pairing code, list paired remotes by display name, revoke one remote, or reset all pairings. Incorrect pairing attempts are rate-limited to make six-digit codes impractical to brute-force. A successful pairing mints a high-entropy token for the phone client and stores only a salted SHA-256 token hash locally under Application Support. Pairing codes and tokens are never returned from `/info`, shown in Settings after initial pairing, or logged. Revoking or resetting removes authorization and causes future reconnects with old credentials to fail.

The phone web remote is deliberately not desktop parity. It uses a pairing-code prompt when needed, stores its client token in browser local storage after successful pairing, reconnects with token authentication, uses large controls for Volume and Preamp, one-tap preset cards, visible connection/current-preset state, no dropdowns for core tasks, and touch handling that avoids accidental vertical page pan while adjusting controls. Full preset editing, app-rule management, diagnostics, and advanced EQ editing remain in the native Mac app.

This is same-LAN protection for trusted local networks, not a cloud/account security model. The local remote still uses unencrypted `http://` and `ws://`; do not expose it to untrusted networks or the internet. Details and manual validation live in `docs/local-network.md`.

## Updates

Mac App Store builds receive updates through the App Store. EqualEase should not include a separate in-app updater in App Store builds.

## Local install

For daily-use testing before a public package exists, use `scripts/install-local.sh` to build EqualEase and replace `/Applications/EqualEase.app`. The script should quit any running instance, copy the fresh app bundle, register it with Launch Services, and launch it. This makes app icon caching, `equalease://` URL handling, AppleScript terminology, and Launch at Login behave closer to a normal installed app than a DerivedData build.

## Persistence

Settings should live under the app's Application Support directory. The format should be easy to inspect during development. Prefer a simple, stable, human-inspectable format where practical; Swift ecosystem support may make JSON practical for the first release.

Corrupt or missing settings should fall back to safe defaults:

- Active off, DSP bypass, or Flat preset.
- No app rules.
- Ignored/hidden device preset rules for the first release.
- Built-in presets restored from code.

## Failure modes

EqualEase must avoid trapping the user in broken audio routing.

Expected safe behavior:

- If EQ processing fails, stop routing, bypass DSP, or restore Flat.
- If routing fails, show clear status in the UI, including underlying Core Audio start status when available.
- If settings are corrupt, reset to defaults and keep a recoverable error note.
- If the selected real device disappears, choose the current macOS default output or ask the user to select another device.

## Testing strategy

Unit-test business logic first:

- Preset resolution precedence, including app-rule fallback to the selected default preset without mutating that default.
- Built-in preset immutability.
- Custom preset CRUD.
- Paused device-rule behavior.
- App rule behavior.

Integration and manual tests must prove real audio behavior:

- Route system audio through EqualEase.
- Play audio from at least two unrelated apps.
- Switch Flat to an obvious preset and hear a difference.
- Validate a speech-focused preset with call-like spoken audio, not only music.
- Change output device and verify the expected preset applies.
- Accept an app-specific prompt and verify it applies when returning to that app.
