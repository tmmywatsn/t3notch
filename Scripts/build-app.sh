#!/bin/bash
# Builds "T3 Notch.app" into ./build.
#
# This calls swiftc directly rather than going through SwiftPM: the app has no
# third-party dependencies, and Command Line Tools installs frequently ship a
# libPackageDescription that does not match their PackageDescription.swiftmodule,
# which breaks `swift build` before it ever reaches our code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/T3 Notch.app"
BUNDLE_ID="com.tmmywatsn.t3notch"
DEPLOYMENT_TARGET="14.0"

# The VERSION file is the one source of truth, so a source tarball with no git
# history builds a correctly stamped app. release.yml checks that the tag being
# released matches it.
VERSION="$(tr -d ' \t\n' < "$ROOT/VERSION")"

# A build that is not exactly on its release tag is marked as such, so "1.0.0"
# in the settings panel always means the released 1.0.0. Display only: the
# CFBundle keys stay plain dotted numbers, which is all macOS accepts.
BUILD_ID="$VERSION"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if ! git -C "$ROOT" describe --tags --exact-match "v$VERSION" >/dev/null 2>&1 ||
     [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] ||
     [ "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" != "$(git -C "$ROOT" rev-parse "v$VERSION^{commit}" 2>/dev/null)" ]; then
    BUILD_ID="$VERSION+$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
  fi
fi

cd "$ROOT"
mkdir -p "$BUILD"

FLAGS=(-O -target "$(uname -m)-apple-macosx$DEPLOYMENT_TARGET" -sdk "$(xcrun --show-sdk-path)")

# Some Command Line Tools installs carry a stale module.modulemap next to
# bridging.modulemap; both define SwiftBridging, and any AppKit import then fails
# with a redefinition error. Mask the stale copy with a virtual filesystem
# overlay instead of modifying a system directory.
CLT_SWIFT="/Library/Developer/CommandLineTools/usr/include/swift"
if [ -f "$CLT_SWIFT/module.modulemap" ] && [ -f "$CLT_SWIFT/bridging.modulemap" ]; then
  : > "$BUILD/empty.modulemap"
  cat > "$BUILD/modulemap-overlay.yaml" <<YAML
{
  "version": 0,
  "case-sensitive": false,
  "roots": [
    {
      "type": "directory",
      "name": "$CLT_SWIFT",
      "contents": [
        { "type": "file", "name": "module.modulemap", "external-contents": "$BUILD/empty.modulemap" }
      ]
    }
  ]
}
YAML
  FLAGS+=(-Xfrontend -vfsoverlay -Xfrontend "$BUILD/modulemap-overlay.yaml")
  echo "note: masking a duplicate SwiftBridging modulemap in Command Line Tools"
fi

echo "==> compiling"
# shellcheck disable=SC2046
swiftc "${FLAGS[@]}" \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -framework ServiceManagement -lsqlite3 \
  $(find "$ROOT/Sources" -name '*.swift') \
  -o "$BUILD/T3Notch"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD/T3Notch" "$APP/Contents/MacOS/T3Notch"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>T3 Notch</string>
  <key>CFBundleDisplayName</key><string>T3 Notch</string>
  <key>CFBundleExecutable</key><string>T3Notch</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>T3NotchBuild</key><string>$BUILD_ID</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# An ad-hoc signature is enough locally, and keeps UserNotifications and
# SMAppService from rejecting the bundle outright.
codesign --force --sign - "$APP" >/dev/null 2>&1 ||
  echo "warning: ad-hoc codesign failed; the app still runs"

echo "==> built $APP ($BUILD_ID)"
