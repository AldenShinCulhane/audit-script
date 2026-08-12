#!/bin/bash
#
# oss_agents.sh — helpers for invoking Claude Code with an OSS backend
# (Zenmux or Fireworks Anthropic-compatible endpoints).
#
# Source this file; do not exec it. The lib does NOT export any env var to
# the parent shell — every override is scoped to the spawned subprocess via
# inline `env` assignment, so the caller's native Claude Code session and
# any sibling commands stay on whatever backend they were already using.
#
# Public API:
#   oss_agents_validate           — check OSS_AGENT_MODEL parses + API key is present
#   oss_agents_describe           — print "provider/slug" (or "<unconfigured>")
#   claude_oss [claude args...]   — spawn `claude` with OSS env, pass-through args
#
# Configuration env (read by oss_agents_validate / claude_oss):
#   OSS_AGENT_MODEL    Required.  <provider>:<slug>
#                      e.g. zenmux:deepseek/deepseek-v4-flash
#                           fireworks:accounts/fireworks/models/minimax-m2p7
#   ZENMUX_API_KEY     Required when provider == zenmux.
#   FIREWORKS_API_KEY  Required when provider == fireworks.
#   ZENMUX_ANTHROPIC_URL  Optional override; default https://zenmux.ai/api/anthropic
#   FIREWORKS_ANTHROPIC_URL Optional override; default https://api.fireworks.ai/inference
#
# Auth-header note (the trap): each provider's Anthropic-compat endpoint
# expects a different auth header, so the lib uses different ANTHROPIC_*
# env vars per provider:
#
#   provider   | endpoint expects        | env var the lib sets    | header Claude Code emits
#   -----------|-------------------------|-------------------------|--------------------------
#   zenmux     | x-api-key               | ANTHROPIC_API_KEY       | x-api-key
#   fireworks  | Authorization: Bearer   | ANTHROPIC_AUTH_TOKEN    | Authorization: Bearer
#
# Zenmux's published Claude-Code config example shows ANTHROPIC_AUTH_TOKEN
# but their server 403s pay-as-you-go (sk-ai-v1-) keys on Bearer; only
# x-api-key works for those. See:
#   https://zenmux.ai/docs/best-practices/cc-switch.html
#
# To prevent a leaked parent-shell auth var from ambiguating the subprocess,
# the lib also `env -u`s the OTHER provider's auth env var on every spawn.

# ── Internal parser ──

# _oss_agents_parse <raw>
#   On success: sets _OSS_PROV and _OSS_SLUG, returns 0.
#   On failure: prints to stderr, returns 2.
# Globals (intentional package-private): _OSS_PROV, _OSS_SLUG.
_oss_agents_parse() {
    local raw="$1"
    if [ -z "$raw" ]; then
        echo "ERROR: OSS_AGENT_MODEL is not set" >&2
        echo "       export OSS_AGENT_MODEL=<provider>:<slug>" >&2
        echo "       e.g.  export OSS_AGENT_MODEL=zenmux:deepseek/deepseek-v4-flash" >&2
        return 2
    fi
    if [[ "$raw" != *:* ]]; then
        echo "ERROR: OSS_AGENT_MODEL='$raw' must use form <provider>:<slug>" >&2
        return 2
    fi
    _OSS_PROV="${raw%%:*}"
    _OSS_SLUG="${raw#*:}"
    case "$_OSS_PROV" in
        zenmux|fireworks) ;;
        *)
            echo "ERROR: OSS_AGENT_MODEL has unknown provider '$_OSS_PROV' (expected zenmux|fireworks)" >&2
            return 2
            ;;
    esac
    if [ -z "$_OSS_SLUG" ]; then
        echo "ERROR: OSS_AGENT_MODEL='$raw' has empty slug after '$_OSS_PROV:'" >&2
        return 2
    fi
    return 0
}

# ── Public API ──

# oss_agents_validate
#   Verify OSS_AGENT_MODEL is set, parses cleanly, and the matching
#   provider's API key is available. Side effect: sets _OSS_PROV / _OSS_SLUG
#   so claude_oss (called next) doesn't have to re-parse. Returns 0 / 2.
#
# Call this early in scripts to fail fast before doing any real work.
oss_agents_validate() {
    _oss_agents_parse "${OSS_AGENT_MODEL:-}" || return $?
    case "$_OSS_PROV" in
        zenmux)
            if [ -z "${ZENMUX_API_KEY:-}" ]; then
                echo "ERROR: ZENMUX_API_KEY is required for OSS_AGENT_MODEL=zenmux:..." >&2
                return 2
            fi
            ;;
        fireworks)
            if [ -z "${FIREWORKS_API_KEY:-}" ]; then
                echo "ERROR: FIREWORKS_API_KEY is required for OSS_AGENT_MODEL=fireworks:..." >&2
                return 2
            fi
            ;;
    esac
    return 0
}

# oss_agents_require_api_key <agent> [seat-label]
#   Verify the matching API key is set for an agentic OSS provider, so
#   callers can fail fast at startup rather than discovering it mid-run.
#   Returns 0 if the agent is not an OSS provider (claude/codex/oss) OR
#   if the key is set; returns 1 if it's an OSS agent and the key is
#   missing (with a stderr message naming the missing var).
#
# Optional second arg adds a seat identifier (e.g. "-i", "-r", "investigator")
# to the error message — e.g. "ERROR: -i zenmux requires ZENMUX_API_KEY".
# Defaults to "agent" when omitted: "ERROR: agent zenmux requires ...".
#
# Library convention: this returns rather than exits, so callers can decide
# whether the missing key is fatal or recoverable. Most worker scripts will
# pair it with `|| exit 1`.
oss_agents_require_api_key() {
    local agent="$1" seat="${2:-agent}"
    case "$agent" in
        zenmux)
            if [ -z "${ZENMUX_API_KEY:-}" ]; then
                echo "ERROR: $seat $agent requires ZENMUX_API_KEY" >&2
                return 1
            fi
            ;;
        fireworks)
            if [ -z "${FIREWORKS_API_KEY:-}" ]; then
                echo "ERROR: $seat $agent requires FIREWORKS_API_KEY" >&2
                return 1
            fi
            ;;
    esac
    return 0
}

