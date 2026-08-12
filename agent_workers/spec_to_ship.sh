#!/bin/bash
set -euo pipefail

# spec_to_ship.sh — bash orchestrator for the spec-to-ship pipeline.
#
# Drafts a seed spec, refines it via spec_loop.sh, implements via
# agent_loop.sh, audits the diff via audit-pr.sh (OSS engine),
# commits, pushes, and opens a PR.
#
# Bash, not an LLM: orchestration costs zero subscription tokens and
# sidesteps the "unknown remaining quota" problem that bites when a
# Claude-Code skill drives the pipeline. See docs/todos/spec-to-ship.md.
#
# Sibling layout (resolved from $0):
#   $SCRIPT_DIR/spec_loop.sh
#   $SCRIPT_DIR/agent_loop.sh
#   $SCRIPT_DIR/../scripts/audit-pr.sh

usage() {
    cat <<'EOF'
Usage: spec_to_ship.sh (--topic "<text>" | --seed-file <path> | --from <stage> --slug <kebab>) [OPTIONS]

Bash orchestrator for the spec-to-ship pipeline (idea → spec → impl →
audit → PR). The user-facing skill is skills/spec-to-ship/SKILL.md;
this script is what the skill execs.

Inputs (one of these is required):
  --topic "<text>"           One-line description of what to build. Doubles as
                             the seed for spec_loop when --seed-file is absent,
                             and as the slug / branch / PR-title source.
  --seed-file <path>         Use this file verbatim as the spec_loop seed.
                             Path is resolved relative to the current
                             working directory at invocation time. File
                             must exist, be readable, and be non-empty. When
                             --topic is omitted, the topic is derived from
                             the seed file's first '# H1' heading (used for
                             slug, branch name, and PR title fallback) — pass
                             --slug to override the derived slug if needed.
  --from <stage>             Enter the pipeline at <stage> instead of running
                             the full pipeline. Stages: spec_loop (default,
                             full run) | agent_loop | audit. When not
                             'spec_loop':
                               * Implies --use-current-branch (the spec must
                                 already live on the working branch).
                               * Requires --slug (used to locate the existing
                                 spec at docs/todos/<slug>.md).
                               * --topic / --seed-file are not accepted; the
                                 PR title is derived from the existing spec's
                                 first '# H1' heading.
                             Useful for resuming a previous run that died
                             mid-pipeline (e.g. agent_loop crashed, or audit
                             hit a transient failure) without re-running the
                             stages that already produced their output.

Options:
  --slug <kebab>             Override derived slug (default: derived from topic).
  --base-branch <ref>        Branch to fork from (default: current branch).
                             With --use-current-branch, this is the audit
                             diff base; defaults to @{upstream} if unset.
  --use-current-branch       Reuse the current branch instead of creating
                             feat/<slug>. Useful when the user has already
                             cut a working branch and wants spec-to-ship
                             to operate on it directly. Requires --base-branch
                             OR an upstream tracking branch (origin/<x>) so
                             the audit step has a diff base. Clean-tree
                             check still applies — commit the seed file
                             before invoking.
  --max-audit-rounds N       Max audit-fix iterations after the initial audit
                             (default: 3). 0 = audit once and surrender on any
                             [BLOCKER]; no fix attempts.
  --skip-audit               Skip the audit gate; do not require the auditor's
                             provider key. Note: if the reviewer is an OSS
                             engine (e.g. -r zenmux), its key is still required
                             because the reviewer always runs. Under the
                             default -r codex the reviewer is native, so no
                             OSS key is needed when only the audit is skipped.
  -i, --coder    <agent>     Implementer for the agent_loop coder seat
                             (default: claude). Accepts: claude|codex|zenmux|fireworks.
  -r, --reviewer <agent>     Reviewer for the agent_loop review seat
                             (default: codex). Same vocabulary as --coder.
                             When EITHER -i or -r is set explicitly, the
                             pair also drives the spec_loop rotation
                             (reviewer first, coder second). When BOTH are
                             at defaults, spec_loop runs with its own
                             default (codex,claude) — useful when codex
                             quota is healthy. Pass any -r/-i to bypass
                             codex in spec_loop.
  -a, --auditor  <agent>     Engine for audit-pr.sh's production-safety pass
                             (default: codex). Same vocabulary.
                             zenmux/fireworks call OSS gateways and need the
                             matching API key. claude/codex use the user's
                             native CLI subscription (no per-token cost).
  -h, --help                 Show this help.

