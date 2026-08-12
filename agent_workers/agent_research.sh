#!/bin/bash

# Research loop: two agents collaborate on an open-ended research goal.
# One agent investigates, the other challenges findings and asks follow-ups.
# No predefined phases or automated validation — exit when both agents agree
# the research is sufficient ([RESOLVED]).
#
# Flow per round:
#   1. Investigator explores the goal, appends findings to findings.md
#   2. Challenger reviews findings, asks follow-up questions or challenges
#      assumptions in discussion.md
#   3. Resolution persists across rounds: if challenger says [RESOLVED] in
#      round N, the investigator gets one more turn in round N+1. If the
#      investigator also resolves (or already resolved), research is complete.
#   4. If both say [PASS] → stalled, wait for human feedback before continuing
#   5. Human can inject feedback or redirect at any time via feedback.md
#      (resets resolution state so agents reconsider)
#
# Stdout capture:
#   If an agent responds in stdout but doesn't write to the expected file,
#   its output is appended as a fallback so work is never silently lost.
#
# Session continuity:
#   Each agent gets a pinned session (--session-id / --resume) for context
#   retention inside bounded round windows. findings.md and discussion.md are
#   the durable state across windows.
#
# Files (under <project>/agent_workers/research/):
#   goal.md        — the research goal (read-only reference, seeded by -f)
#   findings.md    — accumulated findings (append-only by investigator)
#   discussion.md  — back-and-forth discussion between agents
#   feedback.md    — human can inject feedback or write "stop"/"exit"
#   run.log        — full log

set -euo pipefail

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
[ -n "${LOGFILE:-}" ] && echo " Research loop terminated." >> "$LOGFILE"' EXIT

MAX_AGENT_ATTEMPTS=3
TRANSIENT_RETRY_DELAY=30
AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS="${AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS:-3}"
AGENT_RESEARCH_HISTORY_TAIL_LINES="${AGENT_RESEARCH_HISTORY_TAIL_LINES:-300}"

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

research_session_key() {
    local role="$1"
    # round_one is the 1-indexed display round.
    local round_one="$2"
    if [ "$AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS" -eq 0 ]; then
        printf 'research_%s' "$role"
        return
    fi
    local window=$(((round_one - 1) / AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS + 1))
    printf 'research_%s_window_%s' "$role" "$window"
}

# Defaults
INVESTIGATOR="claude"
CHALLENGER="codex"
PROJECT_DIR=""
WORKSPACE_OPT=""
MAX_ROUNDS=20
usage() {
    cat <<'USAGE'
Usage: agent_research.sh [-d project_dir] [-w workspace_dir] [-i claude|codex] [-c claude|codex] [-f goal_file] [-n max_rounds]

Two-agent research loop. One agent investigates, the other challenges
findings and asks follow-up questions. Research continues until both
agents agree findings are sufficient ([RESOLVED]) or max rounds hit.

Options:
  -d <dir>     Project directory to operate on (default: current working directory)
  -w <dir>     Workspace directory for state files (default: <project>/agent_workers/research/)
  -i <agent>   Agent for investigation: claude|codex|zenmux|fireworks
               (default: claude). zenmux/fireworks are agentic OSS-backed
               Claude Code instances (full tool surface; can read files
               and run commands). Requires ZENMUX_API_KEY or
               FIREWORKS_API_KEY respectively.
  -c <agent>   Agent for challenging/review: claude|codex|zenmux|fireworks
               (default: codex). Same vocabulary as -i.
  -f <file>    Seed research goal from this file (copied into research/goal.md)
  -n <rounds>  Max rounds before stopping (default: 20)

Environment:
  AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS  Rounds per session window (default: 3, 0 disables)
  AGENT_RESEARCH_HISTORY_TAIL_LINES       Recent findings/discussion lines agents read (default: 300, 0 disables)

Examples:
  cd ~/projects/aura && ../../mesh/agent_workers/agent_research.sh -f goal.md
  ./agent_workers/agent_research.sh -i codex -c claude -f docs/question.md
  ./agent_workers/agent_research.sh -i zenmux -c claude -f goal.md
  ./agent_workers/agent_research.sh -n 10

Human feedback:
  echo "focus on the database layer" > agent_workers/research/feedback.md
  echo "stop" > agent_workers/research/feedback.md
USAGE
    exit 0
}

