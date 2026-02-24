# VS Code Read-Only Repair Script

VS Code & VS Code Insiders update by modifying their own `.app` bundle in place. Occasionally, it's possible that these updates fail with a “read-only mode” error. This macOS utility script diagnoses and fixes the common causes.

## Overview

The script is intentionally scoped to VS Code and VS Code Insiders apps. It rejects unsupported bundle identifiers (forks).

* VS Code (Stable)
  `/Applications/Visual Studio Code.app`

* VS Code (Insiders)
  `/Applications/Visual Studio Code - Insiders.app`

There are two subcommands:

* `check` — Run diagnostics only
* `fix` — Attempt to restore bundle writeability for self-updates

They help troubleshoot and resolve:

* “Read-only mode” update failures
* Reapplied quarantine attributes
* Immutable file flags (`uchg`, `schg`)
* Ownership or permission drift
* Codesign verification issues
* Read-only mount states
* Third-party utilities altering bundle metadata

## Installation

Make the script executable:

```bash
chmod +x repair.sh
```

Optionally move it into a bin directory:

```bash
mv repair.sh ~/bin/
```

## Usage

```bash
./repair.sh <check|fix> [options]
```

## Subcommands

### `check`

Performs diagnostics without any modifications.

Checks:

* Ownership and permissions
* Filesystem mount flags
* Quarantine attribute detection
* File flags summary (use `--verbose` for more)
* Codesign verification
* Writable test inside `Contents/`
* Running process detection (best-effort)
* CLI symlink sanity check (`code` or `code-insiders`)

Examples:

```bash
./repair.sh check
./repair.sh check --insiders
```

### `fix`

Attempts to restore update capability.

Operations:

* Stops VS Code processes (optional)

  * Uses AppleScript by bundle identifier for graceful quit when possible
  * Falls back to targeted `pkill` against the app’s main executable path
* Removes `com.apple.quarantine`
* Clears immutable flags
* Restores ownership to `<current user>:staff`
* Normalizes permissions (`u+rwX,go+rX,go-w`)
* Verifies codesign
* Tests writability

Examples:

```bash
./repair.sh fix
./repair.sh fix --insiders
```

## Flags and Arguments

### Release Channel

* `--stable` — Target stable build (default)
* `--insiders` — Target Insiders build

If no channel flag is provided, `--stable` is assumed.

### Explicit App Override

```bash
--app "/path/to/Visual Studio Code.app"
```

Use when:

* The app is installed in a nonstandard location
* You want to override the default app paths

Notes:

* The script will still validate that the bundle identifier is one of:

  * `com.microsoft.VSCode`
  * `com.microsoft.VSCodeInsiders`

### Process Handling

```bash
--no-kill
```

Skips stopping VS Code processes during `fix`.

Useful if:

* You prefer to close VS Code manually
* You are debugging behavior while it is open

### Verbose Output

```bash
--verbose
```

Prints additional diagnostic detail, including more extended attributes and helper-process cleanup behavior.

### `help`

```bash
./repair.sh --help
```

## Examples

### `check` stable (default)

```bash
./repair.sh check
```

### `check` Insiders

```bash
./repair.sh check --insiders
```

### `fix` stable

```bash
./repair.sh fix
```

### `fix` Insiders

```bash
./repair.sh fix --insiders
```

### `fix` Insiders without killing processes

```bash
./repair.sh fix --insiders --no-kill
```

### Override app path

```bash
./repair.sh check --app "/Applications/Visual Studio Code - Insiders.app"
```

### Verbose `check`

```bash
./repair.sh check --insiders --verbose
```

## Exit Codes

* `0` — Success
* `1` — App not found or runtime failure
* `2` — Usage error

## Notes

* The `fix` subcommand requires `sudo` for ownership and extended attribute operations.
* If `codesign` verification fails after running `fix`, a fresh reinstall from Microsoft is recommended.
* If writability remains `NO`, the underlying volume may be mounted read-only or controlled by a third-party security or system utility.

## License

MIT License. See [LICENSE](LICENSE).
