#!/usr/bin/env bash
# Runs the CI leg selector next to this file, from any working directory:
#   bash .github/checks/ci-legs.sh --legs-for <base>
#   bash .github/checks/ci-legs.sh gate --event <event name>   (needs context as JSON on stdin)
#   bash .github/checks/ci-legs.sh nightly --event <name> --head <sha> --run-id <id> --runs-url <url>
# The pull request's plan job and the gate job both call it, so they cannot disagree.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/ci-legs.py" "$@"
