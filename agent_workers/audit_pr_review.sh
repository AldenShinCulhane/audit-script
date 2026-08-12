#!/bin/bash
set -euo pipefail

# Syntax self-check (mesh#49): a bash syntax error in a locally-edited, not-yet-
# committed copy is otherwise latent until it aborts a live run mid-audit — after
# the agent turns have already burned tokens, and on the APPROVE path it dies just
# before posting. Every committed SHA already passes `bash -n` in CI, so this is
# the only gate that protects an uncommitted edit. Re-parse the whole file before
# executing a single command: `bash` runs a script as it reads it, so a fault deep
# in the file stays dormant until execution reaches it; forcing a full parse up
# front turns that late abort into a clean refusal. Skipped when $0 is not a
# readable regular file (piped via stdin / process substitution), where there is
# nothing on disk to re-parse. `--` guards a path that begins with a dash.
if [ -f "$0" ] && ! bash -n -- "$0" 2>/dev/null; then
    echo "ERROR: $0 failed its bash syntax self-check (bash -n). Refusing to run a malformed script." >&2
    exit 2
fi

# Multi-agent PR audit with cross-pollination.
# Two agents independently audit a PR, cross-pollinate findings across
# multiple rounds, then produce a drafted GitHub review comment plus an
# approve/request-changes recommendation. Default: posts to GitHub; --no-post
# for local-only.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_FILE="$SCRIPT_DIR/lib/agent_sessions.sh"
HELPERS_FILE="$SCRIPT_DIR/lib/audit_pr_review_helpers.sh"

if [ ! -f "$LIB_FILE" ]; then
    echo "ERROR: Session helper not found: $LIB_FILE" >&2
    exit 1
fi
if [ ! -f "$HELPERS_FILE" ]; then
    echo "ERROR: Audit helper not found: $HELPERS_FILE" >&2
    exit 1
fi

LOGFILE="/dev/null"
FEEDBACK_FILE="/dev/null"

# shellcheck disable=SC1090,SC1091
. "$LIB_FILE"
# shellcheck disable=SC1090,SC1091
. "$HELPERS_FILE"

# ── Defaults ──

PRIMARY_AGENT="claude"
CO_AGENT="codex"
PR_STATE="fresh"
POST=true
RESUME=false
PR_ARG=""
PROJECT_DIR=""
WORKSPACE_OPT=""
COMMENTS_FILE_OPT=""
GROUP_CONFIG_OPT=""
INVOCATION_DIR="$PWD"

MAX_AGENT_ATTEMPTS="${MAX_AGENT_ATTEMPTS:-3}"
TRANSIENT_RETRY_DELAY="${TRANSIENT_RETRY_DELAY:-30}"
FULL_DIFF_MAX_BYTES="${FULL_DIFF_MAX_BYTES:-200000}"
FULL_DIFF_MAX_LINES="${FULL_DIFF_MAX_LINES:-5000}"
CHUNK_MAX_BYTES="${CHUNK_MAX_BYTES:-60000}"

# Partition mode (mesh#38): an over-threshold diff is split into subsystem
# groups, each of which runs the FULL cross-pollination pipeline over its own
# group diff (in parallel, bounded), then a consolidation turn merges the group
# drafts into one review. Replaces chunked summary-only mode as the default
# large-diff path; chunked survives only as the fallback for a single file that
# alone exceeds the threshold (it cannot be partitioned further).
#   MAX_PARALLEL_GROUPS  how many group pipelines run concurrently.
#   GROUP_CONFIG_FILE    optional operator override: a file of `glob<TAB>group`
#                        lines that force specific paths into named groups.
MAX_PARALLEL_GROUPS="${MAX_PARALLEL_GROUPS:-2}"
GROUP_CONFIG_FILE=""
# Cross-cutting surfaces whose changes are interface contracts the other groups
# depend on (types, schemas, migrations, protobuf/openapi, shared config). They
# are pulled into one "shared" group so a single pipeline sees the whole
# contract surface and the consolidation turn has an anchor for hunting
# cross-group interface mismatches. Matched against the lowercased file path.
# A heuristic, not a hard rule — override per-repo via --group-config.
SHARED_SURFACE_REGEX="${SHARED_SURFACE_REGEX:-(^|/)(migrations?|schemas?|types?|interfaces?|contracts?|proto|protos|openapi|graphql)(/|\.)|\.(proto|d\.ts|graphql|avsc|thrift)$|(^|/)(schema|types|interface|contract|openapi)[^/]*\.(py|ts|tsx|js|go|rs|java|kt|rb|sql)$}"

# Per-turn wall-clock cap, consumed by _agent_wait_or_stop in
# lib/agent_sessions.sh. The lib default (3600s) is tuned for long agent_loop
# implementation turns; an audit turn is a single read-only review that should
# finish in minutes. A `claude -p` that stops emitting without EOF is a known
# hang mode, and the retry wrapper would otherwise burn up to
# MAX_AGENT_ATTEMPTS × 3600s (~3h) before giving up. Scope a tighter cap to THIS
# script only — set it here rather than in the shared lib so other workers keep
# the long default — still operator-overridable via the environment.
AGENT_TURN_TIMEOUT="${AGENT_TURN_TIMEOUT:-900}"

DIFF_MODE="full-diff"
RUN_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
RESUME_FROM_HEAD_SHA=""
RESUME_COMMENT_CUTOFF=""
FETCHED_MAX_COMMENT_TS=""

# ── Usage ──

usage() {
    cat <<'EOF'
Usage: audit_pr_review.sh [-p <pr_url_or_number>] [OPTIONS]

Multi-agent PR audit with cross-pollination. Two agents independently
audit a PR, cross-pollinate findings, then produce a drafted GitHub
review comment plus an approve/request-changes recommendation.

Options:
  -p <pr>              PR URL or number. Defaults to the current branch's
                       open PR when gh can resolve one.
  -d <dir>             Project directory (default: .)
  -w <dir>             Workspace directory (default: <project>/agent_workers/audit_pr_review/)
  -i <agent>           Primary auditor: claude|codex (default: claude)
  -r <agent>           Co-auditor: claude|codex (default: codex)
  -s <state>           PR state variant: fresh|audited|merged (default: fresh)
  -R                   Resume the prior audit session for this repo/PR and
                       review only new commits/comments since the last run
  --comments-file <path>  File containing CC review comments (optional)
  --group-config <path>   Override partition grouping: lines of `glob<TAB>group`
                       forcing matching paths into a named group (large diffs)
  --no-post            Skip posting the review to GitHub; write local artifacts only
  -h                   Help
EOF
    exit 0
}

# ── Local helpers ──

build_agent_env() {
    local -n _env_args="$1"
    local _path="${PATH:-/usr/bin:/bin}"
    local _home="${HOME:-}"
    local _shell="${SHELL:-/bin/bash}"
    local _term="${TERM:-dumb}"
    local _lang="${LANG:-C.UTF-8}"

    _env_args=(
        env -i
        "PATH=${_path}"
        "HOME=${_home}"
        "SHELL=${_shell}"
        "TERM=${_term}"
        "LANG=${_lang}"
    )

    [ -n "${USER:-}" ] && _env_args+=("USER=${USER}")
    [ -n "${LOGNAME:-}" ] && _env_args+=("LOGNAME=${LOGNAME}")
    [ -n "${LC_ALL:-}" ] && _env_args+=("LC_ALL=${LC_ALL}")
    [ -n "${LC_CTYPE:-}" ] && _env_args+=("LC_CTYPE=${LC_CTYPE}")

    # Allow only model/provider settings needed by the CLIs. Do not pass
    # GitHub/cloud/repo secrets into agent-visible subprocess environments.
    local _var
    for _var in \
        ANTHROPIC_API_KEY \
        ANTHROPIC_AUTH_TOKEN \
        ANTHROPIC_BASE_URL \
        CLAUDE_CODE_OAUTH_TOKEN \
        CLAUDE_CONFIG_DIR \
        CODEX_HOME \
        OPENAI_API_KEY \
        OPENAI_BASE_URL \
        OPENAI_ORG_ID \
        OPENAI_PROJECT \
        HTTPS_PROXY \
        HTTP_PROXY \
        ALL_PROXY \
        NO_PROXY \
        SSL_CERT_FILE \
        SSL_CERT_DIR \
        REQUESTS_CA_BUNDLE \
        MOCK_COUNTER_DIR \
        MOCK_STOP_AFTER_CALL \
        MOCK_FEEDBACK_PATH \
        MOCK_DIRTY_ON_CALL \
        MOCK_DIRTY_PATH \
        MOCK_CLAUDE_RC \
        MOCK_CODEX_RC; do
        [ -n "${!_var:-}" ] && _env_args+=("${_var}=${!_var}")
    done
    return 0
}

validate_json_array_file() {
    local file="$1"
    local label="$2"

    if ! jq -e 'type == "array"' "$file" >/dev/null 2>>"$LOGFILE"; then
        echo "ERROR: Invalid JSON array returned for $label. Aborting rather than dropping prior review context." >&2
        return 1
    fi
}

fetch_paginated_json_array() {
    local endpoint="$1"
    local output_file="$2"
    local label="$3"

    if ! gh api "$endpoint" --paginate 2>>"$LOGFILE" | jq -s 'add // []' > "$output_file" 2>>"$LOGFILE"; then
        echo "ERROR: Failed to fetch $label via gh api. Check authentication and rate limits." >&2
        return 1
    fi

    validate_json_array_file "$output_file" "$label"
}

create_codex_context_dir() {
    local session_key="$1"
    local context_dir

    context_dir="$CODEX_CONTEXT_DIR/$session_key"
    rm -rf "$context_dir"
    mkdir -p "$context_dir"
    chmod 700 "$context_dir"
    # Stage the raw diff in the codex CWD ONLY in full-diff mode (where the diff
    # is intentionally in-prompt anyway and is small). For ANY large-diff mode
    # (chunked OR partition) stage the bounded manifest instead — codex runs
    # --sandbox read-only, so it CAN read CWD files, and at the parent level in
    # partition mode PR_DIFF_FILE is still the whole over-threshold diff. Copying
    # it here would re-materialize out-of-band the exact diff partitioning exists
    # to avoid (the build_audit_prompt partition branch already omits it from the
    # prompt). DIFF_MANIFEST_FILE is written for all modes; FILE_SUMMARIES_FILE is
    # empty in partition mode (harmless to copy). (mesh#38)
    if [ "${DIFF_MODE:-full-diff}" != "full-diff" ]; then
        cp "$DIFF_MANIFEST_FILE" "$context_dir/diff_manifest.json"
        cp "$FILE_SUMMARIES_FILE" "$context_dir/file_summaries.md"
    else
        cp "$PR_DIFF_FILE" "$context_dir/pr_diff.patch"
    fi
    cp "$CC_COMMENTS_FILE" "$context_dir/cc_comments.md"
    cat > "$context_dir/README.md" <<'EOF'
This isolated workspace intentionally contains only PR audit inputs.
The target repository is not mounted here.
EOF
    printf '%s\n' "$context_dir"
}

# Stable, otherwise-empty dir to run the claude seat from, so the audited repo's
# CLAUDE.md / git status / project hooks do not auto-load into the review
# context (mesh#43). The stable per-session path is required for `claude
# --resume`: Claude stores project transcripts under CLAUDE_CONFIG_DIR keyed by
# the cwd slug, so persisting only the session id is not enough.
create_claude_context_dir() {
    local session_key="$1"
    local context_dir

    context_dir="$CLAUDE_CONTEXT_DIR/$session_key"
    rm -rf "$context_dir"
    mkdir -p "$context_dir"
    chmod 700 "$context_dir"
    cat > "$context_dir/README.md" <<'EOF'
This stable, otherwise-empty workspace isolates the claude audit turn from
the target repository. The review runs text-in -> text-out with built-in tools
disabled (--tools "") and MCP servers disabled (--strict-mcp-config plus an
empty --mcp-config). The target repository is not mounted here.
EOF
    printf '%s\n' "$context_dir"
}

session_sidecar_path() {
    local session_key="$1"
    printf '%s/%s.json' "$SESSION_STATE_DIR" "$session_key"
}

normalize_started_flag() {
    case "${1:-0}" in
        1|true|TRUE|yes|YES) printf '1' ;;
        *) printf '0' ;;
    esac
}

save_session_sidecar() {
    local session_key="$1"
    local sid="${SESSION_IDS[$session_key]:-}"
    local started

    started=$(normalize_started_flag "${STARTED_SESSIONS[$session_key]:-0}")

    [ -n "${SESSION_STATE_DIR:-}" ] || return 0
    [ -n "$sid" ] || return 0
    mkdir -p "$SESSION_STATE_DIR"
    jq -n \
        --arg key "$session_key" \
        --arg sid "$sid" \
        --argjson started "$started" \
        '{session_key:$key,session_id:$sid,started:$started}' \
        > "$(session_sidecar_path "$session_key")"
}

