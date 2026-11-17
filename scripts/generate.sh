#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_command xcodegen

GALNOOK_BUNDLE_ID="$BUNDLE_ID" xcodegen generate --spec project.yml
printf '已生成 %s/%s\n' "$ROOT_DIR" "$PROJECT_FILE"
