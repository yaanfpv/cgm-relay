#!/usr/bin/env bash
# Builds, signs, notarizes and describes one CGM Relay release, ready for
# publish-release.sh. Nothing here publishes anything: it reads the current
# appcast and asks origin whether the tag already exists.
#
# Usage: scripts/release.sh X.Y.Z BUILD
#   X.Y.Z  the version; CHANGELOG.md must already carry its dated
#          "## [X.Y.Z] - YYYY-MM-DD" section (cut in a tracked commit first)
#   BUILD  the build number, greater than the newest one in the published
#          appcast
# Env:   DEVELOPMENT_TEAM          the Apple team that owns the Developer ID
#                                  Application certificate (required)
#        CGMRELAY_NOTARY_PROFILE   the notarytool keychain profile name
#                                  (required)
# The Sparkle signing key is the keychain item for account "cgm-relay"; it is
# read by Sparkle's own tools and never exported or printed.
#
# Output: macos/.build/release/X.Y.Z/ holding the notarized DMG, appcast.xml,
# the release notes and RELEASE.md. A run that fails removes that directory,
# so RELEASE.md existing means every step passed.
#
# Test mode, only for proving these scripts without the owner's credentials:
#   CGMRELAY_RELEASE_TEST_KEY_FILE      Ed25519 seed file used instead of the keychain
#   CGMRELAY_RELEASE_SKIP_NOTARIZE=1    skip notarization and stapling
#   CGMRELAY_RELEASE_TEST_DOWNLOAD_PREFIX, _PREVIOUS_APPCAST, _BUNDLE_ID,
#   _CONFIGURATION                      redirect the download URL, the previous
#                                       appcast, the bundle identifier, the
#                                       build configuration
# A test-mode release is marked TEST ONLY in RELEASE.md and publish-release.sh
# refuses it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${MACOS_DIR}/.." && pwd)"
# shellcheck source=release-lib.sh
source "${SCRIPT_DIR}/release-lib.sh"

usage() {
  echo "usage: $(basename "$0") X.Y.Z BUILD" >&2
  exit 2
}

