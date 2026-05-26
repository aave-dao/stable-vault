#!/usr/bin/env bash
# Verifies that all @custom:selector annotations in Solidity source files
# match the actual computed selector (bytes4 of keccak256 of the signature).
#
# Usage: .github/workflows/tooling/test/check-error-selectors.sh [src_dir]
# Requires: cast (from foundry)

set -euo pipefail

SRC_DIR="${1:-src}"
EXIT_CODE=0
CHECKED=0
FAILED=0

if ! command -v cast &>/dev/null; then
  echo "Error: 'cast' (foundry) is required but not found in PATH." >&2
  exit 1
fi

# Find all lines with @custom:selector, then parse the next error declaration.
while IFS= read -r file; do
  while IFS= read -r match; do
    line_num="${match%%:*}"
    claimed_selector="$(echo "$match" | grep -oE '0x[0-9a-fA-F]+')"

    # Read the next non-empty, non-comment line after the selector annotation to get the error signature.
    error_line=""
    next=$((line_num + 1))
    while IFS= read -r candidate; do
      trimmed="$(echo "$candidate" | sed 's/^[[:space:]]*//')"
      # Skip empty lines and comment-only lines
      if [[ -z "$trimmed" || "$trimmed" == //* || "$trimmed" == \** ]]; then
        next=$((next + 1))
        continue
      fi
      error_line="$trimmed"
      break
    done < <(tail -n +"$next" "$file")

    if [[ -z "$error_line" ]]; then
      echo "WARN: ${file}:${line_num} — could not find declaration after @custom:selector"
      continue
    fi

    # Extract the error signature: "error Name(type1,type2);" -> "Name(type1,type2)"
    # Also handle "error Name();" and multi-param errors.
    # Strip trailing semicolon, visibility modifiers, etc.
    if [[ "$error_line" =~ ^error[[:space:]]+([A-Za-z_][A-Za-z0-9_]*\(.*\)) ]]; then
      raw_sig="${BASH_REMATCH[1]}"
    else
      echo "WARN: ${file}:${line_num} — unrecognized declaration: ${error_line}"
      continue
    fi

    # Remove parameter names, keeping only types.
    # e.g. "InvalidAsset(address asset)" -> "InvalidAsset(address)"
    # e.g. "Foo(uint256 a, uint256 b)" -> "Foo(uint256,uint256)"
    sig="$(echo "$raw_sig" | sed -E 's/ (memory|calldata|storage)//g' | awk '{
      # Strip trailing ");" or ")" to process params cleanly
      gsub(/\);?$/, "")
      # Split at "(" to separate name from params
      idx = index($0, "(")
      name = substr($0, 1, idx)  # includes "("
      params = substr($0, idx + 1)

      # Split params by comma
      n = split(params, parts, ",")
      result = name
      for (i = 1; i <= n; i++) {
        # Trim spaces
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        # If multiple words, drop the last one (param name)
        nw = split(parts[i], words, /[[:space:]]+/)
        if (nw > 1) {
          seg = words[1]
          for (j = 2; j < nw; j++) seg = seg " " words[j]
          parts[i] = seg
        }
        gsub(/[[:space:]]/, "", parts[i])
        if (i > 1) result = result ","
        result = result parts[i]
      }
      print result ")"
    }')"

    # Compute actual selector — cast sig expects bare signature without "error" keyword
    actual_selector="$(cast sig "${sig}" 2>/dev/null || true)"

    if [[ -z "$actual_selector" ]]; then
      echo "WARN: ${file}:${line_num} — cast failed to compute selector for: ${sig}"
      continue
    fi

    CHECKED=$((CHECKED + 1))

    # Normalize to lowercase for comparison
    claimed_lower="$(echo "$claimed_selector" | tr '[:upper:]' '[:lower:]')"
    actual_lower="$(echo "$actual_selector" | tr '[:upper:]' '[:lower:]')"

    if [[ "$claimed_lower" != "$actual_lower" ]]; then
      echo "MISMATCH: ${file}:${line_num}"
      echo "  error:    ${sig}"
      echo "  claimed:  ${claimed_selector}"
      echo "  actual:   ${actual_selector}"
      echo ""
      EXIT_CODE=1
      FAILED=$((FAILED + 1))
    fi
  done < <(grep -n '@custom:selector' "$file")
done < <(find "$SRC_DIR" -name '*.sol' -type f | sort)

if [[ $EXIT_CODE -eq 0 ]]; then
  echo "All ${CHECKED} @custom:selector annotations are correct."
else
  echo "${FAILED}/${CHECKED} selector(s) are incorrect."
fi

exit $EXIT_CODE
