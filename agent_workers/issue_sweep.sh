#!/bin/bash
set -euo pipefail

# issue_sweep.sh — bash-orchestrated GitHub issue sweep.
#
# Phase 1 (this file's current surface): triage the open backlog of a single
# repo into work-items, validate the queue against the schema, apply the
# routing gate, and seed the label ledger. The per-work-item pipeline
# (PATH A / review-fix / audit / aggregate) lands in later phases; the flags
# for it are accepted now so the CLI surface stays stable.
#
# Bash, not an LLM, drives the control flow — same reason spec_to_ship.sh is
# bash: orchestration must not burn Claude-Max budget. See
# docs/todos/issue-sweep.md for the full plan.
#
# Sibling layout (resolved from $0):
#   $SCRIPT_DIR/lib/issue_triage_helpers.sh

usage() {
    cat <<'EOF'
Usage: issue_sweep.sh [-d <repo>] [OPTIONS]

Triage a repo's open GitHub issue backlog into work-items and seed the label
ledger. Drives the automated sweep that takes issues -> audited PRs -> a dated
bot branch a human merges into develop.

Options:
  -d <repo>                  Target repo directory (default: current dir).
  --max N                    Cap issues fetched per run (default: 200).
  --sizes S,M[,L]            Only process work-items whose size is in this set
                             (default: S,M,L). Filter axis only — does NOT
                             affect PATH A/B routing (that keys on complexity).
  --dry-run                  Fetch + triage + validate + print queue only.
                             Performs ZERO GitHub mutations (no labels,
                             branches, PRs, comments, or bot branch).
  --resume-stale retry|park  Policy for a bot:in-progress issue with no
                             matching branch/PR/marker (default: retry).
                             retry -> relabel bot:queued; park -> bot:needs-human.
  -i <agent>                 Fixer for review-fix + audit-fix AND the implement
                             half of the default reason+implement implementer:
                             claude|codex|zenmux|fireworks (default: codex).
                             The planning half is always claude at
                             SWEEP_PLANNER_MODEL.
  --spec-to-ship             Opt-in: route very-complex (path-b) work-items
                             through spec_to_ship.sh (spec_loop refinement ->
                             agent_loop -> dev-stage audit) instead of the
                             default reason+implement pair. Simple/medium
                             items always use reason+implement.
  --review-check-name <name> Server-side reviewer check to poll per push
                             (default: claude-review). Matches the check-run
                             name exactly OR by composed-name segment fallback,
                             preferring the trailing segment (reusable
                             workflows register names like "review / review").
                             Absent in a repo parks the
                             item; local review fallback is disabled.
  --no-aggregate             Skip the bot-merge aggregation step. Shippable
                             per-item PRs are left labeled bot:in-progress for a
                             manual collect (no bot branch, no rollup PR).
  --bot-branch <name>        Bot branch to accumulate approved branches onto
                             (default: bot/auto-fix-<date>). Must be a safe
                             bot/* ref and must NOT be the base branch — the
                             sweep never pushes develop.
  -h, --help                 Show this help.

Non-dry-run drives each eligible queued work-item through the default two-turn
reason+implement implementer (isolated git worktree off origin/<base>; <base> is
SWEEP_PR_BASE, default develop): a planner turn (claude @ SWEEP_PLANNER_MODEL,
default claude-fable-5) writes an implementation plan WITHOUT editing, then an
implementer turn (the -i agent, default codex) edits per that plan, runs the
repo's own validation, and must emit [PASS]. The runner then commits -> pushes
-> opens the PR, then the
outer PR loop (review-fix until only-nits/approve, then audit_pr_review.sh). Each
work-item builds in its OWN worktree so concurrent/sequential items never share a
tree. Approved branches are then merged --no-ff onto one bot branch per repo and
a single rollup PR is opened/updated to develop (Closes #N + per-item PR links);
merged issues become bot:shipped, merge-conflicting issues bot:needs-human.
With --spec-to-ship, path-b (very-complex single-repo code-only) items route
through spec_to_ship.sh (its own spec_loop -> agent_loop -> dev-stage
audit-pr.sh) into the SAME outer PR loop instead; without the flag they use
reason+implement like everything else.
Routing keys on complexity; --sizes is an independent filter axis.

The planner turn spawns a Claude Code agent, so a non-dry-run sweep REFUSES to start
(exit 2) when launched inside an interactive Claude Code session (CLAUDECODE
set) to avoid OOM. Run it detached / via cron, or export SWEEP_DETACHED=1 to
acknowledge an approved detached context.

Environment:
  SWEEP_DATE                 Override the sweep date (default: date +%Y-%m-%d).
                             Used for feat/sweep/<date>/<slug> branch naming.
  SWEEP_WORKDIR_BASE         Base for the run workspace (default:
                             <repo>/.git/mesh/issue_sweep — untracked by git,
                             so PATH A's `git add -A` never captures it).
  SWEEP_PR_BASE              Base branch for per-item PRs (default: develop).
  SWEEP_PLANNER_MODEL        Model for the reason+implement planner turn
                             (default: claude-fable-5). The implement half is
                             the -i agent; codex ignores model overrides (its
                             model comes from ~/.codex/config).
  REVIEW_CHECK_NAME          Server-side reviewer check name (default:
                             claude-review). Same as --review-check-name
                             (exact or composed-name segment fallback).
  SWEEP_DETACHED             Set to acknowledge an approved detached/cron context
                             and bypass the interactive-Claude OOM refusal.
  SWEEP_ALLOW_UNSANDBOXED_AGENT
                             Set to 1 to allow the credential-bearing fix agent
                             (PATH A / review-fix / audit-fix) to run. REQUIRED
                             for any driving: the fix agents run with the runner's
                             git/GitHub push credentials, and a prompt-injected
                             turn could push directly to develop via on-disk creds
                             that no in-process env lockdown can fully revoke. The
                             sweep therefore FAILS CLOSED (parks the item
                             bot:needs-human) for every agent turn unless this is
                             set. Set it ONLY when the sweep runs inside an OS
                             isolation you provide externally — a container /
                             dedicated service account WITHOUT a push token /
                             behind an egress firewall.
  SWEEP_REVIEW_BOT           Login of the review bot, to scope round comments.
                             If unset, every current-round PR comment can be
                             treated as a reviewer finding.
  SWEEP_CLAIM_TTL            Age (seconds, default 21600=6h) past which a stale
                             remote claim ref (sweep-claim/<date>/<slug>) left by
                             a crashed run is reaped during resume-stale / drive;
                             a fresher claim is preserved as a live drive.
  REVIEW_POLL_TIMEOUT REVIEW_POLL_INTERVAL
                             Reviewer-check poll cap / interval (default 1800/30s).
  REVIEW_REGISTER_GRACE      Seconds to wait for the reviewer check to FIRST
                             register on the pushed sha before declaring it
                             absent (default 120). GitHub Actions typically need
                             15-45s post-push to create the check run; absence
                             is only declared on a successful check-runs fetch,
                             and REVIEW_POLL_TIMEOUT remains the overall cap.
  MAX_REVIEW_ROUNDS MAX_PR_ROUNDS MAX_AUDIT_ROUNDS MAX_FIX_ATTEMPTS
                             Per-item cost caps (default 5/3/2/5).

Exit codes: 0 ok · 2 usage/preflight error · 1 runtime/triage error.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent_workers/lib/issue_triage_helpers.sh
source "$SCRIPT_DIR/lib/issue_triage_helpers.sh"
# agent_sessions.sh (run_agent_turn) needs LOGFILE/FEEDBACK_FILE defined before
# sourcing; placeholders here, repointed at the run workspace after parsing.
LOGFILE="/dev/null"
FEEDBACK_FILE="/dev/null"
# shellcheck source=agent_workers/lib/agent_sessions.sh
source "$SCRIPT_DIR/lib/agent_sessions.sh"
# shellcheck source=agent_workers/lib/review_fix_helpers.sh
source "$SCRIPT_DIR/lib/review_fix_helpers.sh"
# shellcheck source=agent_workers/lib/issue_pipeline_helpers.sh
source "$SCRIPT_DIR/lib/issue_pipeline_helpers.sh"
# shellcheck source=agent_workers/lib/issue_aggregate_helpers.sh
source "$SCRIPT_DIR/lib/issue_aggregate_helpers.sh"

# ── Defaults ───────────────────────────────────────────────────────────────
PROJECT_DIR=""
MAX_ISSUES="200"
SIZES="S,M,L"
DRY_RUN=false
RESUME_STALE="retry"
SWEEP_DATE="${SWEEP_DATE:-$(date +%Y-%m-%d)}"
FIXER_AGENT="codex"
REVIEW_CHECK_NAME="${REVIEW_CHECK_NAME:-claude-review}"
SWEEP_PR_BASE="${SWEEP_PR_BASE:-develop}"
# Exported: read only inside the sourced sweep_pipeline (issue_pipeline_helpers.sh)
# as ${AGGREGATE:-true}; export so plain `shellcheck` (no -x) sees it used, not SC2034.
export AGGREGATE=true
# Exported for the same SC2034 reason — both are read only inside the sourced
# issue_pipeline_helpers.sh: SPEC_TO_SHIP gates the path-b -> spec_to_ship.sh
# dispatch; SWEEP_PLANNER_MODEL is the reason+implement planner turn's model.
export SPEC_TO_SHIP=false
export SWEEP_PLANNER_MODEL="${SWEEP_PLANNER_MODEL:-claude-fable-5}"
BOT_BRANCH="${BOT_BRANCH:-}"

# Phase 2 cost caps (env-overridable; bound the per-item blast radius).
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-5}"
MAX_PR_ROUNDS="${MAX_PR_ROUNDS:-3}"
MAX_AUDIT_ROUNDS="${MAX_AUDIT_ROUNDS:-2}"
MAX_FIX_ATTEMPTS="${MAX_FIX_ATTEMPTS:-5}"

_require_value() {
    if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
        echo "ERROR: $1 requires a value" >&2
        usage >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)                  _require_value "$1" "${2:-}"; PROJECT_DIR="$2"; shift 2 ;;
        --max)               _require_value "$1" "${2:-}"; MAX_ISSUES="$2"; shift 2 ;;
        --sizes)             _require_value "$1" "${2:-}"; SIZES="$2"; shift 2 ;;
        --dry-run)           DRY_RUN=true; shift ;;
        --resume-stale)      _require_value "$1" "${2:-}"; RESUME_STALE="$2"; shift 2 ;;
        -i)                  _require_value "$1" "${2:-}"; FIXER_AGENT="$2"; shift 2 ;;
        --review-check-name) _require_value "$1" "${2:-}"; REVIEW_CHECK_NAME="$2"; shift 2 ;;
        --no-aggregate)      AGGREGATE=false; shift ;;
        --spec-to-ship)      SPEC_TO_SHIP=true; shift ;;
        --bot-branch)        _require_value "$1" "${2:-}"; BOT_BRANCH="$2"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ── Flag validation (fail fast, before any work) ───────────────────────────
if ! [[ "$MAX_ISSUES" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --max must be a positive integer (got: $MAX_ISSUES)" >&2
    exit 2
fi

case "$RESUME_STALE" in
    retry|park) ;;
    *) echo "ERROR: --resume-stale must be retry|park (got: $RESUME_STALE)" >&2; exit 2 ;;
esac

# Fixer agent (-i) drives review-fix + audit-fix AND the implement half of the
# default reason+implement pair (the planning half is always claude at
# SWEEP_PLANNER_MODEL); -i selects that implementer/fixer (default codex).
case "$FIXER_AGENT" in
    claude|codex|zenmux|fireworks) ;;
    *) echo "ERROR: -i must be claude|codex|zenmux|fireworks (got: $FIXER_AGENT)" >&2; exit 2 ;;
esac

# Hard guard for Non-goals: the sweep NEVER pushes the base branch or any
# operator-supplied branch outside the bot/ namespace. A bad --bot-branch would
# make the aggregator checkout -B + push that ref — refuse before preflight.
if [[ -n "$BOT_BRANCH" ]]; then
    if [[ "$BOT_BRANCH" == "$SWEEP_PR_BASE" ]]; then
        echo "ERROR: --bot-branch must not be the base branch ($SWEEP_PR_BASE)" >&2
        exit 2
    fi
    if ! sweep_bot_branch_is_safe "$BOT_BRANCH"; then
        echo "ERROR: --bot-branch must be a safe bot namespace ref (bot/<name>; got: $BOT_BRANCH)" >&2
        exit 2
    fi
fi

# Cost caps must be positive integers — a bad env override would otherwise make
# the per-item loops spin or never run.
for _cap in MAX_REVIEW_ROUNDS MAX_PR_ROUNDS MAX_AUDIT_ROUNDS MAX_FIX_ATTEMPTS; do
    if ! [[ "${!_cap}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: $_cap must be a positive integer (got: ${!_cap})" >&2
        exit 2
    fi
done
unset _cap

# --sizes must be a comma list drawn from {S,M,L} with no junk.
IFS=',' read -r -a _SIZE_LIST <<< "$SIZES"
if [[ ${#_SIZE_LIST[@]} -eq 0 ]]; then
    echo "ERROR: --sizes must name at least one of S,M,L" >&2
    exit 2
fi
for _s in "${_SIZE_LIST[@]}"; do
    case "$_s" in
        S|M|L) ;;
        *) echo "ERROR: --sizes entries must be S, M, or L (got: $_s)" >&2; exit 2 ;;
    esac
done
unset _s

size_selected() {
    [[ ",$SIZES," == *",$1,"* ]]
}

# ── Preflight ──────────────────────────────────────────────────────────────
# Tier 1 (always — needed even for --dry-run's fetch + triage):
#   required CLIs, inside a git repo, gh auth, resolvable target repo slug.
# Tier 2 (non-dry-run only — gates the first mutation):
#   clean tree, push permission, origin/$SWEEP_PR_BASE fetch.

for tool in gh jq git claude; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "ERROR: required CLI not found on PATH: $tool" >&2; exit 2; }
done

PROJECT_ROOT="$(cd "${PROJECT_DIR:-.}" 2>/dev/null && pwd)" \
    || { echo "ERROR: -d directory does not exist: $PROJECT_DIR" >&2; exit 2; }
cd "$PROJECT_ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: -d is not inside a git repo: $PROJECT_ROOT" >&2; exit 2; }

gh auth status >/dev/null 2>&1 \
    || { echo "ERROR: gh not authenticated; run 'gh auth login'" >&2; exit 2; }

# Target-repo match: the local dir must resolve to a GitHub repo slug. The
# per-work-item target_repo is validated against this in the triage gate.
REPO_SLUG="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" \
    || REPO_SLUG=""
if [[ -z "$REPO_SLUG" ]]; then
    echo "ERROR: could not resolve target repo via 'gh repo view' in $PROJECT_ROOT" >&2
    exit 2
fi

if [[ "$DRY_RUN" == false ]]; then
    if ! git diff --quiet HEAD -- 2>/dev/null \
       || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
        echo "ERROR: working tree has uncommitted/untracked changes; commit or stash first" >&2
        git status --short >&2
        exit 2
    fi
    git fetch --quiet origin "$SWEEP_PR_BASE" 2>/dev/null \
        || { echo "ERROR: could not fetch origin/$SWEEP_PR_BASE" >&2; exit 2; }
    PERM="$(gh repo view --json viewerPermission --jq '.viewerPermission' 2>/dev/null)" || PERM=""
    case "$PERM" in
        ADMIN|MAINTAIN|WRITE) ;;
        *) echo "ERROR: no push permission on $REPO_SLUG (viewerPermission=$PERM)" >&2; exit 2 ;;
    esac

    # Repo-scoped run lock (audit BLOCKER: overlapping sweeps). A second
    # cron/detached sweep on the SAME repo would race branch/label/rollup
    # mutations and open duplicate PRs. Take a non-blocking lock for the whole
    # mutating run; a concurrent run refuses to start rather than colliding. The
    # lock auto-releases when this process exits (flock on a held fd), so a
    # crashed run never strands it. dry-run skips this — it mutates nothing.
    SWEEP_LOCK_FILE="$PROJECT_ROOT/.git/mesh/issue_sweep.lock"
    sweep_acquire_repo_lock "$SWEEP_LOCK_FILE"; _lock_rc=$?
    case "$_lock_rc" in
        0) trap 'sweep_release_repo_lock' EXIT ;;
        1) echo "ERROR: another issue_sweep run holds the lock on $REPO_SLUG ($SWEEP_LOCK_FILE)." >&2
           echo "       Refusing to start a concurrent sweep (would race branch/label/PR mutations)." >&2
           exit 2 ;;
        *) echo "ERROR: could not acquire repo lock ($SWEEP_LOCK_FILE); 'flock' (util-linux) is required for a non-dry-run." >&2
           exit 2 ;;
    esac
    unset _lock_rc
fi

# ── Fetch + partition ──────────────────────────────────────────────────────
echo ">>> issue_sweep on $REPO_SLUG (date=$SWEEP_DATE, dry-run=$DRY_RUN, sizes=$SIZES)" >&2

ISSUES_JSON="$(sweep_fetch_open_issues "$MAX_ISSUES")"
PARTITION="$(sweep_partition_issues "$ISSUES_JSON")"
FRESH_JSON="$(printf '%s' "$PARTITION" | jq -c '.fresh')"
mapfile -t IN_PROGRESS_NUMS < <(printf '%s' "$PARTITION" | jq -r '.in_progress[].number')

echo ">>> fetched $(printf '%s' "$ISSUES_JSON" | jq 'length') open issues; \
$(printf '%s' "$FRESH_JSON" | jq 'length') fresh, ${#IN_PROGRESS_NUMS[@]} in-progress" >&2

# ── Triage fresh issues ────────────────────────────────────────────────────
QUEUE_JSON="$(sweep_run_triage "$FRESH_JSON" "$REPO_SLUG")" \
    || { echo "ERROR: triage failed" >&2; exit 1; }

if ! sweep_is_json_array "$QUEUE_JSON"; then
    echo "ERROR: triage output is not a JSON array; cannot map to issues" >&2
    printf '%s\n' "$QUEUE_JSON" >&2
    exit 1
fi

# In dry-run, the printed queue is the deliverable — prove triage quality.
echo "===== queue.json ====="
printf '%s\n' "$QUEUE_JSON" | jq '.'
echo "======================"

# The set of issue numbers actually fetched this run (the fresh partition triage
# was given). Decoration flags any work-item referencing a number OUTSIDE this set
# as invalid (unknown-issue-number) so a prompt-injected / hallucinated triage
# response can never label or Refs/Closes an arbitrary repo issue.
FETCHED_NUMS_JSON="$(printf '%s' "$FRESH_JSON" | jq -c '[.[].number]')"
DECORATED="$(sweep_decorate_queue "$QUEUE_JSON" "$REPO_SLUG" "$FETCHED_NUMS_JSON")" \
    || { echo "ERROR: queue decoration failed" >&2; exit 1; }

# Bash-side membership set for the label-mutation defense-in-depth below: even an
# invalid item parked needs-human must only ever touch issue numbers that were
# actually fetched, never an invented one.
declare -A FETCHED_NUM_SET=()
while IFS= read -r _fn; do
    [[ -n "$_fn" ]] && FETCHED_NUM_SET["$_fn"]=1
done < <(printf '%s' "$FRESH_JSON" | jq -r '.[].number')

declare -A RESUME_ISSUES_BY_TARGET=()
RESUME_TARGETS=()

# Ensure the lifecycle labels exist before the first edit (non-dry-run only).
if [[ "$DRY_RUN" == false ]]; then
    sweep_ensure_labels
fi

# ── Disposition loop ───────────────────────────────────────────────────────
# Invalid work-items are tracked so --dry-run can fail with a schema report
# (its job is to prove triage quality before any real run). Non-dry-run parks
# them via bot:needs-human and continues, per the triage spec.
echo ">>> work-item dispositions:" >&2
INVALID_COUNT=0
INVALID_LINES=()
while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    wid="$(jq -r '.work_item_id' <<<"$item")"
    valid="$(jq -r '.valid' <<<"$item")"
    reason="$(jq -r '.reason' <<<"$item")"
    route="$(jq -r '.route' <<<"$item")"
    size="$(jq -r '.size' <<<"$item")"
    mapfile -t nums < <(jq -r '.issue_numbers[]?' <<<"$item")

    label=""
    if [[ "$valid" == false ]]; then
        disp="park (invalid: $reason)"; label="$SWEEP_LABEL_NEEDS_HUMAN"
        INVALID_COUNT=$((INVALID_COUNT + 1))
        INVALID_LINES+=("[$wid] issues=${nums[*]:-none}: $reason")
    elif [[ "$route" == "needs-human" ]]; then
        disp="park (routing -> needs-human)"; label="$SWEEP_LABEL_NEEDS_HUMAN"
    elif ! size_selected "$size"; then
        disp="filtered (size=$size not in $SIZES)"
    else
        disp="queued ($route)"; label="$SWEEP_LABEL_QUEUED"
    fi

    echo "    [$wid] issues=${nums[*]:-none} size=$size -> $disp" >&2
    if [[ "$DRY_RUN" == false && -n "$label" && ${#nums[@]} -gt 0 ]]; then
        # Defense-in-depth (audit BLOCKER): label ONLY members present in the
        # fetched fresh set. An item carrying an unfetched number is already
        # flagged invalid above; this makes the mutation itself unable to reach
        # an arbitrary repo issue the triage turn may have invented.
        safe_nums=()
        for n in "${nums[@]}"; do
            [[ -n "${FETCHED_NUM_SET[$n]:-}" ]] && safe_nums+=("$n")
        done
        if [[ ${#safe_nums[@]} -gt 0 ]]; then
            sweep_add_label "$label" "${safe_nums[@]}"
        fi
    fi
done < <(printf '%s' "$DECORATED" | jq -c '.[]')

# ── In-progress resume pass (non-dry-run only) ─────────────────────────────
if [[ "$DRY_RUN" == false && ${#IN_PROGRESS_NUMS[@]} -gt 0 ]]; then
    echo ">>> resume discovery for ${#IN_PROGRESS_NUMS[@]} in-progress issue(s):" >&2
    for issue in "${IN_PROGRESS_NUMS[@]}"; do
        target="$(sweep_find_resume_target "$issue")"
        if [[ -n "$target" ]]; then
            echo "    #$issue -> resume ($target)" >&2
            if [[ "$target" == pr:#* || "$target" == branch:* ]]; then
                if [[ -z "${RESUME_ISSUES_BY_TARGET[$target]+x}" ]]; then
                    RESUME_TARGETS+=("$target")
                    RESUME_ISSUES_BY_TARGET["$target"]="$issue"
                else
                    RESUME_ISSUES_BY_TARGET["$target"]+=" $issue"
                fi
            fi
        else
            # Stale in-progress: a crash AFTER the atomic remote claim but BEFORE
            # any feat/sweep branch/PR leaves an orphan sweep-claim/<date>/<slug>
            # ref that resume discovery cannot see; reap it (TTL-gated, so a live
            # drive's fresh claim is preserved) BEFORE relabeling, else the retry's
            # acquire would lose to the orphan forever (reviewer 02:06:39).
            sweep_clear_stale_claim_for_issue "$issue" "$PROJECT_ROOT"
            case "$RESUME_STALE" in
                retry)
                    sweep_relabel "$issue" "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_QUEUED"
                    echo "    #$issue -> stale, relabeled $SWEEP_LABEL_QUEUED (retry)" >&2
                    ;;
                park)
                    sweep_relabel "$issue" "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN"
                    echo "    #$issue -> stale, relabeled $SWEEP_LABEL_NEEDS_HUMAN (park)" >&2
                    ;;
            esac
        fi
    done
elif [[ "$DRY_RUN" == true && ${#IN_PROGRESS_NUMS[@]} -gt 0 ]]; then
    echo ">>> ${#IN_PROGRESS_NUMS[@]} in-progress issue(s) skipped (dry-run does not resolve)" >&2
fi

# ── Dry-run schema gate ────────────────────────────────────────────────────
# --dry-run proves the queue passes the jq schema. Any invalid work-item
# (missing field, enum mismatch, target-repo mismatch, duplicate membership)
# is a dry-run failure — reported, non-zero exit, still zero mutations.
if [[ "$DRY_RUN" == true ]]; then
    if (( INVALID_COUNT > 0 )); then
        echo "===== dry-run validation FAILED: $INVALID_COUNT invalid work-item(s) =====" >&2
        for line in "${INVALID_LINES[@]}"; do
            echo "    $line" >&2
        done
        echo "queue.json does not pass schema — fix triage before a non-dry-run." >&2
        exit 1
    fi
    echo ">>> dry-run: queue.json passes schema; zero mutations performed." >&2
    exit 0
fi

echo ">>> Phase 1 complete (triage + ledger seeded)." >&2

# ── Phase 2/4: per-work-item pipeline (non-dry-run only) ───────────────────
# Drive every eligible queued, SIZE-SELECTED work-item through its route ->
# review-fix -> audit. Every item builds via the two-turn reason+implement pair
# (SWEEP_PLANNER_MODEL plan -> FIXER_AGENT implement) unless --spec-to-ship
# routes path-b (very-complex) items through spec_to_ship.sh. Both feed the same outer
# PR loop + aggregator. invalid / needs-human items were already dispositioned
# above. The carried route (path-a|path-b) plus --spec-to-ship decide the
# implementer; --sizes is an
# independent filter axis applied HERE (keyed on .size) so the driven count + the
# OOM guard reflect only items that actually enter the run — a run whose only
# eligible items are all size-filtered must NOT trip the agent-spawn OOM guard.
DRIVE_ITEMS="$(jq -cn --argjson d "$DECORATED" --argjson q "$QUEUE_JSON" \
    --arg sizes ",$SIZES," '
    [ $d[]
      | select(.valid and (.route == "path-a" or .route == "path-b"))
      | (.size // "?") as $sz
      | select($sizes | contains("," + $sz + ","))
      | . as $di
      | ($q | map(select(.work_item_id == $di.work_item_id)) | .[0]) as $qi
      | select($qi != null)
      | $qi + {route: $di.route} ]')" \
    || { echo "ERROR: could not assemble pipeline work-items" >&2; exit 1; }

DRIVE_COUNT="$(printf '%s' "$DRIVE_ITEMS" | jq 'length')"
RESUME_TARGET_COUNT="${#RESUME_TARGETS[@]}"
ACTIVE_COUNT=$((DRIVE_COUNT + RESUME_TARGET_COUNT))

if [[ "$ACTIVE_COUNT" -gt 0 ]]; then
    # OOM guard: PATH A/B spawns a Claude Code agent. Fail fast (before any agent
    # / branch / PR work) if we are inline inside an interactive Claude Code
    # session, unless SWEEP_DETACHED acknowledges an approved detached context.
    # Reached only when >=1 size-selected item will actually be driven.
    sweep_assert_detached || exit 2

    # Run workspace lives under the repo's .git/ (which git never tracks) so
    # PATH A's `git add -A` never captures sweep artifacts into the PR diff,
    # while staying repo-scoped and disposable. Override with SWEEP_WORKDIR_BASE.
    SWEEP_RUN_WORKDIR="${SWEEP_WORKDIR_BASE:-$PROJECT_ROOT/.git/mesh/issue_sweep}/${SWEEP_DATE}"
    mkdir -p "$SWEEP_RUN_WORKDIR"
    LOGFILE="$SWEEP_RUN_WORKDIR/run.log"
    FEEDBACK_FILE="$SWEEP_RUN_WORKDIR/feedback.md"
    touch "$LOGFILE" "$FEEDBACK_FILE"
    export AGENT_PROJECT_ROOT="$PROJECT_ROOT"
    agent_sessions_init
    if [[ -z "${SWEEP_REVIEW_BOT:-}" ]]; then
        echo ">>> WARN: SWEEP_REVIEW_BOT is unset; review-fix will treat all current-round PR comments as reviewer findings." >&2
        sweep_log "WARN: SWEEP_REVIEW_BOT unset; review-fix author filter disabled"
    fi

    if [[ "$RESUME_TARGET_COUNT" -gt 0 ]]; then
        for target in "${RESUME_TARGETS[@]}"; do
            read -r -a resume_nums <<<"${RESUME_ISSUES_BY_TARGET[$target]}"
            case "$target" in
                pr:#*)
                    pr="${target#pr:#}"
                    sweep_drive_resume_pr "$pr" "${resume_nums[@]}" || true
                    ;;
                branch:*)
                    branch="${target#branch:}"
                    sweep_drive_resume_branch "$branch" "${resume_nums[@]}" || true
                    ;;
            esac
        done
    fi

    echo ">>> pipeline: driving $DRIVE_COUNT work-item(s), resuming $RESUME_TARGET_COUNT target(s) \
(planner=$SWEEP_PLANNER_MODEL, fixer=$FIXER_AGENT, spec-to-ship=$SPEC_TO_SHIP, review-check=$REVIEW_CHECK_NAME); log: $LOGFILE" >&2
    sweep_pipeline "$DRIVE_ITEMS"
else
    echo ">>> pipeline: no eligible path-a/path-b work-items to drive." >&2
fi

echo ">>> issue_sweep complete." >&2