while getopts "d:w:i:c:f:n:h" opt; do
  case $opt in
    d) PROJECT_DIR="$OPTARG" ;;
    w) WORKSPACE_OPT="$OPTARG" ;;
    i) INVESTIGATOR="$OPTARG" ;;
    c) CHALLENGER="$OPTARG" ;;
    f) GOAL_FILE_OPT="$OPTARG" ;;
    n) MAX_ROUNDS="$OPTARG" ;;
    h) usage ;;
    \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
  esac
done

if ! [[ "$AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS" =~ ^[0-9]+$ ]]; then
    echo "WARN: AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS='${AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS}' is not a non-negative integer; falling back to 3" >&2
    AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS=3
fi
if ! [[ "$AGENT_RESEARCH_HISTORY_TAIL_LINES" =~ ^[0-9]+$ ]]; then
    echo "WARN: AGENT_RESEARCH_HISTORY_TAIL_LINES='${AGENT_RESEARCH_HISTORY_TAIL_LINES}' is not a non-negative integer; falling back to 300" >&2
    AGENT_RESEARCH_HISTORY_TAIL_LINES=300
fi

# Validate agents. Vocabulary matches agent_loop / spec_loop / pr_loop /
# spec_to_ship.sh — claude|codex|zenmux|fireworks. Underlying dispatch in
# run_agent_turn already routes zenmux/fireworks via claude_oss.
for agent in "$INVESTIGATOR" "$CHALLENGER"; do
    case "$agent" in
        claude|codex|zenmux|fireworks) ;;
        *) echo "ERROR: Agent must be 'claude'|'codex'|'zenmux'|'fireworks', got '$agent'" >&2; exit 1 ;;
    esac
done

# Fail-fast prereq checks for agentic OSS providers (zenmux/fireworks);
# better than discovering a missing key mid-research.
oss_agents_require_api_key "$INVESTIGATOR" "-i" || exit 1
oss_agents_require_api_key "$CHALLENGER"   "-c" || exit 1

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
    WORKSPACE_DIR="$PROJECT_ROOT/agent_workers/research"
fi
OUT_DIR="$WORKSPACE_DIR/out"
GOAL_FILE="$WORKSPACE_DIR/goal.md"
FINDINGS_FILE="$WORKSPACE_DIR/findings.md"
DISCUSSION_FILE="$WORKSPACE_DIR/discussion.md"
RECENT_FINDINGS_FILE="$OUT_DIR/findings_recent.md"
RECENT_DISCUSSION_FILE="$OUT_DIR/discussion_recent.md"
LOGFILE="$WORKSPACE_DIR/run.log"
FEEDBACK_FILE="$WORKSPACE_DIR/feedback.md"

mkdir -p "$WORKSPACE_DIR" "$OUT_DIR"
agent_sessions_init

cd "$PROJECT_ROOT" || exit 1

# Seed goal from -f if given
if [ -n "${GOAL_FILE_OPT:-}" ]; then
    if [ -f "$GOAL_FILE_OPT" ]; then
        cp "$GOAL_FILE_OPT" "$GOAL_FILE"
        echo "Seeded research goal from: $GOAL_FILE_OPT"
    else
        echo "Goal file '$GOAL_FILE_OPT' not found, falling back to $GOAL_FILE"
    fi
fi

if [ ! -f "$GOAL_FILE" ]; then
    echo "ERROR: No research goal found. Provide with -f or create $GOAL_FILE manually." >&2
    exit 1
fi

# Initialize files
touch "$FINDINGS_FILE" "$DISCUSSION_FILE" "$FEEDBACK_FILE"

