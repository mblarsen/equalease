# Spike: persistent volume for audio without an app identity

- Issue: [#21](https://github.com/mblarsen/equalease/issues/21)
- Date: 2026-07-21
- Test environment: macOS 26.4.1 (25E253), Apple silicon, Xcode/macOS SDK 26.4
- Status: complete

## Recommendation

**No-go for shipping an “unidentified audio only” control with the inverted-fallback design.**

A permanently configured fallback can attenuate a new bundle-less source such as `say` from its first captured sample without discovering that source or rebuilding the route. The problem is the other half of the partition: Core Audio has no public tap predicate meaning “processes that have a bundle identifier.” EqualEase must maintain an explicit list of identified processes or bundle identifiers. A never-before-seen identified app therefore enters the fallback until EqualEase classifies it, and Core Audio does not attach a process identity to buffers after streams have been mixed.

The tested machine usually exposed a new process object before its first tapped sample, but that timing is not a contract. Active `kAudioTapPropertyDescription` writes also returned `kAudioDevicePermissionsError` (`'!hog'`) in the signed probe, so this environment could not move a newly discovered process between live taps without recreating routing objects. Even where live description updates work, updating complementary taps is asynchronous and cannot be atomic.

These limitations fail #21’s strict acceptance criterion that identified apps must never receive temporary fallback attenuation. Rebuilding taps when ordinary apps appear would also reverse the routing-stability gains from [#15](https://github.com/mblarsen/equalease/issues/15).

**Keep the current behavior for production:** sources without an app identity receive global EQ/preamp through the unity fallback, but no independent volume.

A safe, much smaller feature is possible only with different semantics: apply a persisted gain to the current fallback and call it **All Other Audio**. That would include every app without a dedicated tap, not only sources macOS cannot identify. This is a product-scope decision, not an implementation detail, and should not be shipped under the “Other Audio” definition from #21 without explicit approval.

## Scope and non-goals

This spike evaluated the route and state model. It did not add production UI, persistence, or localized copy.

Throwaway probes lived under `/tmp`, were not added to the Xcode project, and are intentionally absent from the final commit. The probes used only public Core Audio, Foundation, AppKit, and AVFAudio APIs.

## Current behavior

EqualEase currently has:

1. One dedicated inclusive tap for every actively emitting, bundle-identified app with non-default per-app settings.
2. One exclusive fallback tap that excludes those dedicated processes and EqualEase itself.
3. One `StreamConfig` per tap, in aggregate tap-list order.
4. A fail-safe IOProc that applies stream configs only when the observed buffer layout unambiguously matches the expected stream count.

`AudioProcessDiscovery` filters out empty bundle identifiers. That affects display and dedicated-tap creation, not audibility: bundle-less output remains in the fallback and receives global EQ/preamp at unity per-source gain.

Current routing churn is deliberately bounded:

- discovery polls every 2 seconds;
- new customized app taps require two discovery generations;
- removed customized taps remain sticky for about 8 seconds;
- route-list changes are debounced by 200 ms;
- ordinary/default apps never rebuild the route.

## Public API findings

### What Core Audio supports

`CATapDescription` can describe:

- an inclusive mix of explicit process object IDs;
- an exclusive global mix that excludes explicit process object IDs;
- on macOS 26, explicit bundle IDs;
- multiple processes mixed into one stereo stream.

`kAudioTapPropertyDescription` is documented as the description used to create a tap and as a property that can modify an existing tap. Chromium also uses this public property to refresh process membership for application capture.

`kAudioHardwarePropertyProcessObjectList` supports property listeners, so discovery need not rely only on a 2-second poll.

### What Core Audio does not support

No public API used by EqualEase provides:

- a tap predicate for “has a bundle identifier” or “does not have a bundle identifier”;
- per-process gain on `AudioHardwareProcess`;
- a process ID attached to each buffer after multiple processes have been mixed into one tap stream;
- an atomic transaction that changes two complementary tap descriptions together;
- a public guarantee that process-list notification precedes the first audio sample.

`kAudioProcessPropertyIsRunningOutput` is an observation, not a routing gate. In the probes it became true after tapped audio had already started for the deterministic bundled emitter.

### Tap-membership mutation result

The signed probe used the same bundle/team identity as EqualEase and matching relevant sandbox/audio-input entitlements. It successfully created two taps, received their PCM data, and observed a stable two-stream aggregate. However, setting `kAudioTapPropertyDescription` on either active tap—including setting an unchanged description—returned `560492391`, which is `kAudioDevicePermissionsError` (`'!hog'`) on macOS 26.4.1.

The public property and Chromium implementation justify keeping live mutation as a future test seam, but this result means it is not a dependable production assumption for EqualEase on the tested configuration. Recreating the tap/aggregate remains the only demonstrated membership-change path here.

## Dynamic probe design

The main probe created a private aggregate containing two stereo taps:

1. `identified`: inclusive tap, configured with an explicit known test bundle ID when required;
2. `other`: exclusive global tap, excluding EqualEase and the same known bundle ID.

Both taps were unmuted capture probes, so they did not alter normal playback. The aggregate IOProc recorded:

- input-buffer shape and stream order;
- first non-zero sample time per stream;
- non-zero sample count;
- callback count;
- peak input magnitude;
- process-list notification time;
- live description-write status and duration.

A deterministic AVAudioEngine test bundle emitted a 48 kHz stereo sine wave with a 10 ms attack. Separate bundles represented a preconfigured identity and a previously unseen identity. Short and long `/usr/bin/say` commands covered bundle-less command audio.

A second probe sampled `kAudioHardwarePropertyProcessObjectList` at 1 ms while also registering its property listener. It measured process-object and `isRunningOutput` timing without relying on EqualEase’s current 2-second poll.

## Measurements

### Process classification timing

Times are relative to successful child-process launch.

| Source | First process object | First `isRunningOutput == true` | Identity |
|---|---:|---:|---|
| `say` short, run 1 | 33.742 ms | 2342.455 ms | empty bundle ID, no Core Audio name |
| `say` short, runs 2–5 | 31.898–33.667 ms | 1159.902–1426.724 ms | empty bundle ID, no Core Audio name |
| `say` long | 37.410 ms | 1446.381 ms | empty bundle ID, no Core Audio name |
| `afplay`, three runs | 32.578–47.022 ms | 200.672–221.829 ms | empty bundle ID, no Core Audio name |
| bundled emitter, cold | 488.038 ms | 767.801 ms | expected bundle ID, no Core Audio name |
| bundled emitter, warm runs | 52.878–73.149 ms | 331.028–393.734 ms | expected bundle ID, no Core Audio name |

On this machine, both `say` and `afplay` are bundle-less Core Audio sources and therefore use EqualEase’s fallback. A 2-second raw process poll could observe some long invocations, but production discovery discards their empty bundle IDs. Even if retained, a two-generation confirmation plus route restart could not affect the beginning and could miss a short sound entirely. An event-driven listener is much faster, but `isRunningOutput` is too late to be the boundary for sample-accurate classification.

### Stream mapping and first-sample capture

Every two-tap run reported two interleaved stereo input buffers in tap-list order: `buffers=2`, `channels=(2, 2)`.

| Scenario | Identified stream | Other stream | Result |
|---|---:|---:|---|
| Known bundled emitter preconfigured by bundle ID | first audio 578.996–791.539 ms; 38,318 non-zero samples; peak 0.2 | zero samples | Complete deterministic tone stayed in the identified stream. |
| Short `say` | zero samples | first audio 1776.966–2529.559 ms; 29,802 non-zero samples; peak 0.84228 | Complete observed speech stayed in the always-present other stream without a route rebuild. |
| Previously unseen bundled emitter | zero samples | first audio 244.257–337.706 ms; about 95,800 non-zero samples; peak 0.2 | It entered the fallback because it was not preconfigured and live membership writes failed. |

The stream ordering matched the aggregate tap-list assumption across repeated cold/warm source launches. This supports the current mapping model but does not replace the existing ambiguity fail-safe.

### Membership update and churn

For the previously unseen bundled emitter:

- process-list notification arrived about 61–90 ms after launch;
- the two description writes took about 3.2–10.1 ms in total;
- the writes were separated by about 164–272 µs;
- both writes failed with `kAudioDevicePermissionsError`;
- first fallback audio arrived about 244–338 ms after launch;
- the aggregate itself was not recreated during the three-source run.

The observed notification happened before first audio in these runs. That is encouraging but insufficient for a no-leak guarantee. A cold run also showed process-object publication can vary by hundreds of milliseconds.

### Gain behavior

The existing IOProc applies a stream’s persisted multiplier before mixing and global EQ. Therefore a fallback config present before playback affects the first captured callback. Applying the proposed 25% gain to measured probe peaks gives:

- deterministic emitter: `0.200000 → 0.050000`;
- short `say`: `0.842280 → 0.210570`.

No source discovery or route mutation is required for that attenuation. This validates the key strength of both the inverted fallback and the simpler “All Other Audio” fallback approach.

## Primary approach: inverted fallback

### Proposed shape

A production version would need:

1. one stable identified/default-app group tap at unity gain;
2. one stable exclusive fallback at the persisted Other Audio gain;
3. existing dedicated taps for customized apps;
4. identical explicit exclusions across the group/fallback/dedicated partitions;
5. event-driven observation of all connected Core Audio processes, separate from the running-output list shown in UI.

An identified group can efficiently mix many explicit process IDs into one stereo stream. Its stream count stays constant as membership changes, so successful in-place description updates would avoid aggregate reconstruction and preserve stream indices.

### Why it does not meet the acceptance criteria

- The partition is explicit, not predicate-based. A new identified process is indistinguishable from Other Audio until classified.
- A persisted list of previously seen bundle IDs can improve repeat launches, but cannot cover the first launch of every app/helper.
- Crawling installed app bundles is incomplete, expensive, sandbox-sensitive, and cannot cover dynamic helpers reliably.
- `processRestoreEnabled` can restore previously known bundle-backed processes, but does not solve first encounter.
- Updating the inclusive and exclusive descriptions requires separate asynchronous writes. Updating inclusive first risks overlap/duplicate mixing; updating exclusive first risks a gap. There is no public cross-tap transaction.
- Live description mutation failed on the tested EqualEase configuration.
- Recreating taps/aggregate devices on ordinary app churn reintroduces the dropout class addressed by #15.

**Verdict: no-go for the strict feature.**

## Alternatives

### A. Discover bundle-less processes and create a group tap

**No-go.**

- The setting can persist before a source exists, but the tap cannot include an unknown process object ID.
- Current polling plus confirmation is slower than short `say` audio.
- Even event-driven process discovery requires tap membership mutation after launch.
- Ephemeral process appearance/removal would create route churn or stale membership.
- This directly conflicts with #15’s policy of ignoring ordinary source churn.

It may affect the tail of long-running unidentified audio, but it cannot satisfy “from the beginning.”

### B. Apply gain directly to the current fallback

**Technically go; product-semantics decision required.**

- No new tap.
- No new stream.
- No source classification.
- No source-driven route restart.
- `say` is attenuated from its first captured callback.
- Existing customized app taps remain independent.

The cost is semantic: every default/unmodified app is also in the fallback. The honest name would be **All Other Audio**, with help explaining that it includes apps without individual settings plus audio macOS cannot associate with an app.

This is the safest option relative to #15, but it is not the feature #21 currently specifies.

### C. Route selected commands through a bundled helper

**Go only for an explicit EqualEase CLI integration; no-go as a general solution.**

The known-bundle probe captured the entire deterministic tone in the preconfigured identified stream. A bundled helper can therefore have persistent settings before it emits audio. It cannot automatically intercept arbitrary `say`, `afplay`, shell scripts, system helpers, or third-party command tools. It also adds installation, invocation, lifecycle, sandbox, and support work.

### D. Virtual device or custom driver classification

**No-go for this feature.**

A custom driver could own a richer client/mixing model, but it materially increases signing, installation, App Store review, recovery, and maintenance risk. The benefit is disproportionate to one volume group, and the driver would still need a robust definition of “identified.”

### E. Keep current behavior

**Recommended now.**

- Zero new routing risk.
- Preserves #15 and current fail-safe mapping.
- Bundle-less sources still receive global EQ/preamp.
- Does not provide independent attenuation.

## Interaction with routing stability issue #15

| Approach | Source-driven restarts | Mapping impact | #15 assessment |
|---|---:|---|---|
| Inverted fallback with reliable live membership writes | 0 expected | stable base stream count, membership changes inside streams | Better than recreation, but classification race and non-atomic writes remain. Not demonstrated on tested machine. |
| Inverted fallback with tap recreation | frequent for ordinary identified app churn | repeated tap/aggregate epochs | Unacceptable regression. |
| Bundle-less dedicated group tap | frequent for ephemeral CLI sources | group membership/tap lifecycle churn | Unacceptable regression and still misses beginnings. |
| Direct gain on current fallback | 0 | unchanged | Safest. |
| Bundled helper preconfigured by bundle ID | 0 for helper launches | one stable known membership | Safe but narrow. |
| Keep current behavior | 0 | unchanged | Current baseline. |

Any future implementation must retain the current rule that an ambiguous input layout uses unity per-stream behavior rather than applying a group gain to the wrong stream.

## User-facing naming and control direction

For the strict concept, use **Other Audio**.

Recommended help text direction:

> Audio macOS can’t associate with an app, such as sounds started by Terminal commands.

Avoid:

- **Background Audio** — these sources are not necessarily in the background and the term conflicts with future center-stage/background processing.
- **System & Other Audio** — “system” overpromises treatment of alerts and helpers whose Core Audio identity varies.
- technical terms such as bundle-less, unidentified, process, PID, or CLI in the primary label.

If the product instead accepts alternative B, use **All Other Audio** and explicitly describe the wider membership.

For a first implementation:

- make the row permanent so the setting exists before sound starts;
- place it after normal app rows;
- expose volume only;
- use 0% as silence rather than adding Process/Bypass/Mute semantics before the group boundary is trustworthy;
- keep persistence independent from bundle-keyed app settings;
- do not use a synthetic bundle identifier.

## Localization scope

EqualEase currently ships `en`, `da`, `de`, `es`, and `ne`. A production implementation must add and review every new string in all five locales.

Expected string scope:

- row label (`Other Audio` or `All Other Audio`);
- concise explanatory/help text;
- accessibility label for the volume control;
- accessibility value containing the localized percentage;
- diagnostics role/status text;
- optional empty/active state only if the UI exposes activity.

Add a translator note to `docs/i18n.md` defining membership and warning that “Other” is an audio-source grouping, not background playback. Preserve runtime percentages and app names. Verify truncation, VoiceOver, and panel height in every shipped locale.

No production strings were added by this spike.

## Production implementation plan

### Gate 1: choose semantics

Before implementation, explicitly choose one:

1. **Strict Other Audio:** wait; current public APIs do not meet the no-leak acceptance criterion.
2. **All Other Audio:** implement direct fallback gain and accept that uncustomized identified apps are included.
3. **EqualEase CLI Audio:** implement a bundled helper for opt-in commands only.

### If “All Other Audio” is approved

1. Add an independently named persisted setting, for example `otherAudioVolume`, to the app-volume persistence schema with unity migration default.
2. Replace positional “fallback” assumptions with an explicit stream role (`dedicatedApp`, `allOtherAudio`) in route configuration and diagnostics.
3. Pass the persisted gain into the existing fallback `StreamConfig`; update it live without route restart.
4. Add the permanent volume-only row after app rows; do not add speculative Process/Bypass UI.
5. Keep ambiguous stream-layout behavior at unity and emit a diagnostic that group gain was not applied.
6. Update `docs/audio-routing.md`, `docs/testing.md`, and `docs/i18n.md` with the final approved semantics.
7. Validate simultaneous customized, default, and bundle-less sources before shipping.

### If strict “Other Audio” is revisited

First build a non-shipping routing harness that proves all of the following on supported hardware:

- active description writes succeed with the production-signed app;
- tap membership changes do not require aggregate restart;
- a never-before-seen bundled emitter never produces a fallback sample across hundreds of cold launches;
- complementary updates produce neither overlap nor gaps;
- custom tap add/remove and output-device changes remain safe;
- stream role/order stays authoritative across every epoch.

Failure of any item keeps the feature no-go.

## Automated-test seams

A future change should introduce these testable seams before UI:

- Pure `AudioSourcePartition` input: process object ID, optional bundle ID, own/customized flags.
- Pure output: dedicated app taps, identified-group membership, fallback exclusions, stable role order.
- Injected process-list observer separate from the UI’s running-output discovery.
- Host operation for live tap-description updates returning typed status and membership generation.
- Router policy deciding `update in place`, `restart`, or `keep current route safely`.
- Persistence round-trip and migration tests for the independent group setting.
- Stream-mapping tests with `N` dedicated streams plus stable base streams in interleaved, channel-split, missing, extra, and mixed layouts.
- Tests proving gain/mute updates do not alter tap membership or restart the route.
- Tests proving membership-write failure retains safe unity behavior and reports diagnostics.
- Tests proving default app churn remains restart-free.

Hardware/TCC integration tests should use the deterministic signed emitter plus `say`; they should remain separate from deterministic unit tests.

## Manual QA additions for an approved implementation

### Classification and gain

- The permanent row exists before matching audio starts.
- Short `say "test"` is controlled from its first audible sample.
- A long `say` sentence remains at one consistent level.
- `afplay` classification is recorded rather than assumed.
- Two simultaneous bundle-less sources receive the same gain.
- A never-before-seen bundled test app starts at unity while Other Audio is 20–25%.
- A previously seen bundled app also starts at unity.
- Continuous Safari/Spotify audio remains unchanged before, during, and after `say`.
- Customized app Volume, Process/Bypass, and Mute remain independent.
- 100% matches current fallback behavior.
- macOS alerts and system helpers are tested and the observed result matches help text.

### Routing safety

- Run at least 30 short commands; source churn causes no route restart.
- Launch/quit ordinary bundled audio apps repeatedly; no gain leak, gap, duplicate playback, or restart.
- Add/remove a customized app while Other Audio is active.
- Repeat Active on/off three times while `say` is active.
- Switch outputs while identified and Other Audio play simultaneously.
- Quit/relaunch preserves the setting.
- Cleanup leaves no stale taps or aggregate devices.
- Ambiguous mapping logs a fail-safe and never applies the group gain to a possibly wrong stream.

### UI, accessibility, and localization

- Verify the final label/help without technical vocabulary.
- Verify VoiceOver label and percentage announcement.
- Verify keyboard adjustment and 0%/100% states.
- Verify maximum quick-panel height with many app rows.
- Verify `en`, `da`, `de`, `es`, and `ne` for meaning and truncation.

## Proposed follow-up scope (not filed)

No implementation issue was created because #21 requires explicit approval first.

If **All Other Audio** semantics are approved, the proposed follow-up issue should contain:

- independent persistence and migration;
- explicit fallback stream role and live gain propagation;
- permanent volume-only row and accessibility copy;
- five-locale string updates;
- deterministic router/persistence/mapping tests;
- signed hardware probe and the manual QA checklist above;
- explicit non-goals: strict unidentified-only classification, per-source EQ, helper CLI, and driver work.

## References

- Apple: [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
- Apple: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- Apple SDK 26.4: `AudioHardware.h` documentation for `kAudioHardwarePropertyProcessObjectList`, `kAudioTapPropertyDescription`, and process properties
- Chromium: [live CATap process-membership refresh](https://chromium.googlesource.com/chromium/src/+/dce12943222d8748a846b55f1c6e08707f0cfb9c/media/audio/mac/catap_audio_input_stream.mm)
- EqualEase routing stability: [#15](https://github.com/mblarsen/equalease/issues/15), [PR #20](https://github.com/mblarsen/equalease/pull/20)
