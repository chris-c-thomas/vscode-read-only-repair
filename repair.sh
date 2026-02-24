#!/usr/bin/env bash
# repair.sh
#
# Unified maintenance script for VS Code macOS bundles:
#   - Stable:   /Applications/Visual Studio Code.app
#   - Insiders: /Applications/Visual Studio Code - Insiders.app
#
# Subcommands:
#   - check : diagnostics only
#   - fix   : attempts to restore bundle writeability for self-updates
#
# Intentionally NOT for forks (Cursor/Windsurf/etc). Enforced by bundle identifier.
#
# Requirements:
#   - macOS
#   - bash
#   - /usr/bin/osascript, /usr/bin/codesign, /usr/bin/xattr, /bin/ls, /usr/sbin/chown, /bin/chmod
#   - plutil (macOS default)

set -euo pipefail

STABLE_APP_DEFAULT="/Applications/Visual Studio Code.app"
INSIDERS_APP_DEFAULT="/Applications/Visual Studio Code - Insiders.app"

SCRIPT_NAME="$(basename "$0")"

# ----- helpers -----

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME <check|fix> [--stable|--insiders] [--app "/path/to/VS Code.app"] [--no-kill] [--verbose]

Defaults:
  channel: --stable
  app:     stable/insiders default app path unless --app provided

Subcommands:
  check    Print diagnostics (no modifications)
  fix      Attempt to "unlock" the app bundle (may require sudo)

Options:
  --stable      Target stable bundle (default)
  --insiders    Target insiders bundle
  --app PATH    Explicit app bundle path override
  --no-kill     Do not attempt to quit/kill running VS Code processes during fix
  --verbose     Print extra details (xattrs, file flags summary)
  -h, --help    Show this help

Examples:
  $SCRIPT_NAME check
  $SCRIPT_NAME check --insiders
  $SCRIPT_NAME fix
  $SCRIPT_NAME fix --insiders
  $SCRIPT_NAME fix --app "/Applications/Visual Studio Code - Insiders.app"
  $SCRIPT_NAME fix --insiders --no-kill
EOF
}

die_usage() {
  echo "ERROR: $*" >&2
  echo >&2
  usage >&2
  exit 2
}

log() { echo "$*"; }

is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing required command: $1" >&2; exit 1; }
}

require_app_bundle() {
  local app="$1"
  [[ "$app" == *.app ]] || die_usage "App path must end in .app: $app"
  [[ -d "$app" ]] || { echo "ERROR: Not found: $app" >&2; exit 1; }
  [[ -f "$app/Contents/Info.plist" ]] || { echo "ERROR: Missing Info.plist in: $app" >&2; exit 1; }
}

# Read a key from Info.plist using plutil.
# Returns empty string if missing.
plist_read() {
  local plist="$1"
  local key="$2"
  # plutil -extract returns nonzero if key missing; suppress errors.
  /usr/bin/plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true
}

bundle_id_from_app() {
  local app="$1"
  plist_read "$app/Contents/Info.plist" "CFBundleIdentifier"
}

bundle_executable_from_app() {
  local app="$1"
  plist_read "$app/Contents/Info.plist" "CFBundleExecutable"
}

bundle_name_from_app() {
  local app="$1"
  # Prefer CFBundleName; fallback to app directory name without .app
  local name
  name="$(plist_read "$app/Contents/Info.plist" "CFBundleName")"
  if [[ -n "$name" ]]; then
    echo "$name"
  else
    basename "$app" .app
  fi
}

is_supported_bundle_id() {
  local bid="$1"
  [[ "$bid" == "com.microsoft.VSCode" || "$bid" == "com.microsoft.VSCodeInsiders" ]]
}

detect_channel_from_bundle_id() {
  local bid="$1"
  if [[ "$bid" == "com.microsoft.VSCodeInsiders" ]]; then
    echo "insiders"
  else
    echo "stable"
  fi
}

