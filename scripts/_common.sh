#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="GalNook.xcodeproj"
SCHEME="GalNook"
BUNDLE_ID="${BUNDLE_ID:-app.galnook.ios}"
DERIVED_DATA_PATH=".build/DerivedData"

cd "$ROOT_DIR"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '错误：需要命令 %s，请先安装并确保其在 PATH 中。\n' "$1" >&2
    exit 127
  fi
}
