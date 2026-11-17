#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_command xcodebuild
if [[ "${SKIP_GENERATE:-0}" != "1" ]]; then
  bash scripts/generate.sh
fi

# Compile the app and every test target without requiring an installed iOS
# simulator runtime. The portable suite is executed on Linux/CI separately;
# `make test` remains available on macOS with an installed simulator.
xcodebuild build-for-testing \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  GALNOOK_BUNDLE_ID="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

printf '应用与测试目标编译完成。\n'
