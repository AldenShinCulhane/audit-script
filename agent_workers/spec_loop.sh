#!/bin/bash

# Spec refinement loop: multiple agents take turns challenging and refining
# a specification until all agents agree it is complete.
#
# Flow:
#   1. Agent A reads spec.md, proposes changes → writes to spec.md
#   2. Agent A's change summary is appended to changes.md
#   3. Agent B reads changes.md (full negotiation history), reviews the delta
#   4. If Agent B agrees, it outputs APPROVED
#   5. If Agent B disagrees, it edits spec.md and appends its own changes
#   6. Once ALL agents approve consecutively, spec is finalized
#
# Context retention:
#   - Claude/Codex both use explicit session create/resume.
#   - Session keys roll over every few rounds so hidden vendor session history
#     stays bounded; changes.md remains the durable append-only audit trail.
#
# Files (under <project>/agent_workers/spec_loop/):
#   spec.md      — the specification being refined
#   changes.md   — append-only log of all changes and approvals
#   feedback.md  — human can inject feedback or write "stop"/"exit"
#   run.log      — full log of the refinement process

# Resolve directory where this script (and its auxiliary files) lives,
# so paths work regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_FILE="$SCRIPT_DIR/lib/agent_sessions.sh"

if [ ! -f "$LIB_FILE" ]; then
    echo "ERROR: Session helper not found: $LIB_FILE" >&2
    exit 1
fi

# shellcheck source=agent_workers/lib/agent_sessions.sh
. "$LIB_FILE"

trap 'if [ -n "${AGENT_PID:-}" ]; then
    kill "$AGENT_PID" 2>/dev/null
    pkill -P "$AGENT_PID" 2>/dev/null
    wait "$AGENT_PID" 2>/dev/null
fi
[ -n "${LOGFILE:-}" ] && echo " Spec loop terminated." >> "$LOGFILE"' EXIT

# Agent run/session helpers come from lib/agent_sessions.sh.

MAX_AGENT_ATTEMPTS=3
TRANSIENT_RETRY_DELAY=30
SPEC_LOOP_SESSION_ROLLOVER_ROUNDS="${SPEC_LOOP_SESSION_ROLLOVER_ROUNDS:-3}"
SPEC_LOOP_HISTORY_TAIL_LINES="${SPEC_LOOP_HISTORY_TAIL_LINES:-300}"

# Wrapper around run_agent_turn that retries on transient API errors (exit 2+).
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

spec_loop_session_key() {
    local agent_index="$1"
    # round_one is the 1-indexed display round.
    local round_one="$2"
    if [ "$SPEC_LOOP_SESSION_ROLLOVER_ROUNDS" -eq 0 ]; then
        printf 'spec_loop_agent_%s' "$agent_index"
        return
    fi
    local window=$(((round_one - 1) / SPEC_LOOP_SESSION_ROLLOVER_ROUNDS + 1))
    printf 'spec_loop_agent_%s_window_%s' "$agent_index" "$window"
}

save_state() {
    {
        echo "STATE_ROUND=$ROUND"
        echo "STATE_AGENT_INDEX=$AGENT_INDEX"
        echo "STATE_APPROVALS=$APPROVALS"
        echo "STATE_IS_FIRST_PASS=$IS_FIRST_PASS"
        for key in "${!SESSION_IDS[@]}"; do
            echo "STATE_SID_${key}=${SESSION_IDS[$key]}"
        done
        for key in "${!STARTED_SESSIONS[@]}"; do
            echo "STATE_STARTED_${key}=${STARTED_SESSIONS[$key]}"
        done
    } > "$STATE_FILE"
}

load_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo " No state file found. Cannot resume." >> "$LOGFILE"
        return 1
    fi

    RESUMED_ROUND=0
    RESUMED_AGENT_INDEX=0
    RESUMED_APPROVALS=0
    RESUMED_IS_FIRST_PASS=true

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            STATE_ROUND) RESUMED_ROUND="$value" ;;
            STATE_AGENT_INDEX) RESUMED_AGENT_INDEX="$value" ;;
            STATE_APPROVALS) RESUMED_APPROVALS="$value" ;;
            STATE_IS_FIRST_PASS) RESUMED_IS_FIRST_PASS="$value" ;;
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

    echo " Loaded state: round=$RESUMED_ROUND, agent_index=$RESUMED_AGENT_INDEX, approvals=$RESUMED_APPROVALS, first_pass=$RESUMED_IS_FIRST_PASS, sessions=${!SESSION_IDS[*]}" >> "$LOGFILE"
    return 0
}

