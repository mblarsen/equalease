# EqualEase Local Network Remote Control

EqualEase can run a local-network remote control server so a phone on the same trusted Wi-Fi can adjust the Mac app's system-wide audio controls. The Mac remains the source of truth for audio routing, EQ processing, presets, pairing, and app lifecycle.

The remote is disabled by default. Enable it from Settings > General > Local Network Remote only on a trusted local network.

## Pairing and authentication

Remote control uses local pairing, not accounts or cloud access:

1. On the Mac, open Settings > General > Local Network Remote.
2. Enable “Allow phone remote control on the local network.”
3. Click “Pair New Remote…” to show a temporary six-digit code.
4. Open `http://<mac-lan-ip>:8787/remote` on the phone.
5. Enter the code shown on the Mac.

A valid code creates a paired-client token for that browser. The browser stores the token in local storage and uses it to authenticate future WebSocket reconnects. EqualEase stores only a salted hash of the token in `Application Support/EqualEase/local-network-auth.json`; it does not store reusable plaintext tokens.

Pairing codes are held in memory only, expire after about five minutes, are single-use, and are protected by short retry limits for incorrect attempts. The token is returned only once during pairing. Tokens, token hashes, and pairing codes are not exposed in `/health`, `/info`, Settings, or logs after initial pairing.

Settings > General > Local Network Remote lists paired remotes by display name. Use “Revoke” to invalidate one remote, or “Reset Pairings” to remove all paired remotes and cancel any active pairing code. Revoked/reset clients must pair again; future `auth` messages with old credentials fail.

This is same-LAN protection for trusted Wi-Fi, not internet-grade security. The first implementation uses `ws://`/`http://` without TLS. Do not expose it to untrusted networks or the internet.

## Server endpoints

After enabling Settings > General > Local Network Remote, the default configuration is:

- Bind address: `0.0.0.0`
- Port: `8787`
- HTTP base URL: `http://<mac-lan-ip>:8787`
- WebSocket URL: `ws://<mac-lan-ip>:8787/ws`

Endpoints:

- `GET /health` returns minimal public reachability JSON and does not require authentication.
- `GET /info` returns safe public connection metadata: app name/version, protocol version, WebSocket path, selected port, and server instance ID.
- `GET /` or `GET /remote` serves the paired phone web remote.
- `WebSocket /ws` carries authenticated JSON control/state messages.

EqualEase logs the Mac’s primary reachable HTTP and WebSocket URLs at startup for manual testing, but never logs pairing codes or tokens. It intentionally avoids listing link-local and virtual adapter addresses that a phone on the same Wi-Fi usually cannot use.

## WebSocket protocol

Every WebSocket text frame is UTF-8 JSON with this envelope:

```json
{ "type": "message_type", "id": "optional-request-id", "payload": {} }
```

On connect, EqualEase sends `auth_required` and withholds detailed state until the client pairs or authenticates.

Unauthenticated client messages:

- `ping`: receive `pong`.
- `pair`: complete a Mac-initiated pairing session.
- `auth`: authenticate using previously issued credentials.

Authenticated client messages:

- `get_state`: request a full state snapshot.
- `subscribe`: subscribe to pushed state updates and receive a snapshot.
- `unsubscribe`: stop pushed state updates.
- `command`: request a state-changing action.
- `ping`: receive `pong`.

EqualEase-to-client messages:

- `auth_required`: sent on connect before the client is trusted.
- `auth_ok`: sent after successful `pair` or `auth`.
- `auth_error`: sent for missing, invalid, expired, or revoked credentials.
- `state_snapshot`: full state with `stateVersion`.
- `state_patch`: current implementation sends the latest state as a patch payload when watched state changes; clients can always request `get_state` if unsure.
- `command_result`: request-correlated command result.
- `event`: server events such as heartbeat.
- `error`: protocol or command error not specific to authentication.
- `pong`: ping response.

Pairing request:

```json
{ "type": "pair", "id": "pair-1", "payload": { "code": "123456", "clientName": "Living Room Phone" } }
```

