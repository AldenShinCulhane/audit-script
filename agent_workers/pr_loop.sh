#!/bin/bash

# Automated PR review cycle: commits changes, creates a PR, retrieves reviewer
# comments, uses agents to triage and address them (delegating fixes to agent_loop.sh),
# pushes fix commits, and repeats until resolved. Human approves and merges.
#
# Flow per cycle:
#   1. Wait for reviewer comments on the PR
#   2. Multi-agent triage: classify each comment as ACCEPT or REBUTTAL
#   3. Generate fix spec for ACCEPTed items, invoke agent_loop.sh -1
#   4. Post rebuttals for REBUTTALed items
#   5. Commit, push, post summary comment
#   6. Repeat until max_cycles or approval
#   7. Optionally (-A): hand off to audit_pr_review.sh for one final,
#      independent audit pass (the auditor posts its own review verdict;
#      pr_loop does not read or act on it)
#
# Files (under <project>/agent_workers/pr_loop/):
#   review_comments.md — raw reviewer comments per cycle (overwritten each cycle)
#   triage.md          — agent triage decisions per cycle (overwritten each cycle)
#   fix_spec.md        — mini-spec for agent_loop.sh (overwritten each cycle)
#   changes.md         — append-only audit trail
#   .state             — JSON: { pr_number, cycle, last_comment_ts, branch, base_branch }
#   run.log            — full log
#   feedback.md        — human can inject guidance or write "stop"/"exit"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_FILE="$SCRIPT_DIR/lib/agent_sessions.sh"

if [ ! -f "$LIB_FILE" ]; then
    echo "ERROR: Session helper not found: $LIB_FILE" >&2
    exit 1
fi

# agent_sessions.sh requires LOGFILE and FEEDBACK_FILE to be set before sourcing.
# We set placeholder values here; they are overridden after argument parsing.
LOGFILE="/dev/null"
FEEDBACK_FILE="/dev/null"

# shellcheck disable=SC1090,SC1091
. "$LIB_FILE"

# shellcheck disable=SC2317  # cleanup is invoked indirectly via trap
cleanup() {
    if [ -n "${AGENT_PID:-}" ]; then
        kill "$AGENT_PID" 2>/dev/null
        pkill -P "$AGENT_PID" 2>/dev/null
        wait "$AGENT_PID" 2>/dev/null
    fi
    [ -n "${LOGFILE:-}" ] && [ "$LOGFILE" != "/dev/null" ] && echo " pr_loop terminated." >> "$LOGFILE"
}
trap cleanup EXIT

# ── Error handling (§7): retry wrapper ──

MAX_AGENT_ATTEMPTS="${MAX_AGENT_ATTEMPTS:-3}"
TRANSIENT_RETRY_DELAY="${TRANSIENT_RETRY_DELAY:-30}"

# Wrapper around run_agent_turn that retries on transient API errors (exit 2+).
# Fatal errors (token limit, auth) cause immediate exit.
run_agent_turn_with_retry() {
    local attempt=0
    local outfile="$4"
    while [ "$attempt" -lt "$MAX_AGENT_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        run_agent_turn "$@"
        local rc=$?
        if [ "$rc" -eq 0 ]; then
            return 0
        fi
        if [ -n "$outfile" ] && [ -f "$outfile" ] && is_fatal_error "$(cat "$outfile")"; then
            echo "$(date '+%H:%M:%S') FATAL: Agent hit a non-retryable error. Exiting." >> "$LOGFILE"
            echo "FATAL: Agent error (see $LOGFILE for details)." >&2
            exit 1
        fi
        if [ "$rc" -ge 2 ] && [ "$attempt" -lt "$MAX_AGENT_ATTEMPTS" ]; then
            echo "$(date '+%H:%M:%S') Transient error (exit $rc). Retrying in ${TRANSIENT_RETRY_DELAY}s (attempt $attempt/$MAX_AGENT_ATTEMPTS)..." >> "$LOGFILE"
            sleep "$TRANSIENT_RETRY_DELAY"
        else
            echo "$(date '+%H:%M:%S') Agent failed (exit $rc) after $attempt attempt(s)." >> "$LOGFILE"
            return "$rc"
        fi
    done
}

# ── Defaults ──
# Hidden HTML marker added to every comment posted by this script.
# Used to reliably filter out self-authored comments during polling.
PR_LOOP_MARKER="<!-- pr_loop:self -->"
PR_LOOP_SIGNATURE="— *[pr_loop.sh]*"

# Maximum number of lines from $CHANGES_FILE included as prior-history context
# in each cycle's triage prompts. Override via environment variable for repos
# with very long PR review histories — see notes below before bumping this.
#
# Trade-off:
# - Too small: tail truncates earlier cycles, the triage agent loses memory
#   of older rebuttals, and a current reviewer comment that re-raises an
#   ancient issue gets mis-classified as REBUTTAL instead of REBUTTAL-SKIP
#   → duplicate rebuttal posted on the PR (the exact bug this whole module
#   exists to prevent). Symptom: cycle N+1 reposts a rebuttal that cycle N
#   already addressed; the audit trail (changes.md) shows both as separate
#   REBUTTAL decisions, even though they're the same issue.
# - Too large: each cycle's triage prompt grows by O(history) and the LLM
#   context cost rises. On a long-running PR with 20+ cycles, the prompt
#   could exceed the model's context window and cause truncation higher in
#   the stack.
#
# 300 lines is the default — empirically it covers ~3-5 typical cycles of
# audit trail (each cycle appends triage decisions + rebuttal markers). If
# a PR is hitting the truncation symptom, raise this to 600 or 1000 first;
# if that's still not enough, the right fix is probably to compact older
# cycles in changes.md rather than further inflating the prompt.
PR_LOOP_HISTORY_TAIL_LINES="${PR_LOOP_HISTORY_TAIL_LINES:-300}"
# Defensive: a non-numeric override (e.g. `export PR_LOOP_HISTORY_TAIL_LINES=abc`)
# would make the `tail -n` call inside run_triage fail silently — command
# substitution failures don't trigger `set -e`, so the prior_history_block
# would just become empty and the triage agent would silently lose its memory
# of prior cycles. Validate at module load and warn loudly on fallback so a
# typo doesn't degrade the dedup behavior in stealth.
if ! [[ "$PR_LOOP_HISTORY_TAIL_LINES" =~ ^[0-9]+$ ]]; then
    echo "WARN: PR_LOOP_HISTORY_TAIL_LINES='${PR_LOOP_HISTORY_TAIL_LINES}' is not a non-negative integer; falling back to 300" >&2
    PR_LOOP_HISTORY_TAIL_LINES=300
fi

ANALYZER="codex"
CO_ANALYZER="codex"
MAX_CYCLES=5
SETTLED_AFTER_EMPTY_POLLS="${SETTLED_AFTER_EMPTY_POLLS:-2}"
WAIT_TIMEOUT=14400
RESUME=false
# -p: attach to an explicit existing PR number (decoupled from the cwd branch).
PR_ARG=""
PROJECT_DIR=""
WORKSPACE_OPT=""
BASE_BRANCH=""
PR_TITLE=""
BODY_FILE=""
POLL_INTERVAL="${POLL_INTERVAL:-60}"
# -A final-audit hand-off (off by default; see run_final_audit below).
ENABLE_AUDIT=false
AUDIT_SCRIPT="$SCRIPT_DIR/audit_pr_review.sh"

usage() {
    cat <<'USAGE'
Usage: pr_loop.sh [-d dir] [-w workspace_dir] [-b branch] [-t title] [-m body_file] [-i agent] [-r agent] [-n max_cycles] [-T seconds] [-A] [-a audit_script] [-p pr_number] [-R]

Automated PR review feedback loop. Commits changes, creates a PR, waits
for reviewer comments, uses agents to triage and address them, pushes fixes.

Options:
  -d <dir>       Project directory (default: .)
  -w <dir>       Workspace directory for state files (default: <project>/agent_workers/pr_loop/)
  -b <branch>    Base branch for PR (default: auto-detect via gh)
  -t <title>     PR title (default: derived from branch name)
  -m <body_file> File containing PR description body (optional)
  -i <agent>     Analyzer/implementer agent: claude|codex|zenmux|fireworks
                 (default: codex). Same vocabulary as agent_loop / spec_loop /
                 spec_to_ship.sh. zenmux and fireworks are agentic OSS-backed
                 Claude Code instances (full tool surface; can edit triage.md).
                 'oss' (stateless) is NOT accepted here — see -r below.
  -r <agent>     Co-analyzer/reviewer agent: claude|codex|zenmux|fireworks|oss
                 (default: codex).
                 zenmux/fireworks: agentic, edit triage.md directly during review.
                 oss: stateless HTTP second opinion (non-mutating; the shell
                       appends its commentary to triage.md). Reads
                       OSS_FLASH_MODEL=<provider>:<slug>
                       (e.g. zenmux:deepseek/deepseek-v4-flash) plus the
                       provider's API key (ZENMUX_API_KEY or FIREWORKS_API_KEY).
  -n <max>       Max review-fix cycles (default: 5)
  -T <seconds>   Max wait for comments per cycle (default: 14400; 0 = check once)
  -A             After the review-fix loop finishes (settled, approved, or
                 max cycles), run the standalone mesh auditor
                 (audit_pr_review.sh) once as a discrete final step. The
                 auditor posts its own approve/request-changes review on the
                 PR; pr_loop does NOT read or act on that verdict. Not
                 persisted in .state — pass -A again when resuming with -R.
                 (default: off. Note: in -T 0 single-check mode an empty
                 check exits before the loop settles, so the audit does not
                 run on that path.)
  -a <path>      Path to the audit script invoked by -A
                 (default: audit_pr_review.sh next to this script)
  -p <pr>        Attach to an existing OPEN PR by number instead of using the
                 current branch. The PR defines both the head branch (fetched
                 and checked out into -d; the working tree must have no
                 uncommitted tracked changes) and the base branch (-b is
                 rejected). Never creates a PR. Conflicts with -R; a -p run
                 writes .state, so later resumes use plain -R as usual.
                 PROJECT_DIR (-d) must be a checkout of the PR's repo. If the
                 default workspace dir was previously used for a different PR,
                 pass -w to keep audit trails separate.
  -R             Resume a previous run (skip PR creation)
  -h             Show this help

Examples:
  ./pr_loop.sh                                            # auto title from branch
  ./pr_loop.sh -t "Add user auth" -d ../sibling-repo        # explicit title
  ./pr_loop.sh -p 123 -d ../sibling-repo                    # attach to existing PR #123
  ./pr_loop.sh -R                                         # resume after stop
USAGE
    exit 0
}

while getopts "d:w:b:t:m:i:r:n:T:Aa:p:Rh" opt; do
    case $opt in
        d) PROJECT_DIR="$OPTARG" ;;
        w) WORKSPACE_OPT="$OPTARG" ;;
        b) BASE_BRANCH="$OPTARG" ;;
        t) PR_TITLE="$OPTARG" ;;
        m) BODY_FILE="$OPTARG" ;;
        i) ANALYZER="$OPTARG" ;;
        r) CO_ANALYZER="$OPTARG" ;;
        n) MAX_CYCLES="$OPTARG" ;;
        T) WAIT_TIMEOUT="$OPTARG" ;;
        A) ENABLE_AUDIT=true ;;
        a) AUDIT_SCRIPT="$OPTARG" ;;
        p) PR_ARG="$OPTARG" ;;
        R) RESUME=true ;;
        h) usage ;;
        \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
    esac
done

# Validate agents. Vocabulary matches agent_loop / spec_loop / spec_to_ship.sh
# plus the legacy 'oss' (stateless) reviewer for the -r slot only.
for agent in "$ANALYZER" "$CO_ANALYZER"; do
    case "$agent" in
        claude|codex|zenmux|fireworks|oss) ;;
        *) echo "ERROR: Agent must be 'claude'|'codex'|'zenmux'|'fireworks'|'oss', got '$agent'" >&2; exit 1 ;;
    esac
done

