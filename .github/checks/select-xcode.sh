#!/usr/bin/env bash
# Pull request step "select Xcode": the app is built with Xcode 27.2, the version its releases are
# built with, so a job uses that Xcode whatever the runner's default developer directory is. It takes
# a real Xcode app bundle that reports Xcode 27.2 and has a macOS SDK, never a symlinked one, and in a
# GitHub Actions job switches to it with xcode-select and exports DEVELOPER_DIR for the steps after
# it. A runner without that Xcode fails here, naming what it has, instead of in a build step.
# Run it from anywhere: bash .github/checks/select-xcode.sh
set -u

want_version="Xcode 27.2"

usable() {
  local app="$1" dev version
  [ -d "$app" ] && [ ! -L "$app" ] || return 1
  dev="$app/Contents/Developer"
  version="$(DEVELOPER_DIR="$dev" xcodebuild -version 2>/dev/null | head -n 1)"
  [ "$version" = "$want_version" ] || return 1
  DEVELOPER_DIR="$dev" xcrun --sdk macosx --show-sdk-version >/dev/null 2>&1
}

chosen=""
for app in /Applications/Xcode_27.2.app /Applications/Xcode.app /Applications/Xcode_27*.app; do
  if usable "$app"; then
    chosen="$app/Contents/Developer"
    break
  fi
done

if [ -z "$chosen" ]; then
  installed="$(ls -d /Applications/Xcode*.app 2>/dev/null | tr '\n' ' ')"
  echo "::error title=No ${want_version}::No ${want_version} app bundle with a macOS SDK on this runner. Active developer directory: $(xcode-select -p 2>&1). Installed: ${installed:-none}."
  exit 1
fi

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  sudo xcode-select -s "$chosen" || { echo "::error title=xcode-select failed::Could not switch to ${chosen}."; exit 1; }
  echo "DEVELOPER_DIR=${chosen}" >> "$GITHUB_ENV"
fi
echo "Using ${chosen} ($(DEVELOPER_DIR="$chosen" xcodebuild -version | head -n 1), macOS SDK $(DEVELOPER_DIR="$chosen" xcrun --sdk macosx --show-sdk-version))"
