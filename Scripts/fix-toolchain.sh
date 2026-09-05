#!/bin/bash
# Removes the stale duplicate modulemap in Command Line Tools.
#
# CLT installs sometimes leave behind an older module.modulemap next to
# bridging.modulemap. Both define `SwiftBridging`, so importing AppKit fails with
# "redefinition of module 'SwiftBridging'". The two files are byte-identical
# apart from a copyright year; only the stale one needs to go.
#
#   sudo ./Scripts/fix-toolchain.sh
#
# Reversible: the file is backed up next to itself, and reinstalling the Command
# Line Tools restores it anyway.
set -euo pipefail

CLT_SWIFT="/Library/Developer/CommandLineTools/usr/include/swift"
STALE="$CLT_SWIFT/module.modulemap"
CURRENT="$CLT_SWIFT/bridging.modulemap"

if [ "$(id -u)" -ne 0 ]; then
  echo "This needs root to write inside /Library/Developer. Re-run with:" >&2
  echo "  sudo $0" >&2
  exit 1
fi

if [ ! -f "$STALE" ]; then
  echo "Nothing to do: $STALE is already gone."
  exit 0
fi

if [ ! -f "$CURRENT" ]; then
  echo "Refusing to act: $CURRENT is missing, so $STALE is the only copy." >&2
  exit 1
fi

if ! grep -q "module SwiftBridging" "$STALE" || ! grep -q "module SwiftBridging" "$CURRENT"; then
  echo "Refusing to act: these files are not the duplicate pair this script expects." >&2
  exit 1
fi

BACKUP="$STALE.disabled-$(date +%Y%m%d%H%M%S)"
mv "$STALE" "$BACKUP"
echo "Moved the stale modulemap to:"
echo "  $BACKUP"
echo
echo "Rebuild with ./Scripts/build-app.sh — it will skip the overlay workaround now."