load_session_sidecars() {
    local sidecar key sid started

    [ -d "${SESSION_STATE_DIR:-}" ] || return 0
    for sidecar in "$SESSION_STATE_DIR"/*.json; do
        [ -e "$sidecar" ] || continue
        key=$(jq -r '.session_key // empty' "$sidecar" 2>>"$LOGFILE")
        sid=$(jq -r '.session_id // empty' "$sidecar" 2>>"$LOGFILE")
        started=$(jq -r '.started // 1' "$sidecar" 2>>"$LOGFILE")
        if [ -n "$key" ] && [ -n "$sid" ]; then
            SESSION_IDS["$key"]="$sid"
            STARTED_SESSIONS["$key"]=$(normalize_started_flag "$started")
        fi
    done
}

save_audit_state() {
    local tmp_sessions tmp_started completed_head="${1:-${LAST_REVIEW_HEAD_SHA:-}}"
    local comment_cutoff="${2:-${LAST_REVIEW_COMMENT_TS:-}}"
    local completed_at="${3:-${LAST_REVIEW_COMPLETED_AT:-}}"
    local key started_value

    [ -n "${STATE_FILE:-}" ] || return 0
    mkdir -p "$(dirname "$STATE_FILE")"
    tmp_sessions=$(mktemp)
    tmp_started=$(mktemp)
    : > "$tmp_sessions"
    : > "$tmp_started"

    load_session_sidecars

    for key in "${!SESSION_IDS[@]}"; do
        jq -n --arg key "$key" --arg sid "${SESSION_IDS[$key]}" \
            '{key:$key,value:$sid}' >> "$tmp_sessions"
    done
    for key in "${!STARTED_SESSIONS[@]}"; do
        started_value=$(normalize_started_flag "${STARTED_SESSIONS[$key]:-0}")
        jq -n --arg key "$key" --argjson started "$started_value" \
            '{key:$key,value:$started}' >> "$tmp_started"
    done

    jq -n \
        --arg repo "$REPO_SLUG" \
        --argjson pr "$PR_NUMBER" \
        --arg primary "$PRIMARY_AGENT" \
        --arg co "$CO_AGENT" \
        --arg head "$completed_head" \
        --arg comment_cutoff "$comment_cutoff" \
        --arg completed_at "$completed_at" \
        --slurpfile sessions "$tmp_sessions" \
        --slurpfile started "$tmp_started" \
        '{
            repo_slug:$repo,
            pr_number:$pr,
            primary_agent:$primary,
            co_agent:$co,
            last_review_head_sha:$head,
            last_review_comment_ts:$comment_cutoff,
            last_review_completed_at:$completed_at,
            sessions:($sessions | map({(.key): .value}) | add // {}),
            started_sessions:($started | map({(.key): .value}) | add // {})
        }' > "$STATE_FILE"

    rm -f "$tmp_sessions" "$tmp_started"
}

load_audit_state() {
    local state_repo state_pr

    if [ ! -f "$STATE_FILE" ]; then
        echo "ERROR: Cannot resume — no state file at $STATE_FILE" >&2
        return 1
    fi
    if ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>>"$LOGFILE"; then
        echo "ERROR: Cannot resume — invalid state file at $STATE_FILE" >&2
        return 1
    fi

    state_repo=$(jq -r '.repo_slug // empty' "$STATE_FILE")
    state_pr=$(jq -r '.pr_number // empty' "$STATE_FILE")
    if [ "$state_repo" != "$REPO_SLUG" ] || [ "$state_pr" != "$PR_NUMBER" ]; then
        echo "ERROR: Cannot resume — state file is for ${state_repo:-unknown}#${state_pr:-unknown}, not ${REPO_SLUG}#${PR_NUMBER}." >&2
        return 1
    fi

    RESUME_FROM_HEAD_SHA=$(jq -r '.last_review_head_sha // empty' "$STATE_FILE")
    RESUME_COMMENT_CUTOFF=$(jq -r '.last_review_comment_ts // empty' "$STATE_FILE")
    if [ -z "$RESUME_FROM_HEAD_SHA" ]; then
        echo "ERROR: Cannot resume — state file has no last_review_head_sha." >&2
        return 1
    fi

    while IFS=$'\t' read -r key sid; do
        [ -n "$key" ] || continue
        SESSION_IDS["$key"]="$sid"
        STARTED_SESSIONS["$key"]=1
    done < <(jq -r '.sessions // {} | to_entries[] | [.key, .value] | @tsv' "$STATE_FILE")

    while IFS=$'\t' read -r key started; do
        [ -n "$key" ] || continue
        STARTED_SESSIONS["$key"]=$(normalize_started_flag "$started")
    done < <(jq -r '.started_sessions // {} | to_entries[] | [.key, .value] | @tsv' "$STATE_FILE")

    load_session_sidecars
    echo "$(date '+%Y-%m-%d %H:%M:%S') Loaded audit resume state: repo=${REPO_SLUG} pr=${PR_NUMBER} from_head=${RESUME_FROM_HEAD_SHA} comment_cutoff=${RESUME_COMMENT_CUTOFF:-none} sessions=${!SESSION_IDS[*]}" >> "$LOGFILE"
}

comment_ts_expr='(.submitted_at // .created_at // .updated_at // "")'

filter_comments_since_cutoff() {
    local input_file="$1"
    local output_file="$2"

    if [ -z "${RESUME_COMMENT_CUTOFF:-}" ]; then
        cp "$input_file" "$output_file"
        return
    fi

    jq --arg cutoff "$RESUME_COMMENT_CUTOFF" \
        '[.[] | select(('"$comment_ts_expr"') > $cutoff)]' \
        "$input_file" > "$output_file"
}

max_comment_timestamp() {
    jq -sr '[.[][] | '"$comment_ts_expr"' | select(. != "")] | max // ""' "$@"
}

extract_codex_session_id() {
    local jsonl_file="$1"
    local sid

    sid=$(jq -sr \
        'map(select(type == "object") | (.session_id? // .thread_id? // empty)) | map(select(. != "")) | first // ""' \
        "$jsonl_file" 2>>"$LOGFILE") || sid=""
    printf '%s\n' "$sid"
}

# Isolated CLAUDE_CONFIG_DIR for the claude seat, carrying ONLY what OAuth needs
# and deliberately OMITTING settings.json (hooks) and CLAUDE.md (global memory).
#
# The #43 neutral-cwd isolation stops the *audited repo's* config from loading,
# but the operator's USER-level config still loaded because HOME stays set for
# OAuth: SessionStart/UserPromptSubmit hooks fired and global ~/.claude/CLAUDE.md
# memory was injected into every claude turn. That (a) bled the operator's hooks
# and memory into what should be a clean reviewer context and (b) taxed every
# claude turn with ~1.1k tokens of fixed overhead a sandboxed codex turn never
# pays. Pointing CLAUDE_CONFIG_DIR at a dir that has the credentials + the full
# .claude.json (onboarding/identity state; any MCP entries in it are ignored at
# the seat via --strict-mcp-config) but NO settings.json/CLAUDE.md removes both:
# no hooks fire, no global memory loads, OAuth still resolves.
#
# Copy (not symlink): the real credential store is refreshed by the operator's
# own sessions, and copying avoids both symlink-replace-on-refresh staleness and
# write-contention with the operator's live sessions on this shared box. The
# isolated config dir itself is stable per session key because Claude stores
# resume transcripts under it; only the copied auth/onboarding files are
# refreshed on each turn.
#
# Two cases leave the operator's config untouched (print nothing → caller runs
# claude against the real config, the pre-isolation behavior):
#   1. CLAUDE_CONFIG_DIR is ALREADY set — build_agent_env passes it through, and
#      an operator who chose a custom dir must not have it overridden by our
#      throwaway dir. Their credentials may live inside that custom dir, not at
#      $HOME, so copying from $HOME could strip them. Respect the explicit choice.
#   2. $HOME/.claude.json is absent — it is the REQUIRED gate: a config dir with
#      credentials but no .claude.json sends headless `claude -p` into first-run
#      onboarding, which never returns and hangs the turn until the watchdog kills
#      it. (.claude.json lives at $HOME/.claude.json, NOT inside ~/.claude/.)
create_claude_config_dir() {
    local session_key="$1"
    local config_dir src_state src_creds

    # Case 1: operator already chose a config dir — leave it to build_agent_env's
    # passthrough; do not override (could strip creds living inside that dir).
    [ -z "${CLAUDE_CONFIG_DIR:-}" ] || return 0

    # Case 2: no onboarding/identity state to seed → isolation would hang.
    src_state="${HOME:-}/.claude.json"
    [ -f "$src_state" ] || return 0

    config_dir="$CLAUDE_CONFIG_STATE_DIR/$session_key"
    mkdir -p "$config_dir"
    chmod 700 "$config_dir"
    # Copy the full .claude.json (onboarding + identity + any project/MCP state).
    # The dir is chmod 700; MCP entries are ignored at the seat via
    # --strict-mcp-config.
    cp "$src_state" "$config_dir/.claude.json"
    src_creds="${HOME:-}/.claude/.credentials.json"
    # Best-effort: OAuth uses .credentials.json; an API-key auth path
    # (ANTHROPIC_API_KEY, passed through build_agent_env) needs no creds file.
    if [ -f "$src_creds" ]; then
        cp "$src_creds" "$config_dir/.credentials.json"
    else
        rm -f "$config_dir/.credentials.json"
    fi

    printf '%s\n' "$config_dir"
}

cleanup_claude_config_auth_files() {
    local config_dir="$1"

    [ -n "$config_dir" ] || return 0
    case "$config_dir" in
        "$CLAUDE_CONFIG_STATE_DIR"/*)
            # Keep the stable config dir and its projects/ transcripts for
            # --resume, but do not leave copied auth/onboarding material in the
            # workspace between turns. create_claude_config_dir refreshes these
            # files before every Claude invocation.
            rm -f -- "$config_dir/.credentials.json" "$config_dir/.claude.json"
            ;;
    esac
}

# Fetch CC review comments via gh api.
# Collects: review bodies, inline review comments, issue comments.
fetch_cc_comments() {
    local pr_num="$PR_NUMBER"
    local repo="$REPO_SLUG"
    local tmp_reviews tmp_review_comments tmp_issue_comments
    local tmp_reviews_filtered tmp_review_comments_filtered tmp_issue_comments_filtered tmp_output
    local has_content=false
    tmp_reviews=$(mktemp)
    tmp_review_comments=$(mktemp)
    tmp_issue_comments=$(mktemp)
    tmp_reviews_filtered=$(mktemp)
    tmp_review_comments_filtered=$(mktemp)
    tmp_issue_comments_filtered=$(mktemp)
    tmp_output=$(mktemp)

    _cc_cleanup() {
        rm -f "$tmp_reviews" "$tmp_review_comments" "$tmp_issue_comments" \
            "$tmp_reviews_filtered" "$tmp_review_comments_filtered" \
            "$tmp_issue_comments_filtered" "$tmp_output"
    }

    if ! fetch_paginated_json_array "repos/$repo/pulls/$pr_num/reviews" "$tmp_reviews" "PR reviews"; then
        _cc_cleanup; return 1
    fi
    if ! fetch_paginated_json_array "repos/$repo/pulls/$pr_num/comments" "$tmp_review_comments" "PR review comments"; then
        _cc_cleanup; return 1
    fi
    if ! fetch_paginated_json_array "repos/$repo/issues/$pr_num/comments" "$tmp_issue_comments" "PR issue comments"; then
        _cc_cleanup; return 1
    fi
    filter_comments_since_cutoff "$tmp_reviews" "$tmp_reviews_filtered"
    filter_comments_since_cutoff "$tmp_review_comments" "$tmp_review_comments_filtered"
    filter_comments_since_cutoff "$tmp_issue_comments" "$tmp_issue_comments_filtered"
    FETCHED_MAX_COMMENT_TS=$(max_comment_timestamp \
        "$tmp_reviews_filtered" "$tmp_review_comments_filtered" "$tmp_issue_comments_filtered")

    if ! {
        echo "# CC Review Comments for PR #$pr_num"
        echo ""

        # Review bodies
        if jq -e 'length > 0' "$tmp_reviews_filtered" >/dev/null; then
            echo "## Reviews"
            echo ""
            jq -r '.[] | select(.body != null and .body != "") | "### Review by \(.user.login) (\(.state))\n- URL: \(.html_url)\n- Date: \(.submitted_at)\n\n\(.body)\n"' \
                "$tmp_reviews_filtered"
        fi

        # Inline review comments
        if jq -e 'length > 0' "$tmp_review_comments_filtered" >/dev/null; then
            echo "## Inline Comments"
            echo ""
            jq -r '.[] | "### Comment by \(.user.login)\n- File: \(.path // "n/a"):\(.line // .original_line // "n/a")\n- URL: \(.html_url)\n- Date: \(.created_at)\n\n\(.body)\n"' \
                "$tmp_review_comments_filtered"
        fi

        # Issue comments
        if jq -e 'length > 0' "$tmp_issue_comments_filtered" >/dev/null; then
            echo "## Issue Comments"
            echo ""
            jq -r '.[] | "### Comment by \(.user.login)\n- URL: \(.html_url)\n- Date: \(.created_at)\n\n\(.body)\n"' \
                "$tmp_issue_comments_filtered"
        fi

        # Check if all empty
        for f in "$tmp_reviews_filtered" "$tmp_review_comments_filtered" "$tmp_issue_comments_filtered"; do
            if jq -e 'length > 0' "$f" >/dev/null; then
                has_content=true
                break
            fi
        done
        if [ "$has_content" = false ]; then
            if [ "$RESUME" = true ]; then
                echo "No new comments found since previous audit."
            else
                echo "No prior comments found."
            fi
        fi
    } > "$tmp_output"; then
        echo "ERROR: Failed to render GitHub review comments. Aborting rather than dropping prior review context." >&2
        _cc_cleanup; return 1
    fi

    if ! mv "$tmp_output" "$CC_COMMENTS_FILE"; then
        _cc_cleanup; return 1
    fi
    _cc_cleanup
}

gh_pr_view_metadata() {
    local input="$1"
    local output_file="$2"

    if [ -n "$input" ]; then
        (cd "$PROJECT_DIR" && gh pr view "$input" \
            --json number,url,title,headRefName,baseRefName,headRefOid,state,body \
            > "$output_file" 2>>"$LOGFILE")
    else
        (cd "$PROJECT_DIR" && gh pr view \
            --json number,url,title,headRefName,baseRefName,headRefOid,state,body \
            > "$output_file" 2>>"$LOGFILE")
    fi
}

gh_pr_diff_to_file() {
    local input="$1"
    local output_file="$2"

    if [ -n "$input" ]; then
        (cd "$PROJECT_DIR" && gh pr diff "$input" > "$output_file" 2>>"$LOGFILE")
    else
        (cd "$PROJECT_DIR" && gh pr diff > "$output_file" 2>>"$LOGFILE")
    fi
}

gh_compare_diff_to_file() {
    local base_sha="$1"
    local head_sha="$2"
    local output_file="$3"

    if [ "$base_sha" = "$head_sha" ]; then
        printf 'No new commits since previous audit head %s.\n' "$base_sha" > "$output_file"
        return 0
    fi

    if gh api \
        -H "Accept: application/vnd.github.diff" \
        "repos/${REPO_SLUG}/compare/${base_sha}...${head_sha}" \
        > "$output_file" 2>>"$LOGFILE"; then
        if [ -s "$output_file" ]; then
            return 0
        fi
        printf 'No diff content returned for commits %s...%s.\n' "$base_sha" "$head_sha" > "$output_file"
        return 0
    fi

    return 1
}

git_compare_diff_fallback_to_file() {
    local base_sha="$1"
    local head_sha="$2"
    local output_file="$3"
    local repo_name local_clone

    repo_name="${REPO_SLUG##*/}"
    local_clone="${AUDIT_PR_LOCAL_CLONE_DIR:-${HOME:-$PROJECT_DIR}/projects/${repo_name}}"
    if [ -d "${local_clone}/.git" ] \
        && (cd "${local_clone}" \
            && git fetch origin --quiet 2>>"$LOGFILE" \
            && git diff "${base_sha}...${head_sha}" > "${output_file}.tmp" 2>>"$LOGFILE" \
            && mv "${output_file}.tmp" "$output_file"); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') gh compare diff failed; used local git compare fallback from ${local_clone}" >> "$LOGFILE"
        return 0
    fi

    rm -f "${output_file}.tmp"
    return 1
}

fetch_resume_delta_diff() {
    if gh_compare_diff_to_file "$RESUME_FROM_HEAD_SHA" "$AUDITED_HEAD_SHA" "$PR_DIFF_FILE"; then
        return 0
    fi
    if git_compare_diff_fallback_to_file "$RESUME_FROM_HEAD_SHA" "$AUDITED_HEAD_SHA" "$PR_DIFF_FILE"; then
        return 0
    fi

    echo "ERROR: failed to fetch delta diff for ${RESUME_FROM_HEAD_SHA}...${AUDITED_HEAD_SHA}" >&2
    return 1
}

derive_repo_slug_from_metadata() {
    jq -r '
        .url
        | capture("^https://github[.]com/(?<owner>[^/]+)/(?<repo>[^/]+)/pull/[0-9]+/?(?:[?#].*)?$")?
        | select(. != null)
        | "\(.owner)/\(.repo)"
    ' "$1"
}

is_generated_or_vendor_path() {
    local path="$1"

    case "$path" in
        node_modules/*|vendor/*|dist/*|build/*|coverage/*|*.min.js|*.min.css|package-lock.json|yarn.lock|pnpm-lock.yaml|Gemfile.lock|composer.lock|Cargo.lock|poetry.lock|go.sum)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_binary_patch() {
    local patch_file="$1"

    head -5 "$patch_file" | grep -Eq '^(Binary files|GIT binary patch)' && return 0
    # Slices whose payload is not valid UTF-8 (e.g. mu-law/PCM audio fixtures
    # that git and GitHub text heuristics let through as raw text diffs — no
    # NUL bytes) crash agent CLIs at stdin read with 'input is not valid
    # UTF-8'. Treat them as binary so every consumer skips them the same way.
    ! iconv -f UTF-8 -t UTF-8 "$patch_file" > /dev/null 2>&1
}

patch_path_from_slice() {
    local patch_file="$1"
    awk '
        function unquote(path) {
            if (path ~ /^".*"$/) {
                sub(/^"/, "", path)
                sub(/"$/, "", path)
                gsub(/\\"/, "\"", path)
                gsub(/\\\\/, "\\", path)
            }
            return path
        }
        function clean_path(path) {
            path = unquote(path)
            sub(/^[ab]\//, "", path)
            return path
        }
        /^\+\+\+ / && $0 != "+++ /dev/null" {
            path = clean_path(substr($0, 5))
            print path
            printed = 1
            exit
        }
        /^--- / && $0 != "--- /dev/null" {
            fallback = clean_path(substr($0, 5))
        }
        END {
            if (!printed && fallback != "") {
                print fallback
            }
        }
    ' "$patch_file"
}

split_diff_into_slices() {
    rm -rf "$DIFF_SLICES_DIR"
    mkdir -p "$DIFF_SLICES_DIR"

    awk -v outdir="$DIFF_SLICES_DIR" '
        /^diff --git / {
            if (out != "") {
                close(out)
            }
            idx++
            out = sprintf("%s/%04d.patch", outdir, idx)
        }
        {
            if (out == "") {
                idx = 1
                out = sprintf("%s/%04d_misc.patch", outdir, idx)
            }
            print > out
        }
    ' "$PR_DIFF_FILE"
}

write_diff_manifest() {
    local diff_bytes="$1"
    local diff_lines="$2"
    local tmp_items slice path bytes lines additions deletions binary generated

    tmp_items=$(mktemp)
    : > "$tmp_items"

    for slice in "$DIFF_SLICES_DIR"/*.patch; do
        [ -e "$slice" ] || continue
        path=$(patch_path_from_slice "$slice")
        [ -n "$path" ] || path="$(basename "$slice")"
        bytes=$(wc -c < "$slice" | tr -d ' ')
        lines=$(wc -l < "$slice" | tr -d ' ')
        # Off-by-~1: diff headers (--- a/, +++ b/) match these patterns; acceptable for metadata
        additions=$(grep -c '^+[^+]' "$slice" || true)
        deletions=$(grep -c '^-[^-]' "$slice" || true)
        binary=false
        generated=false
        if is_binary_patch "$slice"; then
            binary=true
        fi
        if is_generated_or_vendor_path "$path"; then
            generated=true
        fi

        if ! jq -n \
            --arg path "$path" \
            --arg slice "$slice" \
            --argjson bytes "$bytes" \
            --argjson lines "$lines" \
            --argjson additions "$additions" \
            --argjson deletions "$deletions" \
            --argjson binary "$binary" \
            --argjson generated "$generated" \
            '{path:$path,slice:$slice,bytes:$bytes,lines:$lines,additions:$additions,deletions:$deletions,binary:$binary,generated:$generated}' \
            >> "$tmp_items"; then
            rm -f "$tmp_items"
            return 1
        fi
    done

    if ! jq -s \
        --arg mode "$DIFF_MODE" \
        --argjson diff_bytes "$diff_bytes" \
        --argjson diff_lines "$diff_lines" \
        --argjson full_diff_max_bytes "$FULL_DIFF_MAX_BYTES" \
        --argjson full_diff_max_lines "$FULL_DIFF_MAX_LINES" \
        --argjson chunk_max_bytes "$CHUNK_MAX_BYTES" \
        '{mode:$mode,stats:{bytes:$diff_bytes,lines:$diff_lines,files:length},thresholds:{full_diff_max_bytes:$full_diff_max_bytes,full_diff_max_lines:$full_diff_max_lines,chunk_max_bytes:$chunk_max_bytes},files:.}' \
        "$tmp_items" > "$DIFF_MANIFEST_FILE"; then
        rm -f "$tmp_items"
        return 1
    fi

    rm -f "$tmp_items"
}

# Split one oversized diff slice into per-hunk sub-slices, each carrying the
# file header (diff --git / index / --- / +++) so the path still resolves, and
# packed to <= cap bytes where possible. Writes <base>_NNN.patch sub-slices and
# removes the original. Prints the number of sub-slices produced; prints 0 and
# leaves the original intact when the slice has no @@ hunks to split on (the map
# stage then truncates it). A single hunk larger than the cap becomes one
# still-oversized sub-slice — also handled (truncated) at the map stage.
subsplit_one_oversized_slice() {
    local slice="$1"
    local cap="$2"
    local outdir base produced

    outdir=$(dirname "$slice")
    base=$(basename "$slice" .patch)

    # Buffer each hunk in full, then decide whether it fits the current
    # sub-slice BEFORE appending it — accounting for the reattached header — so
    # packed sub-slices stay <= cap. A single hunk whose header+body already
    # exceeds cap becomes its own (still-oversized) sub-slice, which the map
    # stage then truncates.
    # LC_ALL=C so awk length() counts BYTES (matching the wc -c cap checks
    # elsewhere); otherwise multibyte UTF-8 diff content is under-counted.
    produced=$(LC_ALL=C awk -v cap="$cap" -v outdir="$outdir" -v base="$base" '
        BEGIN { part = 0; hdr = ""; cur = ""; curbytes = 0; hunk = ""; hunkbytes = 0; inhunk = 0; haveHunk = 0 }
        function flush_subslice(   f) {
            if (cur == "") return
            part++
            f = sprintf("%s/%s_%03d.patch", outdir, base, part)
            printf "%s%s", hdr, cur > f
            close(f)
            cur = ""; curbytes = 0
        }
        function commit_hunk() {
            if (!haveHunk) return
            if (curbytes > 0 && (length(hdr) + curbytes + hunkbytes) > cap) flush_subslice()
            cur = cur hunk; curbytes += hunkbytes
            hunk = ""; hunkbytes = 0; haveHunk = 0
        }
        /^@@/ {
            commit_hunk()
            inhunk = 1; haveHunk = 1
            hunk = $0 "\n"; hunkbytes = length($0) + 1
            next
        }
        {
            if (inhunk == 0) { hdr = hdr $0 "\n" }
            else { hunk = hunk $0 "\n"; hunkbytes += length($0) + 1 }
        }
        END { commit_hunk(); flush_subslice(); print part }
    ' "$slice")

    if [ "${produced:-0}" -ge 1 ]; then
        rm -f "$slice"
    fi
    printf '%s\n' "${produced:-0}"
}

# Walk all chunked-mode slices and sub-split each oversized, non-generated,
# non-binary slice by hunk so one large file can never abort the whole audit
# (mesh#44 Part 1). Generated/vendor/binary slices are skipped wholesale at the
# map stage, so their size never matters here.
subsplit_oversized_slices() {
    local slice path bytes produced

    for slice in "$DIFF_SLICES_DIR"/*.patch; do
        [ -e "$slice" ] || continue
        bytes=$(wc -c < "$slice" | tr -d ' ')
        [ "$bytes" -gt "$CHUNK_MAX_BYTES" ] || continue
        path=$(patch_path_from_slice "$slice")
        [ -n "$path" ] || path="$(basename "$slice")"
        is_generated_or_vendor_path "$path" && continue
        is_binary_patch "$slice" && continue

        produced=$(subsplit_one_oversized_slice "$slice" "$CHUNK_MAX_BYTES")
        if [ "${produced:-0}" -ge 1 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') Sub-split oversized slice $path (${bytes} bytes) into ${produced} hunk sub-chunk(s)." >> "$LOGFILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: oversized slice $path (${bytes} bytes) has no hunk boundaries to split on; leaving whole for map-stage truncation." >> "$LOGFILE"
        fi
    done
}

# Make a string safe to use as a directory name and a session-key fragment:
# collapse anything outside [A-Za-z0-9._-] to '_', trim leading/trailing '_',
# cap length. Empty input falls back to "group".
sanitize_group_name() {
    local out
    out=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_\{1,\}/_/g; s/^_//; s/_$//' | cut -c1-40)
    [ -n "$out" ] || out="group"
    printf '%s' "$out"
}

# Choose the subsystem group key for one changed path (mesh#38). Cross-cutting
# contract surfaces collapse into a single "shared" group so one pipeline sees
# the whole interface surface; everything else groups by its top-level path
# segment. An operator --group-config (glob<TAB>group lines) overrides both.
slice_group_key() {
    local path="$1" lc top glob grp
    if [ -n "$GROUP_CONFIG_FILE" ] && [ -f "$GROUP_CONFIG_FILE" ]; then
        while IFS=$'\t' read -r glob grp; do
            [ -n "$glob" ] || continue
            case "$glob" in '#'*) continue ;; esac
            # shellcheck disable=SC2254
            case "$path" in
                $glob) sanitize_group_name "$grp"; return 0 ;;
            esac
        done < "$GROUP_CONFIG_FILE"
    fi
    lc=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$lc" | grep -Eq "$SHARED_SURFACE_REGEX"; then
        printf 'shared'
        return 0
    fi
    case "$path" in
        */*) top="${path%%/*}" ;;
        *)   top="root" ;;
    esac
    sanitize_group_name "$top"
}

