#!/usr/bin/env bash
# Pull request check "Swift tests". Run it from anywhere: bash .github/checks/swift-test.sh
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo
# One test at a time: several tests that each wait on a child process at once can leave Swift's shared
# threads too few on a small runner, so a waiting test runs out of time before its child's end is seen.
ci_run swift "Swift tests" "swift test --no-parallel --package-path macos/Packages/CGMRelayCore" swift test --no-parallel --package-path macos/Packages/CGMRelayCore
