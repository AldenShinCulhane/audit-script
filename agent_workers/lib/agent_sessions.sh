#!/bin/bash

# Shared agent session management for claude / codex / zenmux / fireworks.
# Requires caller to define:
#   LOGFILE, FEEDBACK_FILE
#
# zenmux and fireworks are OSS-backed Claude Code instances (same `claude`
# binary, redirected via ANTHROPIC_BASE_URL to an Anthropic-compatible OSS
# gateway). The env-shaping logic lives in oss_agents.sh; this file pulls
# in oss_agents_compose_env_array to drive the dispatch case.

_AS_THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_AS_THIS_DIR/oss_agents.sh"
unset _AS_THIS_DIR

declare -Ag STARTED_SESSIONS=()
declare -Ag SESSION_IDS=()

AGENT_PID=""
LAST_AGENT_EXIT=0
CODEX_SUPPORTS_SESSIONS=0

# Named session state uses a separate variable from STATE_FILE to avoid
# colliding with worker scripts (agent_loop.sh etc.) that use STATE_FILE
# for their own loop/runtime state (phase, fix_attempts, etc.).
_NAMED_SESSION_STATE_FILE=""
CODEX_SESSION_MODE="none"

# Caveman mode reduces future context by making agent-authored durable
# artifacts terse. MESH_CAVEMAN_MODE takes precedence over legacy
# MESH_CAVEMAN. Default is full because workers repeatedly re-read
# changes.md/comments.md/findings.md/triage.md across turns.
_agent_caveman_mode() {
    local source_var="MESH_CAVEMAN_MODE"
    local raw="${MESH_CAVEMAN_MODE:-${MESH_CAVEMAN:-full}}"
    if [ -z "${MESH_CAVEMAN_MODE:-}" ] && [ -n "${MESH_CAVEMAN:-}" ]; then
        source_var="MESH_CAVEMAN"
    fi

    local mode="$raw"
    mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
    case "$mode" in
        0|off|false|no|normal) printf 'off' ;;
        lite|full|ultra) printf '%s' "$mode" ;;
        *)
            printf 'WARN: unknown %s=%s; defaulting to full\n' "$source_var" "$raw" >&2
            printf 'full'
            ;;
    esac
}

_agent_caveman_guidance() {
    local mode="$1"
    case "$mode" in
        lite) printf 'Write compact, grammatical bullets. No filler or hedging.' ;;
        ultra) printf 'Write dense fragments. Drop filler and extra glue words when clear. No reasoning transcript.' ;;
        *) printf 'Write terse bullets/fragments. No filler, no reasoning transcript.' ;;
    esac
}

_agent_prepare_prompt() {
    local prompt="$1"
    local mode guidance
    mode=$(_agent_caveman_mode)
    if [ "$mode" = "off" ]; then
        printf '%s' "$prompt"
        return
    fi
    guidance=$(_agent_caveman_guidance "$mode")

    # Listing parser markers here is safe because loop callers match them
    # on final lines or structural headers, not by unanchored substring.
    printf 'Token mode: caveman-%s for process artifacts only.
%s
Preserve exact code, paths, commands, URLs, quoted reviewer text, and parser markers:
APPROVED, [RESOLVED], [PASS], [ACCEPT], [REBUTTAL], [REBUTTAL-SKIP], [TODO], [DONE].
Do not compress implementation code or user-facing spec text unless explicitly asked.

%s' "$mode" "$guidance" "$prompt"
}

output_has_final_signal() {
    local output="$1"
    local signal="$2"
    local last_line signal_lower
    last_line=$(printf '%s\n' "$output" \
        | sed '/^[[:space:]]*$/d' \
        | tail -1 \
        | sed -E 's/^[[:space:]]*([-*>]|[0-9]+\.)[[:space:]]*//;s/^[[:space:]]+//;s/[[:space:]]+$//')
    last_line=$(printf '%s' "$last_line" | tr '[:upper:]' '[:lower:]')
    signal_lower=$(printf '%s' "$signal" | tr '[:upper:]' '[:lower:]')

    # Accept harmless final-line formatting drift while rejecting trailing
    # prose like "[RESOLVED] research complete".
    local plain bold underline code
    plain='^\['"$signal_lower"'\][.!?]*$'
    bold='^\*\*\['"$signal_lower"'\]\*\*[.!?]*$'
    underline='^__\['"$signal_lower"'\]__[.!?]*$'
    code='^`\['"$signal_lower"'\]`[.!?]*$'
    [[ "$last_line" =~ $plain ]] \
        || [[ "$last_line" =~ $bold ]] \
        || [[ "$last_line" =~ $underline ]] \
        || [[ "$last_line" =~ $code ]]
}

