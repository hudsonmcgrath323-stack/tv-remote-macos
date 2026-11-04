#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-0.1.0}"
ARCH="$(uname -m)"

DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/TV Remote.app"
ZIP_NAME="TV-Remote-v${VERSION}-macOS-${ARCH}.zip"
DMG_NAME="TV-Remote-v${VERSION}-macOS-${ARCH}.dmg"

cd "$PROJECT_ROOT"
mkdir -p "$DIST_DIR"

# 1. Build clean MIT-compliant standalone .app (no bundled LGPL site-packages)
echo "==> Building TV Remote.app (v${VERSION}, ${ARCH})..."
TVREMOTE_BUNDLE_SITE_PACKAGES=0 TVREMOTE_APP_OUTPUT="$APP_BUNDLE" "$SCRIPT_DIR/build_app.sh"

# 2. Verify bundle signature & structure
echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

# 3. Create macOS .zip using ditto (preserves code signature, permissions & resource forks)
echo "==> Creating $ZIP_NAME..."
rm -f "$DIST_DIR/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$DIST_DIR/$ZIP_NAME"

# 4. Create drag-to-Applications .dmg disk image
echo "==> Creating $DMG_NAME..."
rm -f "$DIST_DIR/$DMG_NAME"
DMG_STAGE="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$DMG_STAGE/TV Remote.app"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
    -volname "TV Remote" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DIST_DIR/$DMG_NAME" >/dev/null

rm -rf "$DMG_STAGE"

# 5. Generate SHA-256 checksums
echo "==> Generating SHA256SUMS.txt..."
(
    cd "$DIST_DIR"
    shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
)

# Clean intermediate build cache so repo stays tidy
rm -rf "$PROJECT_ROOT/.build"

echo ""
echo "Release artifacts ready in $DIST_DIR:"
ls -lh "$DIST_DIR/$DMG_NAME" "$DIST_DIR/$ZIP_NAME" "$DIST_DIR/SHA256SUMS.txt"
cat "$DIST_DIR/SHA256SUMS.txt"
