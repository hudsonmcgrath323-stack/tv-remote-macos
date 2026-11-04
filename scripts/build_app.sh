#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.env"
    set +a
fi

APP_BUNDLE="${TVREMOTE_APP_OUTPUT:-$PROJECT_ROOT/dist/TV Remote.app}"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VENV_DIR="${TVREMOTE_VENV_DIR:-$HOME/Library/Application Support/TVRemote/venv}"
BUNDLE_SITE_PACKAGES="${TVREMOTE_BUNDLE_SITE_PACKAGES:-0}"

cd "$PROJECT_ROOT"

# 1. Ensure pyatv isolated environment exists
if [ ! -x "$VENV_DIR/bin/python3" ]; then
    "$SCRIPT_DIR/setup_python.sh"
fi

# 2. Build Release Swift 6 binary
echo "Building TVRemote binary (Swift 6, Release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/TVRemote"

# 3. Assemble standalone macOS .app bundle
echo "Packaging '$APP_BUNDLE'..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/TVRemote"
chmod +x "$MACOS_DIR/TVRemote"
cp "$PROJECT_ROOT/src/TVRemote/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_ROOT/src/Helper/atv_bridge.py" "$RESOURCES_DIR/atv_bridge.py"
chmod +x "$RESOURCES_DIR/atv_bridge.py"

# Optionally bundle site-packages for local offline convenience (disabled by default
# for open-source binary releases to avoid redistributing LGPL-2.1 `zeroconf`).
if [ "$BUNDLE_SITE_PACKAGES" = "1" ]; then
    VENV_SITE_PKG="$(find "$VENV_DIR/lib" -maxdepth 2 -name "site-packages" | head -n 1)"
    if [ -n "$VENV_SITE_PKG" ] && [ -d "$VENV_SITE_PKG" ]; then
        rsync -a --delete --exclude "__pycache__" "$VENV_SITE_PKG/" "$RESOURCES_DIR/site-packages/"
    fi
fi

# 4. Generate crisp native AppIcon.icns
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
swift - "$ICONSET_DIR" <<'SWIFT'
import AppKit
import Foundation

let outDir = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (px, filename) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = CGFloat(px) * 0.09
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let radius = bgRect.width * 0.225

    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1.0),
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1.0)
    ])!
    gradient.draw(in: bgPath, angle: -90)

    NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
    bgPath.lineWidth = max(1.0, CGFloat(px) * 0.012)
    bgPath.stroke()

    let ringRadius = bgRect.width * 0.28
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let ringRect = NSRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
    let ringPath = NSBezierPath(ovalIn: ringRect)
    NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
    ringPath.fill()
    NSColor(calibratedWhite: 1.0, alpha: 0.45).setStroke()
    ringPath.lineWidth = max(1.0, CGFloat(px) * 0.018)
    ringPath.stroke()

    let innerRadius = ringRadius * 0.42
    let innerRect = NSRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
    let innerPath = NSBezierPath(ovalIn: innerRect)
    NSColor(calibratedWhite: 0.95, alpha: 0.92).setFill()
    innerPath.fill()

    NSGraphicsContext.restoreGraphicsState()

    if let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: "\(outDir)/\(filename)"))
    }
}
SWIFT

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

# 5. Ad-hoc sign the bundle so Keychain, Bonjour, and SMAppService work cleanly
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built standalone app: $APP_BUNDLE"