cli_name_for_channel() {
  local channel="$1"
  if [[ "$channel" == "insiders" ]]; then
    echo "code-insiders"
  else
    echo "code"
  fi
}

print_mount_flags_minimal() {
  local app="$1"
  local fs_dev
  fs_dev="$(df "$app" | tail -1 | awk '{print $1}')"
  # Print only device, mount point, and flags (avoid volume naming noise).
  mount | awk -v dev="$fs_dev" '$1==dev {print $1, "on", $3, $4}'
}

# Determine running PIDs of main app process by matching the main executable path:
#   <APP>/Contents/MacOS/<CFBundleExecutable>
pgrep_main() {
  local app="$1"
  local exe="$2"
  local main_path="$app/Contents/MacOS/$exe"
  # pgrep -f matches against the full argv command line; this reliably matches the main binary path.
  pgrep -f "$main_path" 2>/dev/null || true
}

# Determine helper PIDs (best-effort). We match on the bundle path under Frameworks.
# This is intentionally conservative: only processes with commandline containing:
#   <APP>/Contents/Frameworks/Code*Helper
pgrep_helpers() {
  local app="$1"
  # Match only within this app bundle Frameworks.
  pgrep -f "$app/Contents/Frameworks/.*Helper" 2>/dev/null || true
}

# Try a graceful quit via AppleScript using bundle id (most reliable).
osascript_quit_by_id() {
  local bundle_id="$1"
  /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
}

wait_for_exit() {
  local pids="$1"
  local timeout_ms="${2:-2000}"
  local interval_ms=100
  local waited=0

  # If no PIDs, nothing to wait for.
  [[ -n "$pids" ]] || return 0

  while [[ "$waited" -lt "$timeout_ms" ]]; do
    local still=""
    for pid in $pids; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        still="1"
        break
      fi
    done
    [[ -z "$still" ]] && return 0
    sleep 0.1
    waited=$((waited + interval_ms))
  done
  return 1
}

# ----- actions -----

do_check() {
  local app="$1"
  local channel="$2"
  local bundle_id="$3"
  local bundle_name="$4"
  local exe="$5"
  local cli_name="$6"
  local verbose="$7"

  log "== VS Code ($channel): bundle info =="
  log "Path: $app"
  log "Bundle ID: $bundle_id"
  log "Bundle Name: $bundle_name"
  log "Executable: $exe"
  log

  log "== Ownership / perms (top-level) =="
  ls -ld "$app"
  stat -f "Owner=%Su Group=%Sg Mode=%Sp" "$app"
  log

  log "== Filesystem =="
  df -h "$app" | sed '1q;2p'
  log
  log "Mount flags (looking for 'read-only'):"
  print_mount_flags_minimal "$app" || true
  log

  log "== Extended attributes (quarantine?) =="
  if xattr -l "$app" 2>/dev/null | grep -q "com.apple.quarantine"; then
    log "QUARANTINE: PRESENT"
    if [[ "$verbose" == "1" ]]; then
      xattr -p com.apple.quarantine "$app" || true
    fi
  else
    log "QUARANTINE: not present"
  fi
  if [[ "$verbose" == "1" ]]; then
    log
    log "xattr summary (top-level):"
    xattr -l "$app" 2>/dev/null || true
  fi
  log

  log "== File flags (immutable?) =="
  # -O shows flags column; immutable flags appear as uchg/schg
  # Keep output minimal by default.
  if [[ "$verbose" == "1" ]]; then
    ls -lO "$app" | sed -n '1,5p' || true
  else
    # Just show the top-level flags line if available
    ls -ldO "$app" || true
  fi
  log

  log "== codesign verification =="
  local logf="/tmp/vscode-${channel}-codesign.log"
  if codesign --verify --deep --strict --verbose=2 "$app" >"$logf" 2>&1; then
    log "codesign: OK"
  else
    log "codesign: FAIL"
    sed -n '1,160p' "$logf"
  fi
  log

  log "== Writability test (inside bundle) =="
  local testdir="$app/Contents/_writetest_$(date +%s)"
  if mkdir "$testdir" 2>/dev/null; then
    rmdir "$testdir"
    log "Writable: YES (able to create/remove a dir inside Contents)"
  else
    log "Writable: NO (cannot create dir inside Contents)"
    log "This is consistent with 'read-only mode' update failures."
  fi
  log

  log "== Running processes (best-effort) =="
  local main_pids helpers
  main_pids="$(pgrep_main "$app" "$exe" | tr '\n' ' ' | xargs || true)"
  helpers="$(pgrep_helpers "$app" | tr '\n' ' ' | xargs || true)"
  if [[ -n "$main_pids" ]]; then
    log "Main PIDs: $main_pids"
  else
    log "Main PIDs: none detected"
  fi
  if [[ -n "$helpers" && "$verbose" == "1" ]]; then
    log "Helper PIDs: $helpers"
  fi
  log

  log "== Shell PATH install sanity (optional) =="
  if command -v "$cli_name" >/dev/null 2>&1; then
    log "$cli_name found at: $(command -v "$cli_name")"
    ls -l "$(command -v "$cli_name")" || true
  else
    log "$cli_name not found in PATH (fine)."
  fi
  log

  log "Done."
}