Agent vocabulary (typical use case):
  claude     Subscription Opus 4.7 via the claude CLI. Best default coder —
             generous subscription ceiling, no pay-per-token cost. Pick for
             other roles when a fresh independent claude session is wanted
             and the OSS gateways are unavailable.
  codex      Subscription GPT 5.5 via the codex CLI. Best default reviewer
             AND auditor — cross-family from the claude coder (catches
             correlated blind spots), strong at short/medium-diff review and
             audits, no incremental cost.
  zenmux     PAYG OSS gateway (DeepSeek family by default). Alternate
             reviewer when a third family / long-context strength is wanted —
             DeepSeek-V4 handles long context well; pay-per-token but cheap.
             Requires ZENMUX_API_KEY.
  fireworks  PAYG OSS gateway (Minimax M2 by default). Alternate OSS seat
             when zenmux is down or for cost A/B comparison.
             Requires FIREWORKS_API_KEY.

Environment:
  ZENMUX_API_KEY             Required if zenmux is selected for any role
                             that runs (for -i/-r whenever that role runs;
                             for -a only when --skip-audit is NOT passed).
                             Not needed under the all-native defaults
                             (claude coder, codex reviewer + auditor).
  FIREWORKS_API_KEY          Required if fireworks is selected, same rules.
  ZENMUX_AGENT_MODEL         Optional slug override for any zenmux role
                             (-i / -r / -a) (default: deepseek/deepseek-v4-pro).
  FIREWORKS_AGENT_MODEL      Optional slug override for any fireworks role
                             (-i / -r / -a) (default:
                             accounts/fireworks/models/minimax-m2p7).
  MAX_FIX_ATTEMPTS           Forwarded to agent_loop.sh (default: 5).
EOF
}

TOPIC=""
SLUG=""
SEED_FILE=""
BASE_BRANCH=""
MAX_AUDIT_ROUNDS="${MAX_AUDIT_ROUNDS:-3}"
SKIP_AUDIT=false
USE_CURRENT_BRANCH=false
FROM_STAGE="spec_loop"
CODER="claude"
REVIEWER="codex"
AUDITOR="codex"
# Track whether -i/-r were user-specified. When both are at defaults, the
# spec_loop seats fall back to spec_loop.sh's own default (codex,claude) —
# subscription-priced and cross-family for spec discussion. When the user
# overrides either, propagate their pair into spec_loop so an explicit
# pick (e.g. -r zenmux to bypass a tight codex quota) carries through.
_CODER_USER_SET=false
_REVIEWER_USER_SET=false

_require_value() {
    if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
        echo "ERROR: $1 requires a value" >&2
        usage >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --topic)            _require_value "$1" "${2:-}"; TOPIC="$2"; shift 2 ;;
        --slug)             _require_value "$1" "${2:-}"; SLUG="$2"; shift 2 ;;
        --seed-file)        _require_value "$1" "${2:-}"; SEED_FILE="$2"; shift 2 ;;
        --base-branch)      _require_value "$1" "${2:-}"; BASE_BRANCH="$2"; shift 2 ;;
        --max-audit-rounds) _require_value "$1" "${2:-}"; MAX_AUDIT_ROUNDS="$2"; shift 2 ;;
        --skip-audit)       SKIP_AUDIT=true; shift ;;
        --use-current-branch) USE_CURRENT_BRANCH=true; shift ;;
        --from)             _require_value "$1" "${2:-}"; FROM_STAGE="$2"; shift 2 ;;
        -i|--coder)         _require_value "$1" "${2:-}"; CODER="$2"; _CODER_USER_SET=true; shift 2 ;;
        -r|--reviewer)      _require_value "$1" "${2:-}"; REVIEWER="$2"; _REVIEWER_USER_SET=true; shift 2 ;;
        -a|--auditor)       _require_value "$1" "${2:-}"; AUDITOR="$2"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Validate agent vocab. Same canonical list as agent_loop.sh / spec_loop.sh
# (claude|codex|zenmux|fireworks) — keep these in lockstep so a misnamed
# agent here would mean the loop fails the same way it does for any other
# bad name, not silently degrade.
_validate_agent_name() {
    local flag="$1" name="$2"
    case "$name" in
        claude|codex|zenmux|fireworks) ;;
        *)
            echo "ERROR: $flag must be one of claude|codex|zenmux|fireworks (got: $name)" >&2
            exit 2
            ;;
    esac
}
_validate_agent_name "-i/--coder"    "$CODER"
_validate_agent_name "-r/--reviewer" "$REVIEWER"
_validate_agent_name "-a/--auditor"  "$AUDITOR"

# --from <stage> picks the entry point. The default 'spec_loop' runs the
# whole pipeline; agent_loop / audit skip earlier stages so a previous run
# that died mid-pipeline can be resumed without re-paying for spec_loop or
# the implementer pass. Map to a FROM_NUM integer so downstream wrappers
# can compare with `<=` instead of repeating the case ladder.
case "$FROM_STAGE" in
    spec_loop)  FROM_NUM=1 ;;
    agent_loop) FROM_NUM=2 ;;
    audit)      FROM_NUM=3 ;;
    *)
        echo "ERROR: --from must be one of spec_loop|agent_loop|audit (got: $FROM_STAGE)" >&2
        exit 2
        ;;
