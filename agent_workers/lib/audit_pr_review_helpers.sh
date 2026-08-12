#!/bin/bash

# Shared parsing helpers for audit_pr_review.sh and its unit tests.

# Extract the final comment from between FINAL_COMMENT_START and FINAL_COMMENT_END markers.
# Writes extracted text to stdout. Returns non-zero on missing/duplicate markers.
extract_final_comment() {
    local input_file="$1"
    if [ ! -f "$input_file" ]; then
        echo "ERROR: extract_final_comment: file not found: $input_file" >&2
        return 1
    fi

    local start_count end_count
    start_count=$(grep -c -- '^FINAL_COMMENT_START$' "$input_file" || true)
    end_count=$(grep -c -- '^FINAL_COMMENT_END$' "$input_file" || true)

    if [ "$start_count" -eq 0 ] || [ "$end_count" -eq 0 ]; then
        echo "ERROR: extract_final_comment: missing FINAL_COMMENT_START/FINAL_COMMENT_END markers" >&2
        return 1
    fi
    if [ "$start_count" -gt 1 ] || [ "$end_count" -gt 1 ]; then
        echo "ERROR: extract_final_comment: duplicate FINAL_COMMENT_START/FINAL_COMMENT_END markers" >&2
        return 1
    fi

    sed -n '/^FINAL_COMMENT_START$/,/^FINAL_COMMENT_END$/p' "$input_file" \
        | sed '1d;$d'
}

# Extract recommendation line from agent output.
# Prints "approve" or "request-changes" to stdout. Returns non-zero on invalid.
extract_recommendation() {
    local input_file="$1"
    if [ ! -f "$input_file" ]; then
        echo "ERROR: extract_recommendation: file not found: $input_file" >&2
        return 1
    fi

    local matches
    matches=$(grep -c -- '^RECOMMENDATION: ' "$input_file" || true)

    if [ "$matches" -eq 0 ]; then
        echo "ERROR: extract_recommendation: no RECOMMENDATION: line found" >&2
        return 1
    fi
    if [ "$matches" -gt 1 ]; then
        echo "ERROR: extract_recommendation: multiple RECOMMENDATION: lines found" >&2
        return 1
    fi

    local value
    value=$(grep -- '^RECOMMENDATION: ' "$input_file" | sed 's/^RECOMMENDATION: //')

    case "$value" in
        approve|request-changes)
            echo "$value"
            return 0
            ;;
        *)
            echo "ERROR: extract_recommendation: invalid value '$value' (expected approve|request-changes)" >&2
            return 1
            ;;
    esac
}