[ $# -eq 2 ] || usage
VERSION="$1"
BUILD="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version \"${VERSION}\" is not X.Y.Z" "for example: $(basename "$0") 1.2.3 12"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || die "build number \"${BUILD}\" is not a positive integer" "for example: $(basename "$0") 1.2.3 12"

OUT_DIR="$(release_dir "$VERSION")"
WORK_DIR="${RELEASES_DIR}/.work-${VERSION}"
DMG_FILE="$(dmg_name "$VERSION")"
NOTES_FILE="CGM-Relay-${VERSION}.md"
MOUNT_POINT=""
OWN_OUT=no

cleanup() {
  local status=$?
  if [ -n "$MOUNT_POINT" ]; then
    hdiutil detach -quiet "$MOUNT_POINT" >/dev/null 2>&1 || hdiutil detach -quiet -force "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  remove_scratch
  rm -rf "$WORK_DIR"
  if [ "$status" -ne 0 ]; then
    [ "$OWN_OUT" != yes ] || rm -rf "$OUT_DIR"
    echo "$(basename "$0"): release ${VERSION} was NOT produced (failed at step \"${CURRENT_STEP}\")" >&2
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- preflight
step "Preflight"
refuse_test_knobs_outside_test_mode
TEST_MODE=no
is_test_mode && TEST_MODE=yes
SKIP_NOTARIZE=no
[ "${CGMRELAY_RELEASE_SKIP_NOTARIZE:-}" = "1" ] && SKIP_NOTARIZE=yes

for t in git go xcodegen xcodebuild lipo codesign hdiutil ditto tiffutil osascript xmllint plutil shasum curl awk sed tar; do
  need_tool "$t"
done
if [ "$SKIP_NOTARIZE" = no ]; then
  xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool is not available" "install the Xcode command line tools"
  xcrun --find stapler >/dev/null 2>&1 || die "xcrun stapler is not available" "install the Xcode command line tools"
  [ -n "${CGMRELAY_NOTARY_PROFILE:-}" ] ||
    die "CGMRELAY_NOTARY_PROFILE is not set" "name the notarytool keychain profile: CGMRELAY_NOTARY_PROFILE=<name>"
  # A bad profile is found now, not after the build.
  if ! PROFILE_OUT="$(xcrun notarytool history --keychain-profile "$CGMRELAY_NOTARY_PROFILE" 2>&1)"; then
    echo "$PROFILE_OUT" >&2
    die "notarytool cannot use the keychain profile \"${CGMRELAY_NOTARY_PROFILE}\"" \
      "if the message above says the profile is missing, create it once with: xcrun notarytool store-credentials ${CGMRELAY_NOTARY_PROFILE}"
  fi
fi
[ -n "${DEVELOPMENT_TEAM:-}" ] || die "DEVELOPMENT_TEAM is not set" "set it to the team that owns your Developer ID Application certificate"

[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] ||
  die "the working tree has uncommitted or untracked files" "commit or remove them; a release names one exact commit"
COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
  TAG_COMMIT="$(git -C "$REPO_ROOT" rev-parse "refs/tags/v${VERSION}^{commit}")"
  [ "$TAG_COMMIT" = "$COMMIT" ] ||
    die "tag v${VERSION} exists locally at ${TAG_COMMIT}, not at HEAD ${COMMIT}" "check out the tagged commit, or delete the stale local tag"
fi
REMOTE_TAG="$(git -C "$REPO_ROOT" ls-remote --tags origin "refs/tags/v${VERSION}")" ||
  die "could not ask origin about tag v${VERSION}" "check the network and the origin remote"
[ -z "$REMOTE_TAG" ] || die "tag v${VERSION} is already on origin" "published versions are never rebuilt; use the next version"

changelog_heading_present "$VERSION" ||
  die "CHANGELOG.md has no \"## [${VERSION}] - YYYY-MM-DD\" section" "cut the release heading in a tracked commit first, then run this again"
NOTES="$(changelog_notes "$VERSION")"
[ -n "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ] ||
  die "the CHANGELOG.md section for ${VERSION} is empty" "write the release notes under that heading and commit"

if is_test_mode; then
  [ -r "$CGMRELAY_RELEASE_TEST_KEY_FILE" ] || die "CGMRELAY_RELEASE_TEST_KEY_FILE is not readable" "point it at an Ed25519 seed file"
fi
fetch_sparkle_tools
new_scratch
build_edsig "$SCRATCH"

step "Preflight: signing key"
if is_test_mode; then
  PUBLIC_KEY="$("$EDSIG" pub "$CGMRELAY_RELEASE_TEST_KEY_FILE")" || die "the test key file is not a valid Ed25519 seed" "regenerate it"
  SIGN_ARGS=(--ed-key-file "$CGMRELAY_RELEASE_TEST_KEY_FILE")
else
  if ! PUBLIC_KEY="$("${SPARKLE_BIN}/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>"$SCRATCH/generate_keys.err")"; then
    sed 's/^/    /' "$SCRATCH/generate_keys.err" >&2
    die "could not read the Sparkle public key for account ${SPARKLE_ACCOUNT} from the login keychain" \
      "if the message above says there is no key, create it once with: ${SPARKLE_BIN}/generate_keys --account ${SPARKLE_ACCOUNT}   (then back the private key up)"
  fi
  SIGN_ARGS=(--account "$SPARKLE_ACCOUNT")
fi
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "the public signing key does not look like a 32-byte Ed25519 key" "check the keychain item for ${SPARKLE_ACCOUNT}"

step "Preflight: previous appcast"
PREVIOUS_APPCAST=""
mkdir -p "$RELEASES_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/archives"
if is_test_mode; then
  if [ -n "${CGMRELAY_RELEASE_TEST_PREVIOUS_APPCAST:-}" ]; then
    [ -r "$CGMRELAY_RELEASE_TEST_PREVIOUS_APPCAST" ] || die "CGMRELAY_RELEASE_TEST_PREVIOUS_APPCAST is not readable" "fix the path"
    cp "$CGMRELAY_RELEASE_TEST_PREVIOUS_APPCAST" "$WORK_DIR/archives/appcast.xml"
    PREVIOUS_APPCAST="$WORK_DIR/archives/appcast.xml"
  fi
else
  HTTP_CODE="$(curl -sSL --retry 3 -o "$WORK_DIR/archives/appcast.xml" -w '%{http_code}' "$FEED_URL")" ||
    die "could not reach ${FEED_URL}" "check the network and run again"
  case "$HTTP_CODE" in
    200) PREVIOUS_APPCAST="$WORK_DIR/archives/appcast.xml" ;;
    404) rm -f "$WORK_DIR/archives/appcast.xml"; echo "    no published appcast yet: this is the first release" ;;
    *) die "${FEED_URL} answered HTTP ${HTTP_CODE}" "wait and run again; a guess here could publish an update that clients skip" ;;
  esac