esac

if [[ "$FROM_NUM" -gt 1 ]]; then
    # Resuming a partial run: --topic / --seed-file are nonsensical because
    # the spec is already on disk. Reject them rather than silently ignore
    # so a copy-pasted invocation that mixes the two modes fails fast.
    if [[ -n "$TOPIC" || -n "$SEED_FILE" ]]; then
        echo "ERROR: --topic / --seed-file cannot be combined with --from $FROM_STAGE (topic is read from existing docs/todos/<slug>.md)" >&2
        exit 2
    fi
    if [[ -z "$SLUG" ]]; then
        echo "ERROR: --from $FROM_STAGE requires --slug to locate docs/todos/<slug>.md" >&2
        exit 2
    fi
    # Auto-imply: a partial-run resume always operates on the user's working
    # branch, never cuts a fresh feat/<slug>. Setting it here keeps the
    # branch-setup block below unchanged.
    USE_CURRENT_BRANCH=true
elif [[ -z "$TOPIC" && -z "$SEED_FILE" ]]; then
    echo "ERROR: --topic or --seed-file is required" >&2
    usage >&2
    exit 2
fi
if ! [[ "$MAX_AUDIT_ROUNDS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --max-audit-rounds must be a non-negative integer (got: $MAX_AUDIT_ROUNDS)" >&2
    exit 2
fi

# Resolve --seed-file to an absolute path NOW, while we still hold the
# caller's working directory. Later steps `cd "$PROJECT_ROOT"` and check out
# a fresh branch, both of which can move the cwd or hide the file from a
# relative path. Validate existence/readability/non-emptiness up front so
# the run fails fast instead of after spec_loop has already started.
if [[ -n "$SEED_FILE" ]]; then
    if [[ ! -e "$SEED_FILE" ]]; then
        echo "ERROR: --seed-file not found: $SEED_FILE" >&2
        exit 2
    fi
    if [[ ! -f "$SEED_FILE" ]]; then
        echo "ERROR: --seed-file is not a regular file: $SEED_FILE" >&2
        exit 2
    fi
    if [[ ! -r "$SEED_FILE" ]]; then
        echo "ERROR: --seed-file not readable: $SEED_FILE" >&2
        exit 2
    fi
    if [[ ! -s "$SEED_FILE" ]]; then
        echo "ERROR: --seed-file is empty: $SEED_FILE" >&2
        exit 2
    fi
    SEED_FILE="$(cd "$(dirname "$SEED_FILE")" && pwd)/$(basename "$SEED_FILE")"
fi

# Derive TOPIC from the seed file's first '# H1' heading when --topic was
# not given. Same regex the SUMMARY extraction uses below ('# ' with a
# space) so a seed whose H1 reads as '#NoSpace' or '## H2' falls through
# to the explicit-required error rather than producing a confusing slug.
# Gated on FROM_NUM <= 1: in --from agent_loop|audit mode, TOPIC and
# SEED_FILE are both empty (the earlier validation rejects both), so an
# unconditional grep here would feed an empty path to grep and emit a
# spurious "No such file or directory". The resume path derives TOPIC
# later from docs/todos/<slug>.md instead.
if [[ "$FROM_NUM" -le 1 && -z "$TOPIC" ]]; then
    # Strip leading '# ' and trailing whitespace — the raw $TOPIC is used
    # verbatim as the commit summary and gh PR title, so a heading padded
    # with trailing spaces by an editor would otherwise leak into both.
    TOPIC=$(grep -m1 '^# ' "$SEED_FILE" | sed 's/^# *//; s/[[:space:]]*$//' || true)
    if [[ -z "$TOPIC" ]]; then
        echo "ERROR: --topic omitted and seed file has no '# H1' heading: $SEED_FILE" >&2
        exit 2
    fi
fi

# Resolve sibling paths from $0 — tests can drop in stub loops/audit at the
# same layout (spec_to_ship.sh + spec_loop.sh + agent_loop.sh in one dir,
# audit-pr.sh under ../scripts/) so no env-var overrides are needed.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MESH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_LOOP="$SCRIPT_DIR/spec_loop.sh"
AGENT_LOOP="$SCRIPT_DIR/agent_loop.sh"
AUDIT_SCRIPT="$MESH_ROOT/scripts/audit-pr.sh"

derive_slug() {
    local text="$1" s
    s=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]\+/-/g; s/^-\+//; s/-\+$//')
    s=${s:0:50}
    s=${s%-}
    [[ -z "$s" ]] && s="spec-to-ship-run"
    printf '%s' "$s"
}

[[ -z "$SLUG" ]] && SLUG=$(derive_slug "$TOPIC")

if ! [[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "ERROR: slug must be kebab-case (lowercase + digits + hyphens), got: $SLUG" >&2
    exit 2
fi

# Which roles will actually invoke a subprocess this run. Skipped roles
# must not pull in their CLI / API-key prereqs — that's what makes
# `--skip-audit` (without a ZENMUX_API_KEY) a usable mode, and the same
# logic extends to --from audit when no repair rounds are allowed.
#
# Coder/reviewer run when:
#   * FROM_NUM <= 2 (spec_loop or agent_loop entry — agent_loop will run), OR
#   * FROM_NUM == 3 AND MAX_AUDIT_ROUNDS > 0 (audit-only entry can still
#     trigger agent_loop -R for repair rounds).
# With --from audit --max-audit-rounds 0, repairs cannot run, so the
# audit-only resume must not fail on a missing reviewer key.
_ACTIVE_AGENTS=()
if [[ "$FROM_NUM" -le 2 ]] \
        || { [[ "$FROM_NUM" -eq 3 ]] && [[ "$MAX_AUDIT_ROUNDS" -gt 0 ]]; }; then
    _ACTIVE_AGENTS+=("$CODER" "$REVIEWER")
fi
[[ "$SKIP_AUDIT" == false ]] && _ACTIVE_AGENTS+=("$AUDITOR")

# Tool prereqs — fail fast with a precise missing-tool name. Required CLIs
# are derived from the active roles: claude/zenmux/fireworks all spawn the
# `claude` binary (zenmux/fireworks redirect it via ANTHROPIC_BASE_URL);
# codex spawns `codex`. curl/jq are only needed when the audit gate runs
# AND the auditor is an OSS engine (zenmux/fireworks). Native engines
# (claude/codex) for -a do not need curl/jq.
_REQUIRED_TOOLS=(git gh)
for _agent in "${_ACTIVE_AGENTS[@]}"; do
    case "$_agent" in
        claude|zenmux|fireworks) _REQUIRED_TOOLS+=(claude) ;;
        codex)                   _REQUIRED_TOOLS+=(codex) ;;
    esac
done
unset _agent
if [[ "$SKIP_AUDIT" == false ]]; then
    case "$AUDITOR" in
        zenmux|fireworks) _REQUIRED_TOOLS+=(curl jq) ;;
    esac