Pairing success:

```json
{ "type": "auth_ok", "id": "pair-1", "payload": { "clientID": "...", "clientName": "Living Room Phone", "token": "..." } }
```

Store the returned `clientID` and `token` on the client. The token is only returned during pairing.

Reconnect/auth request:

```json
{ "type": "auth", "id": "auth-1", "payload": { "clientID": "...", "token": "..." } }
```

Reconnect/auth success:

```json
{ "type": "auth_ok", "id": "auth-1", "payload": { "clientID": "...", "clientName": "Living Room Phone", "token": null } }
```

Authentication errors use stable codes:

- `authentication_required`: a state or command message was sent before authentication.
- `pairing_unavailable`: no pairing code is active on the Mac.
- `invalid_pairing_code`: the provided pairing code is wrong or expired.
- `pairing_rate_limited`: too many incorrect pairing attempts were made; wait a few minutes and try again.
- `invalid_credentials`: the client ID/token pair is unknown, wrong, revoked, or reset.

State payload includes:

- `stateVersion`
- `outputVolume` (`0...1`)
- `preamp` (`0...2`)
- `activePresetID`
- `activePresetName`
- `presets` (`id`, `name`, `source`)
- `isActive`
- `isRoutingTransitioning`
- `routingStatus`

Command examples, after authentication:

```json
{ "type": "command", "id": "vol-1", "payload": { "command": "set_volume", "value": 0.45 } }
{ "type": "command", "id": "pre-1", "payload": { "command": "set_preamp", "value": 1.15 } }
{ "type": "command", "id": "preset-1", "payload": { "command": "select_preset", "presetID": "built-in-voice-boost" } }
```

Values are clamped using the same safe ranges as local controls.

## Phone web remote

Open `http://<mac-lan-ip>:8787/remote` from a phone browser on the same Wi-Fi. The paired remote:

- asks for a pairing code if no stored token is available, if stored credentials were revoked, or if too many incorrect pairing attempts require a short wait before retrying;
- reconnects automatically with the stored token after successful pairing;
- shows large Volume and Preamp controls;
- offers one-tap preset cards;
- shows visible connection/current-preset state;
- avoids dropdowns for core controls;
- uses CSS/touch handling to reduce accidental page pan while dragging controls.

It is a focused phone remote, not a replacement for the native macOS Settings window. Preset editing, app rules, diagnostics, and advanced EQ editing remain Mac-only.

## macOS configuration and permissions

The app declares:

- `NSLocalNetworkUsageDescription` for the local-network privacy prompt;
- sandbox network client/server entitlements for local socket access.

The macOS firewall can still block inbound connections. If a phone cannot connect:

1. Confirm the Mac and phone are on the same Wi-Fi/VLAN.
2. Confirm EqualEase is running and check logs for `http://<lan-ip>:8787`.
3. On the Mac, try `curl http://127.0.0.1:8787/health`.
4. From another device, try `curl http://<mac-lan-ip>:8787/health`.
5. Check System Settings > Network and firewall/app permission prompts.

## Manual validation

With the remote disabled, `curl http://127.0.0.1:8787/health` should fail to connect. Enable Settings > General > Local Network Remote, then run:

```sh
curl http://127.0.0.1:8787/health
curl http://127.0.0.1:8787/info
```

For WebSocket validation, connect to `ws://<mac-lan-ip>:8787/ws` and confirm:

1. The server sends `auth_required` and no `state_snapshot` before auth.
2. Unauthenticated `get_state`, `subscribe`, and `command` return `auth_error` with `authentication_required`.
3. A valid Mac-displayed pairing code returns `auth_ok` with a token and then `state_snapshot`.
4. Reconnecting with `auth` returns `auth_ok` and a fresh `state_snapshot`.
5. Authenticated commands return `command_result` and state updates.
6. Revoking one client or resetting all pairings makes old credentials fail with `invalid_credentials`.
7. `/health` and `/info` remain reachable and do not contain pairing codes, tokens, token hashes, local paths, user names, or paired-client details.
