#!/usr/bin/env bash
# Pull request step "select Xcode 27": the app is built against the macOS 27 SDK, so a job uses an
# Xcode 27 that has a macOS SDK, whatever the runner's default developer directory is. In a GitHub
# Actions job it exports DEVELOPER_DIR for the steps after it. A runner with no such Xcode fails here,
# naming what it has, instead of failing later in a build step.
# Run it from anywhere: bash .github/checks/select-xcode.sh
set -u

usable() {
  local dev="$1" version
  [ -d "$dev" ] || return 1
  version="$(DEVELOPER_DIR="$dev" xcodebuild -version 2>/dev/null | head -n 1)"
  case "$version" in
    "Xcode 27"*) ;;
    *) return 1 ;;
  esac
  DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-version >/dev/null 2>&1
}

current="$(xcode-select -p 2>/dev/null || true)"
chosen=""
for dev in "$current" /Applications/Xcode*.app/Contents/Developer; do
  if usable "$dev"; then
    chosen="$dev"
    break
  fi
done

if [ -z "$chosen" ]; then
  installed="$(ls -d /Applications/Xcode*.app 2>/dev/null | tr '\n' ' ')"
  echo "::error title=No Xcode 27::No Xcode 27 with a macOS SDK on this runner. Active developer directory: ${current:-none}. Installed: ${installed:-none}."
  exit 1
fi

echo "Using ${chosen} ($(DEVELOPER_DIR="$chosen" xcodebuild -version | head -n 1), macOS SDK $(DEVELOPER_DIR="$chosen" xcrun --sdk macosx --show-sdk-version))"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DEVELOPER_DIR=${chosen}" >> "$GITHUB_ENV"
fi
