#!/usr/bin/env bash
set -euo pipefail

# Checks that source contracts (src/) do not exceed the EIP-170 24KB (24576 bytes) size limit.
#
# Library contracts (lib/) are allowed to exceed the limit. A warning is emitted for visibility but does not
# cause a failure.
#
# The script parses the table output of `forge build --sizes`, which has rows like:
#   | path/to/Contract.sol:Contract | size | margin |
# It splits each row by '|', strips spaces/commas from the size column ($3), and compares
# against the 24576-byte threshold.

SIZE_LIMIT=24576

forge build --sizes 2>&1 | tee /tmp/sizes.txt || true

# Warn on lib/ contracts exceeding the limit
if grep -E '^\|.*\blib/' /tmp/sizes.txt | awk -F'|' -v limit="$SIZE_LIMIT" '{gsub(/[, ]/, "", $3); if ($3+0 > limit) found=1} END {exit !found}' 2>/dev/null; then
    echo "::warning::Some lib/ dependency contracts exceed the EIP-170 size limit"
fi

# Fail on src/ contracts exceeding the limit
if grep -E '^\|' /tmp/sizes.txt | grep -v 'lib/' | awk -F'|' -v limit="$SIZE_LIMIT" '{gsub(/[, ]/, "", $3); if ($3+0 > limit) {print $2; found=1}} END {if (found) exit 0; else exit 1}' 2>/dev/null; then
    echo "::error::Source contracts exceed the EIP-170 24KB size limit"
    exit 1
fi
