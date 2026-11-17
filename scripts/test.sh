#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_command xcodebuild
if [[ "${SKIP_GENERATE:-0}" != "1" ]]; then
  bash scripts/generate.sh
fi

SIMULATOR_NAME="${SIMULATOR_NAME:-}"
SIMULATOR_OS="${SIMULATOR_OS:-latest}"
if [[ -z "${DESTINATION:-}" ]]; then
  if [[ -n "$SIMULATOR_NAME" ]]; then
    DESTINATION="platform=iOS Simulator,name=${SIMULATOR_NAME},OS=${SIMULATOR_OS}"
  else
    # GitHub 的 macOS 镜像会随 Xcode 版本变化，不能硬编码 iPhone 16。
    # 从当前镜像实际安装的 iOS 模拟器中选择一台可用 iPhone。
    SIMULATOR_UDID="$(
      xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
candidates = []
for runtime, devices in data.get("devices", {}).items():
    if ".iOS-" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            candidates.append((device["name"], device["udid"]))
candidates.sort(key=lambda item: (0 if item[0].startswith("iPhone 16") else 1, item[0]))
if not candidates:
    raise SystemExit("no available iPhone simulator")
print(candidates[0][1])
'
    )" || SIMULATOR_UDID=""
    if [[ -n "$SIMULATOR_UDID" ]]; then
      DESTINATION="platform=iOS Simulator,id=${SIMULATOR_UDID}"
    else
      DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=${SIMULATOR_OS}"
    fi
  fi
fi
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
