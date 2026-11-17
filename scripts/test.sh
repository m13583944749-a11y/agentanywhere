#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_command xcodebuild
if [[ "${SKIP_GENERATE:-0}" != "1" ]]; then
  bash scripts/generate.sh
fi

SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 16}"
SIMULATOR_OS="${SIMULATOR_OS:-latest}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=${SIMULATOR_NAME},OS=${SIMULATOR_OS}}"
RESULT_BUNDLE_PATH=".build/TestResults.xcresult"

mkdir -p .build
rm -rf "$RESULT_BUNDLE_PATH"

printf '运行单元测试：%s\n' "$DESTINATION"
xcodebuild test \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  GALNOOK_BUNDLE_ID="$BUNDLE_ID" \
  ONLY_ACTIVE_ARCH=YES

printf '测试结果：%s/%s\n' "$ROOT_DIR" "$RESULT_BUNDLE_PATH"
