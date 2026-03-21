#!/bin/zsh

set -euo pipefail

require_env() {
  local name="$1"
  if [[ -z "${(P)name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

PROJECT_PATH="${PROJECT_PATH:-XConnectFTP.xcodeproj}"
SCHEME="${SCHEME:-XConnectFTP}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-XConnectFTP}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-vn.xconnect.XConnectFTP}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64="${APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64:-}"
APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD="${APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD:-}"
APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64="${APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64:-}"
APPLE_API_KEY_ID="${APPLE_API_KEY_ID:-}"
APPLE_API_ISSUER_ID="${APPLE_API_ISSUER_ID:-}"
APPLE_API_PRIVATE_KEY="${APPLE_API_PRIVATE_KEY:-}"
ICLOUD_CONTAINER_ENVIRONMENT="${ICLOUD_CONTAINER_ENVIRONMENT:-Production}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.derivedData-release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PWD/build/XConnectFTP.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$PWD/build/export}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/release}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-$(uuidgen)-$(uuidgen)}"

require_env APPLE_TEAM_ID
require_env APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64
require_env APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD
require_env APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64
require_env APPLE_API_KEY_ID
require_env APPLE_API_ISSUER_ID
require_env APPLE_API_PRIVATE_KEY

BUILD_ROOT="$PWD/build"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.notary.XXXXXX")"
KEYCHAIN_PATH="$TMP_ROOT/app-signing.keychain-db"
CERT_PATH="$TMP_ROOT/developer-id.p12"
PROFILE_PATH="$TMP_ROOT/profile.provisionprofile"
PROFILE_PLIST_PATH="$TMP_ROOT/profile.plist"
AUTH_KEY_PATH="$TMP_ROOT/AuthKey_${APPLE_API_KEY_ID}.p8"
EXPORT_OPTIONS_PATH="$TMP_ROOT/exportOptions.plist"
PRE_NOTARY_ZIP_PATH="$TMP_ROOT/${APP_NAME}-pre-notary.zip"
DMG_STAGING_DIR="$TMP_ROOT/dmg"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

decode_base64_to_file() {
  local encoded="$1"
  local destination="$2"
  printf '%s' "$encoded" | base64 -D > "$destination"
}

echo "Preparing signing assets..."
rm -rf "$DERIVED_DATA_PATH" "$BUILD_ROOT" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR" "$EXPORT_PATH" "$DMG_STAGING_DIR" "$HOME/Library/MobileDevice/Provisioning Profiles"

decode_base64_to_file "$APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64" "$CERT_PATH"
decode_base64_to_file "$APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64" "$PROFILE_PATH"
printf '%s' "$APPLE_API_PRIVATE_KEY" | tr -d '\r' > "$AUTH_KEY_PATH"
chmod 600 "$AUTH_KEY_PATH"

security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST_PATH"
PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST_PATH")"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST_PATH")"
cp "$PROFILE_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.provisionprofile"

echo "Configuring temporary keychain..."
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
existing_keychains=("${(@f)$(security list-keychains -d user | tr -d '"')}")
security list-keychains -d user -s "$KEYCHAIN_PATH" "${existing_keychains[@]}"
security default-keychain -d user -s "$KEYCHAIN_PATH"
security import "$CERT_PATH" -k "$KEYCHAIN_PATH" -P "$APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

cat > "$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>iCloudContainerEnvironment</key>
  <string>${ICLOUD_CONTAINER_ENVIRONMENT}</string>
  <key>method</key>
  <string>developer-id</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${APP_BUNDLE_ID}</key>
    <string>${PROFILE_NAME}</string>
  </dict>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>${APPLE_TEAM_ID}</string>
</dict>
</plist>
EOF

echo "Archiving signed app..."
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  PROVISIONING_PROFILE="$PROFILE_UUID" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH" \
  archive

echo "Exporting Developer ID app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected exported app bundle not found at $APP_PATH" >&2
  exit 1
fi

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Submitting app for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$PRE_NOTARY_ZIP_PATH"
xcrun notarytool submit "$PRE_NOTARY_ZIP_PATH" \
  --key "$AUTH_KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --wait

echo "Stapling notarization ticket to app..."
xcrun stapler staple "$APP_PATH"

PLIST_PATH="$APP_PATH/Contents/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_PATH")"
ARTIFACT_BASENAME="${APP_NAME}-${APP_VERSION}-${BUILD_NUMBER}-macOS"
ZIP_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME}.dmg"
CHECKSUMS_PATH="$OUTPUT_DIR/checksums.txt"

echo "Packaging final zip..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Packaging final dmg..."
ditto "$APP_PATH" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Submitting dmg for notarization..."
xcrun notarytool submit "$DMG_PATH" \
  --key "$AUTH_KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --wait

echo "Stapling notarization ticket to dmg..."
xcrun stapler staple "$DMG_PATH"

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

echo "Signed and notarized release artifacts created:"
echo "- $ZIP_PATH"
echo "- $DMG_PATH"
echo "- $CHECKSUMS_PATH"
