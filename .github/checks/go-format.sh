#!/usr/bin/env bash
# Pull request check "Go formatting". Run it from anywhere: bash .github/checks/go-format.sh
#
# Fails when a Go file is not gofmt-formatted, and also when a Go file does not parse. gofmt reports
# a file it cannot parse on stderr and exits non-zero while printing nothing on stdout, so the exit
# status is checked as well as the list.
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo

title="Go formatting"
shown="gofmt -l ."
log="$CI_LOG_DIR/go-formatting.log"
errors="$CI_LOG_DIR/go-formatting-errors.log"

: > "$log.first"

echo "==> ${title}: ${shown}"
unformatted="$(gofmt -l . 2>"$errors")"
rc=$?
cat "$errors"

if [ "$rc" -eq 0 ] && [ -z "$unformatted" ]; then
  echo "All Go files are formatted."
  exit 0
fi

# What the summary shows: the parse errors gofmt printed, then the files it would rewrite.
{
  cat "$errors"
  while IFS= read -r f; do
    [ -n "$f" ] && echo "${f}:1: not gofmt-formatted"
  done <<< "$unformatted"
} > "$log"

if [ -s "$errors" ]; then
  bash "$CI_REPO_ROOT/.github/checks/annotate-go-output.sh" "$title" "$errors"
  cp "$errors.first" "$log.first"
elif [ "$rc" -ne 0 ]; then
  echo "::error title=${title}::gofmt exited ${rc} with no message; see the step log"
  echo "gofmt exited ${rc} with no message" > "$log.first"
fi

if [ -n "$unformatted" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    echo "::error file=${f},title=${title}::not gofmt-formatted; run gofmt -w ${f}"
  done <<< "$unformatted"
  [ -s "$log.first" ] || echo "$(head -n 1 <<< "$unformatted") is not gofmt-formatted" > "$log.first"
fi

ci_fail_summary "$title" "$shown" "$log"
[ -n "$unformatted" ] && echo "Rewrite the formatted files with: gofmt -w ." | ci_summary
exit 1
