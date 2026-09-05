#!/bin/bash
# Runs the pure-logic tests. Same compiler invocation as build-app.sh, with the
# app's entry point swapped for the test harness.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DEPLOYMENT_TARGET="14.0"

cd "$ROOT"
mkdir -p "$BUILD"

FLAGS=(-target "$(uname -m)-apple-macosx$DEPLOYMENT_TARGET" -sdk "$(xcrun --show-sdk-path)")

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
fi

# shellcheck disable=SC2046
swiftc "${FLAGS[@]}" \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -framework ServiceManagement -lsqlite3 \
  $(find "$ROOT/Sources" -name '*.swift' ! -name 'main.swift') \
  "$ROOT/Tests/main.swift" \
  -o "$BUILD/T3NotchTests"

"$BUILD/T3NotchTests"