fi
if [ -n "$PREVIOUS_APPCAST" ]; then
  xmllint --noout "$PREVIOUS_APPCAST" || die "the previous appcast is not valid XML" "look at what ${FEED_URL} serves"
  PREVIOUS_BUILD="$(appcast_max_build "$PREVIOUS_APPCAST")"
  [ "$BUILD" -gt "$PREVIOUS_BUILD" ] ||
    die "build ${BUILD} is not greater than the published build ${PREVIOUS_BUILD}" "pass a build number above ${PREVIOUS_BUILD}; clients only update to a higher build"
fi

# -------------------------------------------------------------------- build
step "Building the universal Release app"
CONFIGURATION="Release"
BUNDLE_ID="com.yaanfpv.cgmrelay"
BUILD_SETTINGS=()
if is_test_mode; then
  [ -z "${CGMRELAY_RELEASE_TEST_CONFIGURATION:-}" ] || CONFIGURATION="$CGMRELAY_RELEASE_TEST_CONFIGURATION"
  if [ -n "${CGMRELAY_RELEASE_TEST_BUNDLE_ID:-}" ]; then
    BUNDLE_ID="$CGMRELAY_RELEASE_TEST_BUNDLE_ID"
    BUILD_SETTINGS+=("PRODUCT_BUNDLE_IDENTIFIER=${BUNDLE_ID}")
  fi
fi
rm -rf "$OUT_DIR" "${BUILD_DIR}/DerivedData/Build/Products/${CONFIGURATION}"
OWN_OUT=yes
if ! CONFIGURATION="$CONFIGURATION" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="Developer ID Application" \
  bash "${SCRIPT_DIR}/build.sh" \
  "SPARKLE_PUBLIC_ED_KEY=${PUBLIC_KEY}" \
  "MARKETING_VERSION=${VERSION}" \
  "CURRENT_PROJECT_VERSION=${BUILD}" \
  "ARCHS=arm64 x86_64" \
  "ONLY_ACTIVE_ARCH=NO" \
  "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO" \
  "DEPLOYMENT_POSTPROCESSING=YES" \
  "STRIP_INSTALLED_PRODUCT=YES" \
  ${BUILD_SETTINGS[@]+"${BUILD_SETTINGS[@]}"} >"$WORK_DIR/build.log" 2>&1; then
  tail -40 "$WORK_DIR/build.log" >&2
  die "the build failed (last lines above)" "fix the build; the same command works standalone: bash macos/scripts/build.sh"
fi
BUILT_APP="${BUILD_DIR}/DerivedData/Build/Products/${CONFIGURATION}/CGM Relay.app"
[ -d "$BUILT_APP" ] || die "the build produced no app at ${BUILT_APP}" "read ${WORK_DIR}/build.log"
APP="$WORK_DIR/stage/CGM Relay.app"
mkdir -p "$WORK_DIR/stage"
ditto "$BUILT_APP" "$APP"

