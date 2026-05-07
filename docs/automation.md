# EqualEase automation

EqualEase exposes two local automation surfaces for development and personal workflows:

- `equalease://` deep links for URL-based triggers.
- AppleScript commands for `osascript` and Script Editor.

These controls operate on the running app model. If EqualEase is not running, macOS launches it before delivering the URL or Apple event.

External writes are controlled by **Settings > General > Allow automation to change sound settings**. The setting is off by default. When it is off, automation can still read state and select built-in presets, but it cannot change Volume, Preamp, Bypass, or custom presets.

## Deep links

The canonical URL scheme is `equalease`.

Supported links:

```text
equalease:///preset/<name>
equalease:///preamp/<level>
equalease:///volume/<level>
equalease:///bypass/<yes|no|toggle>
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
open 'equalease:///bypass/yes'    # bypass processing
open 'equalease:///bypass/no'     # process audio normally
open 'equalease:///bypass/toggle'
```

Preset names are URL-decoded and matched case-insensitively. Preset IDs also work. If automation writes are disabled in Settings > General, preset links can only select built-in presets.

Level parsing is intentionally forgiving:

- Preamp accepts `0...2`, `0...200`, or percent strings such as `125%`.
- Volume accepts `0...1`, `0...100`, or percent strings such as `45%`.
- Values are clamped to the supported range.

Preamp, volume, and bypass links require automation writes to be enabled in Settings > General.

Bypass values answer the question “bypass processing?”:

- `yes` means processing is bypassed.
- `no` means audio is processed normally.
- `toggle` flips the current bypass state.

`on` and `off` are intentionally not documented or accepted because they can mean either “bypass is on/off” or “processing is on/off”.

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

    bypass state
    set bypass "yes" -- bypass processing
    set bypass "no" -- process audio normally
    set bypass "toggle"
    toggle bypass
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
osascript -e 'tell application "EqualEase" to set bypass "yes"'
osascript -e 'tell application "EqualEase" to set bypass "no"'
osascript -e 'tell application "EqualEase" to bypass state'
osascript -e 'tell application "EqualEase" to toggle bypass'
```

`list presets` returns an AppleScript list of preset names. In shell output, `osascript` prints it as a comma-separated line.

When automation writes are disabled in Settings > General:

- Read commands still work.
- `select preset` only works for built-in presets.
- `set preamp level`, `set output volume`, `set bypass`, and `toggle bypass` return an AppleScript error.

## Notes

EqualEase handles custom AppleScript commands through explicit Apple event handlers. That keeps automation reliable in the SwiftUI/AppKit app while still exposing normal `osascript` terminology from `EqualEase.sdef`.
