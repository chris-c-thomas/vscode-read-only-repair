#!/usr/bin/env bash
set -euo pipefail

APP="/Applications/Visual Studio Code - Insiders.app"

if [[ ! -d "$APP" ]]; then
  echo "ERROR: Not found: $APP" >&2
  exit 1
fi

echo "== Stopping VS Code Insiders (if running) =="
# Use multiple strategies; ignore failures
pkill -f "Visual Studio Code - Insiders" >/dev/null 2>&1 || true
pkill -f "Code - Insiders" >/dev/null 2>&1 || true
sleep 1

echo "== Removing quarantine attribute (if present) =="
# Remove recursively; safe even if not present
sudo xattr -dr com.apple.quarantine "$APP" || true

echo "== Ensuring correct ownership (user:staff) =="
USER_NAME="$(id -un)"
sudo chown -R "${USER_NAME}:staff" "$APP"

echo "== Ensuring sane permissions =="
# Directories 755, files 644; preserve executables by leaving +x intact where present.
# This avoids clobbering embedded binaries.
sudo chmod -R u+rwX,go+rX,go-w "$APP"

echo "== Writability test =="
TESTDIR="$APP/Contents/_writetest_$(date +%s)"
if sudo -u "$USER_NAME" mkdir "$TESTDIR" 2>/dev/null; then
  sudo -u "$USER_NAME" rmdir "$TESTDIR"
  echo "Writable: YES"
else
  echo "Writable: NO"
  echo "If this persists, the containing volume may be mounted read-only or protected by another tool."
fi

echo "== codesign verification (diagnostic) =="
if codesign --verify --deep --strict --verbose=2 "$APP" >/tmp/vscode-insiders-codesign.log 2>&1; then
  echo "codesign: OK"
else
  echo "codesign: FAIL (this can break updates and launches)"
  sed -n '1,160p' /tmp/vscode-insiders-codesign.log
  echo
  echo "If codesign is failing, the safest fix is a fresh reinstall from Microsoft."
fi

echo "Done. Relaunch VS Code Insiders and try 'Check for Updates' again."