kill_vscode() {
  local app="$1"
  local bundle_id="$2"
  local exe="$3"
  local verbose="$4"

  local main_pids
  main_pids="$(pgrep_main "$app" "$exe" | tr '\n' ' ' | xargs || true)"

  if [[ -z "$main_pids" ]]; then
    log "== No running VS Code processes detected for this bundle =="
    return 0
  fi

  log "== Requesting VS Code quit (AppleScript) =="
  osascript_quit_by_id "$bundle_id"

  if wait_for_exit "$main_pids" 2500; then
    log "Quit: OK"
    return 0
  fi

  log "== Forcing termination of main process =="
  local main_path="$app/Contents/MacOS/$exe"

  # TERM first
  pkill -f "$main_path" >/dev/null 2>&1 || true
  sleep 0.4

  # If still alive, KILL
  if pgrep -f "$main_path" >/dev/null 2>&1; then
    pkill -9 -f "$main_path" >/dev/null 2>&1 || true
  fi

  # Helpers are usually reaped; optionally clean up if verbose
  if [[ "$verbose" == "1" ]]; then
    local helper_pids
    helper_pids="$(pgrep_helpers "$app" | tr '\n' ' ' | xargs || true)"
    if [[ -n "$helper_pids" ]]; then
      log "== Helper processes still present (best-effort cleanup) =="
      pkill -f "$app/Contents/Frameworks/.*Helper" >/dev/null 2>&1 || true
    fi
  fi

  sleep 0.5
  return 0
}

do_fix() {
  local app="$1"
  local channel="$2"
  local bundle_id="$3"
  local bundle_name="$4"
  local exe="$5"
  local no_kill="$6"
  local verbose="$7"

  local user_name
  user_name="$(id -un)"

  log "== VS Code ($channel) fix =="
  log "Path: $app"
  log "Bundle ID: $bundle_id"
  log "Bundle Name: $bundle_name"
  log "Executable: $exe"
  log

  if [[ "$no_kill" != "1" ]]; then
    kill_vscode "$app" "$bundle_id" "$exe" "$verbose"
    log
  else
    log "== Skipping process stop (--no-kill) =="
    log
  fi

  log "== Removing quarantine attribute (if present) =="
  # Safe even if absent
  sudo xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1 || true
  log "Done."
  log

  log "== Clearing immutable flags (if any) =="
  # Immutable flags can cause read-only behavior without ownership drift
  sudo chflags -R nouchg,noschg "$app" >/dev/null 2>&1 || true
  log "Done."
  log

  log "== Ensuring correct ownership (${user_name}:staff) =="
  sudo chown -R "${user_name}:staff" "$app"
  log "Done."
  log

  log "== Ensuring sane permissions =="
  # Preserve executables with X; remove group/other write.
  sudo chmod -R u+rwX,go+rX,go-w "$app"
  log "Done."
  log

  log "== Writability test =="
  local testdir="$app/Contents/_writetest_$(date +%s)"
  if sudo -u "$user_name" mkdir "$testdir" 2>/dev/null; then
    sudo -u "$user_name" rmdir "$testdir" 2>/dev/null || true
    log "Writable: YES"
  else
    log "Writable: NO"
    log "If this persists, the containing volume may be mounted read-only or controlled by another tool."
  fi
  log

  log "== codesign verification (diagnostic) =="
  local logf="/tmp/vscode-${channel}-codesign.log"
  if codesign --verify --deep --strict --verbose=2 "$app" >"$logf" 2>&1; then
    log "codesign: OK"
  else
    log "codesign: FAIL (this can break updates and launches)"
    sed -n '1,220p' "$logf"
    log
    log "If codesign is failing, the safest fix is a fresh reinstall from Microsoft."
  fi
  log

  log "Done. Relaunch VS Code and try 'Check for Updates' again."
}

