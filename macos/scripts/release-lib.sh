# shellcheck shell=bash disable=SC2034
# Shared by release.sh, publish-release.sh and verify-release.sh. Sourced, never run.
# Callers set SCRIPT_DIR, MACOS_DIR and REPO_ROOT and `set -euo pipefail` first.

GITHUB_REPO="yaanfpv/cgm-relay"
FEED_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/appcast.xml"
PRODUCT_LINK="https://yaanfpv.com/apps/cgm-relay"
SPARKLE_ACCOUNT="cgm-relay"
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
BUILD_DIR="${MACOS_DIR}/.build"
RELEASES_DIR="${BUILD_DIR}/release"

CURRENT_STEP="starting"
SCRATCH_DIRS=()

step() {
  CURRENT_STEP="$1"
  echo "==> $1"
}

# die names the step that failed and what to do about it, then exits.
die() {
  echo "$(basename "$0"): FAILED at step \"${CURRENT_STEP}\": $1" >&2
  [ -z "${2:-}" ] || echo "  what to do: $2" >&2
  exit 1
}

# new_scratch makes a temporary directory outside the repository, that the
# exit trap removes, and sets SCRATCH to its path. It sets a variable rather
# than printing so the registration survives in the calling shell.
new_scratch() {
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/cgm-relay-release.XXXXXX")"
  SCRATCH_DIRS+=("$SCRATCH")
  case "$SCRATCH" in "${REPO_ROOT}"/*) die "temporary directory ${SCRATCH} is inside the repository" "point TMPDIR outside it" ;; esac
}

remove_scratch() {
  local d
  for d in ${SCRATCH_DIRS[@]+"${SCRATCH_DIRS[@]}"}; do
    rm -rf "$d"
  done
}

is_test_mode() {
  [ -n "${CGMRELAY_RELEASE_TEST_KEY_FILE:-}" ]
}

# refuse_test_knobs_outside_test_mode keeps every test-only setting from
# steering a real release.
refuse_test_knobs_outside_test_mode() {
  is_test_mode && return 0
  local v
  for v in CGMRELAY_RELEASE_SKIP_NOTARIZE CGMRELAY_RELEASE_TEST_DOWNLOAD_PREFIX CGMRELAY_RELEASE_TEST_PREVIOUS_APPCAST \
    CGMRELAY_RELEASE_TEST_BUNDLE_ID CGMRELAY_RELEASE_TEST_CONFIGURATION; do
    [ -z "${!v:-}" ] || die "${v} is set but CGMRELAY_RELEASE_TEST_KEY_FILE is not" "unset ${v}; it exists only for proving the scripts with a throwaway key"
  done
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1" "${2:-install it and run again}"
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# fetch_sparkle_tools downloads the pinned Sparkle release once and checks
# its SHA-256 before anything in it is run. Sets SPARKLE_BIN.
fetch_sparkle_tools() {
  local dir="${BUILD_DIR}/sparkle-${SPARKLE_VERSION}"
  SPARKLE_BIN="${dir}/bin"
  if [ -x "${SPARKLE_BIN}/generate_appcast" ] && [ "$(cat "${dir}/.tarball-sha256" 2>/dev/null)" = "${SPARKLE_SHA256}" ]; then
    return 0
  fi
  step "Fetching Sparkle ${SPARKLE_VERSION} command-line tools"
  mkdir -p "${BUILD_DIR}"
  new_scratch
  local tmp="$SCRATCH"
  curl -fsSL --retry 3 -o "${tmp}/sparkle.tar.xz" "${SPARKLE_URL}" ||
    die "could not download ${SPARKLE_URL}" "check the network and run again"
  local got
  got="$(sha256_of "${tmp}/sparkle.tar.xz")"
  [ "${got}" = "${SPARKLE_SHA256}" ] ||
    die "the Sparkle download has SHA-256 ${got}, expected ${SPARKLE_SHA256}" "do not use it; investigate before releasing"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  tar -xJf "${tmp}/sparkle.tar.xz" -C "${dir}" bin ||
    die "could not unpack the Sparkle tools" "delete ${dir} and run again"
  printf '%s\n' "${SPARKLE_SHA256}" >"${dir}/.tarball-sha256"
  [ -x "${SPARKLE_BIN}/generate_appcast" ] || die "the Sparkle download has no generate_appcast" "delete ${dir} and run again"
}

# build_edsig compiles the Ed25519 helper into $1 and sets EDSIG.
build_edsig() {
  EDSIG="$1/edsig"
  (cd "${REPO_ROOT}" && go build -o "${EDSIG}" ./cmd/edsig) || die "could not build the signature helper" "run go build ./cmd/edsig to see the error"
}

# changelog_heading_present is true when CHANGELOG.md has the dated heading for $1.
changelog_heading_present() {
  grep -Eq "^## \[${1//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$" "${REPO_ROOT}/CHANGELOG.md"
}

# changelog_notes prints the body of the CHANGELOG section for $1 with the
# blank lines around it trimmed.
changelog_notes() {
  awk -v want="## [$1] - " '
    index($0, want) == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on { lines[++n] = $0 }
    END {
      first = 1
      while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
      last = n
      while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }' "${REPO_ROOT}/CHANGELOG.md"
}

# appcast_field prints the text of every element with local name $2 under
# an item of appcast $1, one per line, newest item first.
appcast_field() {
  xmllint --xpath "//*[local-name()='item']/*[local-name()='$2']" "$1" 2>/dev/null |
    sed -e "s/<\/[^>]*>/\\
/g" -e 's/<[^>]*>//g' | sed -e '/^[[:space:]]*$/d'
}

# appcast_max_build prints the highest sparkle:version in appcast $1, or 0.
appcast_max_build() {
  local max=0 v
  while IFS= read -r v; do
    case "$v" in '' | *[!0-9]*) continue ;; esac
    [ "$v" -le "$max" ] || max="$v"
  done < <(appcast_field "$1" version)
  echo "$max"
}

dmg_name() {
  echo "CGM-Relay-$1.dmg"
}

release_dir() {
  echo "${RELEASES_DIR}/$1"
}

# origin_tag_commit prints the commit that tag $1 names on origin, or nothing
# when origin has no such tag. An annotated tag lists its own object and, on
# the peeled line, the commit it names; a lightweight tag lists the commit
# directly. Fails when origin cannot be asked.
origin_tag_commit() {
  local lines
  lines="$(git -C "$REPO_ROOT" ls-remote origin "refs/tags/$1" "refs/tags/$1^{}")" || return 1
  awk '/\^\{\}$/ { peeled = $1; next } { direct = $1 } END { print (peeled != "" ? peeled : direct) }' <<<"$lines"
}

# origin_tag_query prints, for a person, the command that shows the commit tag
# $1 names on origin, the same answer origin_tag_commit compares.
origin_tag_query() {
  echo "git ls-remote origin refs/tags/$1 'refs/tags/$1^{}' | awk '/\\^\\{\\}\$/ {p=\$1; next} {d=\$1} END {print (p != \"\" ? p : d)}'"
}

# release_field reads one `key: value` line of a RELEASE.md.
release_field() {
  sed -n "/^$2: /{s///p;q;}" "$1"
}

# detach_leftover releases an image a failed attach left attached but unmounted.
detach_leftover() {
  local dev
  dev="$(hdiutil info | awk -v want="image-path      : $1" '
    /^=+$/ { hit = 0; done = 0; next }
    $0 == want { hit = 1; next }
    hit && !done && /^\/dev\/disk/ { print $1; done = 1 }')"
  [ -z "$dev" ] || hdiutil detach -quiet "$dev" >/dev/null 2>&1 || true
}

# attach_dmg mounts $1 read-only at $2, trying again when the system is slow to
# hand the image over.
attach_dmg() {
  local try out
  for try in 1 2 3; do
    if out="$(hdiutil attach -nobrowse -readonly -noverify -mountpoint "$2" "$1" 2>&1)"; then
      return 0
    fi
    detach_leftover "$1"
    sleep 2
  done
  echo "$out" >&2
  return 1
}