fi
# Duplicates here are harmless — the same tool name landing in the array
# twice (e.g. -i claude + -r zenmux both contributing `claude`) just calls
# `command -v` twice. Avoid sort -u so this works under the restricted-
# PATH test fixtures, which don't ship `sort`.
for tool in "${_REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "ERROR: required CLI not found on PATH: $tool" >&2; exit 2; }
done

[[ -x "$SPEC_LOOP" ]] \
    || { echo "ERROR: spec_loop.sh not executable: $SPEC_LOOP" >&2; exit 2; }
[[ -x "$AGENT_LOOP" ]] \
    || { echo "ERROR: agent_loop.sh not executable: $AGENT_LOOP" >&2; exit 2; }
[[ -x "$AUDIT_SCRIPT" ]] \
    || { echo "ERROR: audit-pr.sh not executable: $AUDIT_SCRIPT" >&2; exit 2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: not inside a git repo" >&2; exit 2; }
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
cd "$PROJECT_ROOT"

# Clean tree — refuse to layer the pipeline onto in-flight work because the
# final commit step would otherwise sweep the user's edits into the PR.
# Skipped for --from agent_loop|audit: a prior run that died mid-pipeline
# will have left docs/todos/<slug>.md (and possibly other artifacts)
# uncommitted, since this script only commits after audit clears. A strict
# clean-tree gate would refuse the very resume cases --from is meant to
# enable. The trade-off: any unrelated edits sitting in the tree will get
# swept into the final commit by the staging block at the bottom of this
# script. The caller opts into that risk by passing --from.
if [[ "$FROM_NUM" -le 1 ]]; then
    if ! git diff --quiet HEAD -- 2>/dev/null; then
        echo "ERROR: working tree has uncommitted changes; commit or stash first" >&2
        git status --short >&2
        exit 2
    fi
    if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
        echo "ERROR: working tree has untracked files; commit, stash, or ignore first" >&2
        git status --short >&2
        exit 2
    fi
fi

gh auth status >/dev/null 2>&1 \
    || { echo "ERROR: gh not authenticated; run 'gh auth login'" >&2; exit 2; }

# OSS prereqs — fail fast on the API key BEFORE any subprocess (seed file,
# git checkout, agent invocation). Delegates the actual key+slug check to
# `oss_agents_validate` so the error message matches what run_agent_turn
# would emit later — keep one source of truth for "your zenmux config is
# broken". The provider/slug pair is composed the same way agent_sessions.sh
# does it for the zenmux/fireworks dispatch case (per-provider env var with
# a v2-default slug).
_uses_zenmux=false
_uses_fireworks=false
for _agent in "${_ACTIVE_AGENTS[@]}"; do
    case "$_agent" in
        zenmux)    _uses_zenmux=true ;;
        fireworks) _uses_fireworks=true ;;
    esac
