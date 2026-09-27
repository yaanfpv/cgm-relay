#!/usr/bin/env bash
# Turns the Swift tool output saved by a failed CI step into GitHub error annotations.
# Usage: annotate-swift-output.sh <step-name> <log-file>
set -u

step="$1"
log="$2"

if [ ! -s "$log" ]; then
  echo "::error title=${step}::${step} failed with no output; see the step log"
  exit 0
fi

found=0
while IFS= read -r line; do
  # Compiler and swift-testing diagnostics: path/to/File.swift:12:3: error: message
  if [[ "$line" =~ ^[[:space:]]*([^[:space:]:]+\.swift):([0-9]+):([0-9]+):[[:space:]](error|warning):[[:space:]](.*)$ ]]; then
    file="${BASH_REMATCH[1]}"
    lineno="${BASH_REMATCH[2]}"
    msg="${BASH_REMATCH[5]}"
    echo "::error file=${file},line=${lineno},title=${step}::${msg}"
    found=1
  # swift-testing's own issue line: recorded an issue at File.swift:12:3: message
  elif [[ "$line" =~ recorded\ an\ issue\ at\ ([^[:space:]:]+\.swift):([0-9]+):([0-9]+):[[:space:]](.*)$ ]]; then
    file="${BASH_REMATCH[1]}"
    lineno="${BASH_REMATCH[2]}"
    msg="${BASH_REMATCH[4]}"
    echo "::error file=${file},line=${lineno},title=${step}::${msg}"
    found=1
  # A failing test by name, with no file:line attached
  elif [[ "$line" =~ ✘[[:space:]]Test[[:space:]](.*)[[:space:]]failed ]]; then
    echo "::error title=${step}::test ${BASH_REMATCH[1]} failed"
    found=1
  fi
done < "$log"

if [ "$found" -eq 0 ]; then
  echo "::error title=${step}::${step} failed; see the step log"
fi
