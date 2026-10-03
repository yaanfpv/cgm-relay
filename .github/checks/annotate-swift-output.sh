#!/usr/bin/env bash
# Turns the Swift tool output saved by a failed check into GitHub error annotations, and leaves the
# first failure it found in <log-file>.first for the job summary.
# Usage: annotate-swift-output.sh <check-name> <log-file>
set -u

step="$1"
log="$2"

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo
: > "$log.first"

if [ ! -s "$log" ]; then
  echo "::error title=${step}::${step} failed with no output; see the step log"
  exit 0
fi

found=0
note_first() { [ -s "$log.first" ] || printf '%s' "$1" > "$log.first"; }
# A failing test is named before the line that explains it; once that line shows up, say both.
first_test=""
note_detail() {
  if [ -n "$first_test" ]; then
    printf '%s' "test ${first_test} at $1" > "$log.first"
    first_test=""
  else
    note_first "$1"
  fi
}

first_warning=""
while IFS= read -r line; do
  # Compiler and swift-testing diagnostics: path/to/File.swift:12:3: error: message
  if [[ "$line" =~ ^[[:space:]]*([^[:space:]:]+\.swift):([0-9]+):([0-9]+):[[:space:]](error|warning):[[:space:]](.*)$ ]]; then
    file="$(ci_repo_path "${BASH_REMATCH[1]}")"
    lineno="${BASH_REMATCH[2]}"
    severity="${BASH_REMATCH[4]}"
    msg="${BASH_REMATCH[5]}"
    echo "::${severity} file=${file},line=${lineno},title=${step}::${msg}"
    if [ "$severity" = "error" ]; then
      note_detail "${file}:${lineno}: ${msg}"
      found=1
    elif [ -z "$first_warning" ]; then
      first_warning="${file}:${lineno}: ${msg}"
    fi
  # swift-testing's own issue line: recorded an issue at File.swift:12:3: message
  elif [[ "$line" =~ recorded\ an\ issue\ at\ ([^[:space:]:]+\.swift):([0-9]+):([0-9]+):[[:space:]](.*)$ ]]; then
    file="$(ci_repo_path "${BASH_REMATCH[1]}")"
    lineno="${BASH_REMATCH[2]}"
    msg="${BASH_REMATCH[4]}"
    echo "::error file=${file},line=${lineno},title=${step}::${msg}"
    note_detail "${file}:${lineno}: ${msg}"
    found=1
  # A failing test by name, with no file:line attached. The closing line "Test run with N tests
  # ... failed" is the whole run, not a test.
  elif [[ "$line" =~ ✘[[:space:]]Test[[:space:]](.*)[[:space:]]failed ]] && [[ "${BASH_REMATCH[1]}" != "run with "* ]]; then
    echo "::error title=${step}::test ${BASH_REMATCH[1]} failed"
    [ -s "$log.first" ] || first_test="${BASH_REMATCH[1]}"
    note_first "test ${BASH_REMATCH[1]}"
    found=1
  fi
done < "$log"

# A warning is the first failure only when the log holds no error at all.
if [ "$found" -eq 0 ] && [ -n "$first_warning" ]; then
  echo "::error title=${step}::${step} failed; the only diagnostics were warnings, the first is ${first_warning}"
  note_first "$first_warning"
  found=1
fi

if [ "$found" -eq 0 ]; then
  # No file, line or test name to point at: show the first line of the tool's own complaint.
  complaint="$(grep -v -e '^#' -e '^[[:space:]]*$' "$log" | head -n 1)"
  [ -n "$complaint" ] || complaint="${step} failed"
  echo "::error title=${step}::${complaint}"
  note_first "$complaint"
fi
