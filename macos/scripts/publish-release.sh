#!/usr/bin/env bash
# Publishes a release that release.sh produced: tags the commit, pushes the
# tag, and creates the GitHub release with the DMG, appcast.xml and the notes.
# This is the one irreversible step, so it shows the plan and waits for the
# version to be typed before it runs anything.
#
# Usage: scripts/publish-release.sh [--dry-run] X.Y.Z
#   --dry-run  print every command that would run, run none of them
#
# Safe to run again after a partial failure: each surface is asked whether it
# already landed, and only what has not landed is done.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${MACOS_DIR}/.." && pwd)"
# shellcheck source=release-lib.sh
source "${SCRIPT_DIR}/release-lib.sh"

usage() {
  echo "usage: $(basename "$0") [--dry-run] X.Y.Z" >&2
  exit 2
}

DRY_RUN=no
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=yes ;;
    -*) usage ;;
    *) [ -z "$VERSION" ] || usage; VERSION="$arg" ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

TAG="v${VERSION}"
OUT_DIR="$(release_dir "$VERSION")"
RECORD="${OUT_DIR}/RELEASE.md"
DMG_FILE="$(dmg_name "$VERSION")"
NOTES_FILE="CGM-Relay-${VERSION}.md"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${DMG_FILE}"

PUBLISH_STARTED=no
# Set before a refusal that a rerun cannot get past, so the exit message does
# not promise one.
RERUN_CANNOT_CONTINUE=no
finish() {
  local status=$?
  remove_scratch
  if [ "$status" -ne 0 ] && [ "$PUBLISH_STARTED" = yes ] && [ "$RERUN_CANNOT_CONTINUE" = no ]; then
    echo "$(basename "$0"): stopped at step \"${CURRENT_STEP}\"; what had already landed stays. Running it again continues from here." >&2
  fi
}
new_scratch
trap finish EXIT

# ------------------------------------------------- what the record permits
step "Reading the release record"
[ -f "$RECORD" ] || die "no ${RECORD}" "run scripts/release.sh ${VERSION} BUILD first"
TEST_ONLY="$(release_field "$RECORD" test_only)"
WOULD_REFUSE=no
if [ "$TEST_ONLY" != no ]; then
  [ "$DRY_RUN" = yes ] || die "${RECORD} is a test-only release (test_only: ${TEST_ONLY:-missing}); nothing was run" \
    "build the real one with scripts/release.sh and no test settings"
  WOULD_REFUSE=yes
  echo "TEST ONLY, WOULD REFUSE: ${RECORD} is not a real release (test_only: ${TEST_ONLY:-missing}). The plan below is for reading only." >&2
