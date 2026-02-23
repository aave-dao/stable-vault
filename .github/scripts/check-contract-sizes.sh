#!/usr/bin/env bash
set -euo pipefail

# Checks that source contracts (src/) do not exceed the EIP-170 24KB (24576 bytes) size limit.
#
# Library contracts (lib/) are allowed to exceed the limit. A warning is emitted for visibility
# but does not cause a failure.
#
# `forge build --sizes` only outputs contract names (no file paths), so we first collect all
# contract/library/interface names declared in src/ to know which entries are ours vs dependencies.

SIZE_LIMIT=24576

# Collect all contract names defined under src/
src_contracts=$(grep -rh '^\s*\(contract\|abstract contract\|library\) ' src/ | awk '{for(i=1;i<=NF;i++){if($i=="contract"||$i=="library"){print $(i+1); break}}}' | sed 's/[{(].*//' | sort -u)

forge build --sizes 2>&1 | tee /tmp/sizes.txt || true

failed=0

# Parse each size row
grep -E '^\|' /tmp/sizes.txt | grep -v 'Contract' | while IFS='|' read -r _ name size _rest; do
    name=$(echo "$name" | xargs)
    size=$(echo "$size" | tr -d ', ')

    [ -z "$size" ] || [ "$size" -le 0 ] 2>/dev/null && continue

    if [ "$size" -gt "$SIZE_LIMIT" ]; then
        if echo "$src_contracts" | grep -qx "$name"; then
            echo "::error::$name ($size bytes) exceeds the EIP-170 24KB size limit"
            # Signal failure via a temp file since we're in a pipe subshell
            touch /tmp/size_check_failed
        else
            echo "::warning::$name ($size bytes) exceeds the EIP-170 size limit (lib dependency, non-blocking)"
        fi
    fi
done

if [ -f /tmp/size_check_failed ]; then
    rm -f /tmp/size_check_failed
    exit 1
fi
