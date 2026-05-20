#!/usr/bin/env bash
# Strip JSON comments in place from deployment config files. Pairs with
# `JsoncLib.read(path)`: when this script has run, export `JSONC_PRESTRIPPED=true`
# so the Solidity stripper short-circuits and `vm.readFile` returns parseable JSON
# directly. CI calls this before `forge test`; the workspace is ephemeral so the
# in-place edits are thrown away with it. Run locally before `JSONC_PRESTRIPPED=true
# forge test` for the same speedup (the .json files are gitignored from comments
# being added, see CONTRIBUTING).
#
# Handles `//` end-of-line comments only, which is all current configs use. If
# `/* */` block comments are ever added, swap sed for a string-safe parser
# (e.g. node's jsonc-parser). The script also asserts no JSON string contains
# `//`, so an accidental URL slipping in is caught early instead of silently
# corrupting the config.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CONFIGS=(
    "$ROOT/config/deployment-config.prod.jsonc"
    "$ROOT/config/deployment-config.preprod.jsonc"
    "$ROOT/config/deployment-config.staging.jsonc"
)

for f in "${CONFIGS[@]}"; do
    [[ -f "$f" ]] || continue

    if grep -qE '"[^"]*//[^"]*"' "$f"; then
        echo "error: $f contains '//' inside a JSON string; sed-based stripping is unsafe." >&2
        exit 1
    fi

    # -i.bak is the only portable in-place form across BSD (macOS) and GNU sed.
    sed -i.bak -E 's|[[:space:]]*//.*$||' "$f"
    rm -f "$f.bak"
done