done
unset _agent

if [[ "$_uses_zenmux" == true || "$_uses_fireworks" == true ]]; then
    # shellcheck source=agent_workers/lib/oss_agents.sh
    . "$SCRIPT_DIR/lib/oss_agents.sh"
fi
if [[ "$_uses_zenmux" == true ]]; then
    OSS_AGENT_MODEL="zenmux:${ZENMUX_AGENT_MODEL:-deepseek/deepseek-v4-pro}" \
        oss_agents_validate || exit 2
fi
if [[ "$_uses_fireworks" == true ]]; then
    OSS_AGENT_MODEL="fireworks:${FIREWORKS_AGENT_MODEL:-accounts/fireworks/models/minimax-m2p7}" \
        oss_agents_validate || exit 2
fi

if [[ "$USE_CURRENT_BRANCH" == true ]]; then
    # Reuse the current branch — caller has already cut a working branch
    # and the pipeline should operate on it. We still need a diff base for
    # the audit step; default to the upstream tracking branch if --base-branch
    # was not given. Failing fast here is friendlier than letting audit-pr.sh
    # error with an empty diff later.
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    if [[ -z "$BASE_BRANCH" ]]; then
        BASE_BRANCH="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
        if [[ -z "$BASE_BRANCH" ]]; then
            echo "ERROR: --use-current-branch requires --base-branch (no @{upstream} tracking branch found)" >&2
            exit 2
        fi
    fi
    git rev-parse --verify --quiet "$BASE_BRANCH" >/dev/null \
        || { echo "ERROR: base branch not found: $BASE_BRANCH" >&2; exit 2; }
    if [[ "$BRANCH" == "$BASE_BRANCH" ]]; then
        echo "ERROR: --use-current-branch: current branch ($BRANCH) equals base branch — refusing to pipeline onto a long-lived ref" >&2
        exit 2
    fi
    echo ">>> reusing current branch: $BRANCH (base: $BASE_BRANCH)" >&2
else
    [[ -z "$BASE_BRANCH" ]] && BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    git rev-parse --verify --quiet "$BASE_BRANCH" >/dev/null \
        || { echo "ERROR: base branch not found: $BASE_BRANCH" >&2; exit 2; }

    BRANCH="feat/$SLUG"
    if git rev-parse --verify --quiet "$BRANCH" >/dev/null; then
        echo "ERROR: branch already exists: $BRANCH (pick a different --slug or pass --use-current-branch if you already cut it)" >&2
        exit 2
    fi
    git checkout -b "$BRANCH" "$BASE_BRANCH"
fi

WORK_ROOT="agent_workers/$SLUG"
SPEC_LOOP_DIR="$WORK_ROOT/spec_loop"
AGENT_LOOP_DIR="$WORK_ROOT/agent_loop"
SEED_SPEC="$WORK_ROOT/seed.md"
SPEC_FINAL="docs/todos/$SLUG.md"
AUDIT_FILE="$WORK_ROOT/audit.md"
AGENT_FEEDBACK="$AGENT_LOOP_DIR/feedback.md"
mkdir -p "$SPEC_LOOP_DIR" "$AGENT_LOOP_DIR" "$(dirname "$SPEC_FINAL")"

# When entering at agent_loop or audit, the spec_loop output already lives
# at SPEC_FINAL — validate it's there and derive TOPIC from its H1 so the
# downstream commit message + PR title still have a sane summary.
if [[ "$FROM_NUM" -gt 1 ]]; then
    if [[ ! -f "$SPEC_FINAL" ]]; then
        echo "ERROR: --from $FROM_STAGE requires existing spec at $SPEC_FINAL" >&2
        exit 2
    fi
    TOPIC=$(grep -m1 '^# ' "$SPEC_FINAL" | sed 's/^# *//; s/[[:space:]]*$//' || true)
    if [[ -z "$TOPIC" ]]; then
        echo "ERROR: spec at $SPEC_FINAL has no '# H1' heading; cannot derive PR title" >&2
        exit 2
    fi
fi

# Seed for spec_loop. Default path: synthesize a minimal scaffold from
# $TOPIC and let spec_loop expand it. With --seed-file, copy the caller's
# file in verbatim so a richer pre-written draft can drive the refinement
# loop. The orchestrator stays dumb either way — spec_loop's behavior is
# identical regardless of how the seed was produced.
# Skipped when --from agent_loop|audit: the spec already exists and
# spec_loop will not be invoked.
if [[ "$FROM_NUM" -le 1 ]]; then
    if [[ -n "$SEED_FILE" ]]; then
        cp "$SEED_FILE" "$SEED_SPEC"
    else
        # Topic phrasing is preserved verbatim so the refined spec can quote
        # the original intent back.
        cat > "$SEED_SPEC" <<EOF
