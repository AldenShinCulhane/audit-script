#!/bin/bash

# Implementation loop: two agents collaborate to implement a spec phase by phase.
# One agent implements, the other reviews via comments. For spec refinement, see spec_loop.sh.
#
# Flow per phase:
#   1. Implementer codes the phase (including tests)
#   2. Script runs ruff + pytest on changed files only (hard gate)
#   3. If lint/tests fail → feed errors back to implementer, go to 1
#   4. Reviewer evaluates code + tests against spec, writes comments
#   5. If reviewer has comments → feed back to implementer, go to 1
#   6. If reviewer approves → mark [DONE], next phase
#
# Token optimization:
#   When claude is the implementer, each phase gets a pinned session (--session-id).
#   Attempt 1 builds full context (spec + plan). Attempts 2+ resume the session
#   (--resume) with a lean prompt — just review comments — saving re-reads.
#
# Files (under <project>/agent_workers/agent_loop/):
#   spec.md      — the specification (read-only reference)
#   changes.md   — phased plan with progress tracking
#   comments.md  — two-way discussion: review comments, rebuttals, validation errors
#   feedback.md  — human can inject feedback or write "stop"/"exit"
#   run.log      — full log

# Resolve directory where this script (and its auxiliary files) lives,
# so paths work regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_FILE="$SCRIPT_DIR/lib/agent_sessions.sh"

MAX_FIX_ATTEMPTS="${MAX_FIX_ATTEMPTS:-5}"
MAX_PLAN_ATTEMPTS="${MAX_PLAN_ATTEMPTS:-3}"
PYTEST_PER_TEST_TIMEOUT="${PYTEST_PER_TEST_TIMEOUT:-120}"
PYTEST_TOTAL_TIMEOUT="${PYTEST_TOTAL_TIMEOUT:-300}"

# Defensive: non-numeric overrides would silently break the comparisons below.
for _var in MAX_FIX_ATTEMPTS MAX_PLAN_ATTEMPTS PYTEST_PER_TEST_TIMEOUT PYTEST_TOTAL_TIMEOUT; do
    if ! [[ "${!_var}" =~ ^[0-9]+$ ]] || [ "${!_var}" -lt 1 ]; then
        echo "ERROR: $_var='${!_var}' must be a positive integer" >&2
        exit 1
    fi
done
unset _var

if [ ! -f "$LIB_FILE" ]; then
    echo "ERROR: Session helper not found: $LIB_FILE" >&2
    exit 1
fi

# shellcheck source=agent_workers/lib/agent_sessions.sh
. "$LIB_FILE"

cleanup() {
    if [ -n "$AGENT_PID" ]; then
        kill "$AGENT_PID" 2>/dev/null
        pkill -P "$AGENT_PID" 2>/dev/null
        wait "$AGENT_PID" 2>/dev/null
    fi
    [ -n "$LOGFILE" ] && echo " Agent loop terminated." >> "$LOGFILE"
}
trap cleanup EXIT

# Agent run/session helpers come from lib/agent_sessions.sh.

MAX_AGENT_ATTEMPTS=3
TRANSIENT_RETRY_DELAY=30

# Wrapper around run_agent_turn that retries on transient API errors (exit 2+).
# Exit 0 = success, exit 1 = session error (handled by run_agent_turn itself).
# Exit 2+ = transient (500, network timeout) — retry with backoff.
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
        # Check output for fatal (non-retryable) errors
        if [ -n "$outfile" ] && [ -f "$outfile" ] && is_fatal_error "$(cat "$outfile")"; then
            echo " FATAL: Agent hit a non-retryable error. Exiting." >> "$LOGFILE"
            echo "FATAL: Agent error (see $LOGFILE for details)." >&2
            exit 1
        fi
        if [ "$rc" -ge 2 ] && [ "$attempt" -lt "$MAX_AGENT_ATTEMPTS" ]; then
            echo " Transient error (exit $rc). Retrying in ${TRANSIENT_RETRY_DELAY}s (attempt $attempt/$MAX_AGENT_ATTEMPTS)..." >> "$LOGFILE"
            sleep "$TRANSIENT_RETRY_DELAY"
        else
            echo " Agent failed (exit $rc) after $attempt attempt(s)." >> "$LOGFILE"
            return "$rc"
        fi
    done
}

