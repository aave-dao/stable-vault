#!/usr/bin/env bash
# Strip `//` comments from deployment JSONC configs in place before CI runs tests.
# `JSONC_PRESTRIPPED=true` lets `JsoncLib.read(path)` skip Solidity-side stripping.
#
# This sed pass only supports end-of-line comments. Reject strings containing
# `//` so values like URLs are caught before they can be corrupted.
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