# $TOPIC

## Problem

$TOPIC

## Goals

1. Implement: $TOPIC

## Non-goals

(spec_loop will fill this in based on context)

## Approach

(spec_loop will draft an approach)

## Constraints

- Follow the project's .claude/principles.md if present.

## Open questions

(spec_loop will surface ambiguities for resolution)
EOF
    fi
fi

# Rate-limit detection patterns shared by claude + codex CLIs. Kept narrow
# on purpose — false positives here would mask real failures behind a
# misleading "rate-limited" diagnostic.
_RATE_LIMIT_PATTERNS=(
    "rate_limit_exceeded"
    "rate limit"
    "ratelimit"
    "TooManyRequests"
    "5-hour limit"
    "weekly limit"
    "usage limit"
    "Anthropic API rate"
    "Claude AI usage"
)

# Last agent name mentioned in the loop's run.log — that's the seat that
# owned the in-flight turn when the rate-limit fired. Falls back to a
# generic label when the loop crashed before logging any agent name.
# DEPENDENCY: relies on spec_loop.sh / agent_loop.sh emitting the bare
# agent name (claude|codex|zenmux|fireworks) into run.log as each seat
# takes a turn. If those log emissions are renamed (e.g. to `claude-cli`),
# update the regex below in lockstep or seat detection will silently fall
# back to the generic label.
_detect_exhausted_seat() {
    local logfile="$1" last_agent
    [[ -f "$logfile" ]] || { printf 'unknown agent'; return; }
    last_agent=$(grep -oE '\b(claude|codex|zenmux|fireworks)\b' "$logfile" 2>/dev/null | tail -1 || true)
    case "$last_agent" in
        claude)    printf 'claude' ;;
        codex)     printf 'codex' ;;
        zenmux)    printf 'zenmux' ;;
        fireworks) printf 'fireworks' ;;
        *)         printf 'unknown agent' ;;
    esac
}

_check_rate_limit() {
    local logfile="$1" pat
    [[ -f "$logfile" ]] || return 1
    for pat in "${_RATE_LIMIT_PATTERNS[@]}"; do
        if grep -qFi -- "$pat" "$logfile"; then
            return 0
        fi
    done
    return 1
}

# Wrap a loop subprocess. On non-zero exit, scan the loop's run.log for
# rate-limit patterns and emit a loud, seat-named FATAL message; otherwise
# propagate the exit code with a generic ERROR. v1 has no cross-family
# fallback — that's Future Work.
# Args: <seat-label> <run-log-path> <cmd...>
_run_loop() {
    local seat="$1"; shift
    local run_log="$1"; shift
    local rc=0
    set +e
    "$@"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        if _check_rate_limit "$run_log"; then
            local exhausted
            exhausted=$(_detect_exhausted_seat "$run_log")
            echo "" >&2
            echo "FATAL: $seat — $exhausted seat appears rate-limited / exhausted." >&2
            echo "FATAL: no automated cross-family fallback in v1 (see Future Work)." >&2
            echo "FATAL: workspace preserved at $WORK_ROOT — rerun after the cap resets." >&2
            echo "--- tail of $run_log ---" >&2
            tail -30 "$run_log" >&2 || true
            exit 1
        fi
        echo "ERROR: $seat exited $rc; see $run_log" >&2
        exit "$rc"
    fi
}

if [[ "$FROM_NUM" -le 1 ]]; then
    echo ">>> [1/4] spec_loop refining seed..." >&2
    # Agent selection:
    #   - All defaults (no -i, no -r): omit -a so spec_loop.sh applies its own
    #     default (codex,claude) — subscription-priced, cross-family.
    #   - Either -i or -r set: propagate "$REVIEWER,$CODER" so an explicit pick
    #     carries through (e.g. -r zenmux to bypass a tight codex quota).
    # Reviewer goes first so the cross-family seat opens the spec discussion
    # and the coder responds. Per-role ordering knobs are Future Work.
    if [[ "$_CODER_USER_SET" == true || "$_REVIEWER_USER_SET" == true ]]; then
        _run_loop "spec_loop" "$SPEC_LOOP_DIR/run.log" \
            "$SPEC_LOOP" -f "$SEED_SPEC" -w "$SPEC_LOOP_DIR" -a "$REVIEWER" -a "$CODER"
    else
        _run_loop "spec_loop" "$SPEC_LOOP_DIR/run.log" \
            "$SPEC_LOOP" -f "$SEED_SPEC" -w "$SPEC_LOOP_DIR"
    fi

    cp "$SEED_SPEC" "$SPEC_FINAL"