# Defaults
AGENTS=()
MAX_ROUNDS=10
PROJECT_DIR=""
WORKSPACE_OPT=""
RESUME=false
usage() {
    cat <<'USAGE'
Usage: spec_loop.sh [-d project_dir] [-w workspace_dir] [-a AGENT]... [-n max_rounds] [-f spec_file] [-R]

Multi-agent spec refinement loop. Agents take turns reviewing and refining
a specification, challenging each other until all approve consecutively.

Agents use explicit session create/resume across bounded round windows.
All changes are tracked in changes.md (append-only); prompts use a recent
history tail so old hidden session context is not required.

Options:
  -d <dir>     Project directory to operate on (default: current working directory)
  -w <dir>     Workspace directory for state files (default: <project>/agent_workers/spec_loop/)
  -a <agent>   Add an agent to the rotation. Repeatable. See AGENTS below.
               (default: -a codex -a claude)
  -n <rounds>  Max full rounds before stopping (default: 10)
  -f <file>    Use this spec file directly.
               If the file doesn't exist, falls back to spec_loop/spec.md.
               Without -f, the workspace spec lives at spec_loop/spec.md.
  -R           Resume a previous run: restore agent sessions and preserve changes.md

Environment:
  SPEC_LOOP_SESSION_ROLLOVER_ROUNDS  Rounds per session window (default: 3, 0 disables)
  SPEC_LOOP_HISTORY_TAIL_LINES       Recent changes.md lines agents read (default: 300, 0 disables)

AGENTS (vocabulary shared with agent_loop.sh and spec_to_ship.sh):
  claude     Subscription Opus 4.7 via the claude CLI. Best at multi-turn
             agentic refinement; biggest subscription ceiling; no per-token
             cost.
  codex      Subscription GPT 5.5 via the codex CLI. Cross-family from
             claude — pair the two so each catches the other's blind spots
             during refinement.
  zenmux     PAYG OSS gateway (DeepSeek family by default). Routes the
             `claude` binary at the zenmux Anthropic-compat endpoint.
             Useful for very long specs (>200K tokens). Requires
             ZENMUX_API_KEY; slug overridable via ZENMUX_AGENT_MODEL.
  fireworks  PAYG OSS gateway (Minimax M2 by default). Same shape as
             zenmux, alternate provider. Requires FIREWORKS_API_KEY;
             slug overridable via FIREWORKS_AGENT_MODEL.

Examples:
  cd ~/projects/aura && ../../mesh/agent_workers/spec_loop.sh    # operate on aura
  ./agent_workers/spec_loop.sh -d ../sibling-repo                  # operate on sibling repo
  ./agent_workers/spec_loop.sh -a codex -a claude                # codex goes first, then claude
  ./agent_workers/spec_loop.sh -a claude -a codex -a claude      # 3-pass rotation
  ./agent_workers/spec_loop.sh -a zenmux -a claude               # OSS coder vs subscription claude
  ./agent_workers/spec_loop.sh -f docs/design.md -n 5            # seed from draft, max 5 rounds
  ./agent_workers/spec_loop.sh -R                                # resume after stop/crash

Human feedback:
  echo "Add error handling section" > agent_workers/spec_loop/feedback.md   # inject feedback
  echo "stop" > agent_workers/spec_loop/feedback.md                         # stop the loop
USAGE
    exit 0
}

while getopts "d:w:a:n:f:Rh" opt; do
  case $opt in
    d) PROJECT_DIR="$OPTARG" ;;
    w) WORKSPACE_OPT="$OPTARG" ;;
    a) AGENTS+=("$OPTARG") ;;
    n) MAX_ROUNDS="$OPTARG" ;;
    f) SPEC_FILE_OPT="$OPTARG" ;;
    R) RESUME=true ;;
    h) usage ;;
    \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
  esac
done

if ! [[ "$SPEC_LOOP_SESSION_ROLLOVER_ROUNDS" =~ ^[0-9]+$ ]]; then
    echo "WARN: SPEC_LOOP_SESSION_ROLLOVER_ROUNDS='${SPEC_LOOP_SESSION_ROLLOVER_ROUNDS}' is not a non-negative integer; falling back to 3" >&2
    SPEC_LOOP_SESSION_ROLLOVER_ROUNDS=3
fi
if ! [[ "$SPEC_LOOP_HISTORY_TAIL_LINES" =~ ^[0-9]+$ ]]; then
    echo "WARN: SPEC_LOOP_HISTORY_TAIL_LINES='${SPEC_LOOP_HISTORY_TAIL_LINES}' is not a non-negative integer; falling back to 300" >&2
    SPEC_LOOP_HISTORY_TAIL_LINES=300
fi

# Default agents
if [ ${#AGENTS[@]} -eq 0 ]; then
    AGENTS=("codex" "claude")
fi

# Validate
for agent in "${AGENTS[@]}"; do
    case "$agent" in
        claude|codex|zenmux|fireworks) ;;
        *) echo "ERROR: Agent must be 'claude'|'codex'|'zenmux'|'fireworks', got '$agent'" >&2; exit 1 ;;
    esac
