#!/usr/bin/env bash
# Turns the Go tool output saved by a failed check into GitHub error annotations, and leaves the
# first failure it found in <log-file>.first for the job summary.
# Usage: annotate-go-output.sh <check-name> <log-file>
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

while IFS= read -r line; do
  # Compiler, vet and gofmt diagnostics: path/to/file.go:12:3: message
  if [[ "$line" =~ ^[[:space:]]*(\./)?([^[:space:]:]+\.go):([0-9]+)(:[0-9]+)?:[[:space:]](.*)$ ]]; then
    file="$(ci_repo_path "${BASH_REMATCH[2]}")"
    lineno="${BASH_REMATCH[3]}"
    msg="${BASH_REMATCH[5]}"
    echo "::error file=${file},line=${lineno},title=${step}::${msg}"
    note_detail "${file}:${lineno}: ${msg}"
    found=1
  # A failing test by name
  elif [[ "$line" =~ ^[[:space:]]*---[[:space:]]FAIL:[[:space:]]([^[:space:]]+) ]]; then
    echo "::error title=${step}::test ${BASH_REMATCH[1]} failed"
    [ -s "$log.first" ] || first_test="${BASH_REMATCH[1]}"
    note_first "test ${BASH_REMATCH[1]}"
    found=1
  # A package that failed to build or test
  elif [[ "$line" =~ ^FAIL[[:space:]]+([^[:space:]]+) ]]; then
    echo "::error title=${step}::package ${BASH_REMATCH[1]} failed"
    note_first "package ${BASH_REMATCH[1]}"
    found=1
  fi
done < "$log"

if [ "$found" -eq 0 ]; then
  # No file, line or test name to point at: show the first line of the tool's own complaint.
  complaint="$(grep -v -e '^#' -e '^[[:space:]]*$' "$log" | head -n 1)"
  [ -n "$complaint" ] || complaint="${step} failed"
  echo "::error title=${step}::${complaint}"
  note_first "$complaint"
fi