# ----- main -----

main() {
  is_macos || { echo "ERROR: This script is intended for macOS (Darwin) only." >&2; exit 1; }

  require_cmd df
  require_cmd mount
  require_cmd stat
  require_cmd xattr
  require_cmd codesign
  require_cmd plutil
  require_cmd osascript
  require_cmd pgrep
  require_cmd pkill

  [[ $# -ge 1 ]] || die_usage "Missing subcommand: check|fix"
  local subcmd="$1"
  shift

  local channel="stable"
  local app="$STABLE_APP_DEFAULT"
  local app_overridden="0"
  local no_kill="0"
  local verbose="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stable)
        channel="stable"
        app="$STABLE_APP_DEFAULT"
        shift
        ;;
      --insiders)
        channel="insiders"
        app="$INSIDERS_APP_DEFAULT"
        shift
        ;;
      --app)
        app="${2:-}"
        [[ -n "$app" ]] || die_usage "--app requires a value"
        app_overridden="1"
        shift 2
        ;;
      --no-kill)
        no_kill="1"
        shift
        ;;
      --verbose)
        verbose="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die_usage "Unknown argument: $1"
        ;;
    esac
  done

  require_app_bundle "$app"

  local bundle_id bundle_name exe
  bundle_id="$(bundle_id_from_app "$app")"
  bundle_name="$(bundle_name_from_app "$app")"
  exe="$(bundle_executable_from_app "$app")"

  [[ -n "$bundle_id" ]] || { echo "ERROR: Unable to read CFBundleIdentifier from Info.plist: $app" >&2; exit 1; }
  [[ -n "$exe" ]] || { echo "ERROR: Unable to read CFBundleExecutable from Info.plist: $app" >&2; exit 1; }

  # Enforce "official VS Code only"
  if ! is_supported_bundle_id "$bundle_id"; then
    echo "ERROR: Unsupported bundle identifier: $bundle_id" >&2
    echo "This script is intended only for com.microsoft.VSCode and com.microsoft.VSCodeInsiders." >&2
    exit 1
  fi

  # If user explicitly passed --app, derive channel from bundle id (more reliable than path).
  # Otherwise respect --stable/--insiders selection.
  if [[ "$app_overridden" == "1" ]]; then
    channel="$(detect_channel_from_bundle_id "$bundle_id")"
  fi

  local cli_name
  cli_name="$(cli_name_for_channel "$channel")"

  case "$subcmd" in
    check)
      do_check "$app" "$channel" "$bundle_id" "$bundle_name" "$exe" "$cli_name" "$verbose"
      ;;
    fix)
      do_fix "$app" "$channel" "$bundle_id" "$bundle_name" "$exe" "$no_kill" "$verbose"
      ;;
    *)
      die_usage "Unknown subcommand: $subcmd (expected check|fix)"
      ;;
  esac
}

main "$@"