done

# Fail-fast prereq checks for agentic OSS providers (zenmux/fireworks);
# better than discovering a missing key mid-rotation.
for _idx in "${!AGENTS[@]}"; do
    oss_agents_require_api_key "${AGENTS[$_idx]}" "-a[$_idx]" || exit 1
done
unset _idx

# Derive project root and workspace paths after option parsing.
# PROJECT_ROOT is the repo being worked on (default: CWD).
# WORKSPACE_DIR holds state files and lives under the target project.
PROJECT_ROOT="$(cd "${PROJECT_DIR:-$PWD}" && pwd)"
export AGENT_PROJECT_ROOT="$PROJECT_ROOT"
if [ -n "$WORKSPACE_OPT" ]; then
    case "$WORKSPACE_OPT" in
        /*) WORKSPACE_DIR="$WORKSPACE_OPT" ;;
        *)  WORKSPACE_DIR="$PROJECT_ROOT/$WORKSPACE_OPT" ;;
    esac
    mkdir -p "$WORKSPACE_DIR"
    WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"
else
    WORKSPACE_DIR="$PROJECT_ROOT/agent_workers/spec_loop"
fi
OUT_DIR="$WORKSPACE_DIR/out"
SPEC_FILE="$WORKSPACE_DIR/spec.md"
CHANGES_FILE="$WORKSPACE_DIR/changes.md"
RECENT_CHANGES_FILE="$OUT_DIR/changes_recent.md"
LOGFILE="$WORKSPACE_DIR/run.log"
FEEDBACK_FILE="$WORKSPACE_DIR/feedback.md"
STATE_FILE="$WORKSPACE_DIR/.state"

mkdir -p "$WORKSPACE_DIR" "$OUT_DIR"
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

if [ "$RESUME" = true ]; then
    if load_state; then
        echo "Resuming previous run (round $((RESUMED_ROUND + 1)), agent index $RESUMED_AGENT_INDEX, approvals $RESUMED_APPROVALS)."
        echo "  Restored sessions: ${!SESSION_IDS[*]}"
    else
        echo "Resuming (no state file — preserving changes.md, sessions start fresh)."
    fi
else
    # Initialize changes file
    true > "$CHANGES_FILE"
fi

AGENT_LIST=$(IFS=','; echo "${AGENTS[*]}")
echo "Starting Spec Refinement Loop."
echo "  Agents: $AGENT_LIST | Spec: $SPEC_FILE | Max rounds: $MAX_ROUNDS"
echo "  Changes tracked in: $CHANGES_FILE"
echo "  Session mode: explicit create/resume"
echo "  Session rollover rounds: $SPEC_LOOP_SESSION_ROLLOVER_ROUNDS | History tail lines: $SPEC_LOOP_HISTORY_TAIL_LINES"
echo "  Resume: $RESUME"
echo "Monitor progress: tail -f $LOGFILE"
echo "Inject feedback: echo 'your feedback' > $FEEDBACK_FILE"
echo "WARNING: Running with permissions bypassed. Ensure you are in an isolated environment!"

ROUND=0
AGENT_INDEX=0
APPROVALS=0  # consecutive approvals — need ${#AGENTS[@]} to finalize
IS_FIRST_PASS=true

if [ "$RESUME" = true ] && [ -f "$STATE_FILE" ]; then
    ROUND="$RESUMED_ROUND"
    AGENT_INDEX="$RESUMED_AGENT_INDEX"
    APPROVALS="$RESUMED_APPROVALS"
    IS_FIRST_PASS="$RESUMED_IS_FIRST_PASS"
fi

while [ "$ROUND" -lt "$MAX_ROUNDS" ]; do
    # Check for stop/exit
    if [ -s "$FEEDBACK_FILE" ] && grep -qi '^\s*\(stop\|exit\)\s*$' "$FEEDBACK_FILE"; then
        echo " Received stop/exit signal. Shutting down." >> "$LOGFILE"
        true > "$FEEDBACK_FILE"
        exit 0
    fi

    # Inject human feedback
    if [ -s "$FEEDBACK_FILE" ]; then
        HUMAN_FB=$(cat "$FEEDBACK_FILE")
        true > "$FEEDBACK_FILE"
        echo -e "\n--- Human Feedback ---\n$HUMAN_FB" >> "$CHANGES_FILE"
        echo " Human feedback injected into changes file." >> "$LOGFILE"
        APPROVALS=0
        IS_FIRST_PASS=false
        save_state
    fi

    CURRENT_AGENT="${AGENTS[$AGENT_INDEX]}"
    ROUND_DISPLAY=$((ROUND + 1))
    echo " Round $ROUND_DISPLAY — $CURRENT_AGENT (approval streak: $APPROVALS/${#AGENTS[@]})..." >> "$LOGFILE"

    # Write header to changes file before agent runs (so attribution is reliable)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\n--- $CURRENT_AGENT (round $ROUND_DISPLAY) [$TIMESTAMP] ---" >> "$CHANGES_FILE"
    write_recent_tail "$CHANGES_FILE" "$RECENT_CHANGES_FILE" "$SPEC_LOOP_HISTORY_TAIL_LINES"
    RECENT_CHANGES_INSTRUCTION=""
    if [ "$SPEC_LOOP_HISTORY_TAIL_LINES" -gt 0 ]; then
        RECENT_CHANGES_INSTRUCTION="Read $RECENT_CHANGES_FILE — it contains the recent tail of changes made during this refinement session.
Focus on the MOST RECENT entry (before your own header). Then read $SPEC_FILE to see the current state."
    else
        RECENT_CHANGES_INSTRUCTION="Recent changes history is disabled for this run. Read $SPEC_FILE to see the current state."
    fi

    # First pass: full spec review. Subsequent passes: review only the delta.
    if [ "$IS_FIRST_PASS" = true ]; then
        PROMPT="You are refining a specification. Read $SPEC_FILE carefully.
1. Identify gaps, ambiguities, contradictions, missing edge cases, or unclear requirements.
2. If you find issues, edit $SPEC_FILE with your improvements. Then append a CONCISE caveman-style summary (bullet points only, no thinking process) of what you changed and why to $CHANGES_FILE. A header with your name and timestamp has already been written — just append terse bullet points.
3. If the spec is complete and ready for implementation with no changes needed, output exactly 'APPROVED'.
Do NOT approve if there are open questions or incomplete sections."
    else
        PROMPT="You are reviewing changes to a specification.
$RECENT_CHANGES_INSTRUCTION
Your job: Review the recent changes. Are they correct, clear, and consistent with the rest of the spec?
- If the changes are sound and the spec needs no further edits, output exactly 'APPROVED'.
- If you disagree with any changes or spot issues, edit $SPEC_FILE to fix the problems. Then append a CONCISE caveman-style summary (bullet points only, no thinking process) of what you changed and why to $CHANGES_FILE. A header with your name and timestamp has already been written — just append terse bullet points.
Do NOT re-audit the entire spec from scratch. Focus on the delta."
    fi

    OUTPUT_FILE="$OUT_DIR/round_${ROUND_DISPLAY}_agent_${AGENT_INDEX}.txt"
    SESSION_KEY=$(spec_loop_session_key "$AGENT_INDEX" "$ROUND_DISPLAY")
    run_agent_turn_with_retry "$CURRENT_AGENT" "$SESSION_KEY" "$PROMPT" "$OUTPUT_FILE"

    OUTPUT=$(cat "$OUTPUT_FILE")

    # Check if agent approved: last non-empty line must be "APPROVED" with at
    # most one trailing terminator. The `.` covers OSS-routed claude binaries
    # (zenmux/fireworks) that reliably append a period — subscription claude
    # does not. The `!` is defensive coverage for emphatic variants we
    # haven't seen in logs but that any model could plausibly emit. The
    # last-line extraction protects against mid-text "APPROVED" mentions.
    LAST_LINE=$(echo "$OUTPUT" | grep -v '^\s*$' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ "$LAST_LINE" =~ ^APPROVED[.!]?$ ]]; then
        APPROVALS=$((APPROVALS + 1))
        echo "APPROVED" >> "$CHANGES_FILE"
        echo " $CURRENT_AGENT approved ($APPROVALS/${#AGENTS[@]} consecutive)." >> "$LOGFILE"

        if [ "$APPROVALS" -ge "${#AGENTS[@]}" ]; then
            echo " All agents approved. Spec finalized in $SPEC_FILE." >> "$LOGFILE"
            rm -f "$STATE_FILE"
            echo ""
            echo "Spec finalized after $ROUND_DISPLAY rounds. See $SPEC_FILE"
            exit 0
        fi
    else
        # Agent writes its own summary to CHANGES_FILE via the prompt.
        # We just reset the approval streak here.
        APPROVALS=0
        echo " $CURRENT_AGENT made changes. Approval streak reset." >> "$LOGFILE"
    fi

    IS_FIRST_PASS=false

    # Advance to next agent
    AGENT_INDEX=$(( (AGENT_INDEX + 1) % ${#AGENTS[@]} ))
    if [ "$AGENT_INDEX" -eq 0 ]; then
        ROUND=$((ROUND + 1))
    fi

    save_state

    sleep 10
done

echo " Max rounds ($MAX_ROUNDS) reached without full consensus." >> "$LOGFILE"
echo "Max rounds reached. Current spec in $SPEC_FILE. Review $LOGFILE for details."
exit 1
