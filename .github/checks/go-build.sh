#!/usr/bin/env bash
# Pull request check "Go build". Run it from anywhere: bash .github/checks/go-build.sh
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo
export CGO_ENABLED=0
ci_run go "Go build" "go build ./..." go build ./...
