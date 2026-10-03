#!/usr/bin/env bash
# Pull request check "Go tests". Run it from anywhere: bash .github/checks/go-test.sh
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo
export CGO_ENABLED=1
ci_run go "Go tests" "go test -race -count=1 ./..." go test -race -count=1 ./...