else
    echo ">>> [1/4] spec_loop skipped (--from $FROM_STAGE; reusing $SPEC_FINAL)" >&2
fi

if [[ "$FROM_NUM" -le 2 ]]; then
    echo ">>> [2/4] agent_loop implementing..." >&2
    # Resume signal: agent_loop.sh writes changes.md (the phased plan) and
    # .state (the per-phase attempt counter / pinned session ids) into its
    # workspace. Their presence under --from agent_loop means a prior run
    # got partway through implementation; passing -R restores the phase
    # tracker and pinned sessions instead of starting a fresh run that
    # would either redo committed phases or rewrite the workspace state.
    # On the default --from spec_loop path, the workspace is fresh, so no
    # -R is needed (and -R against a missing state file would be an error).
    _agent_loop_extra=()
    if [[ "$FROM_NUM" -eq 2 ]] \
            && { [[ -f "$AGENT_LOOP_DIR/changes.md" ]] || [[ -f "$AGENT_LOOP_DIR/.state" ]]; }; then
        _agent_loop_extra=(-R)
        echo ">>> agent_loop: prior workspace detected — passing -R to resume" >&2
    fi
    _run_loop "agent_loop" "$AGENT_LOOP_DIR/run.log" \
        "$AGENT_LOOP" -f "$SPEC_FINAL" -w "$AGENT_LOOP_DIR" \
            -i "$CODER" -r "$REVIEWER" "${_agent_loop_extra[@]}"
else
    echo ">>> [2/4] agent_loop skipped (--from $FROM_STAGE)" >&2
fi

if [[ "$SKIP_AUDIT" == false ]]; then
    echo ">>> [3/4] audit gate..." >&2
    # audit-pr.sh validates that OSS_FLASH_MODEL / OSS_PRO_MODEL / OSS_MODEL
    # name the same provider as --engine. The user's ambient values may
    # name a different provider (their default for manual audit-pr.sh
    # runs), so override all three for the subprocess so -a $AUDITOR wins.
    # Slugs reuse the per-provider agent default since the audit role
    # doesn't warrant its own knob in v2 (introduce *_AUDIT_MODEL later
    # if a need emerges). All three are set to the same `<provider>:<slug>`
    # — audit-pr.sh today only consumes OSS_FLASH_MODEL on this code path
    # (no --auto-tier, no -M), but future fallback logic that reaches for
    # OSS_PRO_MODEL or OSS_MODEL would still find a provider-matched value
    # rather than something stale from the user's shell. Native engines
    # (claude/codex) skip the OSS path entirely, so the empty values are
    # harmless.
    _audit_oss_model=""
    case "$AUDITOR" in
        zenmux)    _audit_oss_model="zenmux:${ZENMUX_AGENT_MODEL:-deepseek/deepseek-v4-pro}" ;;
        fireworks) _audit_oss_model="fireworks:${FIREWORKS_AGENT_MODEL:-accounts/fireworks/models/minimax-m2p7}" ;;
    esac
    # repairs_done counts repair rounds completed so far (0 before any
    # repair has run). The loop banner prints `pass $((repairs_done + 1))`
    # so the operator's pass number aligns with the surrender message:
    # MAX_AUDIT_ROUNDS=N means N repairs are allowed, so pass N+1 is the
    # final audit attempt before surrendering.
    repairs_done=0
    while :; do
        echo ">>> audit pass $((repairs_done + 1)) of max $MAX_AUDIT_ROUNDS..." >&2
        if OSS_FLASH_MODEL="$_audit_oss_model" \
                OSS_PRO_MODEL="$_audit_oss_model" \
                OSS_MODEL="$_audit_oss_model" \
                "$AUDIT_SCRIPT" -b "$BASE_BRANCH" --no-fetch \
                --engine "$AUDITOR" --strict -o "$AUDIT_FILE"; then
            echo ">>> audit clean — no [BLOCKER]s." >&2
            break
        fi
        if [[ "$repairs_done" -ge "$MAX_AUDIT_ROUNDS" ]]; then
            echo "" >&2
            echo "FATAL: blockers remain after $MAX_AUDIT_ROUNDS round(s)." >&2
            echo "FATAL: audit report: $AUDIT_FILE" >&2
            echo "FATAL: workspace preserved at $WORK_ROOT — no PR opened." >&2
            echo "--- tail of $AUDIT_FILE ---" >&2
            cat "$AUDIT_FILE" >&2 || true
            exit 1
        fi
        {
            printf '\n--- Auditor feedback (round %s) ---\n' "$repairs_done"
            cat "$AUDIT_FILE"
        } >> "$AGENT_FEEDBACK"
        # Open a fresh repair phase so agent_loop -R has [TODO] work to pick
        # up. Without this, the real agent_loop sees all phases [DONE] and
        # exits early after inject_feedback (agent_loop.sh:610-615), so the
        # auditor blockers would be recorded but never acted on.
        local_changes="$AGENT_LOOP_DIR/changes.md"
        existing_phases=0
        [[ -f "$local_changes" ]] \
            && existing_phases=$(grep -c '^## Phase ' "$local_changes" || true)
        next_phase=$((existing_phases + 1))
        cat >> "$local_changes" <<REPAIR

