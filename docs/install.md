# Local EqualEase install

Use this flow when you want to run EqualEase like a normal local app and collect daily-use experience.

## Install to Applications

From the repository root:

```sh
scripts/install-local.sh
```

The script:

1. Builds the `EqualEase` scheme in `Release` configuration.
2. Quits any running EqualEase instance.
3. Replaces `/Applications/EqualEase.app` with the freshly built app.
4. Registers the installed app with Launch Services so the app icon, `equalease://` URLs, AppleScript terminology, and Launch at Login point at `/Applications/EqualEase.app`.
5. Launches EqualEase.

To build Debug instead:

```sh
scripts/install-local.sh --debug
```

To install without launching:

```sh
scripts/install-local.sh --no-launch
```

## Launch at Login

Launch at Login should be tested from the installed `/Applications/EqualEase.app`, not from Xcode DerivedData. After installing:

1. Open EqualEase.
2. Open Settings > General.
3. Turn on **Launch EqualEase when you log in**.
4. If macOS asks for approval, approve EqualEase in System Settings > General > Login Items & Extensions.

Turning the same setting off calls macOS Service Management unregister and should remove/disable the login item. System Settings may need to be reopened before it reflects the change.

## Reinstall after code changes

Run the install script again after pulling or building new changes:

```sh
scripts/install-local.sh
```

This replaces the existing `/Applications/EqualEase.app` bundle and relaunches the app.

## Current scope

This is a local developer install, not a public release package. EqualEase is still development-signed. App Store builds use App Store updates.
