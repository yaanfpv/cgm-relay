#!/usr/bin/env bash
# Turns the Go tool output saved by a failed CI step into GitHub error annotations.
# Usage: annotate-go-output.sh <step-name> <log-file>
set -u

step="$1"
log="$2"

if [ ! -s "$log" ]; then
  echo "::error title=${step}::${step} failed with no output; see the step log"
  exit 0
fi

found=0
while IFS= read -r line; do
  # Compiler and vet diagnostics: path/to/file.go:12:3: message
  if [[ "$line" =~ ^[[:space:]]*(\./)?([^[:space:]:]+\.go):([0-9]+)(:[0-9]+)?:[[:space:]](.*)$ ]]; then
    file="${BASH_REMATCH[2]}"
    lineno="${BASH_REMATCH[3]}"
    msg="${BASH_REMATCH[5]}"
    echo "::error file=${file},line=${lineno},title=${step}::${msg}"
    found=1
  # A failing test by name
  elif [[ "$line" =~ ^[[:space:]]*---[[:space:]]FAIL:[[:space:]]([^[:space:]]+) ]]; then
    echo "::error title=${step}::test ${BASH_REMATCH[1]} failed"
    found=1
  # A package that failed to build or test
  elif [[ "$line" =~ ^FAIL[[:space:]]+([^[:space:]]+) ]]; then
    echo "::error title=${step}::package ${BASH_REMATCH[1]} failed"
    found=1
  fi
done < "$log"

if [ "$found" -eq 0 ]; then
  echo "::error title=${step}::${step} failed; see the step log"
fi
