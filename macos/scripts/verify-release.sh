#!/usr/bin/env bash
# Checks a published CGM Relay release from the outside, the way an install
# sees it. It downloads and builds its helper only into a temporary directory,
# mounts the DMG read-only, and changes nothing it verifies.
#
# Usage: scripts/verify-release.sh [X.Y.Z]
#   With no version, checks the newest item of the live appcast.
#
# Checks: the appcast parses; the enclosure's EdDSA signature matches the DMG
# under the public key inside the shipped app; the appcast, the DMG's size and
# the app agree on version and build; Gatekeeper accepts the app; and, when
# macos/.build/release/X.Y.Z/RELEASE.md exists, the DMG hash matches it.
# Exits nonzero, naming each mismatch.
#
# For checking a copy served somewhere else (a local test feed):
#   CGMRELAY_VERIFY_FEED_URL=<url>   read this appcast instead of the live one
#   CGMRELAY_VERIFY_SKIP_SPCTL=1     skip the Gatekeeper check (an unnotarized
#                                    test build fails it by design)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${MACOS_DIR}/.." && pwd)"
# shellcheck source=release-lib.sh
source "${SCRIPT_DIR}/release-lib.sh"

[ $# -le 1 ] || { echo "usage: $(basename "$0") [X.Y.Z]" >&2; exit 2; }
WANT_VERSION="${1:-}"
[ -z "$WANT_VERSION" ] || [[ "$WANT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $(basename "$0") [X.Y.Z]" >&2; exit 2; }

FEED="${CGMRELAY_VERIFY_FEED_URL:-$FEED_URL}"
FAILURES=0
MOUNT_POINT=""

cleanup() {
  if [ -n "$MOUNT_POINT" ]; then
    hdiutil detach -quiet "$MOUNT_POINT" >/dev/null 2>&1 || hdiutil detach -quiet -force "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  remove_scratch
}
trap cleanup EXIT

mismatch() {
  echo "  MISMATCH: $1" >&2
  FAILURES=$((FAILURES + 1))
}

ok() {
  echo "  ok: $1"
}

# expect_equal reports ok when $1 equals $2, else the mismatch text $4.
expect_equal() {
  if [ "$1" = "$2" ]; then ok "$3"; else mismatch "$4"; fi
}

for t in curl xmllint plutil hdiutil spctl shasum go; do
  need_tool "$t"
done
new_scratch
WORK="$SCRATCH"
build_edsig "$WORK"

step "Reading the appcast"
echo "    ${FEED}"
curl -fsSL --retry 3 -o "$WORK/appcast.xml" "$FEED" || die "could not fetch ${FEED}" "the release may not be published, or has no appcast.xml asset"
xmllint --noout "$WORK/appcast.xml" || die "the appcast is not valid XML" "republish the release with a good appcast.xml"
if [ -n "$WANT_VERSION" ]; then
  ITEM="(//*[local-name()='item'][*[local-name()='shortVersionString']='${WANT_VERSION}'])[1]"
else
  ITEM="(//*[local-name()='item'])[1]"
fi
xp() { xmllint --xpath "string($ITEM$1)" "$WORK/appcast.xml" 2>/dev/null || true; }
VERSION="$(xp "/*[local-name()='shortVersionString']")"
BUILD="$(xp "/*[local-name()='version']")"
[ -n "$VERSION" ] || die "the appcast has no item${WANT_VERSION:+ for version ${WANT_VERSION}}" "the feed does not serve that release"
ENC_URL="$(xp "/*[local-name()='enclosure']/@url")"
ENC_LENGTH="$(xp "/*[local-name()='enclosure']/@length")"
SIGNATURE="$(xp "/*[local-name()='enclosure']/@*[local-name()='edSignature']")"
echo "    item: version ${VERSION}, build ${BUILD}"
[ -n "$ENC_URL" ] || die "the item has no enclosure URL" "republish with a good appcast.xml"
[ -n "$SIGNATURE" ] || mismatch "the enclosure carries no EdDSA signature"
if [ -n "${CGMRELAY_VERIFY_FEED_URL:-}" ]; then
  case "$ENC_URL" in
    https://* | http://127.0.0.1[:/]* | http://localhost[:/]*) ;;
    *) mismatch "the enclosure URL is neither https nor a loopback address: ${ENC_URL}" ;;
  esac
else
  [[ "$ENC_URL" == https://* ]] || mismatch "the enclosure URL is not https: ${ENC_URL}"
fi
if [ -z "${CGMRELAY_VERIFY_FEED_URL:-}" ]; then
  EXPECT_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/$(dmg_name "$VERSION")"
  expect_equal "$ENC_URL" "$EXPECT_URL" "enclosure URL is the release tag's download" "the enclosure URL is ${ENC_URL}, expected ${EXPECT_URL}"
fi

step "Downloading the DMG"
DMG="$WORK/$(dmg_name "$VERSION")"
curl -fsSL --retry 3 -o "$DMG" "$ENC_URL" || die "could not download ${ENC_URL}" "the asset is missing or the tag URL is wrong"
expect_equal "$(stat -f %z "$DMG")" "$ENC_LENGTH" "DMG size equals the appcast length (${ENC_LENGTH})" \
  "the DMG is $(stat -f %z "$DMG") bytes, the appcast says ${ENC_LENGTH}"

step "Opening the shipped app"
MOUNT_POINT="$WORK/mount"
mkdir -p "$MOUNT_POINT"
attach_dmg "$DMG" "$MOUNT_POINT" || die "the DMG will not mount" "it is damaged; republish"
APP="$MOUNT_POINT/CGM Relay.app"
[ -d "$APP" ] || die "there is no CGM Relay.app on the DMG" "republish"
INFO="$APP/Contents/Info.plist"
plist_value() { plutil -extract "$1" raw -o - "$INFO" 2>/dev/null || true; }
APP_KEY="$(plist_value SUPublicEDKey)"
APP_VERSION="$(plist_value CFBundleShortVersionString)"
APP_BUILD="$(plist_value CFBundleVersion)"
[ -n "$APP_KEY" ] || die "the shipped app has no SUPublicEDKey" "clients cannot verify any update"
expect_equal "$APP_VERSION" "$VERSION" "app version ${APP_VERSION} equals the appcast" "the app is version ${APP_VERSION}, the appcast says ${VERSION}"
expect_equal "$APP_BUILD" "$BUILD" "app build ${APP_BUILD} equals the appcast" "the app is build ${APP_BUILD}, the appcast says ${BUILD}"
expect_equal "$(plist_value SUFeedURL)" "$FEED_URL" "the app reads the release feed" "the app's SUFeedURL is $(plist_value SUFeedURL), expected ${FEED_URL}"
expect_equal "$(find "$APP" -name '*.xpc' -print -quit)" "" "no XPC service in the bundle" "an XPC service is inside the app"
if [ -n "$SIGNATURE" ]; then
  if "$EDSIG" verify "$APP_KEY" "$SIGNATURE" "$DMG" 2>"$WORK/edsig.err"; then
    ok "the appcast's EdDSA signature matches the DMG under the shipped app's public key"
  else
    mismatch "the appcast's EdDSA signature does not match this DMG under the public key in the shipped app ($(cat "$WORK/edsig.err"))"
  fi
fi

step "Asking Gatekeeper"
if [ "${CGMRELAY_VERIFY_SKIP_SPCTL:-}" = "1" ]; then
  echo "  SKIPPED: CGMRELAY_VERIFY_SKIP_SPCTL=1"
else
  if OUT="$(spctl --assess --type execute -vv "$APP" 2>&1)"; then
    ok "Gatekeeper accepts the app: ${OUT//$'\n'/ }"
  else
    mismatch "Gatekeeper rejects the app: ${OUT//$'\n'/ }"
  fi
  if OUT="$(spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1)"; then
    ok "Gatekeeper accepts the DMG"
  else
    mismatch "Gatekeeper rejects the DMG: ${OUT//$'\n'/ }"
  fi
fi

RECORD="$(release_dir "$VERSION")/RELEASE.md"
step "Comparing with the release record"
if [ -f "$RECORD" ]; then
  RECORDED="$(sed -n "/^file: /{s/^file: \\([0-9a-f]*\\)  $(dmg_name "$VERSION")\$/\\1/p;}" "$RECORD")"
  if [ -z "$RECORDED" ]; then
    mismatch "${RECORD} does not list $(dmg_name "$VERSION")"
  elif [ "$(sha256_of "$DMG")" = "$RECORDED" ]; then
    ok "the DMG's SHA-256 equals RELEASE.md"
  else
    mismatch "the DMG's SHA-256 is $(sha256_of "$DMG"), RELEASE.md recorded ${RECORDED}"
  fi
else
  echo "  no RELEASE.md for ${VERSION} on this machine; hash comparison skipped"
fi

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "verify-release: ${FAILURES} mismatch(es) for ${VERSION}" >&2
  exit 1
fi
echo "verify-release: ${VERSION} (build ${BUILD}) verified"
