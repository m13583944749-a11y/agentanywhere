#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_command xcodebuild
require_command ditto
require_command zip
require_command unzip
if [[ "${SKIP_GENERATE:-0}" != "1" ]]; then
  bash scripts/generate.sh
fi

ARCHIVE_PATH=".build/GalNook.xcarchive"
IPA_STAGING_PATH=".build/IPA"
IPA_PATH=".build/GalNook.ipa"
APP_PATH="$ARCHIVE_PATH/Products/Applications/GalNook.app"

mkdir -p .build
rm -rf "$ARCHIVE_PATH" "$IPA_STAGING_PATH"
rm -f "$IPA_PATH"

printf '构建 generic iOS device 未签名归档，bundle id：%s\n' "$BUNDLE_ID"
xcodebuild archive \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  GALNOOK_BUNDLE_ID="$BUNDLE_ID" \
  SKIP_INSTALL=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM=""

if [[ ! -d "$APP_PATH" ]]; then
  printf '错误：归档中缺少 %s。\n' "$APP_PATH" >&2
  exit 1
fi

mkdir -p "$IPA_STAGING_PATH/Payload"
ditto "$APP_PATH" "$IPA_STAGING_PATH/Payload/GalNook.app"
(
  cd "$IPA_STAGING_PATH"
  zip -qry GalNook.ipa Payload
)
mv "$IPA_STAGING_PATH/GalNook.ipa" "$IPA_PATH"
unzip -tq "$IPA_PATH"

printf 'xcarchive：%s/%s\n' "$ROOT_DIR" "$ARCHIVE_PATH"
printf '未签名 IPA：%s/%s\n' "$ROOT_DIR" "$IPA_PATH"
