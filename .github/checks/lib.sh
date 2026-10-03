# shellcheck shell=bash
# Shared by the scripts in this folder. Each script is one pull request check, and the same script
# runs in CI and on a contributor's machine, so a red reads the same in both places.
#
# On a failure a check emits `::error` annotations (file and line where the tool gave one) and a
# summary block naming what failed, the first failing file or test, and the command that reproduces
# it. Without GITHUB_STEP_SUMMARY (a local run) the summary prints to the terminal instead.

CI_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_LOG_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

ci_enter_repo() {
  cd "$CI_REPO_ROOT" || exit 2
}

# Appends stdin to the job summary, or prints it when there is none.
ci_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >> "$GITHUB_STEP_SUMMARY"; else cat; fi
}

# Turns a path a tool printed into a path relative to the repository, so an annotation lands on the
# file. `go test` prints paths relative to the package, and `swift test` prints absolute ones.
ci_repo_path() {
  local p="$1"
  p="${p#./}"
  local root
  # The tool may print the checkout under a different spelling of its path (a symlinked temp dir).
  for root in "$CI_REPO_ROOT" "$(cd "$CI_REPO_ROOT" && pwd -P)" "${CI_REPO_ROOT#/private}" "${GITHUB_WORKSPACE:-}"; do
    [ -n "$root" ] && p="${p#"$root"/}"
  done
  if [ ! -f "$p" ]; then
    local found
    found="$(git ls-files --cached --others --exclude-standard -- "*/$p" 2>/dev/null)"
    if [ -n "$found" ] && [ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ]; then p="$found"; fi
  fi
  printf '%s' "$p"
}

# ci_fail_summary <title> <local command> <log>
# Writes the summary block for a failed check. The annotate scripts leave the first failure they
# found in <log>.first.
ci_fail_summary() {
  local title="$1" cmd="$2" log="$3" first=""
  [ -s "$log.first" ] && first="$(cat "$log.first")"
  {
    echo "### ${title} failed"
    echo
    if [ -n "$first" ]; then
      echo "First failure: \`${first}\`"
      echo
    fi
    echo "Run it yourself from the repository root:"
    echo
    echo '```'
    echo "$cmd"
    echo '```'
    if [ -s "$log" ]; then
      echo
      echo "<details><summary>Last lines of output</summary>"
      echo
      echo '```'
      tail -n 30 "$log"
      echo '```'
      echo
      echo "</details>"
    fi
  } | ci_summary
}

# ci_run <go|swift> <title> <local command shown to the reader> <command...>
# Runs the command with its output streamed to the job log and kept in a file. On failure it
# annotates the output, writes the summary and returns the command's exit status.
ci_run() {
  local kind="$1" title="$2" shown="$3"
  shift 3
  local log="$CI_LOG_DIR/${title// /-}.log"
  echo "==> ${title}: ${shown}"
  "$@" 2>&1 | tee "$log"
  local rc="${PIPESTATUS[0]}"
  if [ "$rc" -ne 0 ]; then
    bash "$CI_REPO_ROOT/.github/checks/annotate-${kind}-output.sh" "$title" "$log"
    ci_fail_summary "$title" "$shown" "$log"
  fi
  return "$rc"
}