## Phase $next_phase: address auditor feedback (round $repairs_done) [TODO]
**Scope**: Resolve all [BLOCKER] findings from $AUDIT_FILE; do not regress prior phases.
**Sections**: all
**Exit criteria**: Next audit returns no [BLOCKER]s.
REPAIR
        echo ">>> blockers fed back to agent_loop; running -R..." >&2
        _run_loop "agent_loop -R" "$AGENT_LOOP_DIR/run.log" \
            "$AGENT_LOOP" -f "$SPEC_FINAL" -w "$AGENT_LOOP_DIR" \
                -i "$CODER" -r "$REVIEWER" -R
        repairs_done=$((repairs_done + 1))
    done
else
    echo ">>> [3/4] audit gate skipped (--skip-audit)" >&2
fi

# .gitignore hygiene — workspace dirs must never leak into the PR.
if ! git check-ignore -q agent_workers/ 2>/dev/null; then
    echo 'agent_workers/' >> .gitignore
    git add .gitignore
    git commit -m "chore: ignore agent_workers/" -- .gitignore \
        || git reset HEAD -- .gitignore
fi
if git diff --cached --name-only | grep -q '^agent_workers/'; then
    echo "ERROR: agent_workers/ files are staged — fix .gitignore" >&2
    exit 1
fi

# Stage spec + every other implementation file. Iterate explicit name lists
# instead of `git add -A` so any future scratch path that slips past
# .gitignore doesn't get swept into the PR silently.
git add -- "$SPEC_FINAL"
mapfile -t _untracked < <(git ls-files --others --exclude-standard)
for f in "${_untracked[@]}"; do
    case "$f" in
        agent_workers/*|'') continue ;;
        *) git add -- "$f" ;;
    esac
done
mapfile -t _modified < <(git diff --name-only)
for f in "${_modified[@]}"; do
    case "$f" in
        agent_workers/*|'') continue ;;
        *) git add -- "$f" ;;
    esac
done

SUMMARY=$(grep -m1 '^# ' "$SPEC_FINAL" | sed 's/^# *//' || true)
[[ -z "$SUMMARY" ]] && SUMMARY="$TOPIC"

# Skip when nothing is staged. With --from audit (and sometimes --from
# agent_loop), the agents may have already committed everything via their
# own commit machinery, leaving nothing for this final commit to pick up;
# bare `git commit` would then exit 1 and abort the push/PR.
if ! git diff --cached --quiet; then
    git commit -m "feat($SLUG): $SUMMARY

Full spec: $SPEC_FINAL
Generated by mesh spec-to-ship pipeline.

Co-Authored-By: Claude <noreply@anthropic.com>"
else
    echo ">>> nothing to commit at PR step (already committed by earlier stage)" >&2
fi

# Normalize BASE_BRANCH for the PR base. gh pr create defaults to the
# repo's default branch when --base is omitted, which would silently
# diverge from the audit's diff base. Strip remote-tracking prefixes so
# `origin/develop` becomes `develop`; keep nested local refs intact
# (`release/v1.0` stays `release/v1.0`). Computed before push so the
# recovery hint can name the right --base if the push itself fails.
PR_BASE="$BASE_BRANCH"
_full_ref=$(git rev-parse --symbolic-full-name "$BASE_BRANCH" 2>/dev/null || true)
case "$_full_ref" in
    refs/remotes/*)
        # refs/remotes/<remote>/<branch...> → <branch...>
        PR_BASE="${_full_ref#refs/remotes/}"
        PR_BASE="${PR_BASE#*/}"
        ;;
    refs/heads/*)
        PR_BASE="${_full_ref#refs/heads/}"
        ;;
esac

git push -u origin "$BRANCH" || { echo "FATAL: push failed. To recover: git push -u origin $BRANCH && gh pr create --base $PR_BASE" >&2; exit 1; }

echo ">>> [4/4] opening PR (base=$PR_BASE)..." >&2
PR_URL=$(gh pr create \
    --base "$PR_BASE" \
    --title "feat($SLUG): $SUMMARY" \
    --body "## Summary

$SUMMARY

## Spec

Full spec: \`$SPEC_FINAL\`

## Test plan

- [ ] CI passes (lint + tests already enforced by agent_loop)
- [ ] Production-safety audit cleared by OSS auditor
- [ ] Manual review of \`$SPEC_FINAL\` and the implementation diff

Generated by the mesh \`spec-to-ship\` pipeline.")

echo "$PR_URL"
