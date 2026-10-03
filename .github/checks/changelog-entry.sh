#!/usr/bin/env bash
# Pull request check "Changelog entry": the change must add a line under `## [Unreleased]` in
# CHANGELOG.md.
#
# Usage: BASE_SHA=<base> HEAD_SHA=<head> bash .github/checks/changelog-entry.sh
# Locally: BASE_SHA=origin/main HEAD_SHA=HEAD bash .github/checks/changelog-entry.sh
# The comparison is the pull request's own change (base...head), as GitHub shows it.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo

title="Changelog entry"
base="${BASE_SHA:?set BASE_SHA to the commit the change is compared against}"
head="${HEAD_SHA:?set HEAD_SHA to the commit with the change}"
file="CHANGELOG.md"
shown="BASE_SHA=origin/main HEAD_SHA=HEAD bash .github/checks/changelog-entry.sh"

fail() {
  local line="$1" message="$2"
  if [ -n "$line" ]; then
    echo "::error file=${file},line=${line},title=${title}::${message}"
  else
    echo "::error file=${file},title=${title}::${message}"
  fi
  {
    echo "### ${title} failed"
    echo
    echo "$message"
    echo
    echo "Add one line under \`## [Unreleased]\` in \`${file}\` that describes the change for someone using the app, in the style of the lines already there."
    echo
    echo "If the change needs no entry (documentation or CI only), ask a maintainer to add the \`no changelog\` label."
    echo
    echo "Check it yourself from the repository root:"
    echo
    echo '```'
    echo "$shown"
    echo '```'
  } | ci_summary
  exit 1
}

changelog="$(git show "${head}:${file}" 2>/dev/null)" || fail "" "${file} does not exist at the head of this change."

# The lines of the Unreleased section, as a first and last line number.
range="$(awk '
  /^## \[Unreleased\]/ { start = NR; next }
  start && /^## \[/    { print start, NR - 1; found = 1; exit }
  END { if (start && !found) print start, NR }
' <<< "$changelog")"
[ -n "$range" ] || fail "" "${file} has no \`## [Unreleased]\` heading to add the entry under."
first="${range% *}"
last="${range#* }"

# Added line numbers in the new file, from the zero-context diff's hunk headers.
added="$(git diff -U0 "${base}...${head}" -- "$file" | awk '
  /^@@/ {
    split($3, p, ",")
    start = substr(p[1], 2) + 0
    count = (p[2] == "") ? 1 : p[2] + 0
    for (i = 0; i < count; i++) print start + i
  }')"

entries=0
for n in $added; do
  if [ "$n" -gt "$first" ] && [ "$n" -le "$last" ]; then
    text="$(sed -n "${n}p" <<< "$changelog")"
    case "$text" in
      ""|\#*) ;;
      *[![:space:]]*) entries=$((entries + 1)) ;;
    esac
  fi
done

if [ "$entries" -eq 0 ]; then
  fail "$first" "This change adds no line under \`## [Unreleased]\` in ${file}."
fi
echo "Found ${entries} new line(s) under ## [Unreleased]."
