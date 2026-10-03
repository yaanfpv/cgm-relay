#!/usr/bin/env bash
# Pull request check "Swift tests". Run it from anywhere: bash .github/checks/swift-test.sh
set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ci_enter_repo
ci_run swift "Swift tests" "swift test --package-path macos/Packages/CGMRelayCore" swift test --package-path macos/Packages/CGMRelayCore