fi
[ "$(release_field "$RECORD" version)" = "$VERSION" ] || die "${RECORD} is for version $(release_field "$RECORD" version)" "run scripts/release.sh ${VERSION} BUILD"
RECORD_COMMIT="$(release_field "$RECORD" commit)"
RECORD_BUILD="$(release_field "$RECORD" build)"
[[ "$RECORD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "${RECORD} names no commit" "run scripts/release.sh again"

step "Checking that nothing changed since the release was built"
[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$RECORD_COMMIT" ] ||
  die "HEAD is $(git -C "$REPO_ROOT" rev-parse HEAD), the release was built from ${RECORD_COMMIT}" "check out ${RECORD_COMMIT}, or build the release again from HEAD"
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || die "the working tree has uncommitted or untracked files" "commit or remove them"
LISTED=0
while IFS= read -r line; do
  want="$(awk '{print $2}' <<<"$line")"
  name="$(awk '{print $3}' <<<"$line")"
  [ -f "${OUT_DIR}/${name}" ] || die "${name} is listed in RELEASE.md but missing from ${OUT_DIR}" "run scripts/release.sh again"
  have="$(sha256_of "${OUT_DIR}/${name}")"
  [ "$have" = "$want" ] || die "${name} differs from the release record (SHA-256 ${have}, recorded ${want})" "do not publish it; run scripts/release.sh again"
  LISTED=$((LISTED + 1))
done < <(grep '^file: ' "$RECORD")
[ "$LISTED" -eq 3 ] || die "RELEASE.md lists ${LISTED} files, expected the DMG, appcast.xml and the notes" "run scripts/release.sh again"

# --------------------------------------------------------------------- plan
run() {
  if [ "$DRY_RUN" = yes ]; then
    printf '  would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

echo
echo "About to publish CGM Relay ${VERSION} (build ${RECORD_BUILD}) from ${RECORD_COMMIT}:"
echo "  1. tag ${TAG} on origin"
echo "  2. GitHub release ${TAG} in ${GITHUB_REPO} with ${DMG_FILE} and appcast.xml, the CHANGELOG section as its body"
echo "  3. the live feed ${FEED_URL} then serves this release"
echo "Each step is skipped when a query shows it already landed. This cannot be undone."
if [ "$DRY_RUN" = yes ]; then
  echo
  echo "Dry run. Commands, in order:"
else
  ANSWER=""
  if ! read -r -p "Type ${VERSION} to publish: " ANSWER </dev/tty 2>/dev/null; then
    die "there is no terminal to ask on" "run this from an interactive shell"
  fi
  [ "$ANSWER" = "$VERSION" ] || die "\"${ANSWER}\" is not ${VERSION}; nothing was done" "run again and type the version"
fi

# ------------------------------------------------------------------ publish
remote_tag_commit() {
  origin_tag_commit "$TAG" || die "could not ask origin about ${TAG}" "check the network"
}

step "Surface 1: tag ${TAG}"
[ "$DRY_RUN" = yes ] || PUBLISH_STARTED=yes
if [ "$DRY_RUN" = yes ]; then
  echo "  query: $(origin_tag_query "$TAG")   (skip the rest of this step if it prints ${RECORD_COMMIT})"
  run git -C "$REPO_ROOT" tag -a "$TAG" -m "CGM Relay ${VERSION}" "$RECORD_COMMIT"
  run git -C "$REPO_ROOT" push origin "refs/tags/${TAG}"
else
  ON_ORIGIN="$(remote_tag_commit)"
  if [ -z "$ON_ORIGIN" ]; then
    if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
      [ "$(git -C "$REPO_ROOT" rev-parse "refs/tags/${TAG}^{commit}")" = "$RECORD_COMMIT" ] ||
        die "local tag ${TAG} points at another commit" "delete it with git tag -d ${TAG} and run again"
    else
      run git -C "$REPO_ROOT" tag -a "$TAG" -m "CGM Relay ${VERSION}" "$RECORD_COMMIT"
    fi
    run git -C "$REPO_ROOT" push origin "refs/tags/${TAG}"
  elif [ "$ON_ORIGIN" = "$RECORD_COMMIT" ]; then
    echo "  already landed: origin has ${TAG} at ${ON_ORIGIN}"
  else
    RERUN_CANNOT_CONTINUE=yes
    die "origin has ${TAG} at ${ON_ORIGIN}, not ${RECORD_COMMIT}" "a published tag is never moved; use the next version"
  fi
  echo "  observed: origin has ${TAG} at $(remote_tag_commit)"
fi

asset_listing() {
  gh release view "$TAG" --repo "$GITHUB_REPO" --json assets,isDraft --jq '"draft=\(.isDraft) " + ([.assets[] | "\(.name):\(.size)"] | sort | join(" "))'
}

step "Surface 2: GitHub release ${TAG}"
WANT_DMG_SIZE="$(stat -f %z "${OUT_DIR}/${DMG_FILE}")"
WANT_APPCAST_SIZE="$(stat -f %z "${OUT_DIR}/appcast.xml")"
WANT_ASSETS="$(printf '%s\n' "${DMG_FILE}:${WANT_DMG_SIZE}" "appcast.xml:${WANT_APPCAST_SIZE}" | LC_ALL=C sort | tr '\n' ' ')"
WANT_ASSETS="${WANT_ASSETS% }"
if [ "$DRY_RUN" = yes ]; then
  echo "  query: gh release view ${TAG} --repo ${GITHUB_REPO} --json assets,isDraft"
  run gh release create "$TAG" --repo "$GITHUB_REPO" --verify-tag --draft --title "CGM Relay ${VERSION}" \
    --notes-file "${OUT_DIR}/${NOTES_FILE}" "${OUT_DIR}/${DMG_FILE}" "${OUT_DIR}/appcast.xml"
  echo "  then, only when the listed assets are exactly: ${WANT_ASSETS}"
  run gh release edit "$TAG" --repo "$GITHUB_REPO" --draft=false --latest
else
  # A draft carries the assets first and is published only once both are
  # there, so the live feed never points at a release without an appcast.
  if LISTING="$(asset_listing 2>"$SCRATCH/gh.err")"; then
    echo "  already exists: ${LISTING}"
  else
    # Only "not found" means the release is absent; any other error stops here
    # rather than trying to create over a release that may exist.
    grep -qi 'not found' "$SCRATCH/gh.err" ||
      die "could not ask GitHub about release ${TAG}: $(cat "$SCRATCH/gh.err")" "check gh auth status and the network, then run again"
    run gh release create "$TAG" --repo "$GITHUB_REPO" --verify-tag --draft --title "CGM Relay ${VERSION}" \
      --notes-file "${OUT_DIR}/${NOTES_FILE}" "${OUT_DIR}/${DMG_FILE}" "${OUT_DIR}/appcast.xml"
    LISTING="$(asset_listing)" || die "the release was created but cannot be read back" "look at the release page and run again"
  fi
  for want in "${DMG_FILE}" "appcast.xml"; do
    case " ${LISTING} " in
      *" ${want}:"*) ;;
      *) run gh release upload "$TAG" --repo "$GITHUB_REPO" "${OUT_DIR}/${want}" ;;
    esac
  done
  LISTING="$(asset_listing)" || die "cannot read the release back" "run again"
  ASSETS_ONLY="${LISTING#* }"
  [ "$ASSETS_ONLY" = "$WANT_ASSETS" ] ||
    die "the release carries \"${ASSETS_ONLY}\", expected \"${WANT_ASSETS}\"" \
      "fix the assets on the release page (delete a wrong one), then run again"
  case "$LISTING" in
    draft=true*) run gh release edit "$TAG" --repo "$GITHUB_REPO" --draft=false --latest ;;
  esac
  echo "  observed: $(asset_listing)"
fi

step "Surface 3 and 4: the live feed and the download"
if [ "$DRY_RUN" = yes ]; then
  run curl -sIL "$FEED_URL"
  run curl -sIL "$DOWNLOAD_URL"
  echo
  CURRENT_STEP="Dry run"
  echo "Dry run complete: nothing was run."
  [ "$WOULD_REFUSE" = no ] || die "this release is TEST ONLY; a real run would have refused before running anything" "build the real release"
  exit 0
fi
final_status() {
  # The last status line of a redirect chain is the one that matters.
  curl -sIL --retry 3 "$1" | tr -d '\r' | awk '/^HTTP\// {code=$2} END {print code}'
}
# The feed can trail the publish by a moment while GitHub's edge catches up.
FEED_CODE=""
for _ in 1 2 3 4 5 6; do
  FEED_CODE="$(final_status "$FEED_URL")"
  [ "$FEED_CODE" = 200 ] && break
  sleep 5
done
echo "  observed: ${FEED_URL} -> HTTP ${FEED_CODE}"
DMG_CODE="$(final_status "$DOWNLOAD_URL")"
echo "  observed: ${DOWNLOAD_URL} -> HTTP ${DMG_CODE}"
[ "$FEED_CODE" = 200 ] || die "the live feed answers HTTP ${FEED_CODE}, not 200" "look at the release page; clients cannot update until this is 200"
[ "$DMG_CODE" = 200 ] || die "the DMG URL answers HTTP ${DMG_CODE}, not 200" "look at the release page"
echo
echo "Published CGM Relay ${VERSION}. Now run: scripts/verify-release.sh ${VERSION}"
