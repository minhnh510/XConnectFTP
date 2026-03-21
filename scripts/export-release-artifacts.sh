#!/bin/zsh

set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-XConnectFTP.xcodeproj}"
SCHEME="${SCHEME:-XConnectFTP}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-XConnectFTP}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.derivedData-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/release}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"

BUILD_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"
APP_PATH="$BUILD_DIR/$APP_NAME.app"

rm -rf "$DERIVED_DATA_PATH" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "Building $APP_NAME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle not found at $APP_PATH" >&2
  exit 1
fi

PLIST_PATH="$APP_PATH/Contents/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_PATH")"
ARTIFACT_BASENAME="${APP_NAME}-${APP_VERSION}-${BUILD_NUMBER}-macOS"
ZIP_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME}.dmg"
CHECKSUMS_PATH="$OUTPUT_DIR/checksums.txt"

echo "Packaging zip..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.release.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "Packaging dmg..."
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Generating checksums..."
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$ZIP_PATH")" "$(basename "$DMG_PATH")"
) > "$CHECKSUMS_PATH"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "app_path=$APP_PATH"
    echo "app_version=$APP_VERSION"
    echo "build_number=$BUILD_NUMBER"
    echo "zip_path=$ZIP_PATH"
    echo "dmg_path=$DMG_PATH"
    echo "checksums_path=$CHECKSUMS_PATH"
  } >> "$GITHUB_OUTPUT"
fi

echo "Release artifacts created:"
echo "- $ZIP_PATH"
echo "- $DMG_PATH"
echo "- $CHECKSUMS_PATH"
