#!/usr/bin/env bash
set -euo pipefail

APP="/Applications/Visual Studio Code.app"

if [[ ! -d "$APP" ]]; then
  echo "ERROR: Not found: $APP" >&2
  exit 1
fi

echo "== VS Code: bundle info =="
echo "Path: $APP"
echo

echo "== Ownership / perms (top-level) =="
ls -ld "$APP"
stat -f "Owner=%Su Group=%Sg Mode=%Sp" "$APP"
echo

echo "== Filesystem / mount =="
df -h "$APP" | sed '1q;2p'
echo
echo "Mount flags (looking for 'read-only'):"
FS_DEV="$(df "$APP" | tail -1 | awk '{print $1}')"
mount | grep -F "on /" | grep -F "$FS_DEV" || true
echo

echo "== Extended attributes (quarantine?) =="
if xattr -l "$APP" 2>/dev/null | grep -q "com.apple.quarantine"; then
  echo "QUARANTINE: PRESENT"
  xattr -p com.apple.quarantine "$APP" || true
else
  echo "QUARANTINE: not present"
fi
echo

echo "== codesign verification =="
if codesign --verify --deep --strict --verbose=2 "$APP" >/tmp/vscode-codesign.log 2>&1; then
  echo "codesign: OK"
else
  echo "codesign: FAIL"
  sed -n '1,120p' /tmp/vscode-codesign.log
fi
echo

echo "== Writability test (inside bundle) =="
TESTDIR="$APP/Contents/_writetest_$(date +%s)"
if mkdir "$TESTDIR" 2>/dev/null; then
  rmdir "$TESTDIR"
  echo "Writable: YES (able to create/remove a dir inside Contents)"
else
  echo "Writable: NO (cannot create dir inside Contents)"
  echo "This is consistent with 'read-only mode' update failures."
fi
echo

echo "== Shell PATH install sanity (optional) =="
if command -v code >/dev/null 2>&1; then
  echo "code found at: $(command -v code)"
  ls -l "$(command -v code)" || true
else
  echo "code not found in PATH (fine)."
fi
echo

echo "Done."