echo "Starting Research Loop."
echo "  Investigator: $INVESTIGATOR | Challenger: $CHALLENGER"
echo "  Goal: $GOAL_FILE | Max rounds: $MAX_ROUNDS"
echo "  Session rollover rounds: $AGENT_RESEARCH_SESSION_ROLLOVER_ROUNDS | History tail lines: $AGENT_RESEARCH_HISTORY_TAIL_LINES"
echo "Monitor progress: tail -f $LOGFILE"
echo "Inject feedback: echo 'your feedback' > $FEEDBACK_FILE"
echo "WARNING: Running with permissions bypassed. Ensure you are in an isolated environment!"

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
        echo -e "\n--- Human [$TIMESTAMP] ---\n$HUMAN_FB" >> "$DISCUSSION_FILE"
        echo " Human feedback injected." >> "$LOGFILE"
        # Reset resolution state on human feedback
        INVESTIGATOR_RESOLVED=false
        CHALLENGER_RESOLVED=false
    fi
}

# Capture file hash to detect whether an agent wrote to the expected file.
file_hash() {
    md5sum "$1" 2>/dev/null | cut -d' ' -f1
}

# If the agent didn't write to the target file, append its stdout as a
# fallback so substantive work is never silently lost.
# Strips ANSI, signal markers, and common CLI noise before appending.
capture_fallback() {
    local target_file="$1"
    local hash_before="$2"
    local stdout_file="$3"
    local agent_name="$4"
    local hash_after
    hash_after=$(file_hash "$target_file")
    if [ "$hash_before" = "$hash_after" ] && [ -s "$stdout_file" ]; then
        # Clean stdout: strip ANSI, signals, CLI banners, empty lines
        local cleaned
        # With pipefail, grep -v returns 1 when every line is filtered;
        # that is expected when stdout contains only signal markers.
        cleaned=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$stdout_file" \
            | grep -vE '^\s*\[(RESOLVED|PASS)\][.!?]*\s*$' \
            | grep -vE '^\s*(READY|SESSION_ID:|tokens used|mcp startup:)' \
            | grep -vE '^\s*$' \
            | grep -vE '^-{4,}$' \
            || true)
        if [ -n "$cleaned" ]; then
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
            echo -e "\n--- $agent_name (stdout capture) [$TIMESTAMP] ---" >> "$target_file"
            echo "$cleaned" >> "$target_file"
            echo " $agent_name did not write to $target_file; captured stdout." >> "$LOGFILE"
        fi
    fi
}

ROUND=0
# Resolution flags: carry forward for exactly one round to allow the
# "final turn" handshake.  After one round without the other party
# confirming, the stale flag is cleared.
INVESTIGATOR_RESOLVED=false
CHALLENGER_RESOLVED=false
INVESTIGATOR_RESOLVED_ROUND=0
CHALLENGER_RESOLVED_ROUND=0

while [ "$ROUND" -lt "$MAX_ROUNDS" ]; do
    ROUND=$((ROUND + 1))
    check_stop
    inject_feedback

    {
        echo "========================================"
        echo " Round $ROUND / $MAX_ROUNDS"
        echo "========================================"
    } >> "$LOGFILE"

    # --- Investigator turn ---
    echo " Round $ROUND — $INVESTIGATOR investigating..." >> "$LOGFILE"
    FINDINGS_HASH_BEFORE=$(file_hash "$FINDINGS_FILE")
    write_recent_tail "$FINDINGS_FILE" "$RECENT_FINDINGS_FILE" "$AGENT_RESEARCH_HISTORY_TAIL_LINES"
    write_recent_tail "$DISCUSSION_FILE" "$RECENT_DISCUSSION_FILE" "$AGENT_RESEARCH_HISTORY_TAIL_LINES"
    INVEST_HISTORY_INSTRUCTIONS=""
    if [ "$AGENT_RESEARCH_HISTORY_TAIL_LINES" -gt 0 ]; then
        INVEST_HISTORY_INSTRUCTIONS="- Read $RECENT_DISCUSSION_FILE for the challenger's latest feedback and questions.
- Read $RECENT_FINDINGS_FILE for recent findings so you avoid repeating prior work."
    else
        INVEST_HISTORY_INSTRUCTIONS="- Recent findings/discussion history is disabled for this run. Continue from the goal and current repository state without relying on hidden prior session context."
    fi

    if [ "$ROUND" -eq 1 ]; then
        INVEST_PROMPT="You are researching an open-ended question.