# ---------------------------------------------------------- sign, inside out
step "Signing inside out with hardened runtime"
SIGNATURE_DETAILS="$(codesign -dvv "$APP" 2>&1)"
IDENTITY="$(sed -n '/^Authority=Developer ID Application:/{s/^Authority=//p;q;}' <<<"$SIGNATURE_DETAILS")"
[ -n "$IDENTITY" ] || die "the built app is not signed with a Developer ID Application identity" \
  "install the Developer ID Application certificate for team ${DEVELOPMENT_TEAM} in the login keychain"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$FRAMEWORK" ] || die "Sparkle.framework is not embedded in the app" "check the Sparkle package in macos/project.yml"
# A non-sandboxed app needs none of Sparkle's XPC services, and each one left in
# the bundle is one more item to sign and notarize.
find "$FRAMEWORK" -name XPCServices -prune -exec rm -rf {} +
[ -z "$(find "$APP" -name '*.xpc' -print -quit)" ] || die "an XPC service is still inside the app bundle" "remove it before signing"

sign() {
  local out
  out="$(codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@" 2>&1)" || {
    echo "$out" >&2
    die "codesign failed on ${*: -1}" "read the message above; a timestamp failure means the network or Apple's timestamp server"
  }
}
VERSION_DIR="$FRAMEWORK/Versions/$(readlink "$FRAMEWORK/Versions/Current")"
sign "$APP/Contents/Resources/cgm-relay"
sign "$VERSION_DIR/Autoupdate"
sign "$VERSION_DIR/Updater.app"
sign "$FRAMEWORK"
sign --preserve-metadata=entitlements "$APP"

step "Checking the signed app"
codesign --verify --deep --strict "$APP" || die "codesign --verify --deep --strict failed" "read the message above; nothing was notarized"
for item in "$APP" "$APP/Contents/Resources/cgm-relay" "$VERSION_DIR/Autoupdate" "$VERSION_DIR/Updater.app" "$FRAMEWORK"; do
  details="$(codesign -dvv "$item" 2>&1)"
  grep -q 'flags=0x[0-9a-f]*(.*runtime' <<<"$details" || die "${item#"$APP"/} lacks the hardened runtime flag" "sign it with --options runtime"
  grep -q '^Timestamp=' <<<"$details" || die "${item#"$APP"/} has no secure timestamp" "check the network and sign again"
  # Xcode adds get-task-allow to a plain build; Apple's notary rejects it.
  entitlements="$(codesign -d --entitlements - "$item" 2>&1)"
  ! grep -q 'get-task-allow' <<<"$entitlements" ||
    die "${item#"$APP"/} requests the get-task-allow entitlement" "notarization would reject it; check CODE_SIGN_INJECT_BASE_ENTITLEMENTS"
done
[ -z "$(find "$APP" -name '*.xpc' -print -quit)" ] || die "an XPC service is inside the signed app" "remove it and sign again"
INFO="$APP/Contents/Info.plist"
plist_value() { plutil -extract "$1" raw -o - "$INFO" 2>/dev/null || true; }
[ "$(plist_value SUFeedURL)" = "$FEED_URL" ] || die "SUFeedURL is \"$(plist_value SUFeedURL)\", expected ${FEED_URL}" "fix macos/App/Info.plist"
[ -n "$(plist_value SUPublicEDKey)" ] || die "SUPublicEDKey is empty in the built app" "the build did not receive SPARKLE_PUBLIC_ED_KEY"
[ "$(plist_value SUPublicEDKey)" = "$PUBLIC_KEY" ] || die "SUPublicEDKey in the app is not the signing key's public half" "rebuild"
[ "$(plist_value CFBundleShortVersionString)" = "$VERSION" ] || die "the app reports version $(plist_value CFBundleShortVersionString), expected ${VERSION}" "rebuild"
[ "$(plist_value CFBundleVersion)" = "$BUILD" ] || die "the app reports build $(plist_value CFBundleVersion), expected ${BUILD}" "rebuild"
[ "$(plist_value CFBundleIdentifier)" = "$BUNDLE_ID" ] || die "the app's bundle identifier is $(plist_value CFBundleIdentifier), expected ${BUNDLE_ID}" "rebuild"
for f in "$APP/Contents/MacOS/CGM Relay" "$APP/Contents/Resources/cgm-relay"; do
  ARCHS_FOUND="$(lipo -archs "$f")"
  case " $ARCHS_FOUND " in *" arm64 "*) ;; *) die "${f##*/} has no arm64 slice (${ARCHS_FOUND})" "rebuild" ;; esac
  case " $ARCHS_FOUND " in *" x86_64 "*) ;; *) die "${f##*/} has no x86_64 slice (${ARCHS_FOUND})" "rebuild" ;; esac