# Discover files changed since the phase marker was dropped.
# Populates CHANGED_PY_SRC, CHANGED_PY_TESTS, CHANGED_SH, CHANGED_TS arrays.
discover_changed_files() {
    CHANGED_PY_SRC=()
    CHANGED_PY_TESTS=()
    CHANGED_SH_SRC=()
    CHANGED_SH_TESTS=()
    CHANGED_TS_SRC=()
    CHANGED_TS_TESTS=()

    local -a all_changed_arr=()
    while IFS= read -r -d '' f; do
        all_changed_arr+=("$f")
    done < <(find "$PROJECT_ROOT" -newer "$WORKSPACE_DIR/.phase_marker" \
        \( -name '*.py' -o -name '*.sh' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) \
        -not -path "$PROJECT_ROOT/.venv/*" \
        -not -path "$PROJECT_ROOT/.tox/*" \
        -not -path "$PROJECT_ROOT/__pycache__/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/.next/*" \
        -print0 | sort -z)

    for f in "${all_changed_arr[@]}"; do
        local base; base=$(basename "$f")
        case "$f" in
            *.py)
                if echo "$f" | grep -q "^$PROJECT_ROOT/tests/"; then
                    CHANGED_PY_TESTS+=("$f")
                else
                    CHANGED_PY_SRC+=("$f")
                fi
                ;;
            *.sh)
                if [[ "$base" == test_* || "$base" == *_test.sh || "$f" == */tests/* ]]; then
                    CHANGED_SH_TESTS+=("$f")
                else
                    CHANGED_SH_SRC+=("$f")
                fi
                ;;
            *.ts|*.tsx|*.js|*.jsx)
                if [[ "$base" == *.test.* || "$base" == *.spec.* || "$f" == */__tests__/* || "$f" == */tests/* ]]; then
                    CHANGED_TS_TESTS+=("$f")
                else
                    CHANGED_TS_SRC+=("$f")
                fi
                ;;
        esac
    done

    ALL_CHANGED=("${CHANGED_PY_SRC[@]}" "${CHANGED_PY_TESTS[@]}" "${CHANGED_SH_SRC[@]}" "${CHANGED_SH_TESTS[@]}" "${CHANGED_TS_SRC[@]}" "${CHANGED_TS_TESTS[@]}")
    echo " Changed files: ${ALL_CHANGED[*]}" >> "$LOGFILE"
}

# Run lint and tests scoped to changed files only. Returns 0 if all pass, 1 if any fail.
run_validation() {
    discover_changed_files

    if [ ${#ALL_CHANGED[@]} -eq 0 ]; then
        echo " No changed source files found — skipping validation." >> "$LOGFILE"
        return 0
    fi

    echo " Running validation on: ${ALL_CHANGED[*]}" >> "$LOGFILE"
    local result=0
    true > "$WORKSPACE_DIR/.validation.txt"

    # ── Python validation ──
    local all_py=("${CHANGED_PY_SRC[@]}" "${CHANGED_PY_TESTS[@]}")
    if [ ${#all_py[@]} -gt 0 ]; then
        echo "=== ruff check ===" >> "$WORKSPACE_DIR/.validation.txt"
        if ! ruff check "${all_py[@]}" >> "$WORKSPACE_DIR/.validation.txt" 2>&1; then
            result=1
        fi

        echo "=== ruff format --check ===" >> "$WORKSPACE_DIR/.validation.txt"
        if ! ruff format --check "${all_py[@]}" >> "$WORKSPACE_DIR/.validation.txt" 2>&1; then
            result=1
        fi

        if [ ${#CHANGED_PY_TESTS[@]} -gt 0 ]; then
            echo "=== pytest ===" >> "$WORKSPACE_DIR/.validation.txt"
            timeout "$PYTEST_TOTAL_TIMEOUT" pytest -x --tb=short \
                --timeout="$PYTEST_PER_TEST_TIMEOUT" \
                --timeout-method=thread \
                "${CHANGED_PY_TESTS[@]}" >> "$WORKSPACE_DIR/.validation.txt" 2>&1
            pytest_rc=$?
            if [ "$pytest_rc" -ne 0 ]; then
                result=1
                if [ "$pytest_rc" -eq 124 ]; then
                    echo "pytest exceeded global timeout (${PYTEST_TOTAL_TIMEOUT}s)." >> "$WORKSPACE_DIR/.validation.txt"
                fi
            fi
        fi
    fi

    # ── Bash validation ──
    local all_sh=("${CHANGED_SH_SRC[@]}" "${CHANGED_SH_TESTS[@]}")
    if [ ${#all_sh[@]} -gt 0 ] && command -v shellcheck >/dev/null 2>&1; then
        echo "=== shellcheck ===" >> "$WORKSPACE_DIR/.validation.txt"
        if ! shellcheck -S warning "${all_sh[@]}" >> "$WORKSPACE_DIR/.validation.txt" 2>&1; then
            result=1
        fi
    fi

    if [ ${#CHANGED_SH_TESTS[@]} -gt 0 ]; then
        echo "=== bash tests ===" >> "$WORKSPACE_DIR/.validation.txt"
        for test_sh in "${CHANGED_SH_TESTS[@]}"; do
            echo "--- $test_sh ---" >> "$WORKSPACE_DIR/.validation.txt"
            if ! timeout "$PYTEST_TOTAL_TIMEOUT" bash "$test_sh" >> "$WORKSPACE_DIR/.validation.txt" 2>&1; then
                result=1
            fi
        done
    fi

    # ── TypeScript/JavaScript validation ──
    # Group files by their package root so each project uses its own toolchain + CWD
    local all_ts=("${CHANGED_TS_SRC[@]}" "${CHANGED_TS_TESTS[@]}")
    if [ ${#all_ts[@]} -gt 0 ]; then
        # Collect unique project roots
        declare -A _ts_roots
        for tf in "${all_ts[@]}"; do
            local d; d=$(dirname "$tf")
            while [ "$d" != "/" ]; do
                if [ -f "$d/package.json" ]; then
                    _ts_roots["$d"]=1
                    break
                fi
                d=$(dirname "$d")
            done
        done

        for ts_project_root in "${!_ts_roots[@]}"; do
            # Collect files belonging to this project root
            local proj_files=() proj_tests=()
            for tf in "${all_ts[@]}"; do
                [[ "$tf" == "$ts_project_root/"* ]] || continue
                proj_files+=("$tf")
                local tbase; tbase=$(basename "$tf")
                if [[ "$tbase" == *.test.* || "$tbase" == *.spec.* || "$tf" == */__tests__/* || "$tf" == */tests/* ]]; then
                    proj_tests+=("$tf")
                fi
            done
            [ ${#proj_files[@]} -eq 0 ] && continue

            echo "=== TS/JS validation: $ts_project_root ===" >> "$WORKSPACE_DIR/.validation.txt"

            # Lint (run from project root for correct config resolution)
            if [ -f "$ts_project_root/node_modules/.bin/eslint" ]; then
                echo "--- eslint ---" >> "$WORKSPACE_DIR/.validation.txt"
                if ! (cd "$ts_project_root" && ./node_modules/.bin/eslint "${proj_files[@]}") >> "$WORKSPACE_DIR/.validation.txt" 2>&1; then
                    result=1
                fi
            elif [ -f "$ts_project_root/node_modules/.bin/tsc" ]; then
                echo "--- tsc --noEmit ---" >> "$WORKSPACE_DIR/.validation.txt"
                if ! (cd "$ts_project_root" && ./node_modules/.bin/tsc --noEmit) >> "$WORKSPACE_DIR/.validation.txt" 2>&1; then
                    result=1
                fi
            fi

            # Tests
            if [ ${#proj_tests[@]} -gt 0 ]; then
                if [ -f "$ts_project_root/node_modules/.bin/jest" ]; then
                    echo "--- jest ---" >> "$WORKSPACE_DIR/.validation.txt"
                    if ! (cd "$ts_project_root" && timeout "$PYTEST_TOTAL_TIMEOUT" \
                        ./node_modules/.bin/jest --passWithNoTests "${proj_tests[@]}") >> "$WORKSPACE_DIR/.validation.txt" 2>&1; then
                        result=1
                    fi
                elif [ -f "$ts_project_root/node_modules/.bin/vitest" ]; then
                    echo "--- vitest ---" >> "$WORKSPACE_DIR/.validation.txt"
                    if ! (cd "$ts_project_root" && timeout "$PYTEST_TOTAL_TIMEOUT" \
                        ./node_modules/.bin/vitest run "${proj_tests[@]}") >> "$WORKSPACE_DIR/.validation.txt" 2>&1; then
                        result=1
                    fi
                fi
            fi
        done
        unset _ts_roots
    fi

    if [ "$result" -eq 0 ]; then
        echo " Validation passed." >> "$LOGFILE"
    else
        echo " Validation failed." >> "$LOGFILE"
        cat "$WORKSPACE_DIR/.validation.txt" >> "$LOGFILE"
    fi
    return $result
}

check_stop() {
    if [ -s "$FEEDBACK_FILE" ] && grep -qi '^\s*\(stop\|exit\)\s*$' "$FEEDBACK_FILE"; then
        echo " Received stop/exit signal. Shutting down." >> "$LOGFILE"
        true > "$FEEDBACK_FILE"
        exit 0
    fi
}

inject_feedback() {
    if [ -s "$FEEDBACK_FILE" ]; then
        check_stop
        HUMAN_FB=$(cat "$FEEDBACK_FILE")
        true > "$FEEDBACK_FILE"
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "\n--- Human [$TIMESTAMP] ---\n$HUMAN_FB" >> "$REVIEW_FILE"
        echo " Human feedback injected into review." >> "$LOGFILE"
    fi
}

# Persist session state so --resume can restore agent context.
save_state() {
    {
        echo "STATE_PHASE=$CURRENT_PHASE"
        echo "STATE_FIX_ATTEMPTS=$FIX_ATTEMPTS"
        for key in "${!SESSION_IDS[@]}"; do
            echo "STATE_SID_${key}=${SESSION_IDS[$key]}"
        done
        for key in "${!STARTED_SESSIONS[@]}"; do
            echo "STATE_STARTED_${key}=${STARTED_SESSIONS[$key]}"
        done
    } > "$STATE_FILE"
}

# Restore session state from a previous run.
load_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo " No state file found. Cannot resume." >> "$LOGFILE"
        return 1
    fi
    RESUMED_PHASE=""
    RESUMED_FIX_ATTEMPTS=0
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            STATE_PHASE) RESUMED_PHASE="$value" ;;
            STATE_FIX_ATTEMPTS) RESUMED_FIX_ATTEMPTS="$value" ;;
            STATE_SID_*)
                local skey="${key#STATE_SID_}"
                SESSION_IDS["$skey"]="$value"
                STARTED_SESSIONS["$skey"]=1
                ;;
            STATE_STARTED_*)
                local skey="${key#STATE_STARTED_}"
                STARTED_SESSIONS["$skey"]="$value"
                ;;
        esac
    done < "$STATE_FILE"
    echo " Loaded state: phase=$RESUMED_PHASE, fix_attempts=$RESUMED_FIX_ATTEMPTS, sessions=${!SESSION_IDS[*]}" >> "$LOGFILE"
    return 0
}

ensure_review_prereqs() {
    touch "$REVIEW_FILE"
    if [ ! -f "$PRINCIPLES_FILE" ]; then
        echo "ERROR: Required reviewer guide not found: $PRINCIPLES_FILE" | tee -a "$LOGFILE" >&2
        exit 1
    fi
}

# Defaults
IMPLEMENTER="claude"
REVIEWER="codex"
SINGLE_PHASE=false
RESUME=false
PROJECT_DIR=""
WORKSPACE_OPT=""
usage() {
    cat <<'USAGE'
Usage: agent_loop.sh [-d project_dir] [-w workspace_dir] [-i AGENT] [-r AGENT] [-f spec_file] [-1] [-R]

Two-agent implementation loop. One agent implements, the other reviews via comments.
The script enforces lint/tests (scoped to changed files) between them.
All discussion happens in comments.md with attribution and timestamps.

On first run, the implementer creates changes.md with phases.
Each phase: implement → lint/test → review → approve or iterate.

When claude is the implementer, each phase uses a pinned session (--session-id).
Fix attempts resume the session (--resume) with a lean prompt to save tokens.

Options:
  -d <dir>     Project directory to operate on (default: current working directory)
  -w <dir>     Workspace directory for state files (default: <project>/agent_workers/agent_loop/)
  -i <agent>   Agent for implementation (default: claude). See AGENTS below.
  -r <agent>   Agent for review (default: codex). See AGENTS below.
  -f <file>    Use this spec file directly.
               If the file doesn't exist, falls back to agent_loop/spec.md.
               The spec is read-only during implementation.
  -1           Single-phase mode: skip LLM plan creation, treat spec as one unit
  -R           Resume a previous run: restore agent sessions and preserve comments.md

AGENTS (vocabulary shared with spec_loop.sh and spec_to_ship.sh):
  claude     Subscription Opus 4.7 via the claude CLI. Default coder seat.
             High-quality multi-turn agentic; biggest subscription ceiling;
             no pay-per-token cost.
  codex      Subscription GPT 5.5 via the codex CLI. Default reviewer seat.
             Cross-family from claude (catches correlated blind spots);
             strong at short/medium context typical of code review.
  zenmux     PAYG OSS gateway (DeepSeek family by default). Routes the
             `claude` binary at zenmux.ai/api/anthropic via ANTHROPIC_BASE_URL.
             Fits long-context coder/reviewer roles when the subscription
             ceiling is exhausted. Requires ZENMUX_API_KEY; slug overridable
             via ZENMUX_AGENT_MODEL (default: deepseek/deepseek-v4-pro).
  fireworks  PAYG OSS gateway (Minimax M2 by default). Same shape as zenmux,
             alternate provider. Requires FIREWORKS_API_KEY; slug overridable
             via FIREWORKS_AGENT_MODEL.

Examples:
  cd ~/projects/aura && ../../mesh/agent_workers/agent_loop.sh   # operate on aura
  ./agent_workers/agent_loop.sh -d ../sibling-repo                 # operate on sibling repo
  ./agent_workers/agent_loop.sh -i codex -r claude               # swap roles
  ./agent_workers/agent_loop.sh -i zenmux -r claude              # OSS coder, claude reviewer
  ./agent_workers/agent_loop.sh -f docs/design.md                # seed spec from draft
  ./agent_workers/agent_loop.sh -1                               # small spec, single phase
  ./agent_workers/agent_loop.sh -R                               # resume after stop/crash
USAGE
    exit 0
}

while getopts "d:w:i:r:f:1Rh" opt; do
  case $opt in
    d) PROJECT_DIR="$OPTARG" ;;
    w) WORKSPACE_OPT="$OPTARG" ;;
    i) IMPLEMENTER="$OPTARG" ;;
    r) REVIEWER="$OPTARG" ;;
    f) SPEC_FILE_OPT="$OPTARG" ;;
    1) SINGLE_PHASE=true ;;
    R) RESUME=true ;;
    h) usage ;;
    \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
  esac
done

for agent in "$IMPLEMENTER" "$REVIEWER"; do
    case "$agent" in
        claude|codex|zenmux|fireworks) ;;
        *) echo "ERROR: Agent must be 'claude'|'codex'|'zenmux'|'fireworks', got '$agent'" >&2; exit 1 ;;
    esac
done

# Fail-fast prereq checks for agentic OSS providers (zenmux/fireworks);
# better than discovering a missing key mid-cycle.
oss_agents_require_api_key "$IMPLEMENTER" "-i" || exit 1
oss_agents_require_api_key "$REVIEWER"    "-r" || exit 1

# Derive project root and workspace paths after option parsing.
# PROJECT_ROOT is the repo being worked on (default: CWD).
# WORKSPACE_DIR holds state files and lives under the target project.
PROJECT_ROOT="$(cd "${PROJECT_DIR:-$PWD}" && pwd)"
export AGENT_PROJECT_ROOT="$PROJECT_ROOT"
if [ -n "$WORKSPACE_OPT" ]; then
    # Resolve relative paths against PROJECT_ROOT
    case "$WORKSPACE_OPT" in
        /*) WORKSPACE_DIR="$WORKSPACE_OPT" ;;
        *)  WORKSPACE_DIR="$PROJECT_ROOT/$WORKSPACE_OPT" ;;
    esac
    mkdir -p "$WORKSPACE_DIR"
    WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"
else
    WORKSPACE_DIR="$PROJECT_ROOT/agent_workers/agent_loop"
fi
OUT_DIR="$WORKSPACE_DIR/out"
SPEC_FILE="$WORKSPACE_DIR/spec.md"
PLAN_FILE="$WORKSPACE_DIR/changes.md"
REVIEW_FILE="$WORKSPACE_DIR/comments.md"
LOGFILE="$WORKSPACE_DIR/run.log"
FEEDBACK_FILE="$WORKSPACE_DIR/feedback.md"
STATE_FILE="$WORKSPACE_DIR/.state"
PRINCIPLES_FILE="$PROJECT_ROOT/.claude/principles.md"

mkdir -p "$WORKSPACE_DIR" "$OUT_DIR"
touch "$REVIEW_FILE"
agent_sessions_init

# Change to project root so agents (claude has no -C flag) run in the right directory.
cd "$PROJECT_ROOT" || exit 1

# If -f was given, operate on that file directly rather than copying it into
# the workspace. This keeps the caller's spec path canonical across the run.
if [ -n "$SPEC_FILE_OPT" ]; then
    if [ -f "$SPEC_FILE_OPT" ]; then
        SPEC_FILE="$(cd "$(dirname "$SPEC_FILE_OPT")" && pwd)/$(basename "$SPEC_FILE_OPT")"
        echo "Using spec file: $SPEC_FILE"
    else
        echo "Draft '$SPEC_FILE_OPT' not found, falling back to $SPEC_FILE"
    fi
fi

if [ ! -f "$SPEC_FILE" ]; then
    echo "ERROR: No spec found. Provide a draft with -f or create $SPEC_FILE manually." >&2
    exit 1
fi

RESUMING_PHASE=false
if [ "$RESUME" = true ]; then
    RESUMING_PHASE=true
    if load_state; then
        echo "Resuming previous run (phase $RESUMED_PHASE, attempt $RESUMED_FIX_ATTEMPTS)."
        echo "  Restored sessions: ${!SESSION_IDS[*]}"
    else
        RESUMED_PHASE=""
        RESUMED_FIX_ATTEMPTS=0
        echo "Resuming (no state file — preserving comments.md, sessions start fresh)."
    fi
fi

echo "Starting Implementation Loop."
echo "  Implementer: $IMPLEMENTER | Reviewer: $REVIEWER | Spec: $SPEC_FILE"
echo "  Plan: $PLAN_FILE | Max fix attempts: $MAX_FIX_ATTEMPTS | Plan review rounds: $MAX_PLAN_ATTEMPTS | Single-phase: $SINGLE_PHASE | Resume: $RESUME"
echo "Monitor progress: tail -f $LOGFILE"
echo "Inject feedback: echo 'your feedback' > $FEEDBACK_FILE"
echo "WARNING: Running with permissions bypassed. Ensure you are in an isolated environment!"

# Phase 0: Create implementation plan if it doesn't exist
if [ ! -f "$PLAN_FILE" ]; then
    if [ "$SINGLE_PHASE" = true ]; then
        echo " Single-phase mode: generating plan from spec title..." >> "$LOGFILE"
        # Extract a title from the first heading or first non-empty line
        SPEC_TITLE=$(grep -m1 '^# ' "$SPEC_FILE" | sed 's/^# *//' || head -1 "$SPEC_FILE")
        [ -z "$SPEC_TITLE" ] && SPEC_TITLE="Implement spec"
        cat > "$PLAN_FILE" <<PLAN_EOF
## Phase 1: ${SPEC_TITLE} [TODO]
**Scope**: All modules/files described in the spec
**Sections**: all
**Exit criteria**: All tests pass, lint clean, spec requirements met
PLAN_EOF
        echo " Single-phase plan created." >> "$LOGFILE"
    else
        echo " Creating implementation plan from $SPEC_FILE..." >> "$LOGFILE"

        if ! run_agent_turn_with_retry "$IMPLEMENTER" "plan_create_${IMPLEMENTER}" \
            "Read $SPEC_FILE. Create $PLAN_FILE with a phased implementation plan. Rules:
- Prefer fewer, larger phases over many small ones. Each phase should represent a
  meaningful milestone, not a single function or file. For a cohesive module spec,
  2-4 phases is usually right. Only go beyond 5 for genuinely large, multi-module specs.
- Each phase should be a self-contained unit that can be built and tested independently.
- Respect dependency order: don't schedule work that depends on unbuilt modules.
- Keep every field terse: one-line fragments where possible.
- Use this exact format for each phase (the script parses these markers):

## Phase 1: [SHORT TITLE] [TODO]
**Scope**: What modules/files this phase covers
**Sections**: Which spec sections to reference (e.g., 4.1-4.2)
**Exit criteria**: How to verify this phase is complete (tests, lint, etc.)

## Phase 2: [SHORT TITLE] [TODO]
...

Mark all phases [TODO]. The agent will change them to [DONE] as it completes each one.
Do NOT implement any code yet — only create the plan." \
            "$OUT_DIR/plan_create.txt"; then
            echo "ERROR: Plan creation agent failed (exit $LAST_AGENT_EXIT)." >&2
            exit 1
        fi

        if ! grep -q '## Phase [0-9].*\[TODO\]' "$PLAN_FILE"; then
            echo "ERROR: Plan file has no parseable '## Phase N: ... [TODO]' blocks." >&2
            exit 1
        fi

        # Reviewer validates the plan
        PLAN_ATTEMPT=0
        while [ "$PLAN_ATTEMPT" -lt "$MAX_PLAN_ATTEMPTS" ]; do
            check_stop
            PLAN_ATTEMPT=$((PLAN_ATTEMPT + 1))
            echo " Plan review — $REVIEWER reviewing (attempt $PLAN_ATTEMPT/$MAX_PLAN_ATTEMPTS)..." >> "$LOGFILE"
            ensure_review_prereqs

            : > "$REVIEW_FILE"
            PLAN_REVIEW_HASH_BEFORE=$(md5sum "$REVIEW_FILE" | cut -d' ' -f1)

            if ! run_agent_turn_with_retry "$REVIEWER" "plan_review_${REVIEWER}" \
                "You are reviewing an implementation plan against a spec.
- Read $SPEC_FILE (the full specification).
- Read $PLAN_FILE (the proposed phased plan).
- Check:
  * Does the plan cover ALL spec requirements? Flag any missing sections.
  * Are phases too granular? Each phase should be a meaningful milestone, not a single
    function or file. A cohesive module spec should have 2-4 phases, not 8-10.
  * Are phases self-contained and in correct dependency order?
  * Are exit criteria testable?
- If you find issues, write terse bullet comments to $REVIEW_FILE under '## Plan Review'. Do NOT edit $PLAN_FILE.
- If the plan is sound, do NOT modify $REVIEW_FILE. Output exactly 'APPROVED' as your final word." \
                "$OUT_DIR/plan_review_attempt_${PLAN_ATTEMPT}.txt"; then
                echo "ERROR: Plan reviewer agent failed (exit $LAST_AGENT_EXIT)." | tee -a "$LOGFILE" >&2
                exit 1
            fi

            PLAN_REVIEW_OUTPUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUT_DIR/plan_review_attempt_${PLAN_ATTEMPT}.txt")
            PLAN_REVIEW_HASH_AFTER=$(md5sum "$REVIEW_FILE" | cut -d' ' -f1)

            if [ "$PLAN_REVIEW_HASH_BEFORE" = "$PLAN_REVIEW_HASH_AFTER" ] && echo "$PLAN_REVIEW_OUTPUT" | grep -qiE '^\s*APPROVED[.!]?\s*$'; then
                echo " Plan approved by $REVIEWER." >> "$LOGFILE"
                break
            fi

            if [ "$PLAN_ATTEMPT" -ge "$MAX_PLAN_ATTEMPTS" ]; then
                echo " Plan review: max attempts reached. Proceeding with current plan." >> "$LOGFILE"
                break
            fi

            # Only revise if the reviewer actually wrote comments
            if [ "$PLAN_REVIEW_HASH_BEFORE" = "$PLAN_REVIEW_HASH_AFTER" ]; then
                echo " Plan review — $REVIEWER did not approve but wrote no comments. Proceeding." >> "$LOGFILE"
                break
            fi

            echo " Plan review — $REVIEWER has comments. $IMPLEMENTER revising..." >> "$LOGFILE"
            if ! run_agent_turn_with_retry "$IMPLEMENTER" "plan_create_${IMPLEMENTER}" \
                "The reviewer has comments on your implementation plan.
- Read $REVIEW_FILE for the reviewer's feedback.
- Read $PLAN_FILE (your current plan) and $SPEC_FILE (the spec).
- Revise $PLAN_FILE to address the reviewer's comments.
- Keep phases coarse — prefer fewer, larger phases. Do not split into tiny steps.
- Keep fields terse: one-line fragments where possible.
- Do NOT implement any code yet — only update the plan." \
                "$OUT_DIR/plan_revise_attempt_${PLAN_ATTEMPT}.txt"; then
                echo " Plan revision agent failed (exit $LAST_AGENT_EXIT). Proceeding with current plan." >> "$LOGFILE"
                break
            fi

            if ! grep -q '## Phase [0-9].*\[TODO\]' "$PLAN_FILE"; then
                echo "ERROR: Plan file lost parseable phases after revision." >&2
                exit 1
            fi

            sleep 5
        done

        echo " Plan finalized." >> "$LOGFILE"
        sleep 10
    fi
fi

# Main loop: implement one phase per iteration
while true; do
    check_stop
    inject_feedback

    # Check if all phases are done
    if ! grep -q '\[TODO\]' "$PLAN_FILE"; then
        echo " All phases complete. Implementation finished." >> "$LOGFILE"
        echo ""
        echo "All phases complete. See $PLAN_FILE for summary."
        exit 0
    fi

    CURRENT_PHASE=$(grep -m1 '\[TODO\]' "$PLAN_FILE" | sed 's/^## Phase \([0-9]*\).*/\1/')
    {
        echo "========================================"
        echo " Starting Phase $CURRENT_PHASE"
        echo "========================================"
    } >> "$LOGFILE"

    # On resume (-R): always preserve comments.md for the first phase we enter.
    # Attempt count is only restored if .state had the same phase number.
    if [ "$RESUMING_PHASE" = true ]; then
        RESUMING_PHASE=false
        FIX_ATTEMPTS=0
        echo " Resuming phase $CURRENT_PHASE (preserving comments.md, attempts reset)." >> "$LOGFILE"
    else
        echo "# Phase $CURRENT_PHASE — Review Discussion" > "$REVIEW_FILE"
        FIX_ATTEMPTS=0
    fi

    # Extract only the spec sections relevant to this phase (saves ~80% tokens)
    PHASE_SECTIONS=$(grep -A5 "Phase $CURRENT_PHASE:" "$PLAN_FILE" | grep -oP '(?<=\*\*Sections\*\*:\s).*' | head -1)
    PHASE_SPEC="$OUT_DIR/phase_${CURRENT_PHASE}_spec.md"
    if [ -n "$PHASE_SECTIONS" ] && [ "$PHASE_SECTIONS" != "all" ]; then
        python3 "$SCRIPT_DIR/extract_sections.py" "$SPEC_FILE" "$PHASE_SECTIONS" > "$PHASE_SPEC"
        echo " Extracted spec sections: $PHASE_SECTIONS ($(wc -l < "$PHASE_SPEC") lines)" >> "$LOGFILE"
    else
        echo " Using full spec (sections: ${PHASE_SECTIONS:-not specified})." >> "$LOGFILE"
        PHASE_SPEC="$SPEC_FILE"
    fi

    # Inner loop: implement → validate → review → iterate until approved
    while true; do
        check_stop
        inject_feedback
        FIX_ATTEMPTS=$((FIX_ATTEMPTS + 1))

        if [ "$FIX_ATTEMPTS" -gt "$MAX_FIX_ATTEMPTS" ]; then
            echo " Phase $CURRENT_PHASE: exceeded $MAX_FIX_ATTEMPTS attempts. Stopping for human input." >> "$LOGFILE"
            echo "Phase $CURRENT_PHASE stuck after $MAX_FIX_ATTEMPTS attempts. Check $LOGFILE and $REVIEW_FILE."
            exit 1
        fi

        # --- Step 1: Implement ---
        touch "$WORKSPACE_DIR/.phase_marker"
        echo " Phase $CURRENT_PHASE — $IMPLEMENTER implementing (attempt $FIX_ATTEMPTS)..." >> "$LOGFILE"

        if [ "$FIX_ATTEMPTS" -gt 1 ]; then
            # Resume session — lean prompt (spec + plan already in context)
            VALIDATION_SCRATCH="$OUT_DIR/phase_${CURRENT_PHASE}_validation.txt"
            if [ -f "$VALIDATION_SCRATCH" ]; then
                IMPL_PROMPT="Validation failed. Read $VALIDATION_SCRATCH for the errors.
Fix all lint and test failures. Follow .claude/principles.md for coding standards.
Do NOT mark the phase as [DONE]."
            else
                IMPL_PROMPT="IMPORTANT: You MUST do BOTH steps below. Do step 1 FIRST.

Step 1 — Respond to reviewer: Read $REVIEW_FILE. Append your responses under your own header (e.g. '## Implementer'). For EVERY reviewer comment, write one of:
  FIXED: <what you changed>
  DISAGREE: <why, with spec section reference>
Do NOT skip any comment — the reviewer will re-raise it.
Keep responses terse; preserve exact file paths, commands, and spec section IDs.

Step 2 — Fix code: Address the reviewer's issues and any validation errors in your code.
Follow .claude/principles.md for environment setup and coding standards.

Do NOT mark the phase as [DONE]."
            fi

            run_agent_turn_with_retry "$IMPLEMENTER" "phase_${CURRENT_PHASE}_implementer" "$IMPL_PROMPT" \
                "$OUT_DIR/phase_${CURRENT_PHASE}_impl_attempt_${FIX_ATTEMPTS}.txt"
        else
            # Full context prompt (first attempt — session not yet started)
            IMPL_PROMPT="You are implementing a spec phase by phase.
- Read .claude/principles.md FIRST for environment setup and coding standards.
- Read $PLAN_FILE to find Phase $CURRENT_PHASE ([TODO]).
- Read $PHASE_SPEC for the spec sections relevant to this phase.
- Implement ONLY Phase $CURRENT_PHASE. Do not work on later phases.
- Write tests alongside code in tests/unit/ or tests/integration/.
- Do NOT write to $REVIEW_FILE. The reviewer will read your code via git diff.
- Do NOT mark the phase as [DONE] — the script handles that after review."

            run_agent_turn_with_retry "$IMPLEMENTER" "phase_${CURRENT_PHASE}_implementer" "$IMPL_PROMPT" \
                "$OUT_DIR/phase_${CURRENT_PHASE}_impl_attempt_${FIX_ATTEMPTS}.txt"
        fi
        save_state
        sleep 5

        # --- Step 2: Validate (lint + tests on changed files only) ---
        check_stop
        VALIDATION_SCRATCH="$OUT_DIR/phase_${CURRENT_PHASE}_validation.txt"
        if ! run_validation; then
            echo " Phase $CURRENT_PHASE — validation failed. Feeding errors back to $IMPLEMENTER." >> "$LOGFILE"
            cp "$WORKSPACE_DIR/.validation.txt" "$VALIDATION_SCRATCH"
            save_state
            sleep 5
            continue
        fi
        rm -f "$VALIDATION_SCRATCH"

        # --- Step 3: Review ---
        check_stop
        echo " Phase $CURRENT_PHASE — $REVIEWER reviewing..." >> "$LOGFILE"
        ensure_review_prereqs

        # Pre-write the reviewer header so the agent just appends comments under it.
        # Snapshot AFTER writing the header — if the reviewer adds content below it, they found issues.
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        REVIEW_HEADER="## Reviewer [$TIMESTAMP]"
        echo -e "\n$REVIEW_HEADER" >> "$REVIEW_FILE"
        REVIEW_HASH_BEFORE=$(md5sum "$REVIEW_FILE" | cut -d' ' -f1)

        if ! run_agent_turn_with_retry "$REVIEWER" "phase_${CURRENT_PHASE}_reviewer" \
            "You are reviewing an implementation against a spec.
- Read .claude/principles.md FIRST for environment setup and coding standards.
- Read $PLAN_FILE to see Phase $CURRENT_PHASE and its scope/exit criteria.
- Read $PHASE_SPEC for the spec sections relevant to this phase.
- Read $REVIEW_FILE for the full discussion history. The last section ('$REVIEW_HEADER') is yours. If the implementer has rebuttals, evaluate them — accept if the reasoning is sound and backed by the spec.
- Review the code changes for Phase $CURRENT_PHASE. Check:
  * Does the implementation match the spec requirements?
  * Are there logic errors, missing edge cases, or spec violations?
  * Are tests adequate for the exit criteria?
- If you find issues, append terse bullet comments below the '$REVIEW_HEADER' line in $REVIEW_FILE. Do NOT add another header — yours is already there. Do NOT edit any code files.
- If the implementation is correct and complete, do NOT modify $REVIEW_FILE. Output exactly 'APPROVED' as your final word." \
            "$OUT_DIR/phase_${CURRENT_PHASE}_review_attempt_${FIX_ATTEMPTS}.txt"; then
            echo "ERROR: Phase $CURRENT_PHASE reviewer agent failed (exit $LAST_AGENT_EXIT)." | tee -a "$LOGFILE" >&2
            exit 1
        fi
        save_state

        REVIEW_HASH_AFTER=$(md5sum "$REVIEW_FILE" | cut -d' ' -f1)
        # Strip ANSI codes from output before checking
        REVIEW_OUTPUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUT_DIR/phase_${CURRENT_PHASE}_review_attempt_${FIX_ATTEMPTS}.txt")

        # Approval requires: review file unchanged AND APPROVED appears on
        # its own line. Trailing `.` covers OSS-routed claude binaries
        # (zenmux/fireworks) that append a period; trailing `!` is defensive
        # coverage for emphatic variants. Subscription claude reliably emits
        # bare "APPROVED" but the OSS gateways are stochastic.
        if [ "$REVIEW_HASH_BEFORE" = "$REVIEW_HASH_AFTER" ] && echo "$REVIEW_OUTPUT" | grep -qiE '^\s*APPROVED[.!]?\s*$'; then
            # Remove the empty pre-written header, replace with approval line
            grep -vF "$REVIEW_HEADER" "$REVIEW_FILE" > "${REVIEW_FILE}.tmp" && mv "${REVIEW_FILE}.tmp" "$REVIEW_FILE"
            echo "APPROVED" >> "$REVIEW_FILE"
            echo " Phase $CURRENT_PHASE — approved by $REVIEWER." >> "$LOGFILE"
            sed -i "0,/\(## Phase ${CURRENT_PHASE}[: —].*\)\[TODO\]/s//\1[DONE]/" "$PLAN_FILE"
            echo " Phase $CURRENT_PHASE marked [DONE]." >> "$LOGFILE"
            save_state
            break
        elif [ "$REVIEW_HASH_BEFORE" != "$REVIEW_HASH_AFTER" ]; then
            echo " Phase $CURRENT_PHASE — $REVIEWER wrote comments to $REVIEW_FILE." >> "$LOGFILE"
            sleep 5
        else
            {
                echo " Phase $CURRENT_PHASE — $REVIEWER did not approve (no APPROVED in output)."
                echo " Review output tail:"
                echo "$REVIEW_OUTPUT" | tail -5
            } >> "$LOGFILE"
            sleep 5
        fi
    done

    sleep 10
done
