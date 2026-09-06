#!/bin/bash
# Updates an installed T3 Notch to the latest commit on main: pull, rebuild,
# test, and swap the copy in /Applications while the app is closed.
#
#   update.sh           pull and reinstall if anything is out of date
#   update.sh --force   rebuild and reinstall regardless
#
# Safe to re-run. It refuses rather than guesses whenever the clone is not in a
# state it can fast-forward.
set -euo pipefail

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
elif [ -n "${1:-}" ]; then
  echo "usage: update.sh [--force]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED="/Applications/T3 Notch.app"
BUILT="$ROOT/build/T3 Notch.app"

cd "$ROOT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: $ROOT is not a git clone, so there is nothing to pull." >&2
  echo "Re-clone with: git clone https://github.com/tmmywatsn/t3notch.git" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: you have uncommitted changes. Commit or stash them first." >&2
  git status --short >&2
  exit 1
fi

before="$(git rev-parse --short HEAD)"

echo "==> pulling"
# --ff-only so a diverged branch stops here rather than opening a merge.
git pull --ff-only

after="$(git rev-parse --short HEAD)"
WANT="$(tr -d ' \t\n' < "$ROOT/VERSION")"

# A no-op pull is not enough to skip the rebuild: the clone can already be
# current while /Applications is still on an older build, which is exactly what
# happens to anyone who pulled by hand before running this. Compare what is
# installed as well, so "already up to date" always means the app is too.
INSTALLED_VERSION=""
if [ -d "$INSTALLED" ]; then
  INSTALLED_VERSION="$(plutil -extract CFBundleShortVersionString raw \
    "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
fi

if [ "$FORCE" = "0" ] && [ "$before" = "$after" ] && [ "$INSTALLED_VERSION" = "$WANT" ]; then
  echo "Already up to date ($WANT, $after)."
  exit 0
fi

echo "==> testing"
"$ROOT/Scripts/test.sh" >/dev/null
echo "tests passed"

"$ROOT/Scripts/build-app.sh"

# Quit before replacing the bundle: swapping it underneath a running app leaves
# the process pointing at files that no longer exist.
if pgrep -x T3Notch >/dev/null 2>&1; then
  echo "==> quitting the running app"
  osascript -e 'quit app "T3 Notch"' >/dev/null 2>&1 || pkill -x T3Notch || true
  for _ in $(seq 1 25); do
    pgrep -x T3Notch >/dev/null 2>&1 || break
    sleep 0.2
  done
  pkill -x T3Notch 2>/dev/null || true
  was_running=1
else
  was_running=0
fi

echo "==> installing to $INSTALLED"
rm -rf "$INSTALLED"
cp -R "$BUILT" "$INSTALLED"

if [ "$was_running" = "1" ]; then
  echo "==> relaunching"
  open "$INSTALLED"
fi

if [ "$before" = "$after" ]; then
  echo "Reinstalled $WANT ($after)."
else
  echo "Updated $before -> $after ($WANT)."
fi
