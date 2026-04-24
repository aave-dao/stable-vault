#!/usr/bin/env bash
##
## Generate a markdown gas-diff report from two directories of forge gas
## snapshots produced by `vm.snapshotGasLastCall(...)`.
##
## Each input directory is expected to contain JSON files shaped like:
##   { "<measurement-label>": "<gas-cost-as-decimal-string>", ... }
##
## Usage:
##   gas-diff.sh <baseline-dir> <current-dir>
##
##   <baseline-dir> may be empty/missing or contain no .json files. In that
##   case the report omits the diff columns and just lists the current values.
##
##   When a baseline IS provided and no values changed, the script writes
##   nothing to stdout and exits 0. Callers can treat empty stdout as the
##   "no diff, delete the sticky comment" signal.
##
## Optional environment variables (used only to decorate the report header):
##   COMMIT_SHA   full SHA of the PR HEAD
##   BASE_SHA     full SHA of the baseline commit
##   REPO         "owner/name", used to build commit links
##

set -euo pipefail
export LC_ALL=C

BASELINE_DIR="${1:-}"
CURRENT_DIR="${2:-snapshots}"

has_baseline=false
if [[ -n "$BASELINE_DIR" && -d "$BASELINE_DIR" ]] \
    && compgen -G "$BASELINE_DIR/*.json" > /dev/null; then
    has_baseline=true
fi

# Build the union of basenames across both directories (portable; no associative
# arrays so this works on macOS bash 3.2 as well).
collect_basenames() {
    local dir=$1
    [[ -n "$dir" && -d "$dir" ]] || return 0
    if compgen -G "$dir/*.json" > /dev/null; then
        for f in "$dir"/*.json; do basename "$f"; done
    fi
    return 0
}

sorted_files=$({
    collect_basenames "$CURRENT_DIR"
    collect_basenames "$BASELINE_DIR"
} | sort -u)

if [[ -z "$sorted_files" ]]; then
    exit 0
fi

fmt_num() {
    local n=$1 sign=""
    if [[ "$n" == -* ]]; then sign="-"; n="${n#-}"; fi
    printf "%s%s" "$sign" "$(echo "$n" | rev | sed 's/.../&,/g' | rev | sed 's/^,//')"
}

fmt_pct() {
    local delta=$1 base=$2
    if [[ "$base" -eq 0 ]]; then printf "-"; return; fi
    local x=$(( (delta * 10000) / base ))
    local int=$((x / 100)) dec=$((x % 100))
    [[ "$dec" -lt 0 ]] && dec=$((-dec))
    if [[ "$x" -gt 0 ]]; then
        printf "+%d.%02d%%" "$int" "$dec"
    else
        printf "%d.%02d%%" "$int" "$dec"
    fi
}

any_diff=false
all_sections=""

while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue
    cur_file="$CURRENT_DIR/$fname"
    base_file="$BASELINE_DIR/$fname"
    cur_exists=false; base_exists=false
    [[ -f "$cur_file" ]] && cur_exists=true
    [[ -f "$base_file" ]] && base_exists=true

    section_name="${fname%.json}"

    keys=$({
        if $cur_exists;  then jq -r 'keys[]' "$cur_file"  2>/dev/null; fi
        if $base_exists; then jq -r 'keys[]' "$base_file" 2>/dev/null; fi
    } | sort -u)

    rows=()
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        cur_val=""; base_val=""
        if $cur_exists;  then cur_val=$(jq -r  --arg k "$key" '.[$k] // empty' "$cur_file");  fi
        if $base_exists; then base_val=$(jq -r --arg k "$key" '.[$k] // empty' "$base_file"); fi

        if $has_baseline; then
            if [[ -n "$cur_val" && -n "$base_val" ]]; then
                [[ "$cur_val" == "$base_val" ]] && continue
                delta=$((cur_val - base_val))
                pct=$(fmt_pct "$delta" "$base_val")
                delta_str=$(fmt_num "$delta")
                [[ "$delta" -gt 0 ]] && delta_str="+$delta_str"
                rows+=("| \`$key\` | $(fmt_num "$base_val") | $(fmt_num "$cur_val") | $delta_str | $pct |")
                any_diff=true
            elif [[ -n "$cur_val" ]]; then
                rows+=("| \`$key\` | (new) | $(fmt_num "$cur_val") | - | - |")
                any_diff=true
            elif [[ -n "$base_val" ]]; then
                rows+=("| \`$key\` | $(fmt_num "$base_val") | (removed) | - | - |")
                any_diff=true
            fi
        else
            [[ -n "$cur_val" ]] && rows+=("| \`$key\` | $(fmt_num "$cur_val") |")
        fi
    done <<< "$keys"

    if [[ ${#rows[@]} -gt 0 ]]; then
        section="## $section_name"$'\n\n'
        if $has_baseline; then
            section+="| Method | Old | New | Δ | % |"$'\n'
            section+="|---|---:|---:|---:|---:|"$'\n'
        else
            section+="| Method | Gas |"$'\n'
            section+="|---|---:|"$'\n'
        fi
        for row in "${rows[@]}"; do section+="$row"$'\n'; done
        section+=$'\n'
        all_sections+="$section"
    fi
done <<< "$sorted_files"

if $has_baseline && ! $any_diff; then
    exit 0
fi

out="# Gas Diff Report"$'\n\n'
if $has_baseline; then
    if [[ -n "${COMMIT_SHA:-}" && -n "${BASE_SHA:-}" && -n "${REPO:-}" ]]; then
        out+="> Comparing [\`${COMMIT_SHA:0:7}\`](/$REPO/commit/$COMMIT_SHA) against baseline [\`${BASE_SHA:0:7}\`](/$REPO/commit/$BASE_SHA) from \`master\`."$'\n\n'
    else
        out+="> Compared to baseline from \`master\`."$'\n\n'
    fi
else
    out+="> No baseline artifact found — showing current gas values only."$'\n\n'
fi
out+="$all_sections"

printf "%s" "$out"
