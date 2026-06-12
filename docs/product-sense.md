# Product Sense

## Origin

The name `EqualEase` combines “equalizer” and “ease”: an equalizer that makes everyday Mac audio easy to manage. The motivating use case is practical and human: everyday Mac audio often needs quick adjustment, whether a call is hard to understand, laptop speakers sound thin, headphones need tuning, or external speakers need a saved setup.

## Product promise

EqualEase is the equalizer your Mac is missing.

It gives people one simple place to adjust everyday Mac audio. The app should make it easy to tune laptop speakers, headphones, external speakers, or a sound system for better music, clearer calls, and fewer “why does this sound bad?” moments.

EqualEase is intentionally focused, not prototype-small. It is a real Mac app with a simple product promise: live in the menu bar, work system-wide, and keep audio controls understandable.

The app is not a music player and does not own audio content. Its job is to sit between macOS system audio and the real output device, apply EQ, expose practical volume and preset controls, and make switching sound setups feel like a natural part of macOS.

## Target user

The first users are Mac owners who want everyday audio control without becoming audio engineers. They may use MacBook speakers, AirPods, wired headphones, desktop speakers, HDMI, or a living-room sound system. They care about quick fixes and saved setups more than technical EQ theory.

During development, local builds are useful for testing real audio behavior. That is an implementation reality, not the product stance. User-facing language should present EqualEase as a focused Mac app, not as “just an MVP” or a developer prototype.

## First-release priorities

1. Real system-wide audio processing.
2. One menu bar control for everyday Mac audio.
3. Quick access to output volume, input volume, presets, EQ, and routing.
4. Native macOS menu bar experience that stays out of the way.
5. Simple 10-band graphic EQ.
6. Built-in presets that make sense, plus custom presets for the user's own speakers, headphones, and listening setups.
7. Low microphone volume protection so call input problems are visible before other people cannot hear the user.
8. Optional local-network remote control for simpler real-time interaction from a phone.
9. Smart app and Safari website switching that learns from the user's choices.
10. App Store builds use App Store updates rather than a separate in-app updater.

## Product principles

### System-wide or it does not count

EqualEase must process audio from arbitrary Mac apps such as browsers, Slack, Spotify, games, video players, and system sounds. An app-local player equalizer is out of scope because it does not solve the missing-Mac-equalizer problem.

### Everyday controls first

The app should emphasize controls people reach for often: output volume, input volume, presets, EQ, active state, and output routing. Advanced audio concepts should stay secondary. A user should not need to understand audio engineering vocabulary to improve how their Mac sounds.

### Native beats clever

Permission prompts, helper authorization, and virtual audio setup are acceptable when required, but the app should explain them clearly and integrate with macOS conventions. Avoid flows that require the user to remember fragile terminal commands for normal daily use.

### First-release rules stay simple

Device-specific preset rules are paused for the first release. Output-device selection still controls where processed audio is sent, but presets are resolved from active-website rules, active-app rules, and the selected default preset only. Persisted device-rule code/data can remain internally while the product model is reconsidered as a possible device base profile plus app/source overlay.

Preset precedence for the first release is:

1. Locked preset / paused preset switching.
2. Remembered active-website preset when the user has created website rules, Safari is foreground, and the active tab URL can be read.
3. Remembered active-app preset.
4. Selected default preset.

### Smart switching should be learned, not magical

The app should not ship built-in app or website rules. Instead, when the user selects a preset while an app or explicitly selected website is active, EqualEase may unobtrusively suggest remembering that choice, similar in spirit to macOS remembering keyboard input source per app. Website detection should be user-initiated first: EqualEase should not ask Safari for the active page until the user chooses to select the current web page in Rules.

For v1, app rules switch the single active EQ based on the foreground app. They do not apply separate EQ curves to simultaneous background audio sources. For example, if Spotify plays in the background while Safari is foreground, Safari's active-app rule can win over Spotify's rule. When no active-app rule matches, EqualEase returns to the selected default preset rather than keeping the previous app's preset active.

The more correct long-term behavior is still per-source simultaneous EQ, where different apps can keep different EQ curves at the same time. That is intentionally deferred until after v1 because it likely needs separate process taps or source-aware mixing.

A future “center stage source” mode should build on per-source EQ: one chosen source, such as a call app, stays clear and centered while other sources keep playing but are automatically softened with a muffled/background preset. This should let music or ambient audio remain audible without competing with the source the user is trying to understand.

### Make calls safer without making calls the whole product

Voice clarity matters, and the app should help when a call sounds bad or the microphone input drops. But EqualEase should not be marketed as only a speech-clarity tool. Presets, labels, and validation should cover music, videos, speakers, headphones, and calls.

### Keep the first EQ understandable

The first release exposes a 10-band graphic EQ. Parametric EQ, AutoEQ import, and advanced filter editing can come later after the system-wide audio path and product model are stable.

## Licensing and availability stance

EqualEase is source-available for free personal and non-commercial use. People who are willing to build it themselves may do so without paying for the app. The public source license should not grant permission for someone else to copy EqualEase, sell it, or commercially redistribute a modified version.

The Mac App Store version is the convenient packaged release controlled by the copyright holder. This source-available stance is not OSI open source; it is a product choice that keeps self-built personal use free while reserving commercial rights.

## Not in the first release

- In-app audio playback.
- Built-in preset rules for specific third-party apps.
- Advanced parametric EQ UI.
- Per-source simultaneous EQ for multiple apps at once.
- Cloud sync.
- Multi-user preference sync.
- Separate in-app update mechanisms for App Store builds. App Store builds use App Store updates.