# Check if agent output contains a fatal (non-retryable) error.
# Returns 0 if fatal, 1 if not.
is_fatal_error() {
    local output="$1"
    local lower
    lower=$(echo "$output" | tr '[:upper:]' '[:lower:]')
    local patterns=(
        "max tokens" "token limit" "context window"
        "api key" "authentication"
        "unauthorized" "billing" "quota exceeded"
        "insufficient_quota" "max_tokens_exceeded"
        "context_length_exceeded"
    )
    for pat in "${patterns[@]}"; do
        if echo "$lower" | grep -qF "$pat"; then
            return 0
        fi
    done
    return 1
}

agent_detect_codex_mode() {
    if ! command -v codex >/dev/null 2>&1; then
        CODEX_SUPPORTS_SESSIONS=0
        CODEX_SESSION_MODE="none"
        return
    fi
    local exec_help resume_help
    exec_help=$(codex exec --help 2>/dev/null || true)
    resume_help=$(codex exec resume --help 2>/dev/null || true)
    if echo "$exec_help" | grep -q -- '--session-id'; then
        CODEX_SUPPORTS_SESSIONS=1
        CODEX_SESSION_MODE="exec_session_id"
    elif echo "$resume_help" | grep -q -E 'Usage:\s+codex exec resume'; then
        CODEX_SUPPORTS_SESSIONS=1
        CODEX_SESSION_MODE="exec_resume"
    else
        CODEX_SUPPORTS_SESSIONS=0
        CODEX_SESSION_MODE="none"
    fi
}

agent_sessions_init() {
    STARTED_SESSIONS=()
    SESSION_IDS=()
    agent_detect_codex_mode
}

agent_sessions_reset() {
    STARTED_SESSIONS=()
    SESSION_IDS=()
}

write_recent_tail() {
    local source_file="$1"
    local target_file="$2"
    local line_count="$3"
    : > "$target_file"
    if [ -s "$source_file" ] && [ "$line_count" -gt 0 ]; then
        tail -n "$line_count" "$source_file" > "$target_file"
    fi
}

# Load (or create) a named session that persists across independent runs.
# Usage:
#   MESH_SESSION_DIR="/path/to/state/dir"  # optional, defaults to ~/.mesh/sessions
#   agent_sessions_load_named "doc-refresh"
#
# On first call: creates state dir, returns 1 (new session).
# On subsequent calls: loads SESSION_IDS + STARTED_SESSIONS from prior run, returns 0.
# On corrupt state file: logs warning, resets to fresh session, returns 1.
# The caller can then use run_agent_turn as normal — it will --resume if a session exists.
#
# State file location: $MESH_SESSION_DIR/$name.state
# The caller owns MESH_SESSION_DIR — this lets a consuming repo store state in
# its own data dir while this repo provides the read/write primitives.
#
# NOTE: This does NOT touch the global STATE_FILE variable. Worker scripts
# (agent_loop.sh etc.) use STATE_FILE for their own loop state (phase,
# fix_attempts). Named sessions use _NAMED_SESSION_STATE_FILE instead.
agent_sessions_load_named() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "ERROR: agent_sessions_load_named requires a session name" >&2
        return 2
    fi
    if ! declare -f load_state >/dev/null 2>&1; then
        echo "ERROR: agent_sessions_load_named requires caller-defined load_state" >&2
        return 2
    fi
    local state_dir="${MESH_SESSION_DIR:-$HOME/.mesh/sessions}"
    mkdir -p "$state_dir"
    _NAMED_SESSION_STATE_FILE="$state_dir/${name}.state"
    agent_sessions_init
    if [ -f "$_NAMED_SESSION_STATE_FILE" ]; then
        # Temporarily point STATE_FILE at our named file for load_state,
        # then restore it so worker scripts are not affected.
        local saved_state_file="${STATE_FILE:-}"
        STATE_FILE="$_NAMED_SESSION_STATE_FILE"
        if load_state; then
            STATE_FILE="$saved_state_file"
            return 0
        else
            echo "WARN: named session '$name' state file is corrupt or unreadable — starting fresh" >&2
            STATE_FILE="$saved_state_file"
            agent_sessions_init
            return 1
        fi
    fi
    return 1
}

# Save the current named session state. Call after each logical unit of work
# for crash safety.
#
# NOTE: Does not modify the global STATE_FILE. Writes directly to the path
# established by agent_sessions_load_named.
agent_sessions_save_named() {
    if [ -z "${_NAMED_SESSION_STATE_FILE:-}" ]; then
        echo "ERROR: agent_sessions_save_named called before agent_sessions_load_named" >&2
        return 2
    fi
    if ! declare -f save_state >/dev/null 2>&1; then
        echo "ERROR: agent_sessions_save_named requires caller-defined save_state" >&2
        return 2
    fi
    local saved_state_file="${STATE_FILE:-}"
    STATE_FILE="$_NAMED_SESSION_STATE_FILE"
    save_state
    STATE_FILE="$saved_state_file"
}