- Read $GOAL_FILE for the research goal.
- Read .claude/principles.md if it exists, for environment setup.
- Investigate the goal: read code, run commands, explore data, test hypotheses.
- Append terse caveman-style findings to $FINDINGS_FILE under a timestamped header.
- Be concrete: include file paths, code snippets, data, evidence.
- Do NOT write to $DISCUSSION_FILE — the challenger will respond there.
- If you believe the research is complete and findings are sufficient, end with a final line containing exactly [RESOLVED]. No other text on that line."
    else
        INVEST_PROMPT="Continue your research.
$INVEST_HISTORY_INSTRUCTIONS
- Address the challenger's questions and dig deeper where needed.
- Append terse NEW findings to $FINDINGS_FILE (don't repeat prior findings).
- If you believe the research is complete, end with a final line containing exactly [RESOLVED]. No other text on that line."
    fi

    INVESTIGATOR_SESSION_KEY=$(research_session_key "investigator" "$ROUND")
    run_agent_turn_with_retry "$INVESTIGATOR" "$INVESTIGATOR_SESSION_KEY" "$INVEST_PROMPT" \
        "$OUT_DIR/round_${ROUND}_investigator.txt"
    capture_fallback "$FINDINGS_FILE" "$FINDINGS_HASH_BEFORE" \
        "$OUT_DIR/round_${ROUND}_investigator.txt" "$INVESTIGATOR"
    sleep 2

    # Check investigator output for signals
    INVEST_OUTPUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUT_DIR/round_${ROUND}_investigator.txt")
    if output_has_final_signal "$INVEST_OUTPUT" "RESOLVED"; then
        INVESTIGATOR_RESOLVED=true
        INVESTIGATOR_RESOLVED_ROUND=$ROUND
        echo " $INVESTIGATOR says [RESOLVED]." >> "$LOGFILE"
    else
        # Expire stale resolution: only carry forward for 1 round
        if [ "$INVESTIGATOR_RESOLVED" = true ] && [ $((ROUND - INVESTIGATOR_RESOLVED_ROUND)) -gt 1 ]; then
            INVESTIGATOR_RESOLVED=false
            echo " $INVESTIGATOR resolution expired (not reconfirmed)." >> "$LOGFILE"
        fi
    fi
    if output_has_final_signal "$INVEST_OUTPUT" "PASS"; then
        INVESTIGATOR_PASS=true
    else
        INVESTIGATOR_PASS=false
    fi

    # If both resolved (challenger from prior round, investigator now), done.
    if [ "$INVESTIGATOR_RESOLVED" = true ] && [ "$CHALLENGER_RESOLVED" = true ]; then
        echo " Both agents resolved. Research complete." >> "$LOGFILE"
        echo ""
        echo "Research complete after $ROUND rounds."
        echo "  Findings: $FINDINGS_FILE"
        echo "  Discussion: $DISCUSSION_FILE"
        exit 0
    fi

    check_stop
    inject_feedback

    # --- Challenger turn ---
    echo " Round $ROUND — $CHALLENGER reviewing findings..." >> "$LOGFILE"
    DISCUSSION_HASH_BEFORE=$(file_hash "$DISCUSSION_FILE")

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\n--- $CHALLENGER (round $ROUND) [$TIMESTAMP] ---" >> "$DISCUSSION_FILE"
    # Re-hash after writing the header so the fallback check is accurate
    DISCUSSION_HASH_BEFORE=$(file_hash "$DISCUSSION_FILE")
    write_recent_tail "$FINDINGS_FILE" "$RECENT_FINDINGS_FILE" "$AGENT_RESEARCH_HISTORY_TAIL_LINES"
    write_recent_tail "$DISCUSSION_FILE" "$RECENT_DISCUSSION_FILE" "$AGENT_RESEARCH_HISTORY_TAIL_LINES"
    CHALLENGE_HISTORY_INSTRUCTIONS=""
    if [ "$AGENT_RESEARCH_HISTORY_TAIL_LINES" -gt 0 ]; then
        CHALLENGE_HISTORY_INSTRUCTIONS="- Read $RECENT_FINDINGS_FILE for the investigator's latest additions.
- Read $RECENT_DISCUSSION_FILE for recent discussion history."
    else
        CHALLENGE_HISTORY_INSTRUCTIONS="- Recent findings/discussion history is disabled for this run. Review the current state without relying on hidden prior session context."
    fi

    if [ "$ROUND" -eq 1 ]; then
        CHALLENGE_PROMPT="You are reviewing research findings.
- Read $GOAL_FILE for the research goal.
- Read $FINDINGS_FILE for the investigator's findings.
- Challenge the findings: are they correct? Complete? Are assumptions valid?
- Ask follow-up questions that would make the research more thorough.
- Append terse review and questions to $DISCUSSION_FILE below your header.
- If the findings are thorough, complete, and answer the research goal, end with a final line containing exactly [RESOLVED]. No other text on that line.
- If you have nothing to add but the research isn't complete, end with a final line containing exactly [PASS]. No other text on that line."
    else
        CHALLENGE_PROMPT="Review the latest findings.
$CHALLENGE_HISTORY_INSTRUCTIONS
- Were your previous questions addressed? Are new questions raised?
- Append terse review below your header in $DISCUSSION_FILE.
- If findings are now sufficient and thorough, end with a final line containing exactly [RESOLVED]. No other text on that line.
- If you have nothing to add, end with a final line containing exactly [PASS]. No other text on that line."
    fi

    CHALLENGER_SESSION_KEY=$(research_session_key "challenger" "$ROUND")
    run_agent_turn_with_retry "$CHALLENGER" "$CHALLENGER_SESSION_KEY" "$CHALLENGE_PROMPT" \
        "$OUT_DIR/round_${ROUND}_challenger.txt"
    capture_fallback "$DISCUSSION_FILE" "$DISCUSSION_HASH_BEFORE" \
        "$OUT_DIR/round_${ROUND}_challenger.txt" "$CHALLENGER"
    sleep 2

    # Check challenger output for signals
    CHALLENGE_OUTPUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$OUT_DIR/round_${ROUND}_challenger.txt")
    if output_has_final_signal "$CHALLENGE_OUTPUT" "RESOLVED"; then
        CHALLENGER_RESOLVED=true
        CHALLENGER_RESOLVED_ROUND=$ROUND
        echo " $CHALLENGER says [RESOLVED]." >> "$LOGFILE"
    else
        # Expire stale resolution: only carry forward for 1 round
        if [ "$CHALLENGER_RESOLVED" = true ] && [ $((ROUND - CHALLENGER_RESOLVED_ROUND)) -gt 1 ]; then
            CHALLENGER_RESOLVED=false
            echo " $CHALLENGER resolution expired (not reconfirmed)." >> "$LOGFILE"
        fi
    fi
    if output_has_final_signal "$CHALLENGE_OUTPUT" "PASS"; then
        CHALLENGER_PASS=true
    else
        CHALLENGER_PASS=false
    fi

    # --- Consensus check ---
    # Both resolved — investigator may have resolved earlier, challenger now
    if [ "$INVESTIGATOR_RESOLVED" = true ] && [ "$CHALLENGER_RESOLVED" = true ]; then
        echo " Both agents resolved. Research complete." >> "$LOGFILE"
        echo ""
        echo "Research complete after $ROUND rounds."
        echo "  Findings: $FINDINGS_FILE"
        echo "  Discussion: $DISCUSSION_FILE"
        exit 0
    fi

    # Both passed without resolving — stalled
    if [ "${INVESTIGATOR_PASS:-false}" = true ] && [ "${CHALLENGER_PASS:-false}" = true ]; then
        echo " Both agents passed. Research stalled." >> "$LOGFILE"
        echo ""
        echo "Research stalled after $ROUND rounds. Both agents have nothing to add."
        echo "  Inject feedback: echo 'explore X' > $FEEDBACK_FILE"
        echo "  Or review findings: $FINDINGS_FILE"
        echo " Waiting for human feedback..." >> "$LOGFILE"
        while true; do
            sleep 5
            if [ -s "$FEEDBACK_FILE" ]; then
                inject_feedback
                echo " Resuming after human feedback." >> "$LOGFILE"
                break
            fi
        done
    fi

    sleep 5
done

echo " Max rounds ($MAX_ROUNDS) reached." >> "$LOGFILE"
echo ""
echo "Research stopped after $MAX_ROUNDS rounds."
echo "  Findings: $FINDINGS_FILE"
echo "  Discussion: $DISCUSSION_FILE"
exit 1