# Concatenate the slices listed in an assignment file (lines:
# <bytes>\t<lines>\t<slice>) into one group bin: writes <gdir>/group.patch,
# <gdir>/files.txt, copies the member slices into <gdir>/diff_slices/ (so a
# chunked group can run the existing map stage over them), and appends one
# record line `<name>\t<mode>\t<bytes>\t<lines>\t<files>` to GROUPS_DIR/.records
# plus the name to GROUPS_DIR/.names.
materialize_group_bin() {
    local name="$1" mode="$2" assign_file="$3"
    local gdir="$GROUPS_DIR/$name" bytes lines slice p gb gl gf
    rm -rf "$gdir"
    mkdir -p "$gdir/diff_slices"
    : > "$gdir/group.patch"
    : > "$gdir/files.txt"
    while IFS=$'\t' read -r bytes lines slice; do
        [ -n "$slice" ] || continue
        cat "$slice" >> "$gdir/group.patch"
        cp "$slice" "$gdir/diff_slices/"
        p=$(patch_path_from_slice "$slice")
        [ -n "$p" ] || p="$(basename "$slice")"
        printf '%s\n' "$p" >> "$gdir/files.txt"
    done < "$assign_file"
    gb=$(wc -c < "$gdir/group.patch" | tr -d ' ')
    gl=$(wc -l < "$gdir/group.patch" | tr -d ' ')
    gf=$(wc -l < "$gdir/files.txt" | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$mode" "$gb" "$gl" "$gf" >> "$GROUPS_DIR/.records"
    printf '%s\n' "$name" >> "$GROUPS_DIR/.names"
}

# Turn one semantic key's slices into one or more bins, each <= the full-diff
# thresholds so every group can run in full-diff mode. A key under threshold
# becomes a single full-diff bin (name = key). An over-threshold key is
# first-fit packed into <name>_bNN bins; a single slice that alone exceeds the
# threshold becomes its own bin tagged "chunked" — the one residual case the
# per-group map stage (hunk sub-split) still handles (mesh#44).
emit_bins_for_key() {
    local key="$1" assign_file="$2"
    local maxb="$FULL_DIFF_MAX_BYTES" maxl="$FULL_DIFF_MAX_LINES"
    local total_b total_l
    total_b=$(awk -F'\t' '{s+=$1} END{print s+0}' "$assign_file")
    total_l=$(awk -F'\t' '{s+=$2} END{print s+0}' "$assign_file")
    if [ "$total_b" -le "$maxb" ] && [ "$total_l" -le "$maxl" ]; then
        materialize_group_bin "$key" "full-diff" "$assign_file"
        return 0
    fi

    local bin=0 cur_b=0 cur_l=0 cur_list bytes lines slice
    cur_list=$(mktemp)
    : > "$cur_list"
    _flush_bin() {
        [ -s "$cur_list" ] || return 0
        bin=$((bin + 1))
        materialize_group_bin "$(printf '%s_b%02d' "$key" "$bin")" "full-diff" "$cur_list"
        : > "$cur_list"; cur_b=0; cur_l=0
    }
    while IFS=$'\t' read -r bytes lines slice; do
        [ -n "$slice" ] || continue
        if [ "$bytes" -gt "$maxb" ] || [ "$lines" -gt "$maxl" ]; then
            _flush_bin
            bin=$((bin + 1))
            printf '%s\t%s\t%s\n' "$bytes" "$lines" "$slice" > "$cur_list"
            materialize_group_bin "$(printf '%s_b%02d' "$key" "$bin")" "chunked" "$cur_list"
            : > "$cur_list"; cur_b=0; cur_l=0
            continue
        fi
        if [ $((cur_b + bytes)) -gt "$maxb" ] || [ $((cur_l + lines)) -gt "$maxl" ]; then
            _flush_bin
        fi
        printf '%s\t%s\t%s\n' "$bytes" "$lines" "$slice" >> "$cur_list"
        cur_b=$((cur_b + bytes)); cur_l=$((cur_l + lines))
    done < "$assign_file"
    _flush_bin
    unset -f _flush_bin
    rm -f "$cur_list"
}

# Render GROUPS_DIR/.records (tsv) as GROUPS_DIR/partition.json.
write_partition_manifest() {
    jq -R -s '
        split("\n") | map(select(length > 0) | split("\t")
        | {name: .[0], mode: .[1], bytes: (.[2]|tonumber), lines: (.[3]|tonumber), files: (.[4]|tonumber)})
    ' "$GROUPS_DIR/.records" > "$GROUPS_DIR/partition.json"
}

# Partition the current slice set into subsystem group bins under GROUPS_DIR.
# Sets the global GROUP_COUNT. Assumes split_diff_into_slices already ran.
partition_slices_into_groups() {
    rm -rf "$GROUPS_DIR"
    mkdir -p "$GROUPS_DIR"
    : > "$GROUPS_DIR/.records"
    : > "$GROUPS_DIR/.names"

    local assign_root slice path key bytes lines kf
    assign_root=$(mktemp -d)
    for slice in "$DIFF_SLICES_DIR"/*.patch; do
        [ -e "$slice" ] || continue
        path=$(patch_path_from_slice "$slice")
        [ -n "$path" ] || path="$(basename "$slice")"
        # Binary slices (declared-binary headers or non-UTF-8 payloads) must
        # not be concatenated into group.patch prompts — they crash the agent
        # CLI at stdin read and abort the whole partition run. Skip them here
        # like the chunked map stage does; they remain recorded with
        # binary=true in diff_manifest.json.
        if is_binary_patch "$slice"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') Partition: skipping binary slice $path" >> "$LOGFILE"
            continue
        fi
        key=$(slice_group_key "$path")
        bytes=$(wc -c < "$slice" | tr -d ' ')
        lines=$(wc -l < "$slice" | tr -d ' ')
        printf '%s\t%s\t%s\n' "$bytes" "$lines" "$slice" >> "$assign_root/$key"
    done
    # Deterministic group order (shared first is convenient but not required).
    for kf in "$assign_root"/*; do
        [ -e "$kf" ] || continue
        emit_bins_for_key "$(basename "$kf")" "$kf"
    done
    rm -rf "$assign_root"

    write_partition_manifest
    GROUP_COUNT=$(wc -l < "$GROUPS_DIR/.names" | tr -d ' ')
    echo "$(date '+%Y-%m-%d %H:%M:%S') Partitioned diff into $GROUP_COUNT group(s):" >> "$LOGFILE"
    sed 's/^/  /' "$GROUPS_DIR/.records" >> "$LOGFILE"
}

# Partition is degenerate when it could not actually divide the diff: a single
# group that is itself a lone oversized file (mode chunked). In that case there
# is nothing to consolidate, so fall back to the global chunked map-stage path.
partition_is_degenerate() {
    [ "${GROUP_COUNT:-0}" -le 1 ] && grep -q "$(printf '\tchunked\t')" "$GROUPS_DIR/.records" 2>/dev/null
}

build_diff_package() {
    local diff_bytes diff_lines

    diff_bytes=$(wc -c < "$PR_DIFF_FILE" | tr -d ' ')
    diff_lines=$(wc -l < "$PR_DIFF_FILE" | tr -d ' ')

    split_diff_into_slices

    if [ "$diff_bytes" -le "$FULL_DIFF_MAX_BYTES" ] && [ "$diff_lines" -le "$FULL_DIFF_MAX_LINES" ]; then
        DIFF_MODE="full-diff"
        # A below-threshold diff can still carry undeclared-binary payloads
        # (non-UTF-8 bytes GitHub served as text). Full-diff mode cats
        # PR_DIFF_FILE into the prompt unsliced, so when the raw diff fails
        # UTF-8 validation rebuild it from the non-binary slices; the dropped
        # slices stay flagged binary=true in the manifest.
        if ! iconv -f UTF-8 -t UTF-8 "$PR_DIFF_FILE" > /dev/null 2>&1; then
            local slice path
            : > "$PR_DIFF_FILE.filtered"
            for slice in "$DIFF_SLICES_DIR"/*.patch; do
                [ -e "$slice" ] || continue
                if is_binary_patch "$slice"; then
                    path=$(patch_path_from_slice "$slice")
                    echo "$(date '+%Y-%m-%d %H:%M:%S') Full-diff: dropping binary slice ${path:-$(basename "$slice")} from the prompt payload" >> "$LOGFILE"
                    continue
                fi
                cat "$slice" >> "$PR_DIFF_FILE.filtered"
            done
            mv "$PR_DIFF_FILE.filtered" "$PR_DIFF_FILE"
            if [ ! -s "$PR_DIFF_FILE" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') Full-diff: every slice was binary — no reviewable content." >> "$LOGFILE"
                echo "ERROR: no reviewable diff content after binary-slice filtering; nothing to audit." >&2
                exit 1
            fi
        fi
    else
        # Over threshold: partition into subsystem groups and run the full
        # pipeline per group (mesh#38). chunked survives only as the fallback
        # for a lone file that alone exceeds the threshold.
        partition_slices_into_groups
        if [ "${GROUP_COUNT:-0}" -eq 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') Partition produced zero groups — every slice was skipped as binary." >> "$LOGFILE"
            echo "ERROR: no reviewable diff content after binary-slice filtering; nothing to audit." >&2
            exit 1
        fi
        if partition_is_degenerate; then
            DIFF_MODE="chunked"
        else
            DIFF_MODE="partition"
        fi
    fi

    # In chunked (fallback) mode, sub-split any oversized single-file slice by
    # hunk BEFORE writing the manifest, so the manifest reflects the final slice
    # set and one large file can never abort the whole audit (mesh#44 Part 1).
    # CHUNK_MAX_BYTES is a packing knob (bin size), not a gate that aborts.
    if [ "$DIFF_MODE" = "chunked" ]; then
        subsplit_oversized_slices
    fi
    # Union manifest over every slice (all modes): head-drift and coverage key
    # off the full audited-file list, independent of how groups were formed.
    write_diff_manifest "$diff_bytes" "$diff_lines"

    : > "$FILE_SUMMARIES_FILE"
    if [ "$DIFF_MODE" = "full-diff" ]; then
        printf 'Full diff mode. Raw PR diff is below configured thresholds.\n' > "$FILE_SUMMARIES_FILE"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') Diff package: mode=$DIFF_MODE bytes=$diff_bytes lines=$diff_lines groups=${GROUP_COUNT:-0} full_max_bytes=$FULL_DIFF_MAX_BYTES full_max_lines=$FULL_DIFF_MAX_LINES chunk_max_bytes=$CHUNK_MAX_BYTES" >> "$LOGFILE"
}

build_chunk_audit_prompt() {
    local slice_file="$1"
    local path="$2"

    printf 'You are performing a read-only map-stage audit of one diff chunk from PR #%s in %s.\n' "$PR_NUMBER" "$REPO_SLUG"
    printf 'You have NO tools and NO access to the repository, file system, or network. Base your analysis only on the diff chunk and comments included in this prompt; do NOT attempt to read files, run commands, or otherwise inspect the repo.\n'
    printf 'Production deploy notes are NOT request-changes blockers unless the PR itself must change before merge.\n\n'
    printf 'Focus on this path/chunk: %s\n\n' "$path"
    printf 'Return a concise summary with these fields: risk, findings, needs_followup, coverage_notes.\n\n'
    printf '## Diff Chunk\n\n'
    cat "$slice_file"
    printf '\n\n## CC Review Comments\n\n'
    cat "$CC_COMMENTS_FILE"
}

append_skipped_file_summary() {
    local path="$1"
    local reason="$2"

    {
        printf '### %s\n\n' "$path"
        printf -- "- path: \`%s\`\n" "$path"
        printf -- '- risk: skipped\n'
        printf -- '- findings: Not agent-reviewed because %s.\n' "$reason"
        printf -- '- needs_followup: yes\n'
        printf -- '- coverage_notes: Manual review may be needed if this file affects runtime behavior.\n\n'
    } >> "$FILE_SUMMARIES_FILE"
}

append_reviewed_file_summary() {
    local path="$1"
    local output_file="$2"

    {
        printf '### %s\n\n' "$path"
        printf -- "- path: \`%s\`\n" "$path"
        printf -- '- risk: see map-stage findings\n'
        printf -- '- findings:\n\n'
        sed 's/^/  /' "$output_file"
        printf '\n- needs_followup: see findings\n'
        printf -- '- coverage_notes: Reviewed from chunked diff slice.\n\n'
    } >> "$FILE_SUMMARIES_FILE"
}

# Summary for a slice that was a single hunk larger than the cap: review what
# we could of a truncated view and explicitly route the file to the "Files
# needing manual review" bucket (the 'Manual review may be needed' phrase is
# what write_final_report counts) instead of aborting the run (mesh#44 Part 1).
append_truncated_file_summary() {
    local path="$1"
    local output_file="$2"
    local bytes="$3"
    local cap="$4"

    {
        printf '### %s (TRUNCATED)\n\n' "$path"
        printf -- "- path: \`%s\`\n" "$path"
        printf -- '- risk: partial — a single diff hunk exceeded the chunk cap (%s bytes > %s) and could not be split further; only the first %s bytes were reviewed\n' "$bytes" "$cap" "$cap"
        printf -- '- findings:\n\n'
        if [ -s "$output_file" ]; then
            sed 's/^/  /' "$output_file"
        else
            printf '  (no agent findings — slice too large to review)\n'
        fi
        printf '\n- needs_followup: yes\n'
        printf -- '- coverage_notes: Truncated at %s bytes. Manual review may be needed for the remainder of this file.\n\n' "$cap"
    } >> "$FILE_SUMMARIES_FILE"
}

run_large_diff_map_stage() {
    local idx=0 slice path generated binary output_file prompt bytes trunc_slice

    if [ "$DIFF_MODE" != "chunked" ]; then
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') Large diff map-stage starting" >> "$LOGFILE"
    echo "Large diff detected: running chunked map-stage audit..."
    : > "$FILE_SUMMARIES_FILE"

    for slice in "$DIFF_SLICES_DIR"/*.patch; do
        [ -e "$slice" ] || continue
        idx=$((idx + 1))
        path=$(patch_path_from_slice "$slice")
        [ -n "$path" ] || path="$(basename "$slice")"
        generated=false
        binary=false
        is_generated_or_vendor_path "$path" && generated=true
        is_binary_patch "$slice" && binary=true

        if [ "$binary" = true ]; then
            append_skipped_file_summary "$path" "it is a binary patch"
            continue
        fi
        if [ "$generated" = true ]; then
            append_skipped_file_summary "$path" "it appears to be generated, vendored, or lockfile output"
            continue
        fi

        # Write chunk artifacts beside the active FILE_SUMMARIES_FILE: that is
        # WORKSPACE_DIR in the global fallback path and the group dir when a
        # partition group runs in chunked mode, so concurrent groups never
        # collide on chunk_<idx>_<agent>.md.
        output_file="$(dirname "$FILE_SUMMARIES_FILE")/chunk_${idx}_${PRIMARY_AGENT}.md"
        bytes=$(wc -c < "$slice" | tr -d ' ')

        if [ "$bytes" -gt "$CHUNK_MAX_BYTES" ]; then
            # A single hunk still exceeds the cap (it couldn't be sub-split).
            # Review a truncated view and route the file to manual review rather
            # than aborting the whole run (mesh#44 Part 1).
            trunc_slice=$(mktemp)
            head -c "$CHUNK_MAX_BYTES" "$slice" > "$trunc_slice"
            printf '\n\n[... TRUNCATED: this single diff hunk exceeded the %s-byte chunk cap; only the first %s bytes are shown. The file is flagged for manual review. ...]\n' \
                "$CHUNK_MAX_BYTES" "$CHUNK_MAX_BYTES" >> "$trunc_slice"
            prompt=$(build_chunk_audit_prompt "$trunc_slice" "$path (truncated)")
            run_agent_turn_with_retry "$PRIMARY_AGENT" "chunk_${idx}_${PRIMARY_AGENT}" "$prompt" "$output_file"
            rm -f "$trunc_slice"
            append_truncated_file_summary "$path" "$output_file" "$bytes" "$CHUNK_MAX_BYTES"
            echo "$(date '+%Y-%m-%d %H:%M:%S') Truncated oversized single-hunk slice for manual review: $path (${bytes} bytes)" >> "$LOGFILE"
            assert_repo_unchanged_outside_workspace
            if check_feedback; then
                echo "Stopped by feedback during large-diff map stage."
                return 2
            fi
            continue
        fi

        # Map stage uses PRIMARY_AGENT only; co-agent sees summaries in cross-pollination rounds
        prompt=$(build_chunk_audit_prompt "$slice" "$path")
        run_agent_turn_with_retry "$PRIMARY_AGENT" "chunk_${idx}_${PRIMARY_AGENT}" "$prompt" "$output_file"
        if [ ! -s "$output_file" ]; then
            echo "ERROR: Missing chunk audit output for $path" >&2
            return 1
        fi
        append_reviewed_file_summary "$path" "$output_file"
        assert_repo_unchanged_outside_workspace
        if check_feedback; then
            echo "Stopped by feedback during large-diff map stage."
            return 2
        fi
    done

    echo "$(date '+%Y-%m-%d %H:%M:%S') Large diff map-stage complete: chunks=$idx" >> "$LOGFILE"
}

# Check feedback.md for stop/exit signal. Returns 0 if stop requested.
check_feedback() {
    if [ -s "$FEEDBACK_FILE" ] && grep -qi -- '^\s*\(stop\|exit\)\s*$' "$FEEDBACK_FILE"; then
        return 0
    fi
    return 1
}

# Assert no files outside WORKSPACE_DIR changed since pre-run snapshot.
assert_repo_unchanged_outside_workspace() {
    local current_status ws_rel
    ws_rel=$(realpath --relative-to="$PROJECT_DIR" "$WORKSPACE_DIR" 2>/dev/null || echo "agent_workers/audit_pr_review")
    current_status=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | \
        grep -v -- "^.. ${ws_rel}" || true)

    if [ "$current_status" != "$PRE_RUN_STATUS" ]; then
        echo "ERROR: Files outside workspace changed during agent turn!" >&2
        echo "Pre-run status:" >&2
        echo "$PRE_RUN_STATUS" >&2
        echo "Current status:" >&2
        echo "$current_status" >&2
        return 1
    fi
    return 0
}

# Run a single agent turn. Fresh runs create one session per round; -R resumes
# the prior repo/PR-scoped session for the same round key.
run_audit_agent_turn() {
    local agent="$1"
    local session_key="$2"
    local prompt="$3"
    local outfile="$4"

    prompt=$(_agent_prepare_prompt "$prompt")

    echo "$(date '+%Y-%m-%d %H:%M:%S') Agent turn: agent=$agent session=$session_key" >> "$LOGFILE"

    case "$agent" in
        claude)
            local sid started resume_existing
            local -a claude_session_args=()
            sid="${SESSION_IDS[$session_key]:-}"
            started="${STARTED_SESSIONS[$session_key]:-0}"
            resume_existing=false
            if [ "$started" = "1" ] && [ -n "$sid" ]; then
                claude_session_args=(--resume "$sid")
                resume_existing=true
            else
                sid=$(uuidgen)
                SESSION_IDS["$session_key"]="$sid"
                claude_session_args=(--session-id "$sid")
            fi
            # Isolate the claude seat to match the codex sandbox as closely as
            # the OAuth-on-this-box constraint allows, so untrusted PR content
            # has no tool surface to reach host resources (mesh#43):
            #   --tools ""           disables built-in tools (Read/Bash/Grep/…).
            #   --strict-mcp-config  ignores ~/.claude.json MCP servers and
            #   --mcp-config '{...}' loads an empty server set, so NO MCP tools
            #                        are exposed. (Without these, --tools "" still
            #                        leaves the claude.ai connectors in the init
            #                        event — built-ins off, MCP tools on.)
            #   env -C <neutral dir> runs claude outside the audited repo so
            #                        CLAUDE.md / git status / project hooks do
            #                        not auto-load into the review context.
            #   CLAUDE_CONFIG_DIR    points the seat at an isolated config dir
            #                        (create_claude_config_dir) with credentials +
            #                        onboarding state but NO settings.json/CLAUDE.md,
            #                        so the operator's USER-level hooks and global
            #                        memory no longer load into the reviewer (they
            #                        did before — HOME stays set for OAuth — bleeding
            #                        operator context in and taxing every claude turn
            #                        with ~1.1k tokens of fixed overhead codex never
            #                        paid). --bare would also drop them but breaks
            #                        OAuth on this box. Falls back to the real config
            #                        when no isolated dir could be staged.
            local claude_ctx claude_cfg
            claude_ctx=$(create_claude_context_dir "$session_key")
            claude_cfg=$(create_claude_config_dir "$session_key")
            local -a env_cmd
            build_agent_env env_cmd
            # env_cmd is (env -i <assignments...>); splice -C between -i and the
            # assignments so the chdir applies to the cleaned environment. Inject
            # CLAUDE_CONFIG_DIR LAST so it overrides any value build_agent_env
            # passed through from the caller's environment.
            local -a cmd=(
                env -i -C "$claude_ctx"
                "${env_cmd[@]:2}"
            )
            [ -n "$claude_cfg" ] && cmd+=("CLAUDE_CONFIG_DIR=$claude_cfg")
            # --output-format json: the turn's stdout becomes a single result
            # envelope ({result, usage, total_cost_usd, ...}) instead of bare
            # text. Capture it to a temp, lift .result back into $outfile (so the
            # downstream FINAL_COMMENT marker contract is unchanged), and feed
            # .usage to the metrics log. finalize_claude_json falls back to raw
            # passthrough when the stream is NOT that envelope (older CLI / mock /
            # non-JSON error), so a parse surprise can never blank the review.
            cmd+=(claude -p --output-format json --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' "${claude_session_args[@]}")
            local prompt_file claude_raw
            prompt_file=$(mktemp)
            claude_raw=$(mktemp)
            printf '%s' "$prompt" > "$prompt_file"
            local rc=0
            _agent_run_stdin "$claude_raw" "$prompt_file" "${cmd[@]}" || rc=$?
            cleanup_claude_config_auth_files "$claude_cfg"
            finalize_claude_json "$claude_raw" "$outfile"
            record_agent_metrics claude "$session_key" "$claude_raw"
            if [ "$rc" -eq 0 ]; then
                SESSION_IDS["$session_key"]="$sid"
                STARTED_SESSIONS["$session_key"]=1
            elif [ "$resume_existing" = true ]; then
                unset "SESSION_IDS[$session_key]"
                unset "STARTED_SESSIONS[$session_key]"
            fi
            rm -f "$prompt_file" "$claude_raw"
            return $rc
            ;;
        codex)
            local codex_root prompt_file rc sid started codex_raw parsed_sid
            local -a env_cmd
            build_agent_env env_cmd
            codex_root=$(create_codex_context_dir "$session_key")
            prompt_file=$(mktemp)
            codex_raw=$(mktemp)
            printf '%s' "$prompt" > "$prompt_file"
            : > "$outfile"
            : > "$codex_raw"
            sid="${SESSION_IDS[$session_key]:-}"
            started="${STARTED_SESSIONS[$session_key]:-0}"
            rc=0
            if [ "$started" = "1" ] && [ -n "$sid" ]; then
                # `codex exec resume` has no -C/--sandbox flags in the installed
                # CLI, and a real CLI probe showed it otherwise uses the
                # invoking process cwd. Pin the process cwd to the same stable
                # isolated context root used by the first turn, and mirror the
                # fresh turn's sandbox through the config override surface.
                local -a resume_env_cmd=(
                    env -i -C "$codex_root"
                    "${env_cmd[@]:2}"
                )
                _agent_run_stdin "$codex_raw" "$prompt_file" "${resume_env_cmd[@]}" \
                    codex exec resume \
                    -c 'sandbox_mode="read-only"' \
                    --skip-git-repo-check \
                    --ignore-user-config \
                    --ignore-rules \
                    --disable shell_tool \
                    --json \
                    --output-last-message "$outfile" "$sid" - || rc=$?
            else
                _agent_run_stdin "$codex_raw" "$prompt_file" "${env_cmd[@]}" \
                    codex exec -C "$codex_root" \
                    --skip-git-repo-check \
                    --ignore-user-config \
                    --ignore-rules \
                    --disable shell_tool \
                    --sandbox read-only \
                    --json \
                    --output-last-message "$outfile" - || rc=$?
                if [ "$rc" -eq 0 ]; then
                    parsed_sid=$(extract_codex_session_id "$codex_raw")
                    if [ -z "$parsed_sid" ]; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: Unable to parse codex session id for $session_key; continuing without resume state for this turn." >> "$LOGFILE"
                    else
                        SESSION_IDS["$session_key"]="$parsed_sid"
                        STARTED_SESSIONS["$session_key"]=1
                    fi
                fi
            fi
            record_agent_metrics codex "$session_key" "$codex_raw"
            rm -f "$prompt_file" "$codex_raw"
            return "$rc"
            ;;
        *)
            echo "ERROR: run_audit_agent_turn: unknown agent '$agent'" >&2
            return 1
            ;;
    esac
}

# Retry wrapper around run_audit_agent_turn. Fatal errors exit immediately.
run_agent_turn_with_retry() {
    local attempt=0
    local agent="$1"
    local outfile="$4"
    local rc=0
    while [ "$attempt" -lt "$MAX_AGENT_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        rc=0
        run_audit_agent_turn "$@" || rc=$?
        if [ "$rc" -eq 0 ]; then
            save_session_sidecar "$2"
            return 0
        fi
        if [ -n "$outfile" ] && [ -f "$outfile" ] && is_fatal_error "$(cat "$outfile")"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') FATAL: Agent hit non-retryable error." >> "$LOGFILE"
            echo "FATAL: Agent error (see $LOGFILE for details)." >&2
            exit 1
        fi
        if [ "$rc" -ge 2 ] && [ "$attempt" -lt "$MAX_AGENT_ATTEMPTS" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') Transient error (exit $rc). Retrying in ${TRANSIENT_RETRY_DELAY}s ($attempt/$MAX_AGENT_ATTEMPTS)..." >> "$LOGFILE"
            sleep "$TRANSIENT_RETRY_DELAY"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') Agent failed (exit $rc) after $attempt attempt(s)." >> "$LOGFILE"
            return "$rc"
        fi
    done
}

# Run a co-auditor turn whose required deliverable is a single
# FINAL_COMMENT_START/FINAL_COMMENT_END block, retrying ONCE on a missing
# block before giving up.
#
# Root cause this guards (mesh#41): the co-auditor runs a single toolless
# `-p` turn. When the prompt reads like an action ("verify these findings
# against the diff"), the agent sometimes opens with a short "let me verify
# against the repo" preamble and ends the turn without ever drafting — so the
# output has no markers, extract_final_comment fails, and the whole run aborts
# AFTER the expensive rounds 1-2 have already converged on a verdict. The
# prompts now state plainly that there are no tools/repo and this is the only
# turn; this retry is the belt-and-suspenders for residual LLM nondeterminism,
# re-prompting the same seat with a hardened markers-only instruction so one
# stray miss can't discard a converged verdict.
#
# Args: agent session_key prompt outfile (same shape as run_agent_turn_with_retry).
# Returns 0 once $outfile holds a valid block, 1 if still missing after retry.
run_marker_turn_with_retry() {
    local agent="$1"
    local session_key="$2"
    local prompt="$3"
    local outfile="$4"

    # `|| true`: a non-fatal non-zero return must not abort under `set -e`;
    # success is decided by marker presence below, not exit code. Fatal
    # errors still `exit` from inside run_agent_turn_with_retry.
    run_agent_turn_with_retry "$agent" "$session_key" "$prompt" "$outfile" || true
    if [ -s "$outfile" ] && extract_final_comment "$outfile" >/dev/null 2>&1; then
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: $session_key produced no usable FINAL_COMMENT block (missing or malformed markers; toolless deferral?). Re-prompting once, markers-only." >> "$LOGFILE"
    echo "Co-auditor draft missing or malformed FINAL_COMMENT markers — re-prompting once (markers-only)..."

    local reprompt
    printf -v reprompt '%s\n\n----------------------------------------\nRETRY NOTICE: Your previous response did not contain the required FINAL_COMMENT_START / FINAL_COMMENT_END block. You have NO tools and NO access to the repository or file system — do NOT attempt to read files, run commands, or verify against the repo, and do NOT announce further verification. Everything you need is already in this prompt. Respond with ONLY the GitHub review body wrapped in a single FINAL_COMMENT_START / FINAL_COMMENT_END block (each marker on its own line). Output nothing before or after that block.' "$prompt"

    run_agent_turn_with_retry "$agent" "${session_key}_markers_retry" "$reprompt" "$outfile" || true
    if [ -s "$outfile" ] && extract_final_comment "$outfile" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: $session_key markers-only retry succeeded." >> "$LOGFILE"
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $session_key still missing or malformed FINAL_COMMENT markers after markers-only retry." >> "$LOGFILE"
    return 1
}

# Build the state-variant instruction for Round 1.
state_variant_instruction() {
    if [ "$RESUME" = true ]; then
        # shellcheck disable=SC2016 # Literal backticks are part of the prompt text.
        printf 'This is a resumed incremental audit. Only evaluate commits added after the previous audited head `%s` and comments newer than `%s`. Do not re-review unchanged code except where needed to understand the new delta.\n' \
            "$RESUME_FROM_HEAD_SHA" "${RESUME_COMMENT_CUTOFF:-the previous audit}"
        return
    fi

    case "$PR_STATE" in
        fresh)
            echo "This is a first-time audit. Look for production blockers, general code quality issues, and whether existing review comments need addressing."
            ;;
        audited)
            echo "This is a re-audit after recent changes. Same scope as a fresh audit but acknowledge prior review history visible in the CC review comments."
            ;;
        merged)
            echo "This is a post-merge audit. Same scope as a fresh audit but also evaluate whether a follow-up PR is warranted for any issues found."
            ;;
    esac
}

# Build a full audit prompt with PR context and optional prior round output.
build_audit_prompt() {
    local instruction="$1"
    local prior_file="${2:-}"
    local prior_label="${3:-Prior Round Output}"

    printf 'You are performing a read-only audit of PR #%s in %s.\n' "$PR_NUMBER" "$REPO_SLUG"
    printf 'You have NO tools and NO access to the repository, file system, or network. Everything you need is included in this prompt: the PR diff, the CC review comments, and any prior-round findings. Do NOT attempt to read files, run commands, or otherwise inspect the repo, and do NOT announce that you will — base your review only on the diff text provided here.\n'
    printf 'Because you cannot access the repository or its dependencies, do NOT assert version-pinned dependency-source details — specific third-party file paths, line numbers, or exact library/source code not shown in this diff. You have no way to verify them; keep every claim at the behavior/outcome level so it is checkable from the diff alone. An unverifiable claim in the draft is itself a reason to request changes to the draft, not to the PR.\n'
    printf 'Production deploy notes are NOT request-changes blockers unless the PR itself must change before merge.\n\n'
    if [ "$RESUME" = true ]; then
        # shellcheck disable=SC2016 # Literal backticks are part of the prompt text.
        printf 'Resume context: this prompt contains only the new commit diff from `%s` to `%s` plus comments newer than `%s`. Use the resumed model session for prior-review context; do not ask to see the full historical PR diff.\n\n' \
            "$RESUME_FROM_HEAD_SHA" "$AUDITED_HEAD_SHA" "${RESUME_COMMENT_CUTOFF:-the previous audit}"
    fi
    printf '%s\n\n' "$instruction"
    case "${DIFF_MODE:-full-diff}" in
        full-diff)
            printf '## PR Diff\n\n'
            cat "$PR_DIFF_FILE"
            ;;
        partition)
            # Partition mode only reaches build_audit_prompt at the PARENT level
            # (e.g. the Phase 5 recommendation turn); the per-group pipelines run
            # in subshells with DIFF_MODE overridden to full-diff/chunked over the
            # SMALL group diff. At the parent level PR_DIFF_FILE is still the whole
            # oversized diff, so NEVER cat it here — that would re-dump the entire
            # diff partitioning exists to avoid. The file-level manifest is enough
            # to judge the already-drafted review body.
            printf '## PR Diff Package\n\n'
            printf 'The raw PR diff is too large for a single prompt. It was partitioned into subsystem groups, each audited through a full cross-pollination pipeline and merged in a consolidation step. The per-group findings are already reflected in the drafted review under consideration; the file-level manifest is below.\n\n'
            printf '### Diff Manifest\n\n'
            cat "$DIFF_MANIFEST_FILE"
            ;;
        *)  # chunked
            printf '## PR Diff Package\n\n'
            printf 'The raw PR diff is too large for a single prompt. It was reviewed through a chunked map-stage audit. Do not assume unlisted raw diff context beyond the summaries and coverage notes below.\n\n'
            printf '### Diff Manifest\n\n'
            cat "$DIFF_MANIFEST_FILE"
            printf '\n\n### Chunk/File Summaries\n\n'
            cat "$FILE_SUMMARIES_FILE"
            ;;
    esac
    printf '\n\n## CC Review Comments\n\n'
    cat "$CC_COMMENTS_FILE"

    if [ -n "$prior_file" ] && [ -f "$prior_file" ]; then
        printf '\n\n## %s\n\n' "$prior_label"
        cat "$prior_file"
    fi
}

# Check if the final non-empty line of a file is exactly APPROVED.
is_approved() {
    local file="$1"
    local last_line
    last_line=$(sed '/^[[:space:]]*$/d' "$file" | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ "$last_line" = "APPROVED" ]
}

# Decide whether head drift during the audit invalidates the findings.
# Returns 0 (drift touches audited files → block) when the commits between the
# audited and current head modify any file the audit reviewed, OR when the
# relationship can't be confirmed safe (compare API failure, current head not
# strictly ahead of the audited head, or a truncated/empty file list). Returns
# 1 (benign) only when the new commits are provably disjoint from the audited
# file set. Fail-closed: any uncertainty blocks. The posted review is body-only
# (no line-anchored comments), so disjoint drift cannot misplace anything.
# (mesh#44 Part 2)
head_drift_touches_audited_files() {
    local audited="$1"
    local current="$2"
    local compare_json status file_count changed audited_paths intersect

    if [ ! -f "${DIFF_MANIFEST_FILE:-}" ]; then
        return 0
    fi

    if ! compare_json=$(gh api "repos/${REPO_SLUG}/compare/${audited}...${current}" 2>>"$LOGFILE"); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: compare API failed for ${audited}...${current}; treating drift as blocking." >> "$LOGFILE"
        return 0
    fi

    status=$(printf '%s' "$compare_json" | jq -r '.status // "unknown"' 2>>"$LOGFILE")
    if [ "$status" != "ahead" ]; then
        # The heads differ, so 'identical' is impossible; 'behind'/'diverged'
        # means the audited commit is no longer an ancestor — can't reason about
        # which files moved, so block.
        echo "$(date '+%Y-%m-%d %H:%M:%S') Compare status='${status}' (not 'ahead') for ${audited}...${current}; treating drift as blocking." >> "$LOGFILE"
        return 0
    fi

    # GitHub caps the compare file list at 300 entries; a truncated page comes
    # back as a full 300-entry list (NOT empty), so a >=300 count means we may
    # not see every changed file. Fail closed rather than risk a false
    # "disjoint" when an audited file sits beyond the cap (audit follow-up).
    file_count=$(printf '%s' "$compare_json" | jq -r '(.files | length) // 0' 2>>"$LOGFILE")
    if [ "${file_count:-0}" -ge 300 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Compare returned ${file_count} files (>=300 cap; possibly truncated) for ${audited}...${current}; treating drift as blocking." >> "$LOGFILE"
        return 0
    fi

    # GitHub's compare API names files via .filename (not .path); our own diff
    # manifest uses .path. Keep the two field names distinct.
    changed=$(printf '%s' "$compare_json" | jq -r '.files[]?.filename // empty' 2>>"$LOGFILE" | sort -u)
    if [ -z "$changed" ]; then
        # Ahead but no file list at all — fail closed.
        echo "$(date '+%Y-%m-%d %H:%M:%S') Compare returned no file list for ${audited}...${current}; treating drift as blocking." >> "$LOGFILE"
        return 0
    fi

    audited_paths=$(jq -r '.files[]?.path // empty' "$DIFF_MANIFEST_FILE" 2>>"$LOGFILE" | sort -u)
    intersect=$(comm -12 <(printf '%s\n' "$changed") <(printf '%s\n' "$audited_paths"))
    if [ -n "$intersect" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Drift between ${audited} and ${current} intersects audited files:" >> "$LOGFILE"
        printf '%s\n' "$intersect" >> "$LOGFILE"
        return 0
    fi
    return 1
}

# Extract the file paths a map-stage left UNREVIEWED, from one or more
# file_summaries.md files. Two disjoint buckets, both keyed off the per-file
# '- path: `X`' line that opens every block:
#   skipped — block carries '- risk: skipped' (binary/generated/vendor; never
#             sent to an agent — append_skipped_file_summary).
#   manual  — block carries a '- coverage_notes: Truncated at ' note (a single
#             hunk exceeded the chunk cap, partially reviewed —
#             append_truncated_file_summary).
# A file is never both (a skipped file is never truncated). Emits ONE record per
# file, deduped, in first-seen order, as TAB-separated lines:
#   skipped<TAB><path>
#   manual<TAB><path>
# so write_final_report has ONE source for both the counts and the names — this
# replaces the older split that counted skips from the union manifest and
# manual-review from a 'Manual review may be needed' grep that ALSO matched
# skipped blocks (which emit that same phrase), double-counting them.
# Robustness: one record per path (newline-delimited, never pipe-joined) so a
# path containing '|'/spaces/'$' survives intact; both content matches are
# LINE-ANCHORED to the structural marker lines append_*_file_summary writes, so
# embedded (2-space-indented) agent prose that merely mentions 'Truncated at '
# or 'risk: skipped' cannot be misclassified; the closing backtick is stripped
# with a trailing-anchor so a backtick inside a path is preserved. Missing or
# empty inputs yield nothing.
extract_coverage_paths() {
    awk '
        /^- path: `/ {
            cur = $0
            sub(/^- path: `/, "", cur)
            sub(/`$/, "", cur)
            next
        }
        /^- risk: skipped$/ {
            if (cur != "" && !(cur in seen_s)) { seen_s[cur] = 1; print "skipped\t" cur }
            next
        }
        /^- coverage_notes: Truncated at / {
            if (cur != "" && !(cur in seen_m)) { seen_m[cur] = 1; print "manual\t" cur }
            next
        }
    ' "$@" 2>/dev/null || true
}

# Count non-empty lines in a (possibly-empty) newline-separated string.
count_lines() {
    [ -n "$1" ] || { echo 0; return 0; }
    local n
    n=$(printf '%s\n' "$1" | grep -c . || true)
    echo "${n:-0}"
}

# Render a Coverage bucket: "- <label> (<count>):" then an indented bullet per
# path, or "- <label>: 0" when empty. $1 label, $2 newline-separated paths.
render_coverage_bucket() {
    local label="$1" joined="$2" count p
    count=$(count_lines "$joined")
    if [ "$count" -eq 0 ]; then
        printf -- '- %s: 0\n' "$label"
        return 0
    fi
    printf -- '- %s (%s):\n' "$label" "$count"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        # Literal backtick wraps the path in a Markdown code span (not a command
        # substitution).
        # shellcheck disable=SC2016
        printf -- '    - `%s`\n' "$p"
    done <<< "$joined"
}

# Extract the last claude `--output-format json` result envelope. The CLI emits
# compact, single-line JSON today; parsing each line independently also ignores
# non-JSON diagnostics safely. Selecting the last match tolerates preceding
# result-shaped events while preserving the final turn result. $1 raw stream.
extract_claude_result_envelope() {
    local raw="$1"
    [ -f "$raw" ] || return 0
    jq -c -R \
        'fromjson? | select(type=="object" and .type=="result" and has("result"))' \
        "$raw" 2>/dev/null | tail -n1 || true
}

# Lift a claude result envelope's .result text into the plain-text $outfile the
# rest of the pipeline expects. jq -r decodes the text, so FINAL_COMMENT markers
# land literal (their own lines), not JSON-escaped. Falls back to copying the raw
# stream verbatim when it is NOT a result envelope — a mock, an older CLI that
# ignored --output-format, or a non-JSON error — so the marker contract and
# is_fatal_error detection keep working. $1 raw, $2 out.
finalize_claude_json() {
    local raw="$1" outfile="$2" env_line=""
    env_line=$(extract_claude_result_envelope "$raw")
    if [ -n "$env_line" ]; then
        printf '%s' "$env_line" | jq -r '.result // ""' > "$outfile"
    else
        cp "$raw" "$outfile" 2>/dev/null || : > "$outfile"
    fi
}

# Append one normalized metrics object for an agent turn to $METRICS_FILE.
# $1 agent, $2 turn label (session_key), $3 raw agent output stream:
#   claude — the `--output-format json` result envelope (one JSON line on stdout).
#   codex  — the `--json` JSONL stream; the last `turn.completed` carries usage.
# Best-effort: if no usage parses (mock, plain-text/old CLI, error), records
# nothing. One short-line append, and partition groups each have their OWN
# group-local $METRICS_FILE, so there is no cross-group append race.
record_agent_metrics() {
    local agent="$1" turn="$2" raw="$3" line="" src=""
    [ -n "${METRICS_FILE:-}" ] || return 0
    [ -f "$raw" ] || return 0
    case "$agent" in
        claude)
            src=$(extract_claude_result_envelope "$raw")
            [ -n "$src" ] || return 0
            line=$(printf '%s' "$src" | jq -c --arg agent claude --arg turn "$turn" '
                {agent: $agent, turn: $turn,
                 input_tokens: (.usage.input_tokens // 0),
                 output_tokens: (.usage.output_tokens // 0),
                 cache_read_tokens: (.usage.cache_read_input_tokens // 0),
                 cache_creation_tokens: (.usage.cache_creation_input_tokens // 0),
                 cost_usd: (.total_cost_usd // null)}' 2>/dev/null || true)
            ;;
        codex)
            src=$(grep '"type":"turn.completed"' "$raw" 2>/dev/null | tail -n1 || true)
            [ -n "$src" ] || return 0
            line=$(printf '%s' "$src" | jq -c --arg agent codex --arg turn "$turn" '
                {agent: $agent, turn: $turn,
                 input_tokens: (.usage.input_tokens // 0),
                 output_tokens: ((.usage.output_tokens // 0) + (.usage.reasoning_output_tokens // 0)),
                 cache_read_tokens: (.usage.cached_input_tokens // 0),
                 cache_creation_tokens: 0,
                 cost_usd: null}' 2>/dev/null || true)
            ;;
    esac
    [ -n "$line" ] && printf '%s\n' "$line" >> "$METRICS_FILE"
    return 0
}

# Aggregate per-turn metrics (parent $METRICS_FILE + every group's group-local
# file) into a Markdown table: per-agent and total tokens + cost. No-op-safe:
# prints a note when nothing machine-readable was captured (older CLI / all turns
# mocked). codex `--json` reports tokens but no cost, so its cost shows 0.
aggregate_metrics() {
    local -a files=()
    [ -s "${METRICS_FILE:-/dev/null}" ] && files+=("$METRICS_FILE")
    local gm
    for gm in "$GROUPS_DIR"/*/metrics.jsonl; do
        [ -s "$gm" ] && files+=("$gm")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        printf 'No per-turn token metrics were captured (the agent CLIs did not emit machine-readable usage for this run).\n'
        return 0
    fi
    jq -rs '
        map(select(type == "object")) as $all
        | ($all | group_by(.agent) | map({
              agent: .[0].agent,
              turns: length,
              input: (map(.input_tokens // 0) | add),
              output: (map(.output_tokens // 0) | add),
              cache_read: (map(.cache_read_tokens // 0) | add),
              cache_creation: (map(.cache_creation_tokens // 0) | add),
              cost: (map(.cost_usd // 0) | add)
          })) as $rows
        | ($all | {
              turns: length,
              input: (map(.input_tokens // 0) | add),
              output: (map(.output_tokens // 0) | add),
              cache_read: (map(.cache_read_tokens // 0) | add),
              cache_creation: (map(.cache_creation_tokens // 0) | add),
              cost: (map(.cost_usd // 0) | add)
          }) as $t
        | "| Agent | Turns | Input | Output | Cache read | Cache write | Cost (USD) |",
          "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
          ($rows[] | "| \(.agent) | \(.turns) | \(.input) | \(.output) | \(.cache_read) | \(.cache_creation) | \((.cost * 10000 | round) / 10000) |"),
          "| **total** | \($t.turns) | \($t.input) | \($t.output) | \($t.cache_read) | \($t.cache_creation) | \(($t.cost * 10000 | round) / 10000) |"
    ' "${files[@]}" 2>/dev/null || printf 'Metrics were captured but could not be aggregated.\n'
}

write_final_report() {
    # mesh#53: when the verdict is a non-converged advisory (posted as a comment,
    # not a blocking review), annotate the header so the top-line `request-changes`
    # is not mistaken for a blocking verdict. Converged verdicts get no suffix.
    local _rec_suffix=""
    if [ "${NONCONVERGENCE:-0}" -eq 1 ]; then
        _rec_suffix=" (non-blocking — advisory; posted as a comment, not a blocking review)"
    fi
    {
        printf '# PR #%s Audit Report\n\n' "$PR_NUMBER"
        printf -- "- Repository: \`%s\`\n" "$REPO_SLUG"
        printf -- "- Recommendation: \`%s\`%s\n" "$RECOMMENDATION" "$_rec_suffix"
        printf -- "- Audited head: \`%s\`\n" "$AUDITED_HEAD_SHA"
        if [ "$RESUME" = true ]; then
            printf -- "- Previous audited head: \`%s\`\n" "$RESUME_FROM_HEAD_SHA"
            printf -- "- Comment cutoff: \`%s\`\n" "${RESUME_COMMENT_CUTOFF:-none}"
        fi
        printf -- "- Diff mode: \`%s\`\n\n" "$DIFF_MODE"
        printf '## Review Body\n\n'
        cat "$FINAL_COMMENT_FILE"
        if [ "${NONCONVERGENCE:-0}" -eq 1 ]; then
            printf '\n\n> ⚠️ The two auditors did not fully converge on this draft after the edit round — the primary still had outstanding concerns. This is posted as a NON-BLOCKING comment that leans request-changes (not a blocking review): the auditors did not ratify a common verdict, so the final approve / request-changes call is left to a human. Treat the body as the best consolidated draft rather than a fully ratified one.\n'
            # Surface WHY this is request-changes: the primary's concerns live in
            # round4b_primary.md but the posted body is the co's draft. Without
            # this, the verdict is not actionable and can read inconsistently with
            # an approving-sounding draft. Verbatim, with a toolless caveat so an
            # unverifiable claim is weighed rather than taken as a hard blocker.
            if [ -s "$WORKSPACE_DIR/round4b_primary.md" ]; then
                printf '\n### Primary auditor remaining concerns\n\n'
                printf 'Verbatim from the final verification turn — the reason this is request-changes. The auditors run toolless, so weigh any claim that cannot be confirmed from the diff accordingly.\n\n'
                cat "$WORKSPACE_DIR/round4b_primary.md"
                printf '\n'
            fi
        fi
        printf '\n\n## Coverage\n\n'
        if [ "$DIFF_MODE" = "partition" ]; then
            # Coverage reflects what each group ACTUALLY did, not the union
            # manifest's binary/generated flags: a full-diff group skips NOTHING
            # (its whole group.patch, including any binary/generated slices, goes
            # to the pipeline); only chunked groups skip files. One source —
            # extract_coverage_paths over every group summary — gives both the
            # counts and the file NAMES (skipped from '- risk: skipped', manual
            # from 'Truncated at '). reviewed = total - skipped.
            local total_files part_cov part_skipped_paths part_manual_paths part_reviewed
            total_files=$(jq '.files | length' "$DIFF_MANIFEST_FILE" 2>/dev/null || echo 0)
            part_cov=$(extract_coverage_paths "$GROUPS_DIR"/*/file_summaries.md)
            part_skipped_paths=$(printf '%s\n' "$part_cov" | awk -F'\t' '$1 == "skipped" { print $2 }')
            part_manual_paths=$(printf '%s\n' "$part_cov" | awk -F'\t' '$1 == "manual" { print $2 }')
            part_reviewed=$(( total_files - $(count_lines "$part_skipped_paths") ))
            [ "$part_reviewed" -ge 0 ] || part_reviewed=0
            printf -- '- Partitioned into %s subsystem group(s); each audited through the full cross-pollination pipeline, then merged in a consolidation step.\n' "${GROUP_COUNT:-0}"
            if [ -f "$GROUPS_DIR/partition.json" ]; then
                printf -- '- Groups:\n'
                jq -r '.[] | "    - \(.name) [\(.mode)]: \(.files) file(s), \(.bytes) bytes"' "$GROUPS_DIR/partition.json"
            fi
            printf -- '- Reviewed files: %s\n' "$part_reviewed"
            render_coverage_bucket "Skipped binary/generated/vendor files" "$part_skipped_paths"
            render_coverage_bucket "Files needing manual review" "$part_manual_paths"
            printf '\nPartition mode was used because the raw diff exceeded configured prompt thresholds. Cross-group interface consistency was checked in the consolidation step; any file marked manual-review above may still warrant a closer look.\n'
        elif [ "$DIFF_MODE" = "chunked" ]; then
            # Single-source extraction, same as partition. Fixes the older
            # double-count: a skipped block ALSO prints 'Manual review may be
            # needed', so the previous 'Manual review may be needed' grep tallied
            # skipped files as manual-review too. Names now reported, not just
            # counts. reviewed = total - skipped.
            local total_files ck_cov ck_skipped_paths ck_manual_paths ck_reviewed
            total_files=$(jq '.files | length' "$DIFF_MANIFEST_FILE" 2>/dev/null || echo 0)
            ck_cov=$(extract_coverage_paths "$FILE_SUMMARIES_FILE")
            ck_skipped_paths=$(printf '%s\n' "$ck_cov" | awk -F'\t' '$1 == "skipped" { print $2 }')
            ck_manual_paths=$(printf '%s\n' "$ck_cov" | awk -F'\t' '$1 == "manual" { print $2 }')
            ck_reviewed=$(( total_files - $(count_lines "$ck_skipped_paths") ))
            [ "$ck_reviewed" -ge 0 ] || ck_reviewed=0
            printf -- '- Reviewed chunks/files: %s\n' "$ck_reviewed"
            render_coverage_bucket "Skipped binary/generated/vendor files" "$ck_skipped_paths"
            render_coverage_bucket "Files needing manual review" "$ck_manual_paths"
            printf '\nChunked audit was used because the raw diff exceeded configured prompt thresholds. Files marked as skipped or partial may need manual review.\n'
        else
            printf 'Full PR diff was included directly in the audit prompts.\n'
        fi
        printf '\n\n## Metrics\n\n'
        aggregate_metrics
    } > "$FINAL_REPORT_FILE"
}

# Post the final report as a NON-BLOCKING PR comment (no approve/request-changes
# review state). Used for (a) non-converged verdicts (mesh#53), which are deferred
# to a human rather than auto-blocking, and (b) the self-PR fallback when GitHub
# refuses a review action on your own PR. Returns nonzero on failure; the caller
# decides whether that is fatal.
post_report_comment() {
    local _errf
    _errf=$(mktemp)
    if ! gh pr comment "$PR_NUMBER" -R "$REPO_SLUG" --body-file "$FINAL_REPORT_FILE" 2>"$_errf"; then
        cat "$_errf" >> "$LOGFILE"
        echo "ERROR: gh pr comment failed. GitHub error:" >&2
        sed 's/^/  /' "$_errf" >&2
        echo "Artifacts preserved:" >&2
        echo "  $FINAL_REPORT_FILE" >&2
        echo "  $FINAL_COMMENT_FILE" >&2
        echo "  $RECOMMENDATION_FILE" >&2
        rm -f "$_errf"
        return 1
    fi
    rm -f "$_errf"
    return 0
}

mark_audit_state_complete() {
    local completed_at comment_cutoff

    completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    comment_cutoff="${FETCHED_MAX_COMMENT_TS:-}"
    if [ -z "$comment_cutoff" ]; then
        comment_cutoff="$RUN_STARTED_AT"
    fi
    LAST_REVIEW_HEAD_SHA="$AUDITED_HEAD_SHA"
    LAST_REVIEW_COMMENT_TS="$comment_cutoff"
    LAST_REVIEW_COMPLETED_AT="$completed_at"
    save_audit_state "$LAST_REVIEW_HEAD_SHA" "$LAST_REVIEW_COMMENT_TS" "$LAST_REVIEW_COMPLETED_AT"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Saved audit state: repo=${REPO_SLUG} pr=${PR_NUMBER} head=${LAST_REVIEW_HEAD_SHA} comment_cutoff=${LAST_REVIEW_COMMENT_TS}" >> "$LOGFILE"
}

# ── Arg parsing ──

_require_value() {
    if [ -z "$2" ]; then
        echo "ERROR: $1 requires a value" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p)              _require_value "$1" "${2:-}"; PR_ARG="$2"; shift 2 ;;
        -d)              _require_value "$1" "${2:-}"; PROJECT_DIR="$2"; shift 2 ;;
        -w)              _require_value "$1" "${2:-}"; WORKSPACE_OPT="$2"; shift 2 ;;
        -i)              _require_value "$1" "${2:-}"; PRIMARY_AGENT="$2"; shift 2 ;;
        -r)              _require_value "$1" "${2:-}"; CO_AGENT="$2"; shift 2 ;;
        -s)              _require_value "$1" "${2:-}"; PR_STATE="$2"; shift 2 ;;
        -R)              RESUME=true; shift ;;
        --comments-file) _require_value "$1" "${2:-}"; COMMENTS_FILE_OPT="$2"; shift 2 ;;
        --group-config)  _require_value "$1" "${2:-}"; GROUP_CONFIG_OPT="$2"; shift 2 ;;
        --post)          POST=true; shift ;;
        --no-post)       POST=false; shift ;;
        -h|--help)       usage ;;
        *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Validation ──

# PR argument: omitted, bare number, or full GitHub PR URL.
if [ -z "$PR_ARG" ]; then
    PR_INPUT=""
elif [[ "$PR_ARG" =~ ^[0-9]+$ ]]; then
    PR_INPUT="$PR_ARG"
elif [[ "$PR_ARG" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?([?#].*)?$ ]]; then
    PR_INPUT="https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/pull/${BASH_REMATCH[3]}"
else
    echo "ERROR: -p must be omitted, a bare PR number, or a full GitHub PR URL (got: $PR_ARG)" >&2
    exit 1
fi

# Agent validation: only claude|codex for this script
for _agent_flag in "-i:$PRIMARY_AGENT" "-r:$CO_AGENT"; do
    _flag="${_agent_flag%%:*}"
    _name="${_agent_flag#*:}"
    case "$_name" in
        claude|codex) ;;
        *) echo "ERROR: $_flag must be claude|codex (got: $_name)" >&2; exit 1 ;;
    esac
done
unset _agent_flag _flag _name

# State variant validation
case "$PR_STATE" in
    fresh|audited|merged) ;;
    *) echo "ERROR: -s must be fresh|audited|merged (got: $PR_STATE)" >&2; exit 1 ;;
esac

# ── Resolve paths ──

# Resolve --comments-file to absolute BEFORE cd'ing to project dir
if [ -n "$COMMENTS_FILE_OPT" ]; then
    if [[ "$COMMENTS_FILE_OPT" != /* ]]; then
        COMMENTS_FILE_OPT="$INVOCATION_DIR/$COMMENTS_FILE_OPT"
    fi
    if [ ! -f "$COMMENTS_FILE_OPT" ]; then
        echo "ERROR: --comments-file does not exist: $COMMENTS_FILE_OPT" >&2
        exit 1
    fi
fi

# Resolve --group-config to absolute BEFORE cd'ing to project dir, same as
# --comments-file. GROUP_CONFIG_FILE is read by slice_group_key during
# partitioning.
if [ -n "$GROUP_CONFIG_OPT" ]; then
    if [[ "$GROUP_CONFIG_OPT" != /* ]]; then
        GROUP_CONFIG_OPT="$INVOCATION_DIR/$GROUP_CONFIG_OPT"
    fi
    if [ ! -f "$GROUP_CONFIG_OPT" ]; then
        echo "ERROR: --group-config does not exist: $GROUP_CONFIG_OPT" >&2
        exit 1
    fi
    GROUP_CONFIG_FILE="$GROUP_CONFIG_OPT"
fi

if [ -z "$PROJECT_DIR" ]; then
    PROJECT_DIR="$PWD"
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# gh and jq are needed before the workspace path can be finalized because
# the default workspace is keyed by the resolved PR number.
for _cmd in gh jq iconv; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $_cmd" >&2
        exit 1
    fi
done
unset _cmd

_pr_metadata_tmp=$(mktemp)
trap '[ -n "${_pr_metadata_tmp:-}" ] && rm -f "$_pr_metadata_tmp"' EXIT
# The workspace logfile is not known until the PR number is resolved.
if ! LOGFILE=/dev/null gh_pr_view_metadata "$PR_INPUT" "$_pr_metadata_tmp"; then
    if [ -z "$PR_INPUT" ]; then
        echo "ERROR: could not resolve an open PR from the current branch in $PROJECT_DIR." >&2
        echo "       Pass -p <pr_url_or_number> explicitly." >&2
    else
        echo "ERROR: gh pr view failed for '$PR_INPUT' — is the PR valid?" >&2
    fi
    rm -f "$_pr_metadata_tmp"
    exit 1
fi

PR_NUMBER=$(jq -r '.number' < "$_pr_metadata_tmp")
if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
    echo "ERROR: Could not extract PR number from metadata" >&2
    rm -f "$_pr_metadata_tmp"
    exit 1
fi
REPO_SLUG=$(derive_repo_slug_from_metadata "$_pr_metadata_tmp")
if [ -z "$REPO_SLUG" ]; then
    echo "ERROR: Could not derive repository slug from PR metadata" >&2
    rm -f "$_pr_metadata_tmp"
    exit 1
fi

AUDITED_HEAD_SHA=$(jq -r '.headRefOid' < "$_pr_metadata_tmp")
if [ -z "$AUDITED_HEAD_SHA" ] || [ "$AUDITED_HEAD_SHA" = "null" ]; then
    echo "ERROR: Could not extract head SHA from PR metadata" >&2
    rm -f "$_pr_metadata_tmp"
    exit 1
fi

if [ -n "$WORKSPACE_OPT" ]; then
    if [[ "$WORKSPACE_OPT" != /* ]]; then
        WORKSPACE_OPT="$INVOCATION_DIR/$WORKSPACE_OPT"
    fi
    WORKSPACE_DIR="$WORKSPACE_OPT"
else
    WORKSPACE_DIR="$PROJECT_DIR/agent_workers/audit_pr_review/pr_${PR_NUMBER}"
fi

mkdir -p "$WORKSPACE_DIR"
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"

# ── Workspace files ──

LOGFILE="$WORKSPACE_DIR/run.log"
FEEDBACK_FILE="$WORKSPACE_DIR/feedback.md"
PR_DIFF_FILE="$WORKSPACE_DIR/pr_diff.patch"
CC_COMMENTS_FILE="$WORKSPACE_DIR/cc_comments.md"
PR_METADATA_FILE="$WORKSPACE_DIR/pr_metadata.json"
FINAL_COMMENT_FILE="$WORKSPACE_DIR/final_comment.md"
FINAL_REPORT_FILE="$WORKSPACE_DIR/final_report.md"
RECOMMENDATION_FILE="$WORKSPACE_DIR/recommendation.md"
ROUND4B_CONTEXT_FILE="$WORKSPACE_DIR/round4b_context.md"
DIFF_MANIFEST_FILE="$WORKSPACE_DIR/diff_manifest.json"
DIFF_SLICES_DIR="$WORKSPACE_DIR/diff_slices"
FILE_SUMMARIES_FILE="$WORKSPACE_DIR/file_summaries.md"
STATE_FILE="$WORKSPACE_DIR/.state"
SESSION_STATE_DIR="$WORKSPACE_DIR/session_state"
CODEX_CONTEXT_DIR="$WORKSPACE_DIR/codex_context"
CLAUDE_CONTEXT_DIR="$WORKSPACE_DIR/claude_context"
CLAUDE_CONFIG_STATE_DIR="$WORKSPACE_DIR/claude_config"
GROUPS_DIR="$WORKSPACE_DIR/groups"
# One normalized JSON object per agent turn (mesh metrics). Truncated up front so
# a reused -w workspace never double-counts a prior run. In partition mode each
# group subshell overrides this to a group-local file (run_one_group), so the
# parent file holds only the consolidation / chunked / full-diff turns; the report
# aggregates the parent plus every group file.
METRICS_FILE="$WORKSPACE_DIR/metrics.jsonl"
: > "$METRICS_FILE"

# Partition-mode group pipeline PIDs, tracked so the EXIT trap can reap the
# backgrounded group subshells (and their agent children) if we are killed.
_group_pids=()

# ── Cleanup trap ──

# Recursively kill a process and all its descendants. Partition groups nest one
# level deeper than single-diff Round 1 (group subshell -> round subshell ->
# agent CLI), so a single `pkill -P` level would leave the agent grandchildren
# running on SIGINT. Best-effort. Invoked only from the trap-driven cleanup, so
# the linter cannot see the call site (hence the SC2317/SC2329 suppressions).
# shellcheck disable=SC2317,SC2329
_kill_proc_tree() {
    local _p="$1" _c
    for _c in $(pgrep -P "$_p" 2>/dev/null); do
        _kill_proc_tree "$_c"
    done
    kill "$_p" 2>/dev/null || true
}

# shellcheck disable=SC2317
cleanup() {
    local pid
    for pid in "${_primary_pid:-}" "${_co_pid:-}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            pkill -P "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    # Group subshells nest deeper, so kill the whole tree, not just one level.
    for pid in "${_group_pids[@]:-}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            _kill_proc_tree "$pid"
            wait "$pid" 2>/dev/null || true
        fi
    done
    [ -n "${_pr_metadata_tmp:-}" ] && rm -f "$_pr_metadata_tmp"
    [ -n "${LOGFILE:-}" ] && [ "$LOGFILE" != "/dev/null" ] && \
        echo "$(date '+%Y-%m-%d %H:%M:%S') audit_pr_review terminated." >> "$LOGFILE"
}
trap cleanup EXIT

# ── Prereq checks ──

for _cmd in uuidgen stdbuf; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $_cmd" >&2
        exit 1
    fi
done
unset _cmd

_check_agent_cli() {
    local agent="$1" flag="$2"
    case "$agent" in
        claude)
            if ! command -v claude >/dev/null 2>&1; then
                echo "ERROR: $flag=$agent but 'claude' CLI not found" >&2
                exit 1
            fi
            ;;
        codex)
            if ! command -v codex >/dev/null 2>&1; then
                echo "ERROR: $flag=$agent but 'codex' CLI not found" >&2
                exit 1
            fi
            ;;
    esac
}
_check_agent_cli "$PRIMARY_AGENT" "-i"
_check_agent_cli "$CO_AGENT" "-r"

# ── Phase 0: Setup ──

echo "$(date '+%Y-%m-%d %H:%M:%S') audit_pr_review.sh starting: PR=$PR_INPUT primary=$PRIMARY_AGENT co=$CO_AGENT state=$PR_STATE" >> "$LOGFILE"

agent_sessions_init
if [ "$RESUME" = true ]; then
    load_audit_state
fi

# Truncate stale artifacts from previous runs (BEFORE fetching fresh data)
find "$WORKSPACE_DIR" -maxdepth 1 -type f -name 'round*.md' -exec rm -f -- {} +
find "$WORKSPACE_DIR" -maxdepth 1 -type f -name 'chunk_*.md' -exec rm -f -- {} +
rm -f -- \
    "$FINAL_COMMENT_FILE" \
    "$FINAL_REPORT_FILE" \
    "$RECOMMENDATION_FILE" \
    "$PR_DIFF_FILE" \
    "${PR_DIFF_FILE}.tmp" \
    "$DIFF_MANIFEST_FILE" \
    "$FILE_SUMMARIES_FILE" \
    "$CC_COMMENTS_FILE" \
    "$PR_METADATA_FILE" \
    "$ROUND4B_CONTEXT_FILE" \
    "$LOGFILE"
rm -rf -- "$DIFF_SLICES_DIR" "$GROUPS_DIR"
if [ "$RESUME" = false ]; then
    rm -rf -- "$SESSION_STATE_DIR" "$CODEX_CONTEXT_DIR" \
        "$CLAUDE_CONTEXT_DIR" "$CLAUDE_CONFIG_STATE_DIR"
fi

# Re-initialize log after truncation
echo "$(date '+%Y-%m-%d %H:%M:%S') audit_pr_review.sh starting (post-cleanup): PR=$PR_INPUT" >> "$LOGFILE"

# Initialize feedback file if missing
[ -f "$FEEDBACK_FILE" ] || : > "$FEEDBACK_FILE"

mv "$_pr_metadata_tmp" "$PR_METADATA_FILE"
_pr_metadata_tmp=""

echo "$(date '+%Y-%m-%d %H:%M:%S') PR #$PR_NUMBER in $REPO_SLUG (head=$AUDITED_HEAD_SHA)" >> "$LOGFILE"

# Fetch PR diff — run from PROJECT_DIR for consistency with pr view.
# Resume mode reviews only commits added since the last completed audit.
if [ "$RESUME" = true ]; then
    fetch_resume_delta_diff
elif ! gh_pr_diff_to_file "$PR_INPUT" "$PR_DIFF_FILE"; then
    # Fallback: gh pr diff returns HTTP 406 on diffs > 20000 lines.
    # Try git diff against a local clone of the target repo.
    _base_ref=$(jq -r '.baseRefName' < "$PR_METADATA_FILE")
    _head_ref=$(jq -r '.headRefName' < "$PR_METADATA_FILE")
    _repo_name="${REPO_SLUG##*/}"
    _local_clone="${AUDIT_PR_LOCAL_CLONE_DIR:-${HOME:-$PROJECT_DIR}/projects/${_repo_name}}"
    if [ -d "${_local_clone}/.git" ] \
        && (cd "${_local_clone}" \
            && git fetch origin \
                "+refs/heads/${_base_ref}:refs/remotes/origin/${_base_ref}" \
                "+refs/heads/${_head_ref}:refs/remotes/origin/${_head_ref}" \
                --quiet 2>>"$LOGFILE" \
            && git diff "origin/${_base_ref}...${AUDITED_HEAD_SHA}" > "${PR_DIFF_FILE}.tmp" 2>>"$LOGFILE" \
            && mv "${PR_DIFF_FILE}.tmp" "$PR_DIFF_FILE"); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') gh pr diff failed; used local git diff fallback from ${_local_clone}" >> "$LOGFILE"
    else
        rm -f "${PR_DIFF_FILE}.tmp"
        echo "ERROR: gh pr diff failed for '$PR_INPUT' (and local git diff fallback at ${_local_clone} unavailable)" >&2
        exit 1
    fi
fi

build_diff_package

# Fetch or copy CC review comments
if [ -n "$COMMENTS_FILE_OPT" ]; then
    cp "$COMMENTS_FILE_OPT" "$CC_COMMENTS_FILE"
else
    fetch_cc_comments
fi

# Record pre-run repo status for dirty-check
_ws_rel=$(realpath --relative-to="$PROJECT_DIR" "$WORKSPACE_DIR" 2>/dev/null || echo "agent_workers/audit_pr_review")
PRE_RUN_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | \
    grep -v -- "^.. ${_ws_rel}" || true)
unset _ws_rel

_map_rc=0
run_large_diff_map_stage || _map_rc=$?
if [ "$_map_rc" -eq 2 ]; then
    exit 0
elif [ "$_map_rc" -ne 0 ]; then
    exit "$_map_rc"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 0 complete. Workspace: $WORKSPACE_DIR" >> "$LOGFILE"

echo "Phase 0 setup complete. PR #$PR_NUMBER ($REPO_SLUG), workspace: $WORKSPACE_DIR"
echo "Primary: $PRIMARY_AGENT, Co: $CO_AGENT, State: $PR_STATE, Post: $POST, Diff: $DIFF_MODE"

# ── Phases 1-4: Cross-pollination pipeline ──
#
# Runs the parallel independent audit (Round 1) plus the cross-pollination,
# verification, and edit rounds (Phases 2-4/4b) over the diff package currently
# selected by the diff-source globals (DIFF_MODE / PR_DIFF_FILE /
# DIFF_MANIFEST_FILE / FILE_SUMMARIES_FILE) and CC_COMMENTS_FILE, writing
# round*.md into <ws>. Extracted into a function so partition mode can run it
# once per subsystem group (each over its own group diff + workspace, in
# parallel) before a consolidation step; the single full-diff path calls it once
# with the global workspace.
#
# On a produced draft it sets the globals FINAL_DRAFT_FILE + NONCONVERGENCE and
# also records them in <ws>/.pipeline_result, so a caller that runs this in a
# subshell (partition mode) can read the result back across the subshell
# boundary. The dirty-repo guard and feedback stop still key off the global
# WORKSPACE_DIR / FEEDBACK_FILE (shared across groups), unchanged.
#
# Args:  <ws> [session_prefix]
#   ws              workspace dir for this pipeline's round files
#   session_prefix  optional prefix on agent session keys so parallel group
#                   pipelines stay distinct in the log; default "" = unchanged.
# Returns: 0 produced a draft; 2 stopped by feedback.md; 1 hard error.
run_cross_pollination_pipeline() {
    local ws="$1"
    local prefix="${2:-}"
    local _r4b_ctx="$ws/round4b_context.md"

    # ── Phase 1: Parallel Starting Audit ──
    echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 1: Parallel starting audit (${prefix:-main})" >> "$LOGFILE"
    echo "Phase 1: Parallel starting audit..."

    local _round1_instruction _round1_prompt
    _round1_instruction=$(state_variant_instruction)
    _round1_prompt=$(build_audit_prompt "$_round1_instruction")

    # _primary_pid/_co_pid stay global so the EXIT cleanup trap can reach the
    # Round-1 children if the script is killed mid-wait.
    (
        run_agent_turn_with_retry "$PRIMARY_AGENT" "${prefix}round1_primary_${PRIMARY_AGENT}" \
            "$_round1_prompt" "$ws/round1_primary.md"
    ) &
    _primary_pid=$!

    (
        run_agent_turn_with_retry "$CO_AGENT" "${prefix}round1_co_${CO_AGENT}" \
            "$_round1_prompt" "$ws/round1_co.md"
    ) &
    _co_pid=$!

    local _r1_primary_rc=0 _r1_co_rc=0
    wait "$_primary_pid" || _r1_primary_rc=$?
    wait "$_co_pid" || _r1_co_rc=$?
    unset _primary_pid _co_pid

    if [ "$_r1_primary_rc" -ne 0 ]; then
        echo "ERROR: Primary agent failed in Round 1 (exit $_r1_primary_rc)" >&2
        return 1
    fi
    if [ "$_r1_co_rc" -ne 0 ]; then
        echo "ERROR: Co-agent failed in Round 1 (exit $_r1_co_rc)" >&2
        return 1
    fi

    local _f
    for _f in "$ws/round1_primary.md" "$ws/round1_co.md"; do
        if [ ! -s "$_f" ]; then
            echo "ERROR: Missing Round 1 output: $_f" >&2
            return 1
        fi
    done

    assert_repo_unchanged_outside_workspace
    if check_feedback; then
        echo "Stopped by feedback after Round 1."
        return 2
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 1 complete" >> "$LOGFILE"

    # ── Phase 2: Cross-pollination Round 1 ──
    echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 2: Cross-pollination round 1" >> "$LOGFILE"
    echo "Phase 2: Cross-pollination round 1..."

    local _round2_prompt
    _round2_prompt=$(build_audit_prompt \
        "Here are the co-auditor's independent findings from a parallel audit. Does this add anything to what you find in the diff? Can you verify their claims? Is anything here — or that you find independently — worth calling out in a review comment?" \
        "$ws/round1_co.md" "Co-auditor Findings (Round 1)")

    run_agent_turn_with_retry "$PRIMARY_AGENT" "${prefix}round2_primary_${PRIMARY_AGENT}" \
        "$_round2_prompt" "$ws/round2_primary.md"

    if [ ! -s "$ws/round2_primary.md" ]; then
        echo "ERROR: Missing Round 2 output: round2_primary.md" >&2
        return 1
    fi

    assert_repo_unchanged_outside_workspace
    if check_feedback; then
        echo "Stopped by feedback after Round 2."
        return 2
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 2 complete" >> "$LOGFILE"

    # ── Phase 3: Cross-pollination Round 2 ──
    echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 3: Cross-pollination round 2" >> "$LOGFILE"
    echo "Phase 3: Cross-pollination round 2..."

    local _round3_instruction _round3_prompt
    _round3_instruction="Here are the primary auditor's consolidated findings after cross-pollination. Cross-check these findings against the PR diff included in this prompt (you cannot access the repository — rely only on the diff text provided here), then draft a concise, human-sounding GitHub review body incorporating the final consolidated findings.

Make it clear what is a production deploy note (something that we can cover, as we are in charge of production deploys) vs. what needs to be changed before this is merged or added to this PR.

This is your only turn — do not defer work or announce further verification; produce the review now. Your response MUST contain exactly one FINAL_COMMENT_START / FINAL_COMMENT_END block. Wrap the EXACT draft text to publish between FINAL_COMMENT_START and FINAL_COMMENT_END markers, each on its own line. Text outside those markers is process commentary only."

    _round3_prompt=$(build_audit_prompt "$_round3_instruction" \
        "$ws/round2_primary.md" "Primary Auditor Findings (Round 2)")

    if ! run_marker_turn_with_retry "$CO_AGENT" "${prefix}round3_co_${CO_AGENT}" \
            "$_round3_prompt" "$ws/round3_co.md"; then
        echo "ERROR: Round 3 co-auditor ($CO_AGENT) did not produce a FINAL_COMMENT_START/FINAL_COMMENT_END block, even after a markers-only retry." >&2
        echo "       The audit's rounds 1-2 completed; the converged findings are preserved at:" >&2
        echo "         $ws/round1_primary.md" >&2
        echo "         $ws/round1_co.md" >&2
        echo "         $ws/round2_primary.md" >&2
        echo "       Only the final-comment draft step failed — re-run the audit to retry it." >&2
        return 1
    fi

    assert_repo_unchanged_outside_workspace
    if check_feedback; then
        echo "Stopped by feedback after Round 3."
        return 2
    fi

    FINAL_DRAFT_FILE="$ws/round3_co.md"
    # Set to 1 if Phase 4b ends without convergence (mesh#34): the audit still
    # finalizes as request-changes rather than aborting. Stays 0 on the Phase 4
    # early-approve path and on a converged Phase 4b.
    NONCONVERGENCE=0
    echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 3 complete" >> "$LOGFILE"

    # ── Phase 4: Verification Round ──
    echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 4: Verification round" >> "$LOGFILE"
    echo "Phase 4: Verification round..."

    local _round4_prompt
    _round4_prompt=$(build_audit_prompt \
        "Here is the drafted GitHub review comment. Is this good as the final GitHub review body? Is it missing anything? Is it 100% accurate? Please verify against the diff.

If the comment is perfect and ready to ship as-is, end your response with exactly APPROVED on its own line. Otherwise, describe what needs to change." \
        "$ws/round3_co.md" "Drafted Review Comment (Round 3)")

    run_agent_turn_with_retry "$PRIMARY_AGENT" "${prefix}round4_primary_${PRIMARY_AGENT}" \
        "$_round4_prompt" "$ws/round4_primary.md"

    if [ ! -s "$ws/round4_primary.md" ]; then
        echo "ERROR: Missing Round 4 output: round4_primary.md" >&2
        return 1
    fi

    assert_repo_unchanged_outside_workspace
    if check_feedback; then
        echo "Stopped by feedback after Round 4."
        return 2
    fi

    if is_approved "$ws/round4_primary.md"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 4: APPROVED — skipping Phase 4b" >> "$LOGFILE"
        echo "Phase 4: APPROVED — skipping Phase 4b."
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 4: Not approved — running Phase 4b" >> "$LOGFILE"
        echo "Phase 4: Not approved — running Phase 4b..."

        # ── Phase 4b: Edit Round ──
        if ! {
            echo "## Original Draft"
            echo ""
            cat "$ws/round3_co.md"
            echo ""
            echo "## Primary Auditor Edit Suggestions"
            echo ""
            cat "$ws/round4_primary.md"
        } > "$_r4b_ctx"; then
            echo "ERROR: Failed to prepare Round 4b edit context" >&2
            return 1
        fi

        local _round4b_co_prompt _round4b_primary_prompt
        _round4b_co_prompt=$(build_audit_prompt \
            "The primary auditor has requested changes to the drafted review comment.

This is your only turn — do not defer work or announce further verification; produce the revised comment now (you cannot access the repository — rely only on the diff and context in this prompt). Send the full revised comment with these changes applied. Your response MUST contain exactly one FINAL_COMMENT_START / FINAL_COMMENT_END block. Wrap the revised draft between FINAL_COMMENT_START and FINAL_COMMENT_END markers, each on its own line." \
            "$_r4b_ctx" "Round 4b Edit Context")

        if ! run_marker_turn_with_retry "$CO_AGENT" "${prefix}round4b_co_${CO_AGENT}" \
                "$_round4b_co_prompt" "$ws/round4b_co.md"; then
            echo "ERROR: Round 4b co-auditor ($CO_AGENT) did not produce a FINAL_COMMENT_START/FINAL_COMMENT_END block, even after a markers-only retry." >&2
            echo "       The audit's rounds 1-4 completed; the converged findings and prior draft are preserved at:" >&2
            echo "         $ws/round3_co.md" >&2
            echo "         $ws/round4_primary.md" >&2
            echo "       Only the revised-draft step failed — re-run the audit to retry it." >&2
            return 1
        fi

        assert_repo_unchanged_outside_workspace
        if check_feedback; then
            echo "Stopped by feedback after Round 4b (co)."
            return 2
        fi

        _round4b_primary_prompt=$(build_audit_prompt \
            "Here is the revised GitHub review comment. Is this good for me to ship?

If yes, end your response with exactly APPROVED on its own line. If not, explain what's still wrong." \
            "$ws/round4b_co.md" "Revised Review Comment (Round 4b)")

        run_agent_turn_with_retry "$PRIMARY_AGENT" "${prefix}round4b_primary_${PRIMARY_AGENT}" \
            "$_round4b_primary_prompt" "$ws/round4b_primary.md"

        if [ ! -s "$ws/round4b_primary.md" ]; then
            echo "ERROR: Missing Round 4b output: round4b_primary.md" >&2
            return 1
        fi

        assert_repo_unchanged_outside_workspace

        FINAL_DRAFT_FILE="$ws/round4b_co.md"
        if is_approved "$ws/round4b_primary.md"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 4b: APPROVED" >> "$LOGFILE"
            echo "Phase 4b: APPROVED."
        else
            # mesh#34: a non-APPROVED Phase 4b is a legitimate request-changes
            # outcome, not a tool failure. The co produced a valid marker-gated draft
            # (round4b_co.md) and the primary still wants changes — finalize and post
            # the review as request-changes rather than discarding a completed
            # multi-round audit with a hard exit and nothing posted. The recommendation
            # is forced (Phase 5's "approve or request-changes" turn is moot here).
            NONCONVERGENCE=1
            echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 4b: not converged — finalizing as request-changes (mesh#34)." >> "$LOGFILE"
            echo "Phase 4b: agents did not fully converge — finalizing as request-changes."
        fi
    fi

    printf 'FINAL_DRAFT_FILE=%s\nNONCONVERGENCE=%s\n' "$FINAL_DRAFT_FILE" "$NONCONVERGENCE" > "$ws/.pipeline_result"
    return 0
}

# Run the full cross-pollination pipeline for ONE partition group (mesh#38).
# Runs in its own subshell (backgrounded by the caller), so it overrides the
# diff-source globals locally — PR_DIFF_FILE / DIFF_MODE / DIFF_MANIFEST_FILE /
# FILE_SUMMARIES_FILE / DIFF_SLICES_DIR all point at the group dir — without
# leaking to the parent or sibling groups. WORKSPACE_DIR / PROJECT_DIR /
# PRE_RUN_STATUS / FEEDBACK_FILE stay global so the dirty-check and feedback
# stop behave exactly as in single-diff mode. Returns the pipeline rc
# (0 draft / 2 feedback-stop / 1 error); the draft + NONCONVERGENCE land in
# <gdir>/.pipeline_result for the parent to read back.
run_one_group() {
    local gname="$1"
    local gdir="$GROUPS_DIR/$gname" gmode gb gl _m=0 _rc=0
    gmode=$(awk -F'\t' -v n="$gname" '$1 == n {print $2}' "$GROUPS_DIR/.records")
    [ -n "$gmode" ] || gmode="full-diff"

    PR_DIFF_FILE="$gdir/group.patch"
    DIFF_MODE="$gmode"
    DIFF_MANIFEST_FILE="$gdir/diff_manifest.json"
    FILE_SUMMARIES_FILE="$gdir/file_summaries.md"
    DIFF_SLICES_DIR="$gdir/diff_slices"
    # Group-local metrics sink: this group's agent turns run in a backgrounded
    # subshell, so each records to its OWN file — concurrent groups never share
    # one metrics file, no cross-group append race. The parent aggregates them.
    METRICS_FILE="$gdir/metrics.jsonl"

    gb=$(wc -c < "$PR_DIFF_FILE" | tr -d ' ')
    gl=$(wc -l < "$PR_DIFF_FILE" | tr -d ' ')
    : > "$FILE_SUMMARIES_FILE"
    : > "$METRICS_FILE"

    if [ "$gmode" = "chunked" ]; then
        subsplit_oversized_slices
        write_diff_manifest "$gb" "$gl"
        run_large_diff_map_stage || _m=$?
        if [ "$_m" -eq 2 ]; then return 2; fi
        if [ "$_m" -ne 0 ]; then return 1; fi
    else
        write_diff_manifest "$gb" "$gl"
        printf 'Full diff mode (subsystem group %s).\n' "$gname" > "$FILE_SUMMARIES_FILE"
    fi

    run_cross_pollination_pipeline "$gdir" "g_${gname}_" || _rc=$?
    return "$_rc"
}

# Build the consolidation prompt: merge the per-group review drafts into one
# review and explicitly hunt cross-group interface mismatches the per-group
# audits could not see. Feeds the drafts + partition map (NOT the raw diffs),
# so the consolidation prompt stays small regardless of total PR size.
build_consolidation_prompt() {
    local ctx_file="$1"

    printf 'You are consolidating a multi-part read-only audit of PR #%s in %s.\n' "$PR_NUMBER" "$REPO_SLUG"
    printf 'The PR was too large for one prompt, so it was partitioned into subsystem groups and each group was audited independently through a full cross-pollination pipeline. You have NO tools and NO repository access — work only from the per-group review drafts and the partition map below.\n'
    printf 'Merge the per-group drafts into ONE cohesive, non-redundant GitHub review body. Deduplicate overlapping findings and preserve their severity. Critically, hunt for CROSS-GROUP interface mismatches the per-group audits could not see: a change in the shared-surface group (types/schemas/migrations/contracts/config) whose dependents in another group were not updated to match; a function/field/signature altered in one group but consumed unchanged in another; contract or version drift between groups. Call those out explicitly — they are the failure mode partitioning risks.\n'
    printf 'Any group block marked "Primary auditor UNRESOLVED concerns" lists blockers the per-group edit round did NOT resolve; carry them into the merged review as request-changes items — do not let an approving-sounding group draft bury them.\n'
    printf 'Because you cannot access the repository, do NOT assert version-pinned dependency-source details you cannot verify from these drafts; keep every claim checkable from the drafts. Production deploy notes are NOT request-changes blockers unless the PR itself must change before merge.\n\n'
    printf 'Your response MUST contain exactly one FINAL_COMMENT_START / FINAL_COMMENT_END block. Wrap the EXACT review body to publish between the markers, each on its own line. Text outside those markers is process commentary only.\n\n'
    printf '## Partition Map\n\n'
    [ -f "$GROUPS_DIR/partition.json" ] && cat "$GROUPS_DIR/partition.json"
    printf '\n\n## Per-group Review Drafts\n\n'
    cat "$ctx_file"
    printf '\n\n## CC Review Comments\n\n'
    cat "$CC_COMMENTS_FILE"
}

# Assemble per-group drafts and run a single primary turn to merge them into one
# FINAL_COMMENT block. Sets the global FINAL_DRAFT_FILE. Returns 1 if the
# consolidation turn never produced a usable block.
run_consolidation_phase() {
    local ctx="$WORKSPACE_DIR/consolidation_context.md" gname gdraft prompt nc
    : > "$ctx"
    while IFS= read -r gname; do
        [ -n "$gname" ] || continue
        gdraft=""
        if [ -f "$GROUPS_DIR/$gname/.pipeline_result" ]; then
            gdraft=$(sed -n 's/^FINAL_DRAFT_FILE=//p' "$GROUPS_DIR/$gname/.pipeline_result")
        fi
        nc=$(sed -n 's/^NONCONVERGENCE=//p' "$GROUPS_DIR/$gname/.pipeline_result" 2>/dev/null)
        {
            printf '### Group: %s\n\n' "$gname"
            printf -- '- files: %s\n\n' "$(awk -F'\t' -v n="$gname" '$1 == n {print $5}' "$GROUPS_DIR/.records")"
            if [ -n "$gdraft" ] && [ -f "$gdraft" ]; then
                extract_final_comment "$gdraft" 2>/dev/null || cat "$gdraft"
            else
                printf '(no draft produced for this group)\n'
            fi
            # The group draft is the co-auditor's "passing" body. If the group did
            # NOT converge, the primary still had blockers — surface them so the
            # merged review reflects the real request-changes reason, not just the
            # approving-sounding draft (mesh#34).
            if [ "${nc:-0}" -eq 1 ] && [ -s "$GROUPS_DIR/$gname/round4b_primary.md" ]; then
                printf '\n**Primary auditor UNRESOLVED concerns for this group (request-changes):**\n\n'
                cat "$GROUPS_DIR/$gname/round4b_primary.md"
            fi
            printf '\n\n'
        } >> "$ctx"
    done < "$GROUPS_DIR/.names"

    prompt=$(build_consolidation_prompt "$ctx")
    if ! run_marker_turn_with_retry "$PRIMARY_AGENT" "consolidate_${PRIMARY_AGENT}" \
            "$prompt" "$WORKSPACE_DIR/consolidation_primary.md"; then
        echo "ERROR: Consolidation turn ($PRIMARY_AGENT) did not produce a FINAL_COMMENT_START/FINAL_COMMENT_END block, even after a markers-only retry." >&2
        echo "       Per-group drafts are preserved under: $GROUPS_DIR/*/" >&2
        return 1
    fi
    FINAL_DRAFT_FILE="$WORKSPACE_DIR/consolidation_primary.md"
    return 0
}

# Partition driver (mesh#38): audit each group through the full pipeline (bounded
# parallelism), then consolidate. Sets FINAL_DRAFT_FILE + NONCONVERGENCE and
# records them in WORKSPACE_DIR/.pipeline_result. Returns 0 draft / 2 feedback
# stop / 1 error — same contract as run_cross_pollination_pipeline.
run_partition_pipeline() {
    # Clamp MAX_PARALLEL_GROUPS to a positive integer. A non-numeric value would
    # break the `-lt` comparison, and 0 / negative would spin the launch loop
    # forever (it never advances i), hanging the whole run. (dogfood self-audit)
    case "${MAX_PARALLEL_GROUPS:-}" in
        ''|*[!0-9]*) MAX_PARALLEL_GROUPS=2 ;;
    esac
    [ "$MAX_PARALLEL_GROUPS" -ge 1 ] || MAX_PARALLEL_GROUPS=1

    echo "$(date '+%Y-%m-%d %H:%M:%S') Partition pipeline: $GROUP_COUNT group(s), <= $MAX_PARALLEL_GROUPS in parallel" >> "$LOGFILE"
    echo "Phases 1-4 (partition): auditing $GROUP_COUNT subsystem group(s), up to $MAX_PARALLEL_GROUPS in parallel..."

    local names; mapfile -t names < "$GROUPS_DIR/.names"
    local i=0 any_fail=0 stopped=0 abort=0
    # Stop launching new batches once any group hard-fails (abort) or a feedback
    # stop fires (stopped). A non-retryable fatal error (auth/quota) inside a
    # backgrounded run_one_group only kills that group's subshell, so without
    # abort the parent would keep launching every remaining doomed batch on a
    # global failure — the old foreground chunked path failed fast here.
    while [ "$i" -lt "${#names[@]}" ] && [ "$stopped" -eq 0 ] && [ "$abort" -eq 0 ]; do
        local batch=() p grc
        while [ "${#batch[@]}" -lt "$MAX_PARALLEL_GROUPS" ] && [ "$i" -lt "${#names[@]}" ]; do
            run_one_group "${names[$i]}" &
            p=$!
            batch+=("$p")
            _group_pids+=("$p")
            i=$((i + 1))
        done
        # Drain the in-flight batch (clean PID reaping) even when aborting.
        for p in "${batch[@]}"; do
            grc=0
            wait "$p" || grc=$?
            if [ "$grc" -eq 2 ]; then
                stopped=1
            elif [ "$grc" -ne 0 ]; then
                any_fail=1
                abort=1
            fi
        done
    done
    _group_pids=()

    # A hard failure dominates a cooperative feedback-stop: if both fired in the
    # same batch, report the real failure rather than masking it as a clean stop.
    if [ "$any_fail" -ne 0 ]; then
        echo "ERROR: one or more partition group pipelines failed (see $LOGFILE)." >&2
        return 1
    fi
    if [ "$stopped" -eq 1 ]; then
        echo "Stopped by feedback during group audits."
        return 2
    fi

    # request-changes is contagious across groups: if any group's primary never
    # approved its draft, the whole PR is request-changes (mesh#34 semantics).
    # Aggregate the non-converged groups' primary concerns to the PARENT
    # round4b_primary.md (group-labeled) so the mesh#34 "Primary auditor remaining
    # concerns" block in write_final_report fires in partition mode too — without
    # it, a partition request-changes shows only the generic banner with no
    # actionable specifics (the per-group round4b_primary.md never reaches parent).
    NONCONVERGENCE=0
    local gname nc parent_concerns="$WORKSPACE_DIR/round4b_primary.md" _any_concern=0
    : > "$parent_concerns"
    while IFS= read -r gname; do
        [ -n "$gname" ] || continue
        nc=$(sed -n 's/^NONCONVERGENCE=//p' "$GROUPS_DIR/$gname/.pipeline_result" 2>/dev/null)
        if [ "${nc:-0}" -eq 1 ]; then
            NONCONVERGENCE=1
            if [ -s "$GROUPS_DIR/$gname/round4b_primary.md" ]; then
                {
                    printf '#### Group: %s\n\n' "$gname"
                    cat "$GROUPS_DIR/$gname/round4b_primary.md"
                    printf '\n\n'
                } >> "$parent_concerns"
                _any_concern=1
            fi
        fi
    done < "$GROUPS_DIR/.names"
    [ "$_any_concern" -eq 1 ] || rm -f "$parent_concerns"

    echo "$(date '+%Y-%m-%d %H:%M:%S') Consolidation: merging $GROUP_COUNT group drafts" >> "$LOGFILE"
    echo "Consolidation: merging $GROUP_COUNT group draft(s) into one review..."
    run_consolidation_phase || return 1

    assert_repo_unchanged_outside_workspace
    if check_feedback; then
        echo "Stopped by feedback after consolidation."
        return 2
    fi

    printf 'FINAL_DRAFT_FILE=%s\nNONCONVERGENCE=%s\n' "$FINAL_DRAFT_FILE" "$NONCONVERGENCE" > "$WORKSPACE_DIR/.pipeline_result"
    return 0
}

# `|| _pipe_rc=$?` so a non-zero return does not trip `set -e` before we can
# branch on it: 2 = stopped cooperatively via feedback.md (exit 0), 1 = hard
# error (exit 1), 0 = a draft was produced. Partition mode fans the pipeline out
# per subsystem group then consolidates; every other mode runs it once.
_pipe_rc=0
if [ "$DIFF_MODE" = "partition" ]; then
    run_partition_pipeline || _pipe_rc=$?
else
    run_cross_pollination_pipeline "$WORKSPACE_DIR" || _pipe_rc=$?
fi
if [ "$_pipe_rc" -eq 2 ]; then
    exit 0
elif [ "$_pipe_rc" -ne 0 ]; then
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') Phases 1-4 complete. Final draft: $FINAL_DRAFT_FILE" >> "$LOGFILE"
echo "Phases 1-4 complete. Final draft source: $FINAL_DRAFT_FILE"

# ── Phase 5: Final Recommendation ──

echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 5: Final recommendation" >> "$LOGFILE"
echo "Phase 5: Final recommendation..."

if [ "${NONCONVERGENCE:-0}" -eq 1 ]; then
    # Non-convergence already determines the verdict (mesh#34): the primary
    # declined to approve the final draft, so request-changes is forced and the
    # "approve or request-changes" agent turn is moot. Skip it.
    RECOMMENDATION="request-changes"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 5: skipped — non-convergence forces request-changes." >> "$LOGFILE"
    echo "Phase 5: skipped (non-convergence ⇒ request-changes)."
else
    _round5_prompt=$(build_audit_prompt \
        "Here is the final approved GitHub review comment we are about to submit. Should I approve or request changes with this comment?

Respond with exactly one line: RECOMMENDATION: approve or RECOMMENDATION: request-changes
Base your decision on whether the PR needs code changes before merge. Production deploy notes alone do not warrant request-changes." \
        "$FINAL_DRAFT_FILE" "Final Approved Comment")

    run_agent_turn_with_retry "$PRIMARY_AGENT" "round5_primary_${PRIMARY_AGENT}" \
        "$_round5_prompt" "$WORKSPACE_DIR/round5_primary.md"

    if [ ! -s "$WORKSPACE_DIR/round5_primary.md" ]; then
        echo "ERROR: Missing Round 5 output: round5_primary.md" >&2
        exit 1
    fi

    RECOMMENDATION=$(extract_recommendation "$WORKSPACE_DIR/round5_primary.md")
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 5 complete. Recommendation: $RECOMMENDATION" >> "$LOGFILE"

# ── Phase 6: Output and Optional Post ──

echo "$(date '+%Y-%m-%d %H:%M:%S') Phase 6: Output and optional post" >> "$LOGFILE"
echo "Phase 6: Writing final output..."

extract_final_comment "$FINAL_DRAFT_FILE" > "$FINAL_COMMENT_FILE"
echo "$RECOMMENDATION" > "$RECOMMENDATION_FILE"
write_final_report

echo ""
echo "══════════════════════════════════════════"
echo "Final report: $FINAL_REPORT_FILE"
echo "Final comment: $FINAL_COMMENT_FILE"
echo "Recommendation: $RECOMMENDATION"
echo "══════════════════════════════════════════"
echo ""
cat "$FINAL_REPORT_FILE"
echo ""

if [ "$POST" = true ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Posting audit result to GitHub..." >> "$LOGFILE"
    echo "Posting audit result to GitHub (PR #$PR_NUMBER in $REPO_SLUG)..."

    # Verify PR head hasn't changed since we fetched the diff. A moved head only
    # matters if the new commits touch files we actually audited — benign drift
    # on disjoint files must not discard a clean verdict (mesh#44 Part 2).
    if ! current_head=$(cd "$PROJECT_DIR" && gh pr view "$PR_NUMBER" -R "$REPO_SLUG" \
            --json headRefOid -q '.headRefOid' 2>>"$LOGFILE"); then
        echo "ERROR: Failed to re-fetch PR head SHA before posting. Aborting." >&2
        exit 1
    fi
    if [ "$current_head" != "$AUDITED_HEAD_SHA" ]; then
        if head_drift_touches_audited_files "$AUDITED_HEAD_SHA" "$current_head"; then
            echo "ERROR: PR head changed during audit (audited: ${AUDITED_HEAD_SHA}, current: ${current_head}) and the new commits touch files this audit reviewed. Aborting post." >&2
            echo "  Re-run the audit against the current PR head." >&2
            exit 1
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') PR head drifted ${AUDITED_HEAD_SHA} -> ${current_head}; new commits do not touch audited files, posting audited-SHA review." >> "$LOGFILE"
        echo "NOTE: PR head moved during audit (audited ${AUDITED_HEAD_SHA}, current ${current_head}), but the new commits do not touch any audited file — posting the review for the audited SHA."
        # shellcheck disable=SC2016 # Literal backticks are part of the Markdown report.
        printf '\n> ⚠️ The PR head advanced from `%s` to `%s` during this audit. The new commits do not modify any file covered by this review, so these findings still apply (produced against the audited SHA `%s`).\n' \
            "$AUDITED_HEAD_SHA" "$current_head" "$AUDITED_HEAD_SHA" >> "$FINAL_REPORT_FILE"
    fi

    # mesh#53: a non-converged audit is the lowest-confidence verdict — the two
    # auditors never ratified a common draft (the primary held outstanding concerns
    # through the edit round). Surface the full report — which already carries the
    # request-changes lean and the primary's verbatim concerns — as a NON-BLOCKING
    # comment, and leave the blocking approve/request-changes review state to a
    # human. Converged verdicts (approve / request-changes from the Phase 5 turn)
    # still post as a blocking review below. Generic: keys off convergence
    # confidence, not any PR- or finding-specific condition.
    if [ "${NONCONVERGENCE:-0}" -eq 1 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Non-convergence — posting report as a non-blocking comment (mesh#53)." >> "$LOGFILE"
        echo "Non-convergence ⇒ posting as a non-blocking comment; final approve/request-changes left to a human."
        if ! post_report_comment; then
            exit 1
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') Non-convergence report posted as PR comment." >> "$LOGFILE"
        echo "Report posted as PR comment (non-blocking)."
        # mesh#52 resume: record this run as completed even though it posted a
        # comment rather than a review, so a later -R resume sees it (mirrors the
        # self-PR comment fallback and the review-success path below).
        mark_audit_state_complete
        echo "$(date '+%Y-%m-%d %H:%M:%S') audit_pr_review.sh complete." >> "$LOGFILE"
        exit 0
    fi

    local_gh_args=(gh pr review "$PR_NUMBER" -R "$REPO_SLUG" --body-file "$FINAL_REPORT_FILE")
    case "$RECOMMENDATION" in
        approve)
            local_gh_args+=(--approve)
            ;;
        request-changes)
            local_gh_args+=(--request-changes)
            ;;
    esac

    _gh_error_file=$(mktemp)
    if ! "${local_gh_args[@]}" 2>"$_gh_error_file"; then
        cat "$_gh_error_file" >> "$LOGFILE"
        if grep -qi "own pull request" "$_gh_error_file"; then
            echo "GitHub rejected the review action on your own PR; posting the report as a PR comment instead."
            echo "$(date '+%Y-%m-%d %H:%M:%S') Falling back to gh pr comment because GitHub rejected self-review." >> "$LOGFILE"
            rm -f "$_gh_error_file"
            if ! post_report_comment; then
                exit 1
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') Report posted as PR comment." >> "$LOGFILE"
            echo "Report posted as PR comment."
            mark_audit_state_complete
            echo "$(date '+%Y-%m-%d %H:%M:%S') audit_pr_review.sh complete." >> "$LOGFILE"
            exit 0
        fi
        echo "ERROR: gh pr review failed. Artifacts preserved:" >&2
        echo "GitHub error:" >&2
        sed 's/^/  /' "$_gh_error_file" >&2
        echo "  $FINAL_REPORT_FILE" >&2
        echo "  $FINAL_COMMENT_FILE" >&2
        echo "  $RECOMMENDATION_FILE" >&2
        echo "  Command: ${local_gh_args[*]}" >&2
        rm -f "$_gh_error_file"
        exit 1
    fi
    rm -f "$_gh_error_file"

    echo "$(date '+%Y-%m-%d %H:%M:%S') Review posted successfully." >> "$LOGFILE"
    echo "Review posted successfully."
    mark_audit_state_complete
else
    echo "Draft only (use default or --post to submit). Files:"
    echo "  $FINAL_REPORT_FILE"
    echo "  $FINAL_COMMENT_FILE"
    echo "  $RECOMMENDATION_FILE"
    mark_audit_state_complete
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') audit_pr_review.sh complete." >> "$LOGFILE"
exit 0