done
# No file in the app may carry the path it was built at, or the builder's home folder. Only a
# Release build maps those paths away, so a test run in another configuration skips this.
if [ "$CONFIGURATION" = "Release" ]; then
  for p in "$REPO_ROOT/" "$HOME/"; do
    LEAKED="$(find "$APP" -type f -exec env LC_ALL=C grep -l -a -F "$p" {} + || true)"
    [ -z "$LEAKED" ] ||
      die "the app contains the build machine's path ${p} in: ${LEAKED//"$APP"\//}" \
        "check that the build above still strips the app's debug symbols, and that macos/scripts/build.sh still maps source paths and builds the engine with -trimpath"
  done
fi

# ---------------------------------------------------------------- notarize
notarize() {
  local file="$1" output id
  output="$(xcrun notarytool submit "$file" --keychain-profile "$CGMRELAY_NOTARY_PROFILE" --wait 2>&1)" || true
  echo "    ${output//$'\n'/$'\n'    }"
  id="$(sed -n '/^ *id: /{s///p;q;}' <<<"$output")"
  if ! grep -Eq '^ *status: Accepted' <<<"$output"; then
    [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$CGMRELAY_NOTARY_PROFILE" >&2 || true
    die "Apple did not accept ${file##*/}" "read the notarization log above, fix what it names, and run again"
  fi
}

if [ "$SKIP_NOTARIZE" = no ]; then
  step "Notarizing and stapling the app"
  ditto -c -k --keepParent "$APP" "$WORK_DIR/app.zip"
  notarize "$WORK_DIR/app.zip"
  xcrun stapler staple "$APP" || die "stapling the app failed" "run again; Apple may not have published the ticket yet"
  xcrun stapler validate "$APP" || die "the stapled app does not validate" "run again"
else
  echo "==> Skipping notarization (test mode)"
fi

# --------------------------------------------------------------------- dmg
step "Building the DMG"
new_scratch
STAGING="$SCRATCH"
ditto "$APP" "$STAGING/CGM Relay.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$STAGING/.background" "$WORK_DIR/archives"
tiffutil -cathidpicheck "$SCRIPT_DIR/dmg/background.png" "$SCRIPT_DIR/dmg/background@2x.png" \
  -out "$STAGING/.background/background.tiff" >/dev/null ||
  die "tiffutil could not combine the installer background" "check macos/scripts/dmg/background.png and background@2x.png"
# The window layout is written by Finder into a writable image, which is then
# compressed into the read-only one that ships. Finder finds the volume by
# name, so a mounted volume already called "CGM Relay" would take its place.
[ ! -e "/Volumes/CGM Relay" ] || die "a volume named CGM Relay is already mounted" "eject it and run again"
hdiutil create -quiet -volname "CGM Relay" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$WORK_DIR/layout.dmg" ||
  die "hdiutil could not create the disk image" "run again; check free disk space"
hdiutil attach -quiet -noautoopen "$WORK_DIR/layout.dmg" || die "could not mount the disk image to lay out its window" "run again"
MOUNT_POINT="/Volumes/CGM Relay"
osascript "$SCRIPT_DIR/dmg/layout.applescript" "CGM Relay" >/dev/null ||
  die "Finder could not lay out the installer window" "allow this terminal to control Finder in System Settings > Privacy & Security > Automation, then run again"
[ -f "$MOUNT_POINT/.DS_Store" ] || die "Finder saved no window layout on the disk image" "run again"
sync
hdiutil detach -quiet "$MOUNT_POINT" || die "could not unmount the disk image after laying it out" "eject CGM Relay and run again"
MOUNT_POINT=""
hdiutil convert -quiet "$WORK_DIR/layout.dmg" -format ULFO -ov -o "$WORK_DIR/archives/${DMG_FILE}" ||
  die "hdiutil could not compress the disk image" "run again; check free disk space"
rm -f "$WORK_DIR/layout.dmg"
if ! DMG_SIGN_OUT="$(codesign --force --timestamp --sign "$IDENTITY" "$WORK_DIR/archives/${DMG_FILE}" 2>&1)"; then
  echo "$DMG_SIGN_OUT" >&2
  die "codesign could not sign the DMG" "read the message above; a timestamp failure means the network or Apple's timestamp server"
fi
codesign --verify --strict "$WORK_DIR/archives/${DMG_FILE}" || die "the DMG signature does not verify" "sign it again"
if [ "$SKIP_NOTARIZE" = no ]; then
  step "Notarizing and stapling the DMG"
  notarize "$WORK_DIR/archives/${DMG_FILE}"
  xcrun stapler staple "$WORK_DIR/archives/${DMG_FILE}" || die "stapling the DMG failed" "run again"
  xcrun stapler validate "$WORK_DIR/archives/${DMG_FILE}" || die "the stapled DMG does not validate" "run again"
fi

step "Checking what the DMG delivers"
new_scratch
MOUNT_POINT="$SCRATCH"
attach_dmg "$WORK_DIR/archives/${DMG_FILE}" "$MOUNT_POINT" ||
  die "could not mount the finished DMG" "run again"
codesign --verify --deep --strict "$MOUNT_POINT/CGM Relay.app" || die "the app inside the DMG fails codesign verification" "run again"
[ -z "$(find "$MOUNT_POINT/CGM Relay.app" -name '*.xpc' -print -quit)" ] || die "an XPC service is inside the app on the DMG" "remove it and run again"
if [ "$SKIP_NOTARIZE" = no ]; then
  spctl --assess --type open --context context:primary-signature -vv "$WORK_DIR/archives/${DMG_FILE}" ||
    die "Gatekeeper rejects the DMG" "run again; if it persists the notarization ticket is missing"
  spctl --assess --type execute -vv "$MOUNT_POINT/CGM Relay.app" ||
    die "Gatekeeper rejects the app inside the DMG" "run again; if it persists the notarization ticket is missing"
  xcrun stapler validate "$MOUNT_POINT/CGM Relay.app" || die "the app inside the DMG has no stapled ticket" "run again"
else
  echo "    Gatekeeper assessment skipped: an unnotarized test build is rejected by design"
fi
hdiutil detach -quiet "$MOUNT_POINT" || die "could not unmount the DMG" "eject ${MOUNT_POINT} and run again"
MOUNT_POINT=""

# ------------------------------------------------------------------ appcast
step "Describing the release: notes and appcast"
printf '%s\n' "$NOTES" >"$WORK_DIR/archives/${NOTES_FILE}"
DOWNLOAD_PREFIX="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/"
if is_test_mode && [ -n "${CGMRELAY_RELEASE_TEST_DOWNLOAD_PREFIX:-}" ]; then
  DOWNLOAD_PREFIX="$CGMRELAY_RELEASE_TEST_DOWNLOAD_PREFIX"
fi
"${SPARKLE_BIN}/generate_appcast" "${SIGN_ARGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  --link "$PRODUCT_LINK" \
  "$WORK_DIR/archives" >"$WORK_DIR/generate_appcast.log" 2>&1 || {
  sed 's/^/    /' "$WORK_DIR/generate_appcast.log" >&2
  die "generate_appcast failed" "read its output above; a keychain prompt for account ${SPARKLE_ACCOUNT} must be allowed"
}
APPCAST="$WORK_DIR/archives/appcast.xml"

