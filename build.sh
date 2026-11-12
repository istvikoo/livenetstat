#!/bin/zsh
# Builds a universal (Apple silicon + Intel) NetSpeed.app next to this script.
# Requires Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"

APP="NetSpeed.app"
BIN="$APP/Contents/MacOS/NetSpeed"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library \
    -target "$arch-apple-macos13.0" \
    Sources/NetSpeed.swift \
    -o "$TMP/NetSpeed-$arch"
done
lipo -create "$TMP/NetSpeed-arm64" "$TMP/NetSpeed-x86_64" -output "$BIN"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NetSpeed</string>
  <key>CFBundleDisplayName</key><string>NetSpeed</string>
  <key>CFBundleIdentifier</key><string>local.netspeed</string>
  <key>CFBundleExecutable</key><string>NetSpeed</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP"
