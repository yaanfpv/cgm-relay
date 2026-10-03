#!/usr/bin/env bash
# Pull request check "Mac app build". Run it from anywhere: bash .github/checks/mac-app-build.sh
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo
ci_run swift "Mac app build" "bash macos/scripts/build.sh CODE_SIGNING_ALLOWED=NO" bash macos/scripts/build.sh CODE_SIGNING_ALLOWED=NO
