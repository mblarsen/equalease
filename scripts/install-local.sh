#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/EqualEase/EqualEase.xcodeproj"
SCHEME="EqualEase"
CONFIGURATION="Release"
DESTINATION="/Applications/EqualEase.app"
LAUNCH_AFTER_INSTALL=1

usage() {
  cat <<'USAGE'
Usage: scripts/install-local.sh [options]

Build and install EqualEase locally to /Applications for daily use.

Options:
  --debug             Build Debug instead of Release.
  --release           Build Release (default).
  --destination PATH  Install to PATH (default: /Applications/EqualEase.app).
  --no-launch         Do not launch EqualEase after installing.
  -h, --help          Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIGURATION="Debug"
      shift
      ;;
    --release)
      CONFIGURATION="Release"
      shift
      ;;
    --destination)
      DESTINATION="${2:?Missing destination path}"
      shift 2
      ;;
    --no-launch)
      LAUNCH_AFTER_INSTALL=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$PROJECT" ]]; then
  echo "Xcode project not found: $PROJECT" >&2
  exit 1
fi

DESTINATION_PARENT="$(dirname "$DESTINATION")"
if [[ ! -d "$DESTINATION_PARENT" ]]; then
  echo "Destination parent does not exist: $DESTINATION_PARENT" >&2
  exit 1
fi
if [[ ! -w "$DESTINATION_PARENT" ]]; then
  echo "Destination parent is not writable: $DESTINATION_PARENT" >&2
  echo "Run from an admin account or choose a writable --destination." >&2
  exit 1
fi

DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/equalease-install.XXXXXX")"
cleanup() {
  rm -rf "$DERIVED_DATA"
}
trap cleanup EXIT

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/EqualEase.app"
BUILD_LOG="$DERIVED_DATA/xcodebuild.log"

echo "Building EqualEase (${CONFIGURATION})..."
if ! xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build >"$BUILD_LOG" 2>&1; then
  echo "Build failed. Last 80 log lines:" >&2
  tail -80 "$BUILD_LOG" >&2
  exit 1
fi

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Build succeeded but app bundle was not found: $BUILT_APP" >&2
  exit 1
fi

echo "Stopping running EqualEase, if needed..."
osascript -e 'tell application id "boutique.code.EqualEase" to quit' >/dev/null 2>&1 || true
for _ in {1..25}; do
  if ! pgrep -x EqualEase >/dev/null; then
    break
  fi
  sleep 0.2
done
if pgrep -x EqualEase >/dev/null; then
  echo "EqualEase did not quit cleanly; terminating it before replacing the app bundle."
  pkill -x EqualEase || true
fi

echo "Installing to ${DESTINATION}..."
rm -rf "$DESTINATION"
ditto "$BUILT_APP" "$DESTINATION"

# Remove quarantine if the bundle was copied through a quarantined location.
xattr -dr com.apple.quarantine "$DESTINATION" >/dev/null 2>&1 || true

# Register the installed bundle with Launch Services so app icon, URL scheme,
# AppleScript terminology, and Launch at Login resolve to /Applications.
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted "$DESTINATION"

echo "Installed EqualEase: ${DESTINATION}"

if [[ "$LAUNCH_AFTER_INSTALL" -eq 1 ]]; then
  echo "Launching EqualEase..."
  open "$DESTINATION"
fi