# Set to 1 by _agent_wait_or_stop when the watchdog kills the running
# turn. Reset to 0 at the start of every wait cycle so it cannot leak
# across turns. Read by _invalidate_session_on_timeout (below) so the
# enclosing run_agent_turn dispatch can drop the session key — running
# `--resume <sid>` against a session whose remote state is unknown
# (because we hard-killed it) is worse than starting fresh.
_AGENT_TURN_TIMED_OUT=0

# Wait for AGENT_PID to exit, polling FEEDBACK_FILE for cooperative stop
# and enforcing a wall-clock cap on the turn.
#
# Env knobs:
#   AGENT_TURN_TIMEOUT     Hard wall-clock cap per turn, in seconds.
#                          Default 3600 (60 min). Set to 0 to disable.
#   AGENT_TURN_KILL_GRACE  Seconds between SIGTERM and SIGKILL on timeout.
#                          Default 30.
#
# AGENT_PID is the bash subshell wrapping `cmd | tee outfile >> LOGFILE`,
# so we kill its direct children too — `claude -p` in headless mode has
# been observed to stop emitting output but never EOF, leaving tee
# blocked on a closed-but-not-EOF pipe and the parent on `wait`. `pkill
# -P` reaches those children regardless of process-group leadership
# (which bash doesn't guarantee for backgrounded subshells in scripts).
#
# Snapshot semantics: the loop condition is `while kill -0 AGENT_PID`.
# Once SIGTERM kills tee, the wrapper subshell exits, breaking the loop
# even if a TERM-ignoring inner child (e.g. a hung claude -p) is still
# alive. We snapshot pgrep -P AGENT_PID BEFORE sending TERM so we can
# reach those children after the wrapper is gone — without this, a
# TERM-ignoring orphan would silently outlive _agent_wait_or_stop.
#
# A timed-out turn returns non-zero, which run_agent_turn_with_retry
# treats as transient — the caller (agent_loop.sh) retries with a fresh
# session up to MAX_AGENT_ATTEMPTS=3, so worst-case latency is roughly
# 3 × AGENT_TURN_TIMEOUT before the outer script gives up.
_agent_wait_or_stop() {
    _AGENT_TURN_TIMED_OUT=0
    local timeout_secs="${AGENT_TURN_TIMEOUT:-3600}"
    local kill_grace="${AGENT_TURN_KILL_GRACE:-30}"
    local started_at term_sent=0 kill_sent=0 term_at=0
    local -a tracked_pids=()
    started_at=$(date +%s)

    while kill -0 "$AGENT_PID" 2>/dev/null; do
        if [ -s "$FEEDBACK_FILE" ] && grep -qi '^\s*\(stop\|exit\)\s*$' "$FEEDBACK_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') Received stop signal. Shutting down." >> "$LOGFILE"
            true > "$FEEDBACK_FILE"
            exit 0
        fi

        if [ "$timeout_secs" -gt 0 ]; then
            local now elapsed
            now=$(date +%s)
            elapsed=$(( now - started_at ))
            if [ "$term_sent" -eq 0 ] && [ "$elapsed" -ge "$timeout_secs" ]; then
                # Capture direct children before TERM so the post-loop
                # block can SIGKILL any TERM-ignoring survivor even after
                # the wrapper subshell has exited.
                mapfile -t tracked_pids < <(pgrep -P "$AGENT_PID" 2>/dev/null || true)
                _AGENT_TURN_TIMED_OUT=1
                echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: agent turn exceeded ${timeout_secs}s (pid=$AGENT_PID, children=${tracked_pids[*]:-none}). Sending SIGTERM." >> "$LOGFILE"
                # `|| true` because the target may already be dead between
                # `kill -0` and here; pkill/kill returning 1 in that case
                # would otherwise abort the calling script under set -e.
                pkill -TERM -P "$AGENT_PID" 2>/dev/null || true
                kill -TERM "$AGENT_PID" 2>/dev/null || true
                term_sent=1
                term_at=$now
            elif [ "$term_sent" -eq 1 ] && [ "$kill_sent" -eq 0 ] && [ $(( now - term_at )) -ge "$kill_grace" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: agent turn unresponsive ${kill_grace}s after SIGTERM (pid=$AGENT_PID). Sending SIGKILL." >> "$LOGFILE"
                pkill -KILL -P "$AGENT_PID" 2>/dev/null || true
                kill -KILL "$AGENT_PID" 2>/dev/null || true
                # Belt-and-braces: hit the captured pids too in case the
                # wrapper's child set has shifted since we snapshotted.
                local pid
                for pid in "${tracked_pids[@]}"; do
                    [ -n "$pid" ] || continue
                    kill -KILL "$pid" 2>/dev/null || true
                done
                kill_sent=1
            fi
        fi

        sleep 2
    done

    # Wrapper exited but a SIGTERM-ignoring tracked child may have
    # outlived it. Wait the rest of the grace, then SIGKILL any survivor.
    # Without this, _agent_wait_or_stop returns leaving an orphan agent
    # process holding a remote session — the bug that motivated this
    # whole watchdog.
    if [ "$term_sent" -eq 1 ] && [ "${#tracked_pids[@]}" -gt 0 ]; then
        if [ "$kill_sent" -eq 0 ]; then
            local now remaining
            now=$(date +%s)
            remaining=$(( kill_grace - (now - term_at) ))
            [ "$remaining" -gt 0 ] && sleep "$remaining"
            local pid
            for pid in "${tracked_pids[@]}"; do
                [ -n "$pid" ] || continue
                if kill -0 "$pid" 2>/dev/null; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: orphan agent child (pid=$pid) survived wrapper exit. Sending SIGKILL." >> "$LOGFILE"
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            done
        fi

        # Settle: SIGKILL'd orphans are reaped by init (their wrapper is
        # gone, so we can't `wait` them). The reap is async — `kill -0`
        # can briefly return 0 on a process that's TASK_DEAD but not yet
        # removed from the process table. Poll up to 2s so the function's
        # post-condition ("no tracked pid alive") holds for callers.
        local settle=0
        while [ "$settle" -lt 20 ]; do
            local any_alive=0 p
            for p in "${tracked_pids[@]}"; do
                [ -n "$p" ] || continue
                if kill -0 "$p" 2>/dev/null; then
                    any_alive=1
                    break
                fi
            done
            [ "$any_alive" -eq 0 ] && break
            sleep 0.1
            settle=$((settle + 1))
        done
    fi

    wait "$AGENT_PID" 2>/dev/null
    LAST_AGENT_EXIT=$?
    AGENT_PID=""
}

# If the most recent turn was killed by the watchdog, drop the named
# session so run_agent_turn_with_retry's next attempt creates a fresh
# one. Calling --resume <sid> against a session we hard-killed risks
# layering a retry on top of half-applied state; cheaper to start over.
# No-op when _AGENT_TURN_TIMED_OUT is 0 (normal failures). Idempotent —
# unsetting an already-empty associative-array key is silent.
_invalidate_session_on_timeout() {
    local session_key="$1"
    [ "${_AGENT_TURN_TIMED_OUT:-0}" -eq 1 ] || return 0
    local old_sid="${SESSION_IDS[$session_key]:-}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: agent turn timed out — invalidating session ($old_sid, key=$session_key); next attempt will start fresh." >> "$LOGFILE"
    unset "STARTED_SESSIONS[$session_key]"
    unset "SESSION_IDS[$session_key]"
}

_agent_run() {
    local outfile="$1"
    shift
    if [ -n "$outfile" ]; then
        : > "$outfile"
        (
            set -o pipefail
            stdbuf -oL "$@" 2>&1 | stdbuf -oL tee "$outfile" >> "$LOGFILE"
        ) &
    else
        (
            set -o pipefail
            stdbuf -oL "$@" >> "$LOGFILE" 2>&1
        ) &
    fi
    AGENT_PID=$!
    _agent_wait_or_stop
    return "$LAST_AGENT_EXIT"
}

# Like _agent_run but pipes a file into stdin of the command.
# This avoids ARG_MAX limits when passing large prompts.
# Usage: _agent_run_stdin "$outfile" "$stdin_file" cmd arg1 arg2 ...
_agent_run_stdin() {
    local outfile="$1"
    local stdin_file="$2"
    shift 2
    if [ -n "$outfile" ]; then
        : > "$outfile"
        (
            set -o pipefail
            stdbuf -oL "$@" < "$stdin_file" 2>&1 | stdbuf -oL tee "$outfile" >> "$LOGFILE"
        ) &
    else
        (
            set -o pipefail
            stdbuf -oL "$@" < "$stdin_file" >> "$LOGFILE" 2>&1
        ) &
    fi
    AGENT_PID=$!
    _agent_wait_or_stop
    return "$LAST_AGENT_EXIT"
}

_agent_run_prompt_stdin() {
    local outfile="$1"
    local prompt="$2"
    local prompt_file rc
    shift 2
    prompt_file=$(mktemp)
    printf '%s' "$prompt" > "$prompt_file"
    _agent_run_stdin "$outfile" "$prompt_file" "$@"
    rc=$?
    rm -f "$prompt_file"
    return "$rc"
}

_codex_extract_thread_id() {
    local json_out="$1"
    sed -n 's/.*"thread_id":"\([^"]*\)".*/\1/p' "$json_out" | head -1
}

_codex_json_to_text() {
    local json_out="$1"
    local outfile="$2"
    sed -n 's/.*"type":"agent_message","text":"\(.*\)".*/\1/p' "$json_out" \
        | sed 's/\\"/"/g; s/\\\\/\\/g; s/\\n/\n/g' > "$outfile"
}

_run_codex_first_turn() {
    local session_key="$1"
    local prompt="$2"
    local outfile="$3"
    local codex_root="${AGENT_PROJECT_ROOT:-$PWD}"
    local json_out="${outfile}.jsonl"
    : > "$outfile"
    : > "$json_out"

    # Pass prompt via stdin to avoid ARG_MAX limits on large issue-sweep plans.
    _agent_run_prompt_stdin "$json_out" "$prompt" \
        codex exec -C "$codex_root" --dangerously-bypass-approvals-and-sandbox --json - \
        || return $?

    local thread_id
    thread_id=$(_codex_extract_thread_id "$json_out")
    if [ -z "$thread_id" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unable to parse codex thread_id." >> "$LOGFILE"
        return 2
    fi

    SESSION_IDS["$session_key"]="$thread_id"
    STARTED_SESSIONS["$session_key"]=1
    _codex_json_to_text "$json_out" "$outfile"
    return 0
}

run_agent_turn() {
    local agent="$1"
    local session_key="$2"
    local prompt="$3"
    local outfile="$4"
    local model="${5:-}"

    prompt=$(_agent_prepare_prompt "$prompt")

    echo "$(date '+%Y-%m-%d %H:%M:%S') Agent turn start: agent=${agent} session=${session_key}" >> "${LOGFILE:-/dev/null}"

    case "$agent" in
        claude)
            local sid="${SESSION_IDS[$session_key]:-}"
            local started="${STARTED_SESSIONS[$session_key]:-0}"
            local is_resume=false
            local -a args=(claude -p --dangerously-skip-permissions)
            if [ -n "$model" ]; then
                args+=(--model "$model")
            fi
            if [ "$started" = "1" ] && [ -n "$sid" ]; then
                args+=(--resume "$sid")
                is_resume=true
            else
                sid=$(uuidgen)
                SESSION_IDS["$session_key"]="$sid"
                STARTED_SESSIONS["$session_key"]=1
                args+=(--session-id "$sid")
            fi
            # Pass prompt via stdin to avoid ARG_MAX limits on large prompts.
            # claude -p reads from stdin when no prompt argument is given.
            local prompt_file
            prompt_file=$(mktemp)
            printf '%s' "$prompt" > "$prompt_file"
            # Claude Code has no -C flag (unlike `codex exec -C "$codex_root"`);
            # it operates on its CWD. Run it FROM AGENT_PROJECT_ROOT so per-item
            # worktree isolation is real for issue_sweep PATH A (edits land in the
            # worktree, not the shared parent tree). Save/restore CWD here rather
            # than wrapping in a subshell — a subshell would swallow the globals
            # _agent_run_stdin sets (AGENT_PID, _AGENT_TURN_TIMED_OUT) and break
            # timeout handling. No-op for loops whose CWD is already that dir.
            local _agent_prevdir="$PWD"
            cd "${AGENT_PROJECT_ROOT:-$PWD}" || { rm -f "$prompt_file"; return 1; }
            _agent_run_stdin "$outfile" "$prompt_file" "${args[@]}"
            local rc=$?
            cd "$_agent_prevdir" || true
            rm -f "$prompt_file"
            _invalidate_session_on_timeout "$session_key"
            # Only retry on resume-specific failure (exit 1 = session not found).
            # Transient errors (exit 2+ = network, timeout) keep the session intact.
            # Watchdog kill (exit 137/143) is also exit 2+, but the helper above
            # has already cleared the session — the outer retry will start fresh.
            # Fatal errors (token limit, auth) must propagate immediately — a fresh
            # session won't help and would just waste an API call.
            if [ "$rc" -ne 0 ] && [ -n "$outfile" ] && [ -f "$outfile" ] && is_fatal_error "$(cat "$outfile")"; then
                return "$rc"
            fi
            if [ "$rc" -eq 1 ] && [ "$is_resume" = true ]; then
                local old_sid="$sid"
                sid=$(uuidgen)
                SESSION_IDS["$session_key"]="$sid"
                echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: claude --resume failed (exit $rc, old=$old_sid, new=$sid). Context reset — retrying with fresh session." >> "$LOGFILE"
                local -a retry_args=(claude -p --dangerously-skip-permissions)
                if [ -n "$model" ]; then
                    retry_args+=(--model "$model")
                fi
                retry_args+=(--session-id "$sid")
                prompt_file=$(mktemp)
                printf '%s' "$prompt" > "$prompt_file"
                # Same CWD discipline as the first turn (see comment above).
                cd "${AGENT_PROJECT_ROOT:-$PWD}" || { rm -f "$prompt_file"; return 1; }
                _agent_run_stdin "$outfile" "$prompt_file" "${retry_args[@]}"
                local retry_rc=$?
                cd "$_agent_prevdir" || true
                rm -f "$prompt_file"
                _invalidate_session_on_timeout "$session_key"
                return $retry_rc
            fi
            return $rc
            ;;
        codex)
            if [ "$CODEX_SUPPORTS_SESSIONS" -ne 1 ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: codex session continuity not supported." >> "$LOGFILE"
                return 2
            fi
            local sid="${SESSION_IDS[$session_key]:-}"
            local started="${STARTED_SESSIONS[$session_key]:-0}"
            local codex_root="${AGENT_PROJECT_ROOT:-$PWD}"
            if [ "$started" != "1" ] || [ -z "$sid" ]; then
                _run_codex_first_turn "$session_key" "$prompt" "$outfile"
                return $?
            fi
            local rc
            if [ "$CODEX_SESSION_MODE" = "exec_session_id" ]; then
                _agent_run_prompt_stdin "$outfile" "$prompt" \
                    codex exec -C "$codex_root" --dangerously-bypass-approvals-and-sandbox --session-id "$sid" -
                rc=$?
            else
                _agent_run_prompt_stdin "$outfile" "$prompt" \
                    codex exec -C "$codex_root" resume --dangerously-bypass-approvals-and-sandbox "$sid" -
                rc=$?
            fi
            _invalidate_session_on_timeout "$session_key"
            # Only retry on exit 1 (session/thread not found).
            # Higher exit codes (network, timeout) preserve the session for manual retry,
            # except watchdog kill — the helper above has already cleared the session
            # so the outer retry naturally takes the first-turn path.
            # Fatal errors (token limit, auth) must propagate immediately.
            if [ -n "$outfile" ] && [ -f "$outfile" ] && is_fatal_error "$(cat "$outfile")"; then
                return "$rc"
            fi
            if [ "$rc" -eq 1 ]; then
                local old_sid="$sid"
                echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: codex resume failed (exit $rc, old_thread=$old_sid). Context reset — retrying with fresh session." >> "$LOGFILE"
                unset "STARTED_SESSIONS[$session_key]"
                unset "SESSION_IDS[$session_key]"
                _run_codex_first_turn "$session_key" "$prompt" "$outfile"
                local retry_rc=$?
                if [ "$retry_rc" -eq 0 ]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: codex fresh session OK (new_thread=${SESSION_IDS[$session_key]:-unknown})." >> "$LOGFILE"
                fi
                return $retry_rc
            fi
            return $rc
            ;;
        zenmux|fireworks)
            # OSS-backed Claude Code via Anthropic-compat. Same session
            # semantics as the `claude` case (--session-id / --resume),
            # just with env vars steering claude at the OSS gateway. The
            # env array is composed by oss_agents.sh's
            # oss_agents_compose_env_array, sourced at the top of this file.
            #
            # Provider+slug come from per-provider env vars. The agentic seat
            # always runs at Pro tier (multi-turn agentic work; Flash is for
            # cheap one-shots wired through the /zenmux & /fireworks skills).
            #
            # Override precedence:
            #   1. <PROVIDER>_AGENT_MODEL  (legacy, full slug; takes priority)
            #   2. <PROVIDER>_PRO_MODEL    (per-tier override; same default as oss_agents_default_slug)
            #   3. hardcoded default in oss_agents_default_slug
            #
            # We compose OSS_AGENT_MODEL inline (subshell scope) so the
            # per-provider slug for THIS turn doesn't pollute later turns
            # that may use a different provider.
            #
            # Note on the two-step lookup: we cannot collapse this into
            # `_zf_slug="${LEGACY:-$(oss_agents_default_slug ...)}"` because
            # `${VAR:-$(...)}` swallows the inner non-zero exit, which would
            # leave _zf_slug empty on a bad provider/tier and surface as the
            # downstream "empty slug" error rather than the real cause.
            local _zf_slug=""
            case "$agent" in
                zenmux)    _zf_slug="${ZENMUX_AGENT_MODEL:-}" ;;
                fireworks) _zf_slug="${FIREWORKS_AGENT_MODEL:-}" ;;
            esac
            if [ -z "$_zf_slug" ]; then
                if ! _zf_slug="$(oss_agents_default_slug "$agent" pro)"; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $agent agent: oss_agents_default_slug failed." >> "$LOGFILE"
                    echo "ERROR: $agent agent: failed to resolve default slug" > "$outfile"
                    return 2
                fi
            fi

            # Compose the env-array via the lib (validates API key etc.).
            if ! OSS_AGENT_MODEL="${agent}:${_zf_slug}" oss_agents_compose_env_array; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $agent agent: oss_agents_compose_env_array failed." >> "$LOGFILE"
                echo "ERROR: $agent agent: failed to resolve OSS env" > "$outfile"
                return 2
            fi

            local sid="${SESSION_IDS[$session_key]:-}"
            local started="${STARTED_SESSIONS[$session_key]:-0}"
            local is_resume=false
            local -a args=(claude -p --dangerously-skip-permissions)
            # Note: $model arg ignored — the OSS slug is the model and is
            # baked into _OSS_ENV_ARRAY. Passing --model would override
            # ANTHROPIC_MODEL in confusing ways.
            if [ "$started" = "1" ] && [ -n "$sid" ]; then
                args+=(--resume "$sid")
                is_resume=true
            else
                sid=$(uuidgen)
                SESSION_IDS["$session_key"]="$sid"
                STARTED_SESSIONS["$session_key"]=1
                args+=(--session-id "$sid")
            fi

            local prompt_file
            prompt_file=$(mktemp)
            printf '%s' "$prompt" > "$prompt_file"
            # _OSS_ENV_ARRAY is composed by the immediately-preceding
            # oss_agents_compose_env_array call above; must not be
            # overwritten between composition and consumption.
            # The OSS agent path still runs the Claude Code CLI, which has no
            # `-C` flag. Match the native claude branch's CWD discipline so
            # issue_sweep worktree isolation holds for zenmux/fireworks fixers.
            local _agent_prevdir="$PWD"
            cd "${AGENT_PROJECT_ROOT:-$PWD}" || { rm -f "$prompt_file"; return 1; }
            _agent_run_stdin "$outfile" "$prompt_file" \
                env "${_OSS_ENV_ARRAY[@]}" "${args[@]}"
            local rc=$?
            cd "$_agent_prevdir" || true
            rm -f "$prompt_file"
            _invalidate_session_on_timeout "$session_key"

            # Same retry-on-resume-failure pattern as the claude case.
            if [ "$rc" -ne 0 ] && [ -n "$outfile" ] && [ -f "$outfile" ] && is_fatal_error "$(cat "$outfile")"; then
                return "$rc"
            fi
            if [ "$rc" -eq 1 ] && [ "$is_resume" = true ]; then
                local old_sid="$sid"
                sid=$(uuidgen)
                SESSION_IDS["$session_key"]="$sid"
                echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: $agent --resume failed (exit $rc, old=$old_sid, new=$sid). Context reset — retrying with fresh session." >> "$LOGFILE"
                local -a retry_args=(claude -p --dangerously-skip-permissions --session-id "$sid")
                prompt_file=$(mktemp)
                printf '%s' "$prompt" > "$prompt_file"
                # _OSS_ENV_ARRAY was composed by the oss_agents_compose_env_array
                # call above; must not be overwritten before this consumption.
                cd "${AGENT_PROJECT_ROOT:-$PWD}" || { rm -f "$prompt_file"; return 1; }
                _agent_run_stdin "$outfile" "$prompt_file" \
                    env "${_OSS_ENV_ARRAY[@]}" "${retry_args[@]}"
                local retry_rc=$?
                cd "$_agent_prevdir" || true
                rm -f "$prompt_file"
                _invalidate_session_on_timeout "$session_key"
                return $retry_rc
            fi
            return $rc
            ;;
        oss)
            # Stateless OSS-model agent. Reads OSS_FLASH_MODEL env var
            # (form: <provider>:<slug>; e.g. zenmux:deepseek/deepseek-v4-flash)
            # and dispatches to the provider's OpenAI-compatible chat-
            # completions endpoint. No session continuity — every turn is
            # independent. Suitable for review/triage roles where the
            # orchestrator can re-feed the relevant context each cycle.
            #
            # Required env: OSS_FLASH_MODEL plus the provider's API key
            # (ZENMUX_API_KEY or FIREWORKS_API_KEY).
            #
            # The 5th `model` arg is ignored on purpose — provider+slug
            # come from OSS_FLASH_MODEL so the same convention as
            # scripts/audit-pr.sh is honored.
            #
            # NOTE: the stop-signal mechanism (writing `stop` to
            # FEEDBACK_FILE) is NOT honored during an oss turn. curl runs
            # inline below (not via _agent_run), so AGENT_PID is not set
            # for this branch and the cleanup trap cannot interrupt a hung
            # request. The `--max-time 120 --connect-timeout 15` caps on
            # the curl invocation bound the worst-case wait — that bound
            # is the operational guarantee in lieu of cooperative stop.
            local raw="${OSS_FLASH_MODEL:-}"
            if [ -z "$raw" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: oss agent requires OSS_FLASH_MODEL=<provider>:<slug>" >> "$LOGFILE"
                echo "ERROR: oss agent requires OSS_FLASH_MODEL=<provider>:<slug>" > "$outfile"
                return 2
            fi
            if [[ "$raw" != *:* ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: OSS_FLASH_MODEL='$raw' must use form <provider>:<slug>" >> "$LOGFILE"
                echo "ERROR: OSS_FLASH_MODEL='$raw' must use form <provider>:<slug>" > "$outfile"
                return 2
            fi
            local oss_provider="${raw%%:*}" oss_slug="${raw#*:}"
            local oss_url oss_key
            case "$oss_provider" in
                zenmux)
                    oss_url="${ZENMUX_CHAT_URL:-https://zenmux.ai/api/v1/chat/completions}"
                    oss_key="${ZENMUX_API_KEY:-}"
                    ;;
                fireworks)
                    oss_url="${FIREWORKS_CHAT_URL:-https://api.fireworks.ai/inference/v1/chat/completions}"
                    oss_key="${FIREWORKS_API_KEY:-}"
                    ;;
                *)
                    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: oss agent: unknown provider '$oss_provider'" >> "$LOGFILE"
                    echo "ERROR: oss agent: unknown provider '$oss_provider' (expected zenmux|fireworks)" > "$outfile"
                    return 2
                    ;;
            esac
            if [ -z "$oss_key" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: oss agent: missing API key for provider '$oss_provider'" >> "$LOGFILE"
                local key_var
                key_var=$(printf '%s' "$oss_provider" | tr '[:lower:]' '[:upper:]')_API_KEY
                echo "ERROR: oss agent: $key_var is required for provider '$oss_provider'" > "$outfile"
                return 2
            fi

            local req_body resp_body http_status prompt_file
            req_body=$(mktemp)
            resp_body=$(mktemp)
            prompt_file=$(mktemp)
            printf '%s' "$prompt" > "$prompt_file"

            if ! jq -n --arg model "$oss_slug" --rawfile prompt "$prompt_file" \
                    '{model: $model,
                      messages: [{role:"user", content: $prompt}],
                      temperature: 0.1}' > "$req_body"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: oss agent: jq failed to build request body" >> "$LOGFILE"
                echo "ERROR: oss agent: jq failed" > "$outfile"
                rm -f "$req_body" "$resp_body" "$prompt_file"
                return 2
            fi

            http_status=$(curl -sS -o "$resp_body" -w '%{http_code}' \
                --max-time 120 --connect-timeout 15 \
                -X POST "$oss_url" \
                -H "Authorization: Bearer $oss_key" \
                -H "Content-Type: application/json" \
                --data-binary "@$req_body" 2>>"$LOGFILE" || echo "000")

            rm -f "$req_body" "$prompt_file"

            if [ "$http_status" != "200" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: oss agent: HTTP $http_status from $oss_provider" >> "$LOGFILE"
                {
                    echo "ERROR: oss agent: HTTP $http_status from $oss_provider"
                    echo "--- response body (first 1KB) ---"
                    head -c 1024 "$resp_body"
                } > "$outfile"
                rm -f "$resp_body"
                # Treat 4xx as fatal (auth/quota), 5xx and 000 as transient.
                if [ "$http_status" -ge 400 ] && [ "$http_status" -lt 500 ]; then
                    return 1
                fi
                return 2
            fi

            if ! jq -re '.choices[0].message.content' < "$resp_body" > "$outfile" \
                    || [ ! -s "$outfile" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: oss agent: response missing .choices[0].message.content" >> "$LOGFILE"
                {
                    echo "ERROR: oss agent: malformed response from $oss_provider"
                    echo "--- response body (first 1KB) ---"
                    head -c 1024 "$resp_body"
                } > "$outfile"
                rm -f "$resp_body"
                return 2
            fi
            rm -f "$resp_body"
            return 0
            ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unknown agent '$agent'" >> "$LOGFILE"
            return 1
            ;;
    esac
}