# 'oss' (legacy stateless agent) has no tool surface — it cannot edit
# triage.md or any other working file. Only fits the co-analyzer/reviewer
# (-r) seat where pr_loop's flow already tolerates "no file change" as
# implicit agreement. Reject -i oss to avoid the silent-degradation pattern
# (Agent B ends up doing all the work because Agent A produced no triage update).
#
# NOTE: 'zenmux' and 'fireworks' are AGENTIC (full Claude Code tool surface
# via OSS provider; they CAN edit triage.md), so they're valid for -i.
if [ "$ANALYZER" = "oss" ]; then
    echo "ERROR: -i oss not supported (oss is stateless and cannot edit triage.md)." >&2
    echo "       For an agentic OSS implementer, use '-i zenmux' or '-i fireworks' instead" >&2
    echo "       (full Claude Code tool surface via OSS provider; can edit triage.md)." >&2
    echo "       For a non-mutating second opinion in the reviewer slot, use '-r oss'." >&2
    exit 1
fi

# Up-front prereq checks for agentic OSS agents (zenmux/fireworks) in either
# seat — fail fast at script start, not mid-cycle. zenmux/fireworks are
# dispatched through run_agent_turn → claude_oss, so we just need the
# matching provider API key to be set; the lib helper handles the rest.
oss_agents_require_api_key "$ANALYZER"    "-i" || exit 1
oss_agents_require_api_key "$CO_ANALYZER" "-r" || exit 1

# When 'oss' is selected for the reviewer seat, fail loudly up-front if the
# provider/slug or API key is missing — better than discovering it mid-cycle.
if [ "$CO_ANALYZER" = "oss" ]; then
    if [ -z "${OSS_FLASH_MODEL:-}" ]; then
        echo "ERROR: agent 'oss' requires OSS_FLASH_MODEL=<provider>:<slug>" >&2
        echo "       e.g. export OSS_FLASH_MODEL=zenmux:deepseek/deepseek-v4-flash" >&2
        exit 1
    fi
    if [[ "$OSS_FLASH_MODEL" != *:* ]]; then
        echo "ERROR: OSS_FLASH_MODEL='$OSS_FLASH_MODEL' must use form <provider>:<slug>" >&2
        exit 1
    fi
    _oss_provider="${OSS_FLASH_MODEL%%:*}"
    case "$_oss_provider" in
        zenmux)
            [ -n "${ZENMUX_API_KEY:-}" ] || { echo "ERROR: agent 'oss' provider zenmux requires ZENMUX_API_KEY" >&2; exit 1; }
            ;;
        fireworks)
            [ -n "${FIREWORKS_API_KEY:-}" ] || { echo "ERROR: agent 'oss' provider fireworks requires FIREWORKS_API_KEY" >&2; exit 1; }
            ;;
        *)
            echo "ERROR: agent 'oss' provider '$_oss_provider' unknown (expected zenmux|fireworks)" >&2
            exit 1
            ;;
    esac
    unset _oss_provider
fi

# Validate numeric arguments
if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]] || [ "$MAX_CYCLES" -lt 1 ]; then
    echo "ERROR: -n max_cycles must be a positive integer, got '$MAX_CYCLES'" >&2
    exit 1
