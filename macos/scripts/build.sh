#!/usr/bin/env bash
# Builds the CGM Relay menu bar app: the Go engine for both Apple
# Silicon and Intel Macs, joined into one universal binary, then the
# Xcode project (generated fresh from project.yml) with that binary
# embedded in the app bundle's Resources.
#
# Usage: scripts/build.sh [xcodebuild args...]
# Env:   CONFIGURATION (default: Debug)
#        DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY sign with a real identity,
#        so a Keychain grant survives rebuilds; without them the build is
#        signed ad hoc. Pass CODE_SIGNING_ALLOWED=NO to build unsigned.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${MACOS_DIR}/.." && pwd)"

CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${MACOS_DIR}/.build"
ENGINE_DIR="${BUILD_DIR}/engine"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"

echo "==> Building the engine for arm64 and amd64 (CGO_ENABLED=0)"
mkdir -p "${ENGINE_DIR}"
(
  cd "${REPO_ROOT}"
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o "${ENGINE_DIR}/cgm-relay-arm64" ./cmd/cgm-relay
  CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o "${ENGINE_DIR}/cgm-relay-amd64" ./cmd/cgm-relay
)

lipo -create -output "${ENGINE_DIR}/cgm-relay" "${ENGINE_DIR}/cgm-relay-arm64" "${ENGINE_DIR}/cgm-relay-amd64"
chmod +x "${ENGINE_DIR}/cgm-relay"
echo "==> Universal engine binary built:"
lipo -info "${ENGINE_DIR}/cgm-relay"

echo "==> Generating the Xcode project with XcodeGen"
(
  cd "${MACOS_DIR}"
  xcodegen generate --spec project.yml --project .
)

SIGNING_ARGS=()
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  # CODE_SIGN_STYLE stays Automatic in project.yml for the no-team case
  # below, but Automatic signing resolves its own identity and ignores an
  # explicit CODE_SIGN_IDENTITY override, so a real identity needs Manual
  # style here instead -- a Mac app run locally needs no provisioning
  # profile for that.
  SIGNING_ARGS+=(
    "CODE_SIGN_STYLE=Manual"
    "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
    "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY:-Apple Development}"
  )
else
  case " $* " in
    *" CODE_SIGNING_ALLOWED=NO "*)
      echo "==> Code signing disabled: building an unsigned app" ;;
    *)
      echo "==> DEVELOPMENT_TEAM not set: building with an ad hoc signature (Keychain access will prompt on every rebuild)" ;;
  esac
fi

echo "==> Building CGM Relay.app (configuration: ${CONFIGURATION})"
xcodebuild \
  -project "${MACOS_DIR}/CGMRelay.xcodeproj" \
  -scheme CGMRelay \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  build ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"} "$@"

APP_PATH="${DERIVED_DATA_DIR}/Build/Products/${CONFIGURATION}/CGM Relay.app"
echo "==> Built app bundle:"
echo "${APP_PATH}"