step "Checking the appcast against the DMG"
xmllint --noout "$APPCAST" || die "appcast.xml is not valid XML" "run again"
ITEM="//*[local-name()='item'][*[local-name()='shortVersionString']='${VERSION}']"
xp() { xmllint --xpath "string($ITEM$1)" "$APPCAST"; }
[ "$(xp "/*[local-name()='version']")" = "$BUILD" ] || die "the appcast item for ${VERSION} has sparkle:version \"$(xp "/*[local-name()='version']")\", expected ${BUILD}" "run again"
ENC_URL="$(xp "/*[local-name()='enclosure']/@url")"
[ "$ENC_URL" = "${DOWNLOAD_PREFIX}${DMG_FILE}" ] || die "the enclosure URL is \"${ENC_URL}\", expected ${DOWNLOAD_PREFIX}${DMG_FILE}" "run again"
[ "$(xp "/*[local-name()='enclosure']/@length")" = "$(stat -f %z "$WORK_DIR/archives/${DMG_FILE}")" ] ||
  die "the enclosure length does not equal the DMG size" "run again"
SIGNATURE="$(xp "/*[local-name()='enclosure']/@*[local-name()='edSignature']")"
if [ -z "$SIGNATURE" ]; then
  sed 's/^/    /' "$WORK_DIR/generate_appcast.log" >&2
  die "the appcast item carries no EdDSA signature" \
    "generate_appcast signs only with the key whose public half is in the app; check the signing key (output above)"
fi
"$EDSIG" verify "$PUBLIC_KEY" "$SIGNATURE" "$WORK_DIR/archives/${DMG_FILE}" ||
  die "the appcast signature does not verify against the DMG with the app's public key" "the signing key and the app's SUPublicEDKey disagree; do not publish"
[ "$(xp "/*[local-name()='description']/@*[local-name()='format']")" = "markdown" ] || die "the release notes are not embedded as markdown" "run again"
[ "$(xp "/*[local-name()='description']")" = "$(cat "$WORK_DIR/archives/${NOTES_FILE}")" ] ||
  die "the embedded notes differ from the CHANGELOG section" "run again"

# ------------------------------------------------------------------ output
step "Writing ${OUT_DIR}"
mkdir -p "$OUT_DIR"
cp "$WORK_DIR/archives/${DMG_FILE}" "$OUT_DIR/"
cp "$APPCAST" "$OUT_DIR/appcast.xml"
cp "$WORK_DIR/archives/${NOTES_FILE}" "$OUT_DIR/"

TEST_LINE=""
if [ "$SKIP_NOTARIZE" = yes ]; then
  TEST_LINE="NOT NOTARIZED, TEST ONLY"
elif [ "$TEST_MODE" = yes ]; then
  TEST_LINE="SIGNED WITH A TEST KEY, TEST ONLY"
fi
{
  [ -z "$TEST_LINE" ] || printf '%s\n\n' "$TEST_LINE"
  echo "# CGM Relay ${VERSION} release"
  echo
  echo "version: ${VERSION}"
  echo "build: ${BUILD}"
  echo "commit: ${COMMIT}"
  echo "tag: v${VERSION}"
  echo "test_only: $([ -n "$TEST_LINE" ] && echo yes || echo no)"
  echo
  echo "## Files"
  echo
  for f in "$DMG_FILE" appcast.xml "$NOTES_FILE"; do
    echo "file: $(sha256_of "$OUT_DIR/$f")  $f"
  done
  echo
  echo "## Surfaces publish-release.sh touches, in order, and the query that proves each"
  echo
  echo "1. Tag v${VERSION} on origin."
  echo "   $(origin_tag_query "v${VERSION}")"
  echo "2. GitHub release v${VERSION} with ${DMG_FILE} and appcast.xml attached, notes as its body."
  echo "   gh release view v${VERSION} --json assets,isDraft"
  echo "3. The live feed resolves to this release's appcast."
  echo "   curl -sIL ${FEED_URL}"
  echo "4. The download resolves."
  echo "   curl -sIL ${DOWNLOAD_PREFIX}${DMG_FILE}"
} >"$OUT_DIR/RELEASE.md"

echo
echo "Release ${VERSION} (build ${BUILD}) is ready in ${OUT_DIR}"
[ -z "$TEST_LINE" ] || echo "${TEST_LINE}: publish-release.sh will refuse it."
echo "Next: scripts/publish-release.sh ${VERSION}"