fi
if ! [[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: -T seconds must be a non-negative integer, got '$WAIT_TIMEOUT'" >&2
    exit 1
fi
if ! [[ "$SETTLED_AFTER_EMPTY_POLLS" =~ ^[0-9]+$ ]] || [ "$SETTLED_AFTER_EMPTY_POLLS" -lt 1 ]; then
    echo "ERROR: SETTLED_AFTER_EMPTY_POLLS must be a positive integer, got '$SETTLED_AFTER_EMPTY_POLLS'" >&2
    exit 1
fi

# Validate -p: positive integer, mutually exclusive with -R, and the PR
# defines its own base branch, so an explicit -b is rejected rather than
# silently overridden (fail closed: a warning in a long-running orchestrator
# scrolls away while the caller's wrong mental model persists).
if [ -n "$PR_ARG" ]; then
    if ! [[ "$PR_ARG" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: -p pr_number must be a positive integer, got '$PR_ARG'" >&2
        exit 1
    fi
    if [ "$RESUME" = true ]; then
        echo "ERROR: -p and -R are mutually exclusive (resume loads its PR from .state)." >&2
        exit 1
    fi
    if [ -n "$BASE_BRANCH" ]; then
        echo "ERROR: -b cannot be combined with -p; the PR defines its own base branch." >&2
        exit 1
    fi
fi

# -A: fail fast at startup if the audit script is missing — far better than
# discovering that after N review cycles have already run. Only checked when
# the audit is enabled: a custom -a path without -A is inert by design.
if [ "$ENABLE_AUDIT" = true ] && [ ! -f "$AUDIT_SCRIPT" ]; then
    echo "ERROR: -A set but audit script not found: $AUDIT_SCRIPT" >&2
    exit 1
fi

# ── Derive paths ──
PROJECT_ROOT="$(cd "${PROJECT_DIR:-.}" && pwd)"
export AGENT_PROJECT_ROOT="$PROJECT_ROOT"
if [ -n "$WORKSPACE_OPT" ]; then
    case "$WORKSPACE_OPT" in
        /*) WORKSPACE_DIR="$WORKSPACE_OPT" ;;
        *)  WORKSPACE_DIR="$PROJECT_ROOT/$WORKSPACE_OPT" ;;
    esac
    mkdir -p "$WORKSPACE_DIR"
    WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"
else
    WORKSPACE_DIR="$PROJECT_ROOT/agent_workers/pr_loop"
fi
LOGFILE="$WORKSPACE_DIR/run.log"
FEEDBACK_FILE="$WORKSPACE_DIR/feedback.md"
STATE_FILE="$WORKSPACE_DIR/.state"
mkdir -p "$WORKSPACE_DIR"
# Create all §5 workspace files up front
touch "$WORKSPACE_DIR/review_comments.md" \
      "$WORKSPACE_DIR/triage.md" \
      "$WORKSPACE_DIR/fix_spec.md" \
      "$WORKSPACE_DIR/changes.md" \
      "$WORKSPACE_DIR/run.log" \
      "$FEEDBACK_FILE"

# ── Initialization (§4.1) ──

agent_sessions_init

# Verify gh auth
if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh auth failed. Run 'gh auth login' first." >&2
    exit 1
fi

# Detect default branch if -b not provided. Skipped in -p mode: the PR
# defines its own base, resolved from the PR itself below.
if [ -z "$PR_ARG" ] && [ -z "$BASE_BRANCH" ]; then
    BASE_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null) || true
    if [ -z "$BASE_BRANCH" ]; then
        echo "ERROR: Could not auto-detect base branch. Specify with -b." >&2
        exit 1
    fi
fi

# Verify we are on a feature branch, not the default branch. Skipped in -p
# mode: the PR defines its head branch (checked out below), and the invoking
# checkout may legitimately be sitting on the default branch.
if [ -z "$PR_ARG" ]; then
    CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
        echo "ERROR: Currently on default branch '$BASE_BRANCH'. Switch to a feature branch first." >&2
        exit 1
    fi
fi

# ── State management (§5, §6) ──

# Write state as JSON.
save_state() {
    local pr_num="${1:-${PR_NUMBER:-}}"
    local cycle="${2:-${CYCLE:-0}}"
    local last_ts="${3:-${LAST_COMMENT_TS:-}}"
    local branch="${4:-${CURRENT_BRANCH}}"
    local base="${5:-${BASE_BRANCH}}"

    cat > "$STATE_FILE" <<EOF
{
  "pr_number": ${pr_num},
  "cycle": ${cycle},
  "last_comment_ts": "${last_ts}",
  "branch": "${branch}",
  "base_branch": "${base}"
}
EOF
}

# Read state from JSON. Sets PR_NUMBER, CYCLE, LAST_COMMENT_TS, CURRENT_BRANCH, BASE_BRANCH.
load_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo " No state file found. Cannot resume." >> "$LOGFILE"
        return 1
    fi

    local state_json
    state_json=$(cat "$STATE_FILE")

    PR_NUMBER=$(echo "$state_json" | jq -r '.pr_number')
    CYCLE=$(echo "$state_json" | jq -r '.cycle')
    LAST_COMMENT_TS=$(echo "$state_json" | jq -r '.last_comment_ts')
    CURRENT_BRANCH=$(echo "$state_json" | jq -r '.branch')
    BASE_BRANCH=$(echo "$state_json" | jq -r '.base_branch')

    if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
        echo " State file missing pr_number." >> "$LOGFILE"
        return 1
    fi

    echo " Loaded state: pr=#${PR_NUMBER}, cycle=${CYCLE}, last_ts=${LAST_COMMENT_TS}" >> "$LOGFILE"
    return 0
}

# ── -p: attach to an explicit existing PR (decoupled from the cwd branch) ──
if [ -n "$PR_ARG" ]; then
    # Derive owner/repo from PROJECT_ROOT's origin remote so every gh call in
    # this mode is pinned to the project's repo regardless of invocation cwd.
    ORIGIN_URL=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null) || ORIGIN_URL=""
    if [ -z "$ORIGIN_URL" ]; then
        echo "ERROR: -p requires an 'origin' remote in $PROJECT_ROOT." >&2
        exit 1
    fi
    # Normalize the common remote forms to owner/repo:
    #   git@host:owner/repo(.git)          (incl. ssh-config host aliases)
    #   ssh://git@host[:port]/owner/repo(.git)
    #   https://[user@]host/owner/repo(.git)
    REPO_SLUG=$(printf '%s\n' "$ORIGIN_URL" \
        | sed -E -e 's#^(git@[^:/]+:|ssh://[^/]+/|git://[^/]+/|https?://[^/]+/)##' \
                 -e 's#/+$##' -e 's#\.git$##')
    if ! [[ "$REPO_SLUG" =~ ^[^/:]+/[^/:]+$ ]]; then
        echo "ERROR: Could not derive owner/repo from origin remote '$ORIGIN_URL'." >&2
        exit 1
    fi
    # Canonicalize via the API when reachable (fixes remote-URL casing and
    # follows renamed-repo redirects); fall back to the URL-derived slug.
    CANON_SLUG=$(gh repo view "$REPO_SLUG" --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || CANON_SLUG=""
    if [ -n "$CANON_SLUG" ]; then
        REPO_SLUG="$CANON_SLUG"
    fi
    PR_JSON=$(gh pr view "$PR_ARG" -R "$REPO_SLUG" \
        --json state,headRefName,baseRefName,headRepositoryOwner,headRepository,url \
        2>/dev/null) || PR_JSON=""
    if [ -z "$PR_JSON" ]; then
        echo "ERROR: Cannot find PR #${PR_ARG} in ${REPO_SLUG}." >&2
        exit 1
    fi
    PR_STATE=$(echo "$PR_JSON" | jq -r '.state // ""')
    if [ "$PR_STATE" != "OPEN" ]; then
        echo "PR #${PR_ARG} is ${PR_STATE:-UNKNOWN} (not OPEN). Nothing to do." >&2
        exit 0
    fi
    # Reject cross-fork PRs: pr_loop pushes fixes to origin, which only works
    # when the PR head lives in this exact repo. Compare the complete slug,
    # case-insensitively because GitHub repository identities are case-insensitive.
    PR_HEAD_OWNER=$(echo "$PR_JSON" | jq -r '.headRepositoryOwner.login // ""')
    PR_HEAD_REPO=$(echo "$PR_JSON" | jq -r '.headRepository.name // ""')
    if [ -z "$PR_HEAD_OWNER" ] || [ -z "$PR_HEAD_REPO" ]; then
        echo "ERROR: PR #${PR_ARG} is missing head repository data." >&2
        exit 1
    fi
    PR_HEAD_SLUG="${PR_HEAD_OWNER}/${PR_HEAD_REPO}"
    if [ "$(printf '%s' "$PR_HEAD_SLUG" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$REPO_SLUG" | tr '[:upper:]' '[:lower:]')" ]; then
        echo "ERROR: PR #${PR_ARG} head is in '${PR_HEAD_SLUG}', not '${REPO_SLUG}'. Cross-fork PRs are not supported." >&2
        exit 1
    fi

    PR_NUMBER="$PR_ARG"
    CURRENT_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName // ""')
    BASE_BRANCH=$(echo "$PR_JSON" | jq -r '.baseRefName // ""')
    PR_URL=$(echo "$PR_JSON" | jq -r '.url // ""')
    if [ -z "$CURRENT_BRANCH" ] || [ -z "$BASE_BRANCH" ]; then
        echo "ERROR: PR #${PR_ARG} is missing head/base branch data." >&2
        exit 1
    fi

    # Pin every later repo-inferring gh call (gh pr view / gh pr comment in
    # the poll helpers) to this repo so -p mode works regardless of cwd.
    # Only -p mode sets this; the other modes keep cwd-based inference.
    export GH_REPO="$REPO_SLUG"

    echo "Attaching to PR #${PR_NUMBER}: ${PR_URL}"
    echo " -p mode: PR #${PR_NUMBER} (${CURRENT_BRANCH} -> ${BASE_BRANCH}) in ${REPO_SLUG}" >> "$LOGFILE"

    # Check out the PR's head branch so fixes can be committed and pushed.
    # Refuse to switch over uncommitted tracked changes — never clobber.
    # (Untracked files are left to git itself, which fails closed if one
    # collides with the incoming branch. A status --porcelain guard would
    # false-positive on the default workspace dir, which lives untracked
    # under PROJECT_ROOT.)
    if ! git -C "$PROJECT_ROOT" diff --quiet || ! git -C "$PROJECT_ROOT" diff --cached --quiet; then
        echo "ERROR: Uncommitted changes in $PROJECT_ROOT. Commit or stash them before running with -p." >&2
        exit 1
    fi
    git -C "$PROJECT_ROOT" fetch origin "$CURRENT_BRANCH" || {
        echo "ERROR: git fetch origin '${CURRENT_BRANCH}' failed." >&2
        exit 1
    }
    LOCAL_HEAD=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || LOCAL_HEAD=""
    if [ "$LOCAL_HEAD" != "$CURRENT_BRANCH" ]; then
        if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/${CURRENT_BRANCH}"; then
            git -C "$PROJECT_ROOT" checkout "$CURRENT_BRANCH" || {
                echo "ERROR: Could not check out existing local branch '${CURRENT_BRANCH}'." >&2
                exit 1
            }
        else
            git -C "$PROJECT_ROOT" checkout -b "$CURRENT_BRANCH" --track "origin/${CURRENT_BRANCH}" || {
                echo "ERROR: Could not create local tracking branch '${CURRENT_BRANCH}' from origin." >&2
                exit 1
            }
        fi
    fi
    # Align with origin without ever rewriting local work: fast-forwards if
    # behind, no-ops if equal or ahead (unpushed local commits ride along on
    # the next fix push), errors out if the histories diverged.
    git -C "$PROJECT_ROOT" merge --ff-only "origin/${CURRENT_BRANCH}" || {
        echo "ERROR: Local '${CURRENT_BRANCH}' diverged from origin/${CURRENT_BRANCH}. Resolve manually, then rerun." >&2
        exit 1
    }
    echo " Checked out '${CURRENT_BRANCH}' at origin tip." >> "$LOGFILE"

    # From here behave exactly like PR adoption. NEVER create a PR in -p mode.
    # Initialize LAST_COMMENT_TS to the PR's own latest comment/review
    # timestamp so the first poll only picks up NEW comments (same jq as the
    # adopt path; PR-side timestamps avoid local clock skew).
    CYCLE=0
    LAST_COMMENT_TS=$(gh pr view "$PR_NUMBER" -R "$REPO_SLUG" --json comments,reviews 2>/dev/null |
        jq -r '[(.comments // [])[], (.reviews // [])[]] | map(.createdAt // .submittedAt) | map(select(. != null)) | max // ""' 2>/dev/null || echo "")
    if [ -z "$LAST_COMMENT_TS" ]; then
        LAST_COMMENT_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        echo " LAST_COMMENT_TS fallback to local now: ${LAST_COMMENT_TS}" >> "$LOGFILE"
    fi
    save_state "$PR_NUMBER" "$CYCLE" "$LAST_COMMENT_TS" "$CURRENT_BRANCH" "$BASE_BRANCH"
    echo " State saved to $STATE_FILE (last_ts=${LAST_COMMENT_TS})" >> "$LOGFILE"
# ── Resume (§6) ──
elif [ "$RESUME" = true ]; then
    if ! load_state; then
        echo "ERROR: Cannot resume — no valid state file at $STATE_FILE" >&2
        exit 1
    fi

    # Verify PR still exists and is open
    PR_STATE=$(gh pr view "$PR_NUMBER" --json state --jq '.state' 2>/dev/null) || true
    if [ -z "$PR_STATE" ]; then
        echo "ERROR: Cannot find PR #${PR_NUMBER}." >&2
        exit 1
    fi
    if [ "$PR_STATE" != "OPEN" ]; then
        echo "PR #${PR_NUMBER} is ${PR_STATE} (not OPEN). Nothing to do." >&2
        exit 0
    fi

    echo "Resuming pr_loop for PR #${PR_NUMBER} (cycle ${CYCLE})."
    echo " Resumed: pr=#${PR_NUMBER}, cycle=${CYCLE}, last_ts=${LAST_COMMENT_TS}" >> "$LOGFILE"
else
    # ── Detect existing PR on current branch ──
    # This lets pr_loop attach to a PR that was created outside pr_loop
    # (e.g., manually, or by another tool) without needing a state file.
    #
    # Match criteria (strict, to avoid adopting the wrong PR):
    #   - open state
    #   - headRefName == CURRENT_BRANCH
    #   - baseRefName == BASE_BRANCH
    #   - head repo is the same repo (not a fork) — headRepositoryOwner matches
    REPO_OWNER=$(gh repo view --json owner --jq '.owner.login' 2>/dev/null || true)
    if [ -z "$REPO_OWNER" ]; then
        echo "ERROR: Could not determine repo owner via 'gh repo view'. Cannot safely detect existing PR." >&2
        echo "Run from inside a gh-recognized repo, or use -R with an explicit state file." >&2
        exit 1
    fi

    EXISTING_PRS_JSON=$(gh pr list --head "$CURRENT_BRANCH" --base "$BASE_BRANCH" --state open \
        --json number,headRefName,baseRefName,headRepositoryOwner,url 2>/dev/null || echo "[]")

    # Filter to same-repo PRs only (exclude fork PRs)
    MATCHING_PRS_JSON=$(echo "$EXISTING_PRS_JSON" | jq -c \
        --arg owner "$REPO_OWNER" \
        --arg branch "$CURRENT_BRANCH" \
        --arg base "$BASE_BRANCH" \
        '[.[] | select(.headRefName == $branch and .baseRefName == $base and .headRepositoryOwner.login == $owner)]' 2>/dev/null || echo "[]")

    # Robust numeric parsing: default to 0 if jq output is empty or non-numeric
    MATCH_COUNT_RAW=$(echo "$MATCHING_PRS_JSON" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$MATCH_COUNT_RAW" =~ ^[0-9]+$ ]]; then
        MATCH_COUNT="$MATCH_COUNT_RAW"
    else
        MATCH_COUNT=0
    fi

    if [ "$MATCH_COUNT" -gt 1 ]; then
        echo "ERROR: Found $MATCH_COUNT open PRs matching branch '$CURRENT_BRANCH' → '$BASE_BRANCH'. Cannot auto-adopt." >&2
        echo "Matching PRs:" >&2
        echo "$MATCHING_PRS_JSON" | jq -r '.[] | "  #\(.number): \(.url)"' >&2
        echo "Specify a state file and resume with -R, or close duplicates." >&2
        exit 1
    fi

    EXISTING_PR_NUMBER=""
    if [ "$MATCH_COUNT" -eq 1 ]; then
        EXISTING_PR_NUMBER=$(echo "$MATCHING_PRS_JSON" | jq -r '.[0].number')
    fi

    if [ -n "$EXISTING_PR_NUMBER" ]; then
        # ── Adopt existing PR ──
        PR_NUMBER="$EXISTING_PR_NUMBER"
        PR_URL=$(echo "$MATCHING_PRS_JSON" | jq -r '.[0].url')
        echo "Adopting existing PR #${PR_NUMBER}: ${PR_URL}"
        echo " Adopted existing PR #${PR_NUMBER}: ${PR_URL}" >> "$LOGFILE"

        # Do NOT auto-commit uncommitted changes when adopting an existing PR.
        # The PR already exists with its own pushed state — local WIP/debug
        # files should not be silently committed under "adopt existing PR".
        # If the user has uncommitted work they want on the PR, they should
        # commit + push before running pr_loop.
        if ! git -C "$PROJECT_ROOT" diff --quiet || ! git -C "$PROJECT_ROOT" diff --cached --quiet; then
            echo "WARN: Uncommitted changes detected in working tree. They will NOT be added to PR #${PR_NUMBER}." >&2
            echo " WARN: Uncommitted changes present — not auto-committing during adoption." >> "$LOGFILE"
        fi

        # Initialize LAST_COMMENT_TS to the current latest PR comment timestamp
        # so the first poll only picks up NEW comments, not existing ones.
        # Fallback to local "now" if the query fails. Using the PR's own
        # timestamp avoids local-vs-server clock skew issues.
        CYCLE=0
        LAST_COMMENT_TS=$(gh pr view "$PR_NUMBER" --json comments,reviews 2>/dev/null |
            jq -r '[(.comments // [])[], (.reviews // [])[]] | map(.createdAt // .submittedAt) | map(select(. != null)) | max // ""' 2>/dev/null || echo "")
        if [ -z "$LAST_COMMENT_TS" ]; then
            LAST_COMMENT_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            echo " LAST_COMMENT_TS fallback to local now: ${LAST_COMMENT_TS}" >> "$LOGFILE"
        fi
        save_state "$PR_NUMBER" "$CYCLE" "$LAST_COMMENT_TS" "$CURRENT_BRANCH" "$BASE_BRANCH"
        echo " State saved to $STATE_FILE (last_ts=${LAST_COMMENT_TS})" >> "$LOGFILE"
    else
        # ── Auto-generate title from branch name if not provided ──
        if [ -z "$PR_TITLE" ]; then
            PR_TITLE=$(echo "$CURRENT_BRANCH" | sed 's/[-_]/ /g; s|/| |g')
        fi

        # ── Commit & PR creation (§4.2) ──
        echo " Starting new pr_loop run..." >> "$LOGFILE"

        # Stage all uncommitted changes
        git -C "$PROJECT_ROOT" add -A

        # Commit if there are staged changes
        if ! git -C "$PROJECT_ROOT" diff --cached --quiet; then
            git -C "$PROJECT_ROOT" commit -m "pr_loop: initial commit for review"
            echo " Committed staged changes." >> "$LOGFILE"
        else
            echo " No staged changes to commit." >> "$LOGFILE"
        fi

        # Push the branch
        git -C "$PROJECT_ROOT" push -u origin HEAD
        echo " Pushed branch '$CURRENT_BRANCH' to origin." >> "$LOGFILE"

        # Create the draft PR
        pr_body="$PR_LOOP_SIGNATURE"
        if [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
            pr_body="$(cat "$BODY_FILE")

$PR_LOOP_SIGNATURE"
        fi
        PR_CREATE_ARGS=(gh pr create --base "$BASE_BRANCH" --title "$PR_TITLE" --body "$pr_body")

        echo " Running: ${PR_CREATE_ARGS[*]}" >> "$LOGFILE"
        gh_exit=0
        PR_URL=$("${PR_CREATE_ARGS[@]}" 2>&1) || gh_exit=$?
        if [ "$gh_exit" -ne 0 ]; then
            echo "ERROR: gh pr create failed (exit $gh_exit): $PR_URL" | tee -a "$LOGFILE" >&2
            exit 1
        fi
        # Extract PR number from the returned URL
        PR_NUMBER=$(echo "$PR_URL" | grep -oP '/pull/\K[0-9]+' || true)
        if [ -z "$PR_NUMBER" ]; then
            echo "ERROR: Could not parse PR number from: $PR_URL" | tee -a "$LOGFILE" >&2
            exit 1
        fi

        echo "Created PR #${PR_NUMBER}: ${PR_URL}"
        echo " Created PR #${PR_NUMBER}: ${PR_URL}" >> "$LOGFILE"

        CYCLE=0
        LAST_COMMENT_TS=""
        save_state "$PR_NUMBER" "$CYCLE" "$LAST_COMMENT_TS" "$CURRENT_BRANCH" "$BASE_BRANCH"
        echo " State saved to $STATE_FILE" >> "$LOGFILE"
    fi
fi

# ── Summary ──
echo "pr_loop initialized."
echo "  PR: #${PR_NUMBER} | Branch: ${CURRENT_BRANCH} → ${BASE_BRANCH}"
echo "  Analyzer: ${ANALYZER} | Co-analyzer: ${CO_ANALYZER}"
echo "  Max cycles: ${MAX_CYCLES} | Wait timeout: ${WAIT_TIMEOUT}s"
echo "  Resume: ${RESUME}"
echo "  Final audit (-A): ${ENABLE_AUDIT}"
echo "Monitor progress: tail -f $LOGFILE"
echo "Inject feedback: echo 'your feedback' > $FEEDBACK_FILE"

# ── Review polling helpers (§4.3.1, §4.3.6, §4.4, §8) ──

# In -p mode REPO_SLUG was already derived from PROJECT_ROOT's origin remote
# (and canonicalized via the API); keep it. The other modes infer it from the
# invocation cwd, matching the un-scoped gh pr view/comment calls they use.
if [ -z "${REPO_SLUG:-}" ]; then
    REPO_SLUG=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
        echo "ERROR: Could not determine repo owner/name." >&2
        exit 1
    }
fi
APPROVED=false
CONSECUTIVE_EMPTY_POLLS=0
FIRST_POLL_DONE=false
# shellcheck disable=SC2034
FEEDBACK_CONTEXT=""
NEW_COMMENTS_FILE="$WORKSPACE_DIR/.new_comments.json"

# Check feedback.md for stop/exit or capture content as context (§8).
check_feedback() {
    if [ ! -s "$FEEDBACK_FILE" ]; then
        return 0
    fi
    local content
    content=$(cat "$FEEDBACK_FILE")
    if echo "$content" | grep -qiw 'stop\|exit'; then
        echo "$(date '+%H:%M:%S') Stop/exit received via feedback.md." >> "$LOGFILE"
        : > "$FEEDBACK_FILE"
        exit 0
    fi
    FEEDBACK_CONTEXT="$content"
    : > "$FEEDBACK_FILE"
    echo "$(date '+%H:%M:%S') Captured feedback (${#content} chars)." >> "$LOGFILE"
}

# Re-fetch the PR state and exit 0 if the PR is closed or merged.
# Distinct from _check_pr_status: this is a checkpoint, not a poll —
# it does NOT touch APPROVED, LAST_COMMENT_TS, or comment data.
# On a failed gh call, logs a WARN and returns (does not exit).
_assert_pr_still_open() {
    local pr_state
    pr_state=$(gh pr view "$PR_NUMBER" --json state --jq '.state' 2>/dev/null) || {
        echo "$(date '+%H:%M:%S') WARN: Failed to fetch PR status mid-cycle." >> "$LOGFILE"
        return 0
    }
    if [ "$pr_state" = "CLOSED" ] || [ "$pr_state" = "MERGED" ]; then
        echo "$(date '+%H:%M:%S') PR #${PR_NUMBER} is ${pr_state} mid-cycle. Exiting." >> "$LOGFILE"
        exit 0
    fi
}

# Check PR state and approval from pr_data JSON. Exits if closed/merged.
_check_pr_status() {
    local pr_data="$1" last_ts="$2"
    local pr_state
    pr_state=$(echo "$pr_data" | jq -r '.state')
    if [ "$pr_state" = "CLOSED" ] || [ "$pr_state" = "MERGED" ]; then
        echo "$(date '+%H:%M:%S') PR #${PR_NUMBER} is ${pr_state}. Exiting." >> "$LOGFILE"
        exit 0
    fi
    local has_approval
    has_approval=$(echo "$pr_data" | jq -r --arg ts "$last_ts" \
        '[.reviews[]? | select(.state == "APPROVED" and .submittedAt > $ts)] | length > 0')
    if [ "$has_approval" = "true" ]; then
        APPROVED=true
        echo "$(date '+%H:%M:%S') PR #${PR_NUMBER} approved." >> "$LOGFILE"
    fi
}

# Extract PR-level comments newer than a timestamp.
# Uses the REST API (issues/N/comments) to get updated_at, which catches
# bot comments that are created then edited with the full review body.
_extract_pr_comments() {
    local pr_data="$1" last_ts="$2"
    local issue_comments
    issue_comments=$(gh api "repos/${REPO_SLUG}/issues/${PR_NUMBER}/comments" 2>/dev/null) || issue_comments="[]"
    local general_comments
    general_comments=$(echo "$issue_comments" | jq -c --arg ts "$last_ts" '
        [.[]? | select(.updated_at > $ts) | {
            type: "general", author: .user.login,
            body: .body, created_at: .updated_at
        }]')
    local review_comments
    review_comments=$(echo "$pr_data" | jq -c --arg ts "$last_ts" '
        [.reviews[]? | select(.submittedAt > $ts and .body != "") | {
            type: "review", author: .author.login,
            body: .body, created_at: .submittedAt,
            review_state: .state
        }]')
    jq -sc '.[0] + .[1]' <(echo "$general_comments") <(echo "$review_comments")
}

# Fetch inline review comments newer than a timestamp via GitHub API.
_fetch_inline_comments() {
    local last_ts="$1"
    local inline_raw
    inline_raw=$(gh api "repos/${REPO_SLUG}/pulls/${PR_NUMBER}/comments" 2>/dev/null) || inline_raw="[]"
    echo "$inline_raw" | jq -c --arg ts "$last_ts" '
        [.[]? | select((.updated_at // .created_at) > $ts) | {
            type: "inline", author: .user.login,
            body: .body, created_at: (.updated_at // .created_at),
            path: .path,
            line: (.line // .original_line // null),
            id: .id, in_reply_to_id: .in_reply_to_id
        }]'
}

# Update LAST_COMMENT_TS to the max timestamp in a comment array.
_update_last_comment_ts() {
    local all_new="$1"
    local latest_ts
    latest_ts=$(echo "$all_new" | jq -r \
        'if length > 0 then [.[].created_at] | max else empty end' 2>/dev/null) || true
    if [ -n "$latest_ts" ] && [ "$latest_ts" != "null" ]; then
        LAST_COMMENT_TS="$latest_ts"
    fi
}

# Scan a JSON array of new comments for natural-language approval phrases.
# Sets APPROVED=true on first match. Logs the matching phrase and author.
_detect_nl_approval() {
    local all_new="$1"
    local body author lc
    while IFS=$'\t' read -r body author; do
        [ -n "$body" ] || continue
        # Trim whitespace, lowercase, strip all trailing punct/emoji/whitespace
        lc=$(printf '%s' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            | tr '[:upper:]' '[:lower:]' \
            | sed -E 's/[[:space:]!.🚀👍]+$//')
        case "$lc" in
            lgtm|"looks good to me"|"looks good"|"ready to merge"|"good to merge"|"good to ship"|"ship it"|":shipit:"|approved)
                APPROVED=true
                echo "$(date '+%H:%M:%S') PR #${PR_NUMBER} natural-language approval detected (\"${lc}\" by ${author}). Will exit after this poll round." >> "$LOGFILE"
                return 0
                ;;
        esac
    done < <(echo "$all_new" | jq -r '.[] | [(.body // ""), (.author // "unknown")] | @tsv')
}

# Fetch and filter new PR comments. Updates LAST_COMMENT_TS. May set APPROVED.
# Exits 0 if PR closed/merged. Returns:
#   0 — new comments found
#   1 — no new comments (successful fetch)
#   2 — fetch failed (API error)
fetch_new_comments() {
    local last_ts="${LAST_COMMENT_TS:-}"
    local pr_data
    pr_data=$(gh pr view "$PR_NUMBER" --json 'reviews,comments,state' 2>/dev/null) || {
        echo "$(date '+%H:%M:%S') WARN: Failed to fetch PR data." >> "$LOGFILE"
        return 2
    }
    _check_pr_status "$pr_data" "$last_ts"
    local pr_comments inline_new all_new count
    pr_comments=$(_extract_pr_comments "$pr_data" "$last_ts")
    inline_new=$(_fetch_inline_comments "$last_ts")
    # Merge comments, filtering out only the script's own posts (tagged
    # with the hidden marker). All other comments — human reviewers,
    # CI bots, code review tools — are treated as actionable feedback.
    all_new=$(jq -sc --arg marker "pr_loop:self" '
        .[0] + .[1]
        | [.[] | select(.body | contains($marker) | not)]
        | sort_by(.created_at)
    ' <(echo "$pr_comments") <(echo "$inline_new"))
    echo "$all_new" > "$NEW_COMMENTS_FILE"
    _update_last_comment_ts "$all_new"
    _detect_nl_approval "$all_new"
    count=$(echo "$all_new" | jq 'length')
    if [ "$count" -gt 0 ]; then
        echo "$(date '+%H:%M:%S') Found ${count} new comment(s)." >> "$LOGFILE"
        return 0
    fi
    return 1
}

# Poll for new reviewer comments at regular intervals (§4.3.1).
# Returns:
#   0 — new comments found
#   1 — no new comments (at least one successful fetch confirmed empty)
#   2 — timed out, but every fetch failed (API errors); no confirmed empty poll
# Exits 0 on closed/approved-no-comments or single-check mode (-T 0).
poll_for_comments() {
    local elapsed=0
    local had_successful_empty=false
    local frc=0
    fetch_new_comments || frc=$?
    if [ "$frc" -eq 0 ]; then
        return 0
    fi
    [ "$frc" -eq 1 ] && had_successful_empty=true
    if [ "$APPROVED" = true ]; then
        echo "$(date '+%H:%M:%S') PR approved with no new feedback. Exiting." >> "$LOGFILE"
        run_final_audit
        exit 0
    fi
    if [ "$WAIT_TIMEOUT" -eq 0 ]; then
        echo "$(date '+%H:%M:%S') No new comments (single-check mode). Exiting." >> "$LOGFILE"
        exit 0
    fi
    while [ "$elapsed" -lt "$WAIT_TIMEOUT" ]; do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        check_feedback
        echo "$(date '+%H:%M:%S') Polling... (${elapsed}/${WAIT_TIMEOUT}s)" >> "$LOGFILE"
        frc=0
        fetch_new_comments || frc=$?
        if [ "$frc" -eq 0 ]; then
            return 0
        fi
        [ "$frc" -eq 1 ] && had_successful_empty=true
        if [ "$APPROVED" = true ]; then
            echo "$(date '+%H:%M:%S') PR approved with no new feedback. Exiting." >> "$LOGFILE"
            run_final_audit
            exit 0
        fi
    done
    echo "$(date '+%H:%M:%S') Timeout (${WAIT_TIMEOUT}s) with no new comments." >> "$LOGFILE"
    if [ "$had_successful_empty" = true ]; then
        return 1
    fi
    return 2
}

# Post a PR comment with the self-marker and signature.
post_marked_comment() {
    local body="$1"
    gh pr comment "$PR_NUMBER" --body "${PR_LOOP_MARKER}
${body}

${PR_LOOP_SIGNATURE}" 2>/dev/null
}

# Post completion comment when max_cycles reached (§4.4).
post_completion_comment() {
    local body="Automated review cycle stopped after reaching the configured limit"
    body+=" of ${MAX_CYCLES} cycle(s). Further review comments may need human follow-up."
    post_marked_comment "$body" || {
        echo "$(date '+%H:%M:%S') WARN: Failed to post completion comment." >> "$LOGFILE"
    }
    echo "$(date '+%H:%M:%S') Posted completion comment on PR #${PR_NUMBER}." >> "$LOGFILE"
}

# ── Final audit hand-off (-A) ──
# Invoke the standalone mesh auditor (audit_pr_review.sh) as a discrete
# orchestration step once the review-fix loop finishes (settled, approved,
# or max cycles). The auditor posts its own approve/request-changes review
# directly on the PR (posting is its default behavior). pr_loop deliberately
# does NOT parse the auditor's output or verdict, does NOT set APPROVED from
# it, and does NOT alter loop control flow based on it — this is a hand-off,
# not a gate. The auditor's posted review carries no pr_loop:self marker, so
# a still-running pr_loop instance will surface it as ordinary reviewer
# input on a later poll; that is intended — do NOT add the marker to it.
# Always returns 0 (set -e safe at every call site).
AUDIT_RAN=false
run_final_audit() {
    [ "$ENABLE_AUDIT" = true ] || return 0
    # Belt-and-suspenders: every call site exits immediately afterward, but
    # guard against a future edit chaining two exit paths in one run.
    if [ "$AUDIT_RAN" = true ]; then
        return 0
    fi
    AUDIT_RAN=true
    echo "$(date '+%H:%M:%S') Running final audit: bash $AUDIT_SCRIPT -p $PR_NUMBER -d $PROJECT_ROOT" >> "$LOGFILE"
    local audit_rc=0
    bash "$AUDIT_SCRIPT" -p "$PR_NUMBER" -d "$PROJECT_ROOT" >> "$LOGFILE" 2>&1 || audit_rc=$?
    if [ "$audit_rc" -ne 0 ]; then
        echo "$(date '+%H:%M:%S') WARN: audit_pr_review.sh exited non-zero (exit ${audit_rc}); its posted verdict may be missing or partial. pr_loop exits normally regardless." >> "$LOGFILE"
    else
        echo "$(date '+%H:%M:%S') Final audit completed." >> "$LOGFILE"
    fi
    echo "$(date '+%H:%M:%S') REMINDER: read the auditor's posted review verdict on PR #${PR_NUMBER} before merging." >> "$LOGFILE"
    return 0
}

# ── Phase 3: Triage, Fixes & Rebuttals (§4.3.2–§4.3.5, §7) ──

AGENT_LOOP="$SCRIPT_DIR/agent_loop.sh"
REVIEW_COMMENTS_FILE="$WORKSPACE_DIR/review_comments.md"
TRIAGE_FILE="$WORKSPACE_DIR/triage.md"
FIX_SPEC_FILE="$WORKSPACE_DIR/fix_spec.md"
CHANGES_FILE="$WORKSPACE_DIR/changes.md"
TRIAGE_OUT="$WORKSPACE_DIR/.triage_out.txt"

# Format raw JSON comments into structured review_comments.md (§4.3.2).
format_comments_md() {
    local cycle="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
    local formatted count
    count=$(jq 'length' "$NEW_COMMENTS_FILE")
    formatted=$(jq -r '
        to_entries[]
        | .key as $idx
        | .value as $comment
        | ($comment.author // "unknown") as $author
        | ($comment.body // "" | gsub("\n+$"; "")) as $body
        | ($comment.type // "") as $comment_type
        | ($comment.path // "") as $path
        | ($comment.line // "") as $line
        | (
            if $comment_type == "inline" and ($path | length) > 0 then
                "on \($path)" + (
                    if (($line | tostring) != "" and ($line | tostring) != "null") then
                        ":\($line)"
                    else
                        ""
                    end
                )
            else
                "general"
            end
          ) as $location
        | "### Comment \($idx + 1) (by @\($author), \($location))",
          ($body | split("\n")[] | "> \(.)"),
          ""
    ' "$NEW_COMMENTS_FILE")

    {
        echo "## Review Cycle ${cycle} — Comments received ${timestamp}"
        echo ""
        if [ -n "$formatted" ]; then
            printf '%s\n\n' "$formatted"
        fi
    } > "$REVIEW_COMMENTS_FILE"

    echo "$(date '+%H:%M:%S') Wrote ${count} comment(s) to review_comments.md." >> "$LOGFILE"
}

# Check if Agent B changed any dispositions compared to the previous triage.
# Returns 0 if dispositions changed, 1 if unchanged.
# REBUTTAL-SKIP must be listed before REBUTTAL in the alternation, otherwise
# POSIX ERE alternation matches REBUTTAL first and leaves -SKIP] outside.
_triage_dispositions_changed() {
    local prev_triage="$1" curr_triage="$2"
    local prev_dispositions curr_dispositions
    prev_dispositions=$(grep -oE '\[(REBUTTAL-SKIP|ACCEPT|REBUTTAL)\]' "$prev_triage" 2>/dev/null | sort)
    curr_dispositions=$(grep -oE '\[(REBUTTAL-SKIP|ACCEPT|REBUTTAL)\]' "$curr_triage" 2>/dev/null | sort)
    if [ "$prev_dispositions" != "$curr_dispositions" ]; then
        return 0
    fi
    # Also check line-by-line pairing: same count but different order/assignment
    local prev_lines curr_lines
    prev_lines=$(grep -E '###.*\[(REBUTTAL-SKIP|ACCEPT|REBUTTAL)\]' "$prev_triage" 2>/dev/null)
    curr_lines=$(grep -E '###.*\[(REBUTTAL-SKIP|ACCEPT|REBUTTAL)\]' "$curr_triage" 2>/dev/null)
    [ "$prev_lines" != "$curr_lines" ]
}

# Resolve disputed dispositions after max negotiation rounds (§4.3.2 step 4).
# Compares Agent B's round-2 triage with Agent A's round-3 triage.
# With three dispositions there are six dispute pairs; the function rewrites
# Agent A's line to match the resolution table from spec §2:
#
#   A=ACCEPT       B=REBUTTAL      → ACCEPT          (existing default)
#   A=REBUTTAL     B=ACCEPT        → ACCEPT          (existing default)
#   A=ACCEPT       B=REBUTTAL-SKIP → ACCEPT          (A wants a fix; honor it)
#   A=REBUTTAL-SKIP B=ACCEPT       → ACCEPT          (B wants a fix; honor it)
#   A=REBUTTAL     B=REBUTTAL-SKIP → REBUTTAL-SKIP   (one agent saw a dup)
#   A=REBUTTAL-SKIP B=REBUTTAL     → REBUTTAL-SKIP   (symmetrical)
#
# The code-fix outcome (ACCEPT) requires both agents to agree on ACCEPT, or
# at least one of them to vote ACCEPT in a SKIP-vs-ACCEPT pair. A REBUTTAL-vs-
# REBUTTAL-SKIP disagreement defaults to SKIP, never to ACCEPT — converting a
# disagreement into a code fix is the worst outcome (it implements something
# the team may not want).
#
# Rewriting uses literal-substring substitution (`${line/\[X\]/[Y]}`) so
# `[REBUTTAL]` substitution never accidentally matches inside `[REBUTTAL-SKIP]`.
_resolve_disputed_dispositions() {
    local agent_b_file="$1" agent_a_file="$2"

    # Build comment-number → line maps for each file. Pairing by Comment number
    # — not by array index — is essential: if one agent silently omits a
    # disposition header (e.g., dropping a duplicate entirely instead of
    # tagging it as REBUTTAL-SKIP), index-based pairing would mis-align every
    # subsequent item against the wrong comment. With REBUTTAL-SKIP in the
    # vocabulary, the "skip the line entirely" failure mode is plausible
    # enough that the join key has to be the comment number.
    #
    # NOTE: associative arrays require bash 4.0+. mesh's CI is Linux which
    # ships bash 5+, so this is fine. macOS ships bash 3.2 by default —
    # anyone running mesh tooling on a Mac must `brew install bash` and
    # invoke via /usr/local/bin/bash.
    declare -A a_line_for=() b_line_for=()
    local line cnum
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        cnum=$(echo "$line" | grep -oE 'Comment [0-9]+' | grep -oE '[0-9]+' || true)
        [ -n "$cnum" ] && a_line_for[$cnum]="$line"
    done < <(grep -E '###.*\[(REBUTTAL-SKIP|ACCEPT|REBUTTAL)\]' "$agent_a_file" 2>/dev/null || true)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        cnum=$(echo "$line" | grep -oE 'Comment [0-9]+' | grep -oE '[0-9]+' || true)
        [ -n "$cnum" ] && b_line_for[$cnum]="$line"
    done < <(grep -E '###.*\[(REBUTTAL-SKIP|ACCEPT|REBUTTAL)\]' "$agent_b_file" 2>/dev/null || true)

    # Fast path: same set of comment numbers AND every line is byte-identical
    # → no disputes to resolve.
    if [ "${#a_line_for[@]}" -eq "${#b_line_for[@]}" ]; then
        local same=true
        for cnum in "${!a_line_for[@]}"; do
            if [ "${a_line_for[$cnum]:-}" != "${b_line_for[$cnum]:-}" ]; then
                same=false
                break
            fi
        done
        if [ "$same" = true ]; then
            return 0
        fi
    fi

    # Map from disputed comment number → resolution disposition (ACCEPT or
    # REBUTTAL-SKIP). Iterate over Agent A's keys: A is the file we rewrite,
    # so we can only resolve comments A has a line for. If B is silent on a
    # given comment, A's vote stands (we can't infer disagreement from absence).
    declare -A resolution_for=()
    local resolved=0
    local a_disp b_disp resolution
    for cnum in "${!a_line_for[@]}"; do
        # B has no opinion on this comment (silently dropped) → no dispute.
        [ -z "${b_line_for[$cnum]:-}" ] && continue

        a_disp=$(echo "${a_line_for[$cnum]}" | grep -oE '\[(REBUTTAL-SKIP|ACCEPT|REBUTTAL)\]')
        b_disp=$(echo "${b_line_for[$cnum]}" | grep -oE '\[(REBUTTAL-SKIP|ACCEPT|REBUTTAL)\]')
        if [ "$a_disp" = "$b_disp" ]; then
            continue
        fi

        # Pair lookup — table from §2.
        if [ "$a_disp" = "[ACCEPT]" ] || [ "$b_disp" = "[ACCEPT]" ]; then
            resolution="[ACCEPT]"
        else
            # Both are REBUTTAL/REBUTTAL-SKIP variants but they differ —
            # so one is REBUTTAL and the other REBUTTAL-SKIP. Resolve to SKIP.
            resolution="[REBUTTAL-SKIP]"
        fi

        if [ "$resolution" = "$a_disp" ]; then
            # Agent A's line already matches the resolution; nothing to rewrite.
            continue
        fi

        resolution_for[$cnum]="$resolution"
        resolved=$((resolved + 1))
    done

    if [ "$resolved" -eq 0 ]; then
        return 0
    fi

    # Rewrite the triage file line by line. Use literal `[X]` substitutions
    # so `[REBUTTAL]` never matches inside `[REBUTTAL-SKIP]`.
    local tmpfile="${agent_a_file}.tmp"
    : > "$tmpfile"
    while IFS= read -r line; do
        if [[ "$line" =~ Comment\ ([0-9]+): ]]; then
            cnum="${BASH_REMATCH[1]}"
        else
            cnum=""
        fi
        if [ -n "$cnum" ] && [ -n "${resolution_for[$cnum]:-}" ]; then
            local target="${resolution_for[$cnum]}"
            local rewritten_line="$line"
            # Try each literal source disposition; only one will match this line.
            if [[ "$rewritten_line" == *"[REBUTTAL-SKIP]"* ]]; then
                rewritten_line="${rewritten_line/\[REBUTTAL-SKIP\]/$target}"
            elif [[ "$rewritten_line" == *"[REBUTTAL]"* ]]; then
                rewritten_line="${rewritten_line/\[REBUTTAL\]/$target}"
            elif [[ "$rewritten_line" == *"[ACCEPT]"* ]]; then
                rewritten_line="${rewritten_line/\[ACCEPT\]/$target}"
            fi
            echo "$rewritten_line" >> "$tmpfile"
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$agent_a_file"
    mv "$tmpfile" "$agent_a_file"

    echo "$(date '+%H:%M:%S') Resolved ${resolved} disputed item(s) per dispute table." >> "$LOGFILE"
}

# Run multi-agent triage negotiation (§4.3.2).
run_triage() {
    local cycle="$1"
    local round=0
    local prev_triage_snapshot="$WORKSPACE_DIR/.triage_prev.md"
    local review_content feedback_extra=""

    review_content=$(cat "$REVIEW_COMMENTS_FILE")
    if [ -n "$FEEDBACK_CONTEXT" ]; then
        feedback_extra="

Additional context from the human:
${FEEDBACK_CONTEXT}"
    fi

    # Build prior_history_block ONCE so all three rounds see byte-identical
    # history. Reading $CHANGES_FILE more than once per cycle would risk
    # picking up the cycle's own in-progress triage if it were appended
    # mid-run. Tail-cap via PR_LOOP_HISTORY_TAIL_LINES to keep the prompt
    # manageable on long-running PRs — see the constant's docstring near
    # the top of this file for the truncation trade-off and override.
    local prior_history_block=""
    if [ -s "$CHANGES_FILE" ]; then
        local history_tail_lines="$PR_LOOP_HISTORY_TAIL_LINES"
        prior_history_block="

## Prior review history on this PR

The following is the audit trail of earlier review cycles on this same PR,
including which comments were ACCEPTed (and fixed) and which were REBUTTALed
(with rationale). If a current reviewer comment re-raises an issue that was
already rebutted with substantially the same reasoning, mark it as
\`[REBUTTAL-SKIP]\` instead of \`[REBUTTAL]\`. The runner will keep your
triage decision in the audit trail but will NOT post a duplicate rebuttal
comment on the PR.

\`\`\`
$(tail -n "${history_tail_lines}" "$CHANGES_FILE")
\`\`\`
"
    fi

    # Keep hidden vendor session history bounded to this PR review cycle.
    # Cross-cycle memory is carried explicitly through the capped changes.md
    # history block above, so long-running PR loops do not accumulate every
    # prior triage turn in the resumed agent session.
    local analyzer_session_key="pr_triage_analyzer_cycle_${cycle}"
    local co_analyzer_session_key="pr_triage_co_analyzer_cycle_${cycle}"

    # Round 1: Agent A writes initial triage
    round=1
    echo "$(date '+%H:%M:%S') Triage round ${round}: Agent A (${ANALYZER})..." >> "$LOGFILE"
    local triage_prompt_a
    triage_prompt_a="You are triaging PR review comments. Read the review comments below and produce a triage.

For each comment, decide: ACCEPT (we should fix this), REBUTTAL (we disagree and will explain why), or REBUTTAL-SKIP (this is a duplicate rebuttal — the same issue was already rebutted in a prior cycle, so we should not post the rebuttal again).

Decision policy — be decisive; minimize review round-trips:
- Default to ACCEPT for trivial nits: style, naming, typos, comment or doc wording, log-message phrasing, and other low-risk suggestions. A one-line fix now is cheaper than another review round arguing about it. Do not rebut a nit.
- Reserve REBUTTAL for substantive technical disagreement, requests that are out of scope for this PR, or cases where the requested change would be incorrect or harmful. State the reason plainly in the Plan line.
- REBUTTAL is also the correct disposition when the reviewer comment is itself wrong: a false positive, a factual error, or a claim based on a misreading of the code. Do not ACCEPT a change just to appease a mistaken comment — rebut it, citing the actual code behavior in the Plan line.
- Use REBUTTAL-SKIP only for a duplicate of an already-rebutted issue from a prior cycle.
- Every comment gets exactly one clear disposition. No deferring, no hedging, no new tags — never leave a comment without a disposition.

Write your triage to the file $TRIAGE_FILE in this exact format:

## Triage — Cycle ${cycle}

### Comment N: [ACCEPT]
Plan: <terse fix plan; preserve exact paths/symbols>

### Comment N: [REBUTTAL]
Plan: <terse rebuttal rationale>

### Comment N: [REBUTTAL-SKIP]
Plan: <terse duplicate rationale — reference prior cycle>

Here are the review comments:

${review_content}${feedback_extra}${prior_history_block}"

    run_agent_turn_with_retry "$ANALYZER" "$analyzer_session_key" "$triage_prompt_a" "$TRIAGE_OUT" || {
        echo "$(date '+%H:%M:%S') ERROR: Agent A triage failed." >> "$LOGFILE"
        return 1
    }

    # Copy triage for comparison
    cp "$TRIAGE_FILE" "$prev_triage_snapshot" 2>/dev/null || true

    # Round 2: Agent B reviews and may edit
    round=2
    echo "$(date '+%H:%M:%S') Triage round ${round}: Agent B (${CO_ANALYZER}) reviewing..." >> "$LOGFILE"
    local triage_content_b
    triage_content_b=$(cat "$TRIAGE_FILE" 2>/dev/null || echo "(empty)")
    local triage_prompt_b
    triage_prompt_b="You are the second reviewer in a triage negotiation for PR review comments.

Read the original review comments and the initial triage below. If you agree with all dispositions, leave the triage file unchanged. If you disagree with any disposition (ACCEPT vs REBUTTAL vs REBUTTAL-SKIP), edit the file $TRIAGE_FILE with your changes. Use REBUTTAL-SKIP when the comment re-raises an issue already rebutted in a prior cycle (see history below).

Original review comments:
${review_content}

Current triage:
${triage_content_b}${feedback_extra}${prior_history_block}"

    run_agent_turn_with_retry "$CO_ANALYZER" "$co_analyzer_session_key" "$triage_prompt_b" "$TRIAGE_OUT" || {
        echo "$(date '+%H:%M:%S') ERROR: Agent B triage failed." >> "$LOGFILE"
        return 1
    }

    # Option A second-opinion plumbing for the stateless oss reviewer.
    # oss has no file-edit tools, so its response went only to TRIAGE_OUT
    # and triage.md is still Agent A's round-1 content. Append the oss
    # commentary to triage.md as a "Second Opinion" appendix so round 3's
    # analyzer can see it, and force round 3 (dispositions_changed below
    # checks only bracketed [ACCEPT]/[REBUTTAL]/[REBUTTAL-SKIP] tags, so
    # an appended prose block alone wouldn't trigger it).
    local force_round3=false
    if [ "$CO_ANALYZER" = "oss" ] && [ -s "$TRIAGE_OUT" ]; then
        {
            echo ""
            echo "---"
            echo "## Second Opinion (oss, round 2)"
            echo ""
            cat "$TRIAGE_OUT"
            echo ""
        } >> "$TRIAGE_FILE"
        force_round3=true
        echo "$(date '+%H:%M:%S') Appended OSS second opinion to triage.md (round 3 will follow)." >> "$LOGFILE"
    fi

    # Check if Agent B changed dispositions; if so, give Agent A one more round
    if [ -f "$prev_triage_snapshot" ] && [ -f "$TRIAGE_FILE" ] && \
       { [ "$force_round3" = true ] || _triage_dispositions_changed "$prev_triage_snapshot" "$TRIAGE_FILE"; }; then
        # Save Agent B's round-2 output before Agent A's round 3
        local agent_b_triage="$WORKSPACE_DIR/.triage_agent_b.md"
        cp "$TRIAGE_FILE" "$agent_b_triage"

        round=3
        echo "$(date '+%H:%M:%S') Triage round ${round}: Agent A final review (dispositions changed)..." >> "$LOGFILE"
        local triage_content_a2
        triage_content_a2=$(cat "$TRIAGE_FILE" 2>/dev/null || echo "(empty)")
        local triage_prompt_a2 round3_intro
        if [ "$CO_ANALYZER" = "oss" ]; then
            round3_intro="The co-reviewer (oss) left a Second Opinion appendix on the triage. Review it. If you agree with any of its critiques, edit $TRIAGE_FILE to revise the affected disposition(s). If you disagree, leave the dispositions as they are. You may keep, edit, or remove the Second Opinion section itself when rewriting; the audit trail captures the final triage.md as the authoritative record."
        else
            round3_intro="The co-reviewer changed some triage dispositions. Review the updated triage below.
If you still disagree on any items, edit $TRIAGE_FILE."
        fi
        triage_prompt_a2="${round3_intro} Any items still in dispute after this round will be resolved by the dispute table: ACCEPT wins over REBUTTAL/REBUTTAL-SKIP; REBUTTAL vs REBUTTAL-SKIP resolves to REBUTTAL-SKIP.

Original review comments:
${review_content}

Updated triage:
${triage_content_a2}${prior_history_block}"

        run_agent_turn_with_retry "$ANALYZER" "$analyzer_session_key" "$triage_prompt_a2" "$TRIAGE_OUT" || {
            echo "$(date '+%H:%M:%S') WARN: Agent A final triage round failed. Using Agent B's triage." >> "$LOGFILE"
        }

        # Resolve disputed items: where Agent A (round 3) and Agent B (round 2)
        # still disagree, apply the §2 dispute resolution table
        # (ACCEPT/REBUTTAL/REBUTTAL-SKIP pairs).
        _resolve_disputed_dispositions "$agent_b_triage" "$TRIAGE_FILE"
        rm -f "$agent_b_triage"
    fi

    rm -f "$prev_triage_snapshot"

    # Append final triage to changes.md audit trail
    {
        echo ""
        echo "---"
        echo "## Triage — Cycle ${cycle} ($(date '+%Y-%m-%dT%H:%M:%SZ'))"
        cat "$TRIAGE_FILE" 2>/dev/null
        echo ""
    } >> "$CHANGES_FILE"

    echo "$(date '+%H:%M:%S') Triage complete (${round} round(s)). Appended to changes.md." >> "$LOGFILE"
    return 0
}

# Generate fix_spec.md from ACCEPT items in triage (§4.3.3).
generate_fix_spec() {
    local cycle="$1"
    local triage_content
    triage_content=$(cat "$TRIAGE_FILE" 2>/dev/null)

    if [ -z "$triage_content" ]; then
        echo "$(date '+%H:%M:%S') WARN: triage.md is empty; no fix spec to generate." >> "$LOGFILE"
        : > "$FIX_SPEC_FILE"
        return 0
    fi

    # Extract ACCEPT blocks: each starts with ### Comment N: [ACCEPT] and ends before next ###
    local has_accepts=false
    {
        echo "# Fix Spec — Cycle ${cycle}"
        echo ""
        echo "Implement the following fixes based on reviewer feedback:"
        echo ""
    } > "$FIX_SPEC_FILE"

    # Parse triage.md: extract comment header + plan for ACCEPT items
    local in_accept=false
    local fix_num=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^### Comment.*\[ACCEPT\]'; then
            in_accept=true
            has_accepts=true
            fix_num=$((fix_num + 1))
            echo "## Fix ${fix_num}" >> "$FIX_SPEC_FILE"
            # Extract comment reference
            echo "${line//\[ACCEPT\]/}" >> "$FIX_SPEC_FILE"
        elif echo "$line" | grep -qE '^### Comment'; then
            in_accept=false
        elif [ "$in_accept" = true ] && [ -n "$line" ]; then
            echo "$line" >> "$FIX_SPEC_FILE"
        fi
    done < "$TRIAGE_FILE"

    if [ "$has_accepts" = true ]; then
        echo "$(date '+%H:%M:%S') Generated fix spec with ${fix_num} item(s)." >> "$LOGFILE"
    else
        echo "$(date '+%H:%M:%S') No ACCEPT items in triage; fix spec is empty." >> "$LOGFILE"
        : > "$FIX_SPEC_FILE"
    fi
    return 0
}

# Invoke agent_loop.sh to implement fixes (§4.3.3).
# Returns 0 on success, non-zero on failure.
run_fixes() {
    if [ ! -s "$FIX_SPEC_FILE" ]; then
        echo "$(date '+%H:%M:%S') No fixes to implement (fix_spec.md is empty)." >> "$LOGFILE"
        return 0
    fi

    if [ ! -f "$AGENT_LOOP" ]; then
        echo "$(date '+%H:%M:%S') ERROR: agent_loop.sh not found at $AGENT_LOOP" >> "$LOGFILE"
        return 1
    fi

    echo "$(date '+%H:%M:%S') Running agent_loop.sh for fixes..." >> "$LOGFILE"
    # Use an isolated workspace for each cycle so agent_loop doesn't see
    # stale plans/state from the main agent_loop workspace or prior cycles.
    # Place it in /tmp so `git add -A` in commit_and_push_fixes doesn't
    # sweep the workspace state into the user's PR.
    local cycle_workspace
    cycle_workspace="$(mktemp -d -t pr_loop_cycle_${CYCLE}_XXXXXX)"
    local rc=0

    # Forward pr_loop's agent choices to agent_loop so its fix-implementation
    # phase respects -i/-r. Without this, agent_loop falls back to its own
    # defaults (claude impl, codex review), which silently re-introduces
    # codex even when the user passed -r claude/-r oss to avoid it.
    #
    # agent_loop has no 'oss' code path (it depends on session continuity +
    # tool surface); when oss is in pr_loop's -r seat, substitute the
    # partner agent so agent_loop still gets two valid choices. If both
    # pr_loop seats end up resolving to the same agent, agent_loop will
    # accept that — claude reviewing claude is a valid (if redundant) mode.
    local impl_agent="$ANALYZER"
    local review_agent="$CO_ANALYZER"
    if [ "$review_agent" = "oss" ]; then
        # ANALYZER is guaranteed non-oss here (validation above rejects -i oss).
        # Fall back to the partner so agent_loop sees a tool-capable reviewer.
        review_agent="$impl_agent"
    fi

    bash "$AGENT_LOOP" -d "$PROJECT_ROOT" -w "$cycle_workspace" \
        -i "$impl_agent" -r "$review_agent" \
        -f "$FIX_SPEC_FILE" -1 >> "$LOGFILE" 2>&1 || rc=$?
    # Clean up after the run (keeps /tmp tidy; state is no longer needed)
    rm -rf "$cycle_workspace"

    if [ "$rc" -ne 0 ]; then
        echo "$(date '+%H:%M:%S') ERROR: agent_loop.sh exited with code ${rc}." >> "$LOGFILE"
        # Post failure notification to PR (§7)
        local fail_body="agent_loop.sh failed (exit ${rc}) while implementing fixes for review cycle ${CYCLE}. Human intervention needed."
        post_marked_comment "$fail_body" || {
            echo "$(date '+%H:%M:%S') WARN: Failed to post agent_loop failure comment." >> "$LOGFILE"
        }
        return "$rc"
    fi

    echo "$(date '+%H:%M:%S') agent_loop.sh completed successfully." >> "$LOGFILE"
    return 0
}

# Build the per-cycle fingerprint dedup cache (§3 safety net).
#
# Fetches every self-authored comment on the PR (issue + review-thread),
# filters by ${PR_LOOP_MARKER}, extracts every embedded
# `pr_loop:rebuttal-for:<hash>` substring, and writes the unique hashes (one
# per line) to $WORKSPACE_DIR/.rebuttal_fingerprints. The companion check in
# `_post_single_rebuttal` then suppresses any rebuttal whose computed
# fingerprint matches a hash already in this file.
#
# `--paginate` is used so a long-running PR with hundreds of comments doesn't
# silently truncate the cache and cause false negatives. It also makes the
# call distinguishable from the new-comment poll for test mocks.
#
# On fetch failure (network, rate limit), this is non-fatal: a warning is
# logged and the cache is left empty. The triage-history fix in §1 is the
# primary defense; this fingerprint check is the safety net and only needs
# to be "usually right".
_load_existing_rebuttal_fingerprints() {
    local cache_file="$WORKSPACE_DIR/.rebuttal_fingerprints"
    : > "$cache_file"

    echo "$(date '+%H:%M:%S') Building rebuttal fingerprint cache..." >> "$LOGFILE"

    local issue_comments review_comments fetch_ok=true
    issue_comments=$(gh api --paginate "repos/${REPO_SLUG}/issues/${PR_NUMBER}/comments" 2>/dev/null) || {
        fetch_ok=false
        issue_comments="[]"
    }
    review_comments=$(gh api --paginate "repos/${REPO_SLUG}/pulls/${PR_NUMBER}/comments" 2>/dev/null) || {
        fetch_ok=false
        review_comments="[]"
    }

    if [ "$fetch_ok" = false ]; then
        echo "$(date '+%H:%M:%S') WARN: Partial fetch failure for fingerprint cache; continuing with available data." >> "$LOGFILE"
    fi

    # Extract bodies that contain PR_LOOP_MARKER, then pull every embedded
    # rebuttal-for hash. `sort -u` keeps the file deduplicated.
    {
        printf '%s\n' "$issue_comments" | jq -r --arg marker "$PR_LOOP_MARKER" \
            '.[]? | select((.body // "") | contains($marker)) | .body' 2>/dev/null || true
        printf '%s\n' "$review_comments" | jq -r --arg marker "$PR_LOOP_MARKER" \
            '.[]? | select((.body // "") | contains($marker)) | .body' 2>/dev/null || true
    } | grep -oE 'pr_loop:rebuttal-for:[a-f0-9]+' \
      | sed 's/^pr_loop:rebuttal-for://' \
      | sort -u > "$cache_file" || true
}

# Post rebuttals for REBUTTAL items (§4.3.4).
#
# The branch patterns below are intentionally narrow:
#   `^### Comment.*\[REBUTTAL\]`      matches REBUTTAL only (the trailing `]`
#                                      boundary excludes `-SKIP]`)
#   `^### Comment.*\[ACCEPT\]`         matches ACCEPT only
#   `^### Comment.*\[REBUTTAL-SKIP\]`  matches REBUTTAL-SKIP only
# Do NOT broaden any of these patterns: REBUTTAL-SKIP must NOT trigger a post.
post_rebuttals() {
    local triage_content comments_json
    triage_content=$(cat "$TRIAGE_FILE" 2>/dev/null)
    comments_json=$(cat "$NEW_COMMENTS_FILE" 2>/dev/null)

    if [ -z "$triage_content" ]; then
        return 0
    fi

    # Build the per-cycle dedup cache once, before any rebuttal is posted.
    # _post_single_rebuttal will read $WORKSPACE_DIR/.rebuttal_fingerprints
    # to skip rebuttals whose fingerprint already exists on the PR.
    _load_existing_rebuttal_fingerprints

    local comment_idx=-1
    local in_rebuttal=false
    local rebuttal_plan=""
    local rebuttal_count=0
    local rebuttals_skipped_triage=0
    local rebuttals_skipped_post=0

    while IFS= read -r line; do
        if echo "$line" | grep -qE '^### Comment.*\[REBUTTAL\]'; then
            # If we had a pending rebuttal, post it first
            if [ "$in_rebuttal" = true ] && [ -n "$rebuttal_plan" ]; then
                if _post_single_rebuttal "$comment_idx" "$rebuttal_plan" "$comments_json"; then
                    rebuttal_count=$((rebuttal_count + 1))
                else
                    rebuttals_skipped_post=$((rebuttals_skipped_post + 1))
                fi
            fi
            in_rebuttal=true
            rebuttal_plan=""
            # Extract comment number (1-indexed) from "### Comment N:"
            comment_idx=$(echo "$line" | grep -oE 'Comment [0-9]+' | grep -oE '[0-9]+')
            comment_idx=$((comment_idx - 1))  # Convert to 0-indexed for JSON
        elif echo "$line" | grep -qE '^### Comment.*\[REBUTTAL-SKIP\]'; then
            # Triage marked this as a duplicate of a prior rebuttal — terminate
            # any pending rebuttal block (post it) and increment the skip counter.
            # The SKIP block itself produces no PR comment.
            if [ "$in_rebuttal" = true ] && [ -n "$rebuttal_plan" ]; then
                if _post_single_rebuttal "$comment_idx" "$rebuttal_plan" "$comments_json"; then
                    rebuttal_count=$((rebuttal_count + 1))
                else
                    rebuttals_skipped_post=$((rebuttals_skipped_post + 1))
                fi
            fi
            in_rebuttal=false
            rebuttal_plan=""
            rebuttals_skipped_triage=$((rebuttals_skipped_triage + 1))
            local skip_idx
            skip_idx=$(echo "$line" | grep -oE 'Comment [0-9]+' | grep -oE '[0-9]+')
            echo "$(date '+%H:%M:%S') Skipped duplicate rebuttal for comment ${skip_idx} (triage marked REBUTTAL-SKIP)." >> "$LOGFILE"
        elif echo "$line" | grep -qE '^### Comment.*\[ACCEPT\]'; then
            # Post pending rebuttal if any
            if [ "$in_rebuttal" = true ] && [ -n "$rebuttal_plan" ]; then
                if _post_single_rebuttal "$comment_idx" "$rebuttal_plan" "$comments_json"; then
                    rebuttal_count=$((rebuttal_count + 1))
                else
                    rebuttals_skipped_post=$((rebuttals_skipped_post + 1))
                fi
            fi
            in_rebuttal=false
            rebuttal_plan=""
        elif [ "$in_rebuttal" = true ]; then
            # Collect plan text (strip "Plan: " prefix if present)
            local stripped
            stripped="${line#Plan: }"
            if [ -n "$stripped" ]; then
                if [ -n "$rebuttal_plan" ]; then
                    rebuttal_plan="${rebuttal_plan}
${stripped}"
                else
                    rebuttal_plan="$stripped"
                fi
            fi
        fi
    done < "$TRIAGE_FILE"

    # Post final pending rebuttal
    if [ "$in_rebuttal" = true ] && [ -n "$rebuttal_plan" ]; then
        if _post_single_rebuttal "$comment_idx" "$rebuttal_plan" "$comments_json"; then
            rebuttal_count=$((rebuttal_count + 1))
        else
            rebuttals_skipped_post=$((rebuttals_skipped_post + 1))
        fi
    fi

    # Persist both skip counters so commit_and_push_fixes (Phase 3) can read
    # them when building the cycle summary. Always write the files so
    # downstream readers don't need a fallback.
    echo "${rebuttals_skipped_triage}" > "$WORKSPACE_DIR/.rebuttals_skipped_triage"
    echo "${rebuttals_skipped_post}" > "$WORKSPACE_DIR/.rebuttals_skipped_post"

    if [ "$rebuttal_count" -gt 0 ]; then
        echo "$(date '+%H:%M:%S') Posted ${rebuttal_count} rebuttal(s)." >> "$LOGFILE"
        # Log rebuttals to changes.md
        echo "" >> "$CHANGES_FILE"
        echo "### Rebuttals posted: ${rebuttal_count}" >> "$CHANGES_FILE"
    fi
}

# Compute the §3 dedup fingerprint for a reviewer comment at index $idx in
# $comments_json. Echoes the 16-hex-char hash to stdout. Inline comments
# (path non-empty) are prefixed with `path:line:` so two reviewers asking
# the same thing about different files don't collide.
_compute_rebuttal_fingerprint() {
    local idx="$1" comments_json="$2"
    local body raw_path raw_line input norm
    body=$(echo "$comments_json" | jq -r ".[$idx].body // \"\"")
    raw_path=$(echo "$comments_json" | jq -r ".[$idx].path // \"\"")
    raw_line=$(echo "$comments_json" | jq -r ".[$idx].line // \"\"")
    if [ -n "$raw_path" ] && [ "$raw_path" != "null" ]; then
        if [ -z "$raw_line" ] || [ "$raw_line" = "null" ]; then
            raw_line=0
        fi
        input="${raw_path}:${raw_line}:${body}"
    else
        input="$body"
    fi
    # Lossy normalization: lowercase + whitespace-stripped + first 200 chars,
    # then first 16 hex of SHA1. The 200-char cap tolerates the reviewer bot
    # rephrasing the trailing portion of a comment between cycles. The
    # collision risk is documented in spec §3 / open question 2.
    #
    # PORTABILITY: this function depends on `sha1sum` (GNU coreutils, Linux).
    # On macOS the equivalent is `shasum -a 1`. mesh's CI is Linux-only, so
    # we use sha1sum directly. If macOS support becomes a requirement, wrap
    # this in a `command -v sha1sum || sha1sum() { shasum -a 1 "$@"; }` shim.
    norm=$(printf '%s' "$input" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' | cut -c1-200)
    printf '%s' "$norm" | sha1sum | cut -c1-16
}

# Post a single rebuttal — threaded reply for inline, PR comment for general.
# Returns 0 if the rebuttal was posted, 1 if it was suppressed by the
# fingerprint dedup cache. The caller uses the return code to update its
# own counters — no globals or dynamic-scope side effects.
_post_single_rebuttal() {
    local idx="$1" plan="$2" comments_json="$3"
    local comment_type comment_id author
    comment_type=$(echo "$comments_json" | jq -r ".[$idx].type // \"general\"")
    comment_id=$(echo "$comments_json" | jq -r ".[$idx].id // empty")
    author=$(echo "$comments_json" | jq -r ".[$idx].author // \"reviewer\"")

    # §3 safety net: compute the fingerprint for the reviewer comment and
    # skip if it already appears in the per-cycle cache.
    local fingerprint cache_file
    fingerprint=$(_compute_rebuttal_fingerprint "$idx" "$comments_json")
    cache_file="$WORKSPACE_DIR/.rebuttal_fingerprints"
    if [ -s "$cache_file" ] && grep -qFx "$fingerprint" "$cache_file"; then
        echo "$(date '+%H:%M:%S') Skipped duplicate rebuttal for comment $((idx + 1)) (fingerprint already posted)." >> "$LOGFILE"
        return 1
    fi

    local rebuttal_body="${PR_LOOP_MARKER}
<!-- pr_loop:rebuttal-for:${fingerprint} -->
**Rebuttal**: ${plan}"

    if [ "$comment_type" = "inline" ] && [ -n "$comment_id" ] && [ "$comment_id" != "null" ]; then
        # Post threaded reply on inline comment
        local reply_payload
        reply_payload=$(jq -nc --arg body "$rebuttal_body" --argjson id "$comment_id" \
            '{body: $body, in_reply_to: $id}')
        gh api "repos/${REPO_SLUG}/pulls/${PR_NUMBER}/comments" \
            --method POST --input - <<< "$reply_payload" >/dev/null 2>&1 || {
            echo "$(date '+%H:%M:%S') WARN: Failed to post threaded rebuttal for comment $comment_id. Falling back to PR comment." >> "$LOGFILE"
            post_marked_comment "Re: @${author}'s inline comment — ${rebuttal_body}" || true
        }
    else
        # Post as regular PR comment referencing the reviewer and the disputed comment
        local comment_body_excerpt comment_num ref_line
        comment_num=$((idx + 1))
        comment_body_excerpt=$(echo "$comments_json" | jq -r ".[$idx].body // \"\"" | head -1 | cut -c1-80)
        ref_line="Re: @${author} (comment #${comment_num}"
        # Add location if available (e.g., inline comment that fell through)
        local ref_path ref_ln
        ref_path=$(echo "$comments_json" | jq -r ".[$idx].path // empty")
        ref_ln=$(echo "$comments_json" | jq -r ".[$idx].line // empty")
        if [ -n "$ref_path" ] && [ "$ref_path" != "null" ]; then
            ref_line="${ref_line}, on ${ref_path}"
            [ -n "$ref_ln" ] && [ "$ref_ln" != "null" ] && ref_line="${ref_line}:${ref_ln}"
        fi
        ref_line="${ref_line})"
        if [ -n "$comment_body_excerpt" ]; then
            ref_line="${ref_line}: \"${comment_body_excerpt}...\""
        fi

        post_marked_comment "${ref_line}

${rebuttal_body}" || {
            echo "$(date '+%H:%M:%S') WARN: Failed to post rebuttal comment." >> "$LOGFILE"
        }
    fi
    # Explicit "posted" return code per the function contract documented above.
    # Without this, the implicit exit code is whatever the last command in the
    # if/else block produced (post_marked_comment || { warn; }), which is
    # always 0 in practice but relies on the warn-clause swallowing the error.
    return 0
}

# Commit fixes, push, and post summary (§4.3.5).
commit_and_push_fixes() {
    local cycle="$1"
    local triage_content
    triage_content=$(cat "$TRIAGE_FILE" 2>/dev/null)

    # Stage all changes
    git -C "$PROJECT_ROOT" add -A

    # Check if there are staged changes
    if git -C "$PROJECT_ROOT" diff --cached --quiet; then
        echo "$(date '+%H:%M:%S') No changes to commit after cycle ${cycle}." >> "$LOGFILE"
        return 0
    fi

    # Commit
    git -C "$PROJECT_ROOT" commit -m "pr_loop: address review cycle ${cycle} comments" || {
        echo "$(date '+%H:%M:%S') ERROR: git commit failed." >> "$LOGFILE"
        return 1
    }
    echo "$(date '+%H:%M:%S') Committed fixes for cycle ${cycle}." >> "$LOGFILE"

    # Push (§7: exit on push failure, never force-push)
    git -C "$PROJECT_ROOT" push || {
        echo "$(date '+%H:%M:%S') ERROR: git push failed. Exiting (will not force-push)." >> "$LOGFILE"
        return 1
    }
    echo "$(date '+%H:%M:%S') Pushed fixes for cycle ${cycle}." >> "$LOGFILE"

    # Build summary from triage.
    # NOTE: both regexes are intentionally bracket-bounded with `\[ACCEPT\]`
    # and `\[REBUTTAL\]` so they EXCLUDE `[REBUTTAL-SKIP]`. Do NOT broaden
    # them to `\[REBUTTAL(-SKIP)?\]` or similar — REBUTTAL-SKIP is a separate
    # disposition (the triage agent recognized a duplicate of a prior cycle's
    # rebuttal) and is reported on its own "Skipped (duplicate)" line below,
    # not folded into the Rebutted count. See agent_loop/spec.md §4.
    # NOTE: use `|| true` (NOT `|| echo "0"`). `grep -c` always prints a count
    # to stdout — even "0" — and only exits 1 to signal "no matches". Chaining
    # `|| echo "0"` appends a SECOND "0" to the captured value, producing the
    # multi-line string "0\n0" which then breaks the summary template
    # ("Addressed: 0\n0 comment(s)"). `|| true` swallows the exit without
    # writing anything to stdout, so the captured value stays "0" exactly.
    # The integer-coerce guard below handles the rare case where the file is
    # missing (grep prints nothing and exits 2).
    local accepted_items rebutted_items summary_body
    accepted_items=$(grep -cE '^\### Comment.*\[ACCEPT\]' "$TRIAGE_FILE" 2>/dev/null || true)
    rebutted_items=$(grep -cE '^\### Comment.*\[REBUTTAL\]' "$TRIAGE_FILE" 2>/dev/null || true)
    [[ "$accepted_items" =~ ^[0-9]+$ ]] || accepted_items=0
    [[ "$rebutted_items" =~ ^[0-9]+$ ]] || rebutted_items=0

    # §4: read and consume the two skip counters persisted by post_rebuttals.
    # Both files are removed after reading so the next cycle starts clean.
    local skipped_triage skipped_post skipped_total
    skipped_triage=0
    skipped_post=0
    if [ -f "$WORKSPACE_DIR/.rebuttals_skipped_triage" ]; then
        skipped_triage=$(cat "$WORKSPACE_DIR/.rebuttals_skipped_triage" 2>/dev/null || echo 0)
        rm -f "$WORKSPACE_DIR/.rebuttals_skipped_triage"
    fi
    if [ -f "$WORKSPACE_DIR/.rebuttals_skipped_post" ]; then
        skipped_post=$(cat "$WORKSPACE_DIR/.rebuttals_skipped_post" 2>/dev/null || echo 0)
        rm -f "$WORKSPACE_DIR/.rebuttals_skipped_post"
    fi
    # Coerce to integers (defensively guard against blank/garbage file content).
    [[ "$skipped_triage" =~ ^[0-9]+$ ]] || skipped_triage=0
    [[ "$skipped_post" =~ ^[0-9]+$ ]] || skipped_post=0
    skipped_total=$((skipped_triage + skipped_post))

    # `rebutted_items` counts triage decisions ([REBUTTAL] in triage.md), but
    # the safety-net fingerprint dedup may suppress some of those at post time
    # (skipped_post). The summary's "Rebutted: N" should reflect actually-posted
    # rebuttals, not triage decisions, so a reader doesn't see "Rebutted: 3"
    # when only 2 comments were actually posted to the PR.
    local rebutted_posted
    rebutted_posted=$((rebutted_items - skipped_post))
    # Defensive floor — should not happen unless skipped_post > rebutted_items
    # (which would indicate a counter accounting bug worth investigating).
    if [ "$rebutted_posted" -lt 0 ]; then
        echo "$(date '+%H:%M:%S') WARN: rebutted_posted=${rebutted_posted} < 0 (rebutted_items=${rebutted_items}, skipped_post=${skipped_post}); clamping to 0." >> "$LOGFILE"
        rebutted_posted=0
    fi

    summary_body="**Review cycle ${cycle} summary:**
- Addressed: ${accepted_items} comment(s)
- Rebutted: ${rebutted_posted} comment(s)"
    # Suppress the Skipped line on quiet cycles (K=0) to avoid noise.
    if [ "$skipped_total" -gt 0 ]; then
        summary_body="${summary_body}
- Skipped (duplicate): ${skipped_total} comment(s)"
    fi

    post_marked_comment "$summary_body" || {
        echo "$(date '+%H:%M:%S') WARN: Failed to post summary comment." >> "$LOGFILE"
    }
    echo "$(date '+%H:%M:%S') Posted cycle ${cycle} summary comment." >> "$LOGFILE"
    return 0
}

# ── Main review-fix cycle (§4.3) ──

while [ "$CYCLE" -lt "$MAX_CYCLES" ]; do
    CYCLE=$((CYCLE + 1))
    echo "$(date '+%H:%M:%S') ── Cycle ${CYCLE}/${MAX_CYCLES} ──" >> "$LOGFILE"

    check_feedback

    poll_rc=0
    poll_for_comments || poll_rc=$?

    if [ "$poll_rc" -ne 0 ]; then
        # No new comments (poll timed out). Handle settled-signal logic.
        # Only count confirmed empty polls (rc=1) toward settled, not API
        # failures (rc=2) — a flaky GitHub API must not trigger a false exit.
        # Note: the FIRST_POLL_DONE gate skips counting the very first empty
        # poll after each (re)start, so the effective total empty cycles
        # before exit is SETTLED_AFTER_EMPTY_POLLS + 1.
        if [ "$poll_rc" -eq 1 ] && [ "$FIRST_POLL_DONE" = true ]; then
            CONSECUTIVE_EMPTY_POLLS=$((CONSECUTIVE_EMPTY_POLLS + 1))
            if [ "$CONSECUTIVE_EMPTY_POLLS" -ge "$SETTLED_AFTER_EMPTY_POLLS" ]; then
                echo "$(date '+%H:%M:%S') PR #${PR_NUMBER} appears settled (${CONSECUTIVE_EMPTY_POLLS} consecutive empty polls). Exiting." >> "$LOGFILE"
                post_marked_comment "PR appears settled after ${CONSECUTIVE_EMPTY_POLLS} consecutive empty poll round(s). Exiting automated review cycle." || {
                    echo "$(date '+%H:%M:%S') WARN: Failed to post settled comment." >> "$LOGFILE"
                }
                run_final_audit
                exit 0
            fi
        fi
        FIRST_POLL_DONE=true
        save_state "$PR_NUMBER" "$CYCLE" "$LAST_COMMENT_TS" "$CURRENT_BRANCH" "$BASE_BRANCH"
        echo "$(date '+%H:%M:%S') State: cycle=${CYCLE}, last_ts=${LAST_COMMENT_TS}" >> "$LOGFILE"
        # shellcheck disable=SC2034
        FEEDBACK_CONTEXT=""
        continue
    fi

    # New comments found — reset settled counter.
    CONSECUTIVE_EMPTY_POLLS=0
    FIRST_POLL_DONE=true

    # Mid-cycle checkpoint 1: before triage
    _assert_pr_still_open

    # §4.3.2: Format comments and run triage
    format_comments_md "$CYCLE"
    if ! run_triage "$CYCLE"; then
        echo "$(date '+%H:%M:%S') ERROR: Triage failed for cycle ${CYCLE}. Exiting." >> "$LOGFILE"
        exit 1
    fi

    # Mid-cycle checkpoint 2: before fixes
    _assert_pr_still_open

    # §4.3.3: Generate fix spec and implement fixes
    generate_fix_spec "$CYCLE"
    if ! run_fixes; then
        echo "$(date '+%H:%M:%S') ERROR: Fixes failed for cycle ${CYCLE}. Exiting." >> "$LOGFILE"
        exit 1
    fi

    # Mid-cycle checkpoint 3: before rebuttals
    _assert_pr_still_open

    # §4.3.4: Post rebuttals
    post_rebuttals

    # Mid-cycle checkpoint 4: before commit/push
    _assert_pr_still_open

    # §4.3.5: Commit, push, post summary
    if ! commit_and_push_fixes "$CYCLE"; then
        echo "$(date '+%H:%M:%S') ERROR: Commit/push failed for cycle ${CYCLE}. Exiting." >> "$LOGFILE"
        exit 1
    fi

    # Update state (§4.3.6)
    save_state "$PR_NUMBER" "$CYCLE" "$LAST_COMMENT_TS" "$CURRENT_BRANCH" "$BASE_BRANCH"
    echo "$(date '+%H:%M:%S') State: cycle=${CYCLE}, last_ts=${LAST_COMMENT_TS}" >> "$LOGFILE"

    if [ "$APPROVED" = true ]; then
        echo "$(date '+%H:%M:%S') PR approved. Exiting after final cycle." >> "$LOGFILE"
        run_final_audit
        exit 0
    fi

    # shellcheck disable=SC2034
    FEEDBACK_CONTEXT=""
done

# Max cycles reached (§4.4)
post_completion_comment
echo "$(date '+%H:%M:%S') Max cycles (${MAX_CYCLES}) reached." >> "$LOGFILE"
run_final_audit
exit 0
