# EqualEase automation

EqualEase exposes two local automation surfaces for development and personal workflows:

- `equalease://` deep links for URL-based triggers.
- AppleScript commands for `osascript` and Script Editor.

These controls operate on the running app model. If EqualEase is not running, macOS launches it before delivering the URL or Apple event.

External writes are controlled by **Settings > General > Allow automation to change sound settings**. The setting is off by default. When it is off, automation can still read state and select built-in presets, but it cannot change Active, Volume, Preamp, Bypass, whether app preset switching is paused, or custom presets.

## Deep links

The canonical URL scheme is `equalease`.

Supported links:

```text
equalease:///preset/<name>
equalease:///preamp/<level>
equalease:///volume/<level>
equalease:///active/<on|off|toggle>
equalease:///bypass/<yes|no|toggle>
equalease:///lock/<on|off|toggle>
equalease:///lock/on/<name>
```

Examples:

```sh
open 'equalease:///preset/Call%20Clarity'
open 'equalease:///preamp/90'
open 'equalease:///preamp/0.9'
open 'equalease:///preamp/125%25'
open 'equalease:///volume/45'
open 'equalease:///volume/0.45'
open 'equalease:///volume/33%25'
open 'equalease:///active/on'     # start EqualEase routing
open 'equalease:///active/off'    # stop EqualEase routing
open 'equalease:///active/toggle'
open 'equalease:///bypass/yes'    # bypass processing without stopping routing
open 'equalease:///bypass/no'     # process audio normally
open 'equalease:///bypass/toggle'
open 'equalease:///lock/on'       # lock the current effective preset
open 'equalease:///lock/on/Warm'  # lock Warm and pause app preset rules
open 'equalease:///lock/off'      # resume normal app preset rules
open 'equalease:///lock/toggle'
```

Preset names are URL-decoded and matched case-insensitively. Preset IDs also work. If automation writes are disabled in Settings > General, preset links can only select built-in presets.

Level parsing is intentionally forgiving:

- Preamp accepts `0...2`, `0...200`, or percent strings such as `125%`.
- Volume accepts `0...1`, `0...100`, or percent strings such as `45%`.
- Values are clamped to the supported range.

Active, preamp, volume, bypass, and preset-lock links require automation writes to be enabled in Settings > General.

Use Active for normal on/off automation:

- `on` starts EqualEase audio routing.
- `off` stops EqualEase audio routing.
- `toggle` flips the current routing state.

When Active is off, EqualEase stops routing/capturing system audio. The native macOS purple recording indicator goes away after routing stops.

Preset lock values answer the question “lock the current preset?”:

- `on` means lock the named preset, or the current effective preset when no name is provided.
- `off` means unlock and resume normal app preset rules.
- `toggle` flips the current lock state. When toggling on, EqualEase locks the current effective preset.

Bypass values answer the question “bypass processing?”:

- `yes` means processing is bypassed.
- `no` means audio is processed normally.
- `toggle` flips the current bypass state.

`on` and `off` are intentionally not documented or accepted for bypass because they can mean either “bypass is on/off” or “processing is on/off”. Bypass is a diagnostics/debug control: it leaves EqualEase routing active but makes the DSP do nothing. Because routing stays active, macOS may still show the purple recording indicator while bypass is enabled. For Shortcuts, scripts, or launchers that should switch EqualEase itself on or off, use the Active URL instead.

## AppleScript / osascript

EqualEase provides command-style AppleScript terminology.

```applescript
tell application "EqualEase"
    list presets
    current preset name
    select preset "Call Clarity"

    current preamp level
    set preamp level 90
    set preamp level "125%"

    current output volume
    set output volume 45
    set output volume "33%"

    active state
    set active "on"
    set active "off"
    set active "toggle"
    toggle active

    bypass state
    set bypass "yes" -- bypass processing
    set bypass "no" -- process audio normally
    set bypass "toggle"
    toggle bypass

    preset lock state
    lock preset -- lock the current effective preset
    lock preset "Warm"
    unlock preset
    toggle preset lock
end tell
```

Shell examples:

```sh
osascript -e 'tell application "EqualEase" to list presets'
osascript -e 'tell application "EqualEase" to select preset "Warm"'
osascript -e 'tell application "EqualEase" to current preset name'
osascript -e 'tell application "EqualEase" to set preamp level 90'
osascript -e 'tell application "EqualEase" to current preamp level'
osascript -e 'tell application "EqualEase" to set output volume 45'
osascript -e 'tell application "EqualEase" to current output volume'
osascript -e 'tell application "EqualEase" to set active "on"'
osascript -e 'tell application "EqualEase" to set active "off"'
osascript -e 'tell application "EqualEase" to active state'
osascript -e 'tell application "EqualEase" to toggle active'
osascript -e 'tell application "EqualEase" to set bypass "yes"'
osascript -e 'tell application "EqualEase" to set bypass "no"'
osascript -e 'tell application "EqualEase" to bypass state'
osascript -e 'tell application "EqualEase" to toggle bypass'
osascript -e 'tell application "EqualEase" to lock preset'
osascript -e 'tell application "EqualEase" to lock preset "Warm"'
osascript -e 'tell application "EqualEase" to preset lock state'
osascript -e 'tell application "EqualEase" to unlock preset'
osascript -e 'tell application "EqualEase" to toggle preset lock'
```

`list presets` returns an AppleScript list of preset names. In shell output, `osascript` prints it as a comma-separated line.

When automation writes are disabled in Settings > General:

- Read commands still work.
- `select preset` only works for built-in presets.
- `set active`, `toggle active`, `set preamp level`, `set output volume`, `set bypass`, `toggle bypass`, `lock preset`, `unlock preset`, and `toggle preset lock` return an AppleScript error.

## Notes

EqualEase handles custom AppleScript commands through explicit Apple event handlers. That keeps automation reliable in the SwiftUI/AppKit app while still exposing normal `osascript` terminology from `EqualEase.sdef`.