# oss_agents_default_slug <provider> <tier>
#   Print the default model slug (no <provider>: prefix) for the requested
#   provider/tier pair, honoring per-tier env overrides. Returns 2 on bad
#   input. Centralizes slug picks so callers (run_agent_turn dispatcher,
#   /zenmux & /fireworks skills, future tooling) don't sprinkle hardcoded
#   strings across the tree.
#
# Tier guide (also documented in skills/zenmux/SKILL.md and skills/fireworks/SKILL.md):
#   flash  cheap one-shots (lints, scans, summaries)
#   pro    harder reasoning, multi-step agentic, long context
#
# Override env vars (each holds the slug only, no provider prefix):
#   ZENMUX_FLASH_MODEL     ZENMUX_PRO_MODEL
#   FIREWORKS_FLASH_MODEL  FIREWORKS_PRO_MODEL
oss_agents_default_slug() {
    local provider="$1" tier="$2"
    case "$provider:$tier" in
        zenmux:flash)    echo "${ZENMUX_FLASH_MODEL:-deepseek/deepseek-v4-flash}" ;;
        zenmux:pro)      echo "${ZENMUX_PRO_MODEL:-deepseek/deepseek-v4-pro}" ;;
        fireworks:flash) echo "${FIREWORKS_FLASH_MODEL:-accounts/fireworks/models/minimax-m2p7}" ;;
        fireworks:pro)   echo "${FIREWORKS_PRO_MODEL:-accounts/fireworks/models/kimi-k2p6}" ;;
        *)
            echo "ERROR: oss_agents_default_slug: unknown provider:tier '$provider:$tier'" >&2
            echo "       expected one of: zenmux:flash zenmux:pro fireworks:flash fireworks:pro" >&2
            return 2
            ;;
    esac
}

# oss_agents_describe
#   Print a short human-readable label for logs, matching the
#   <provider>:<slug> form of OSS_AGENT_MODEL itself (so the label round-
#   trips). Prints "<unconfigured>" if validation fails.
#   Side effect: on success, leaves _OSS_PROV / _OSS_SLUG set as a
#   consequence of the internal oss_agents_validate call.
oss_agents_describe() {
    if oss_agents_validate >/dev/null 2>&1; then
        printf '%s:%s' "$_OSS_PROV" "$_OSS_SLUG"
    else
        printf '<unconfigured>'
    fi
}

# oss_agents_compose_env_array
#   Compose the array of args for `env` that switches a child claude
#   process onto the OSS backend selected by OSS_AGENT_MODEL. Sets the
#   global array _OSS_ENV_ARRAY so callers can:
#       env "${_OSS_ENV_ARRAY[@]}" claude ...
#   This is the primitive shared by `claude_oss` (one-shot spawn) and by
#   `run_agent_turn` in agent_sessions.sh (multi-turn session integration).
#
# Output side effect: _OSS_ENV_ARRAY is overwritten on each call.
#
# Per-provider auth-header note:
#   zenmux (PAYG keys)  → x-api-key path → ANTHROPIC_API_KEY
#   fireworks           → Bearer path    → ANTHROPIC_AUTH_TOKEN
# The "wrong" env var is included as `-u VAR` so a leaked parent export
# cannot force ambiguous-auth state in the subprocess.
oss_agents_compose_env_array() {
    oss_agents_validate || return $?

    local base_url auth_var auth_val unset_var
    case "$_OSS_PROV" in
        zenmux)
            base_url="${ZENMUX_ANTHROPIC_URL:-https://zenmux.ai/api/anthropic}"
            auth_var="ANTHROPIC_API_KEY"
            auth_val="$ZENMUX_API_KEY"
            unset_var="ANTHROPIC_AUTH_TOKEN"
            ;;
        fireworks)
            base_url="${FIREWORKS_ANTHROPIC_URL:-https://api.fireworks.ai/inference}"
            auth_var="ANTHROPIC_AUTH_TOKEN"
            auth_val="$FIREWORKS_API_KEY"
            unset_var="ANTHROPIC_API_KEY"
            ;;
    esac

    # Callers must read _OSS_ENV_ARRAY before calling this function again
    # for a different provider — the array is overwritten on each call.
    _OSS_ENV_ARRAY=(
        -u "$unset_var"
        "ANTHROPIC_BASE_URL=$base_url"
        "$auth_var=$auth_val"
        "ANTHROPIC_MODEL=$_OSS_SLUG"
        "ANTHROPIC_DEFAULT_HAIKU_MODEL=$_OSS_SLUG"
        "ANTHROPIC_DEFAULT_SONNET_MODEL=$_OSS_SLUG"
        "ANTHROPIC_DEFAULT_OPUS_MODEL=$_OSS_SLUG"
        "ANTHROPIC_SMALL_FAST_MODEL=$_OSS_SLUG"
    )
    return 0
}

# claude_oss [claude args...]
#   Spawn `claude` with the OSS-backed env. Pass-through args. Returns
#   claude's exit code (or 2 on configuration error before spawn).
claude_oss() {
    oss_agents_compose_env_array || return $?
    env "${_OSS_ENV_ARRAY[@]}" claude "$@"
}
