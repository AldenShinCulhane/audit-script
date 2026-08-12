#!/bin/bash
set -euo pipefail

# audit-pr.sh — Production-safety audit of a feature branch's PR diff.
# Extracts the diff vs the base branch and asks a model to produce tiered
# [BLOCKER]/[WARN]/[OK] findings. Four backends are supported:
#
#   --engine codex     (default) — pipes the diff to `codex exec` against the
#                      user's ~/.codex/config.toml model, using
#                      --output-last-message to capture the model's final
#                      response without CLI framing. Matches the original
#                      behavior shipped in commit ff66cd2.
#   --engine claude    Agentic Claude — pipes the diff to `claude -p
#                      --dangerously-skip-permissions`. Same agentic-shell
#                      contract as codex (the model can read surrounding
#                      files for context). Natural pick when the user wants
#                      a third independent claude session that is separate
#                      from a coder/reviewer claude in the same pipeline,
#                      or when zenmux/fireworks are unavailable but the
#                      Opus subscription has headroom. Uses the user's
#                      existing claude auth (OAuth or ANTHROPIC_API_KEY);
#                      no new env vars.
#   --engine zenmux    OSS path — calls ZenMux's OpenAI-compatible chat-
#                      completions API. Requires ZENMUX_API_KEY plus
#                      OSS_FLASH_MODEL=zenmux:<slug> (and OSS_PRO_MODEL=zenmux:<slug>
#                      if --auto-tier is used). spec_to_ship.sh opts into
#                      `--engine zenmux` explicitly.
#   --engine fireworks alt OSS path — calls Fireworks' chat-completions API.
#                      Requires FIREWORKS_API_KEY plus OSS_FLASH_MODEL=fireworks:<slug>
#                      (and OSS_PRO_MODEL=fireworks:<slug> for --auto-tier).
#
# All three backends write the saved report to stdout AND to
# agent_workers/audit/pr-audit-<branch>.md (slashes replaced with dashes),
# and all honor --strict (exit non-zero when any [BLOCKER] is present).
#
# Default engine stays `codex` so existing callers keep current behavior.
# spec_to_ship.sh passes `--engine "$AUDITOR"` (default codex).
#
# The codex engine and the OSS engines (zenmux/fireworks) run different
# prompts on purpose. codex exec is an agentic shell with a read-only
# sandbox, so its prompt invites it to read files for context. Direct HTTP
# is an oracle (curated diff in, judgment out), so its prompt restricts the
# auditor to the diff payload and forbids claims about unseen files. See
# the spec's "Agentic shells vs LLM oracles".
#
# OSS engines use unprefixed env vars whose values carry a <provider>:<slug>
# discriminator. The provider half is validated against --engine; the slug
# half goes into the request body. This lets a single OSS_FLASH_MODEL line
# in ~/.bashrc switch the user between providers (e.g., `zenmux:<slug>` vs
# `fireworks:<slug>`) without renaming env vars or commenting blocks.
#
# The script does NOT carry built-in model defaults — the env var IS the
# configuration. If OSS_FLASH_MODEL (or OSS_PRO_MODEL when --auto-tier is
# used) is unset for the chosen --engine, the script errors out and names
# the missing var. Avoids silent fallback to slugs that may be renamed or
# retired by the provider.

usage() {
    cat <<'EOF'
Usage: audit-pr.sh [OPTIONS]

Run a production-safety audit on the current branch's PR diff.

Options:
  -b, --base <branch>          Base branch to diff against (default: origin/develop)
  -o, --output <path>          Override output path
                               (default: agent_workers/audit/pr-audit-<branch>.md,
                               where / in branch name is replaced with -)
  --no-fetch                   Skip the remote-tracking ref refresh (offline use)
  --strict                     Exit non-zero if any [BLOCKER] is found
      --engine {codex,claude,zenmux,fireworks}
                               Backend to use. Default: codex (preserves
                               current behavior of every existing caller).
                               spec-to-ship passes --engine "$AUDITOR"
                               (default codex).
                               --engine claude uses the user's claude CLI
                               with --dangerously-skip-permissions; pick it
                               for a third independent claude session
                               (separate context from any coder/reviewer
                               claude seats in the same pipeline) when the
                               OSS gateways are unavailable.
  -M, --model <slug>           Explicit model override. Wins over the
                               <PROVIDER>_OSS_* env vars and --auto-tier.
                               Only consulted with --engine zenmux/fireworks.
      --auto-tier              Pick the Pro-tier model when the diff exceeds
                               ~400KB (~100k tokens at 4 bytes/token).
                               Only meaningful with --engine zenmux/fireworks.
  -h, --help                   Show this help

Environment (OSS engines):
  ZENMUX_API_KEY               Required when --engine zenmux. User's ZenMux key.
                               Passed via curl -H "Authorization: Bearer ..." so the
                               key appears in `ps aux` for the lifetime of the
                               request — run on dedicated CI/agent hosts, not
                               shared multi-user systems.
  ZENMUX_CHAT_URL              Optional endpoint override for --engine zenmux.
                               Default: https://zenmux.ai/api/v1/chat/completions
  FIREWORKS_API_KEY            Required when --engine fireworks. User's Fireworks key.
                               Same `ps aux` exposure as ZENMUX_API_KEY above —
                               keep on dedicated CI/agent hosts.
  FIREWORKS_CHAT_URL           Optional endpoint override for --engine fireworks.
                               Default: https://api.fireworks.ai/inference/v1/chat/completions
  OSS_FLASH_MODEL              Required for OSS engines (or use OSS_MODEL / -M).
                               Form: <provider>:<slug>, where <provider> must
                               match --engine. Slug is whatever the provider's
                               API expects in the chat-completions `model` field.
  OSS_PRO_MODEL                Required when --auto-tier picks the Pro tier
                               (i.e., diff > ~400KB). Same form.
  OSS_MODEL                    Single-tier override. Same form. Beats auto-tier
                               and OSS_FLASH_MODEL.

The script has no built-in model defaults: if the relevant OSS_*_MODEL is
unset for the chosen engine, the script fails loudly and names the missing
env var. Set the slugs in your shell rc.

Scope (production-safety only — not style or general correctness):
  - Breaking changes to public APIs, data contracts, message schemas
  - Data migrations: concurrent-write safety, rollback, long locks
  - Secrets/credentials leakage
  - Feature-flag / rollback coverage
  - Error handling at system boundaries
  - Observability gaps for new failure modes

Output tiers:
  [BLOCKER] — must be fixed before deploy
  [WARN]    — risky but not a deploy blocker
  [OK]      — summary of what looks safe
EOF
}

BASE_BRANCH="origin/develop"
OUTPUT_PATH=""
STRICT=false
FETCH=true
ENGINE="codex"
MODEL_OVERRIDE=""
AUTO_TIER=false

_require_value() {
    # Args: flag-name, value (may be empty, unset, or a following flag).
    # Rejecting leading "-" catches `--base --strict` — a paths starting
    # with "-" are rare enough that users can pass `./-name` if needed.
    if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
        echo "ERROR: $1 requires a value" >&2
        usage >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--base)    _require_value "$1" "${2:-}"; BASE_BRANCH="$2"; shift 2 ;;
        -o|--output)  _require_value "$1" "${2:-}"; OUTPUT_PATH="$2"; shift 2 ;;
        --no-fetch)   FETCH=false; shift ;;
        --strict)     STRICT=true; shift ;;
        --engine)     _require_value "$1" "${2:-}"; ENGINE="$2"; shift 2 ;;
        -M|--model)   _require_value "$1" "${2:-}"; MODEL_OVERRIDE="$2"; shift 2 ;;
        --auto-tier)  AUTO_TIER=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$ENGINE" in
    codex|claude|zenmux|fireworks) ;;
    *) echo "ERROR: --engine must be 'codex', 'claude', 'zenmux', or 'fireworks' (got: $ENGINE)" >&2; exit 2 ;;
esac

# Tool prereqs — only check what this engine will actually invoke so that
# codex users don't need jq/curl and OSS-engine users don't need codex.
if [[ "$ENGINE" == "codex" ]]; then
    command -v codex >/dev/null 2>&1 \
        || { echo "ERROR: codex CLI not found on PATH" >&2; exit 2; }
elif [[ "$ENGINE" == "claude" ]]; then
    command -v claude >/dev/null 2>&1 \
        || { echo "ERROR: claude CLI not found on PATH" >&2; exit 2; }
else
    command -v curl >/dev/null 2>&1 \
        || { echo "ERROR: curl not found on PATH" >&2; exit 2; }
    command -v jq >/dev/null 2>&1 \
        || { echo "ERROR: jq not found on PATH" >&2; exit 2; }
    if [[ "$ENGINE" == "zenmux" && -z "${ZENMUX_API_KEY:-}" ]]; then
        echo "ERROR: ZENMUX_API_KEY is required for --engine zenmux" >&2
        exit 2
    fi
    if [[ "$ENGINE" == "fireworks" && -z "${FIREWORKS_API_KEY:-}" ]]; then
        echo "ERROR: FIREWORKS_API_KEY is required for --engine fireworks" >&2
        exit 2
    fi
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: not inside a git repo" >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
    echo "ERROR: detached HEAD — check out a branch first" >&2
    exit 2
fi
if [[ "$BRANCH" == "$BASE_BRANCH" || "$BRANCH" == "${BASE_BRANCH##*/}" ]]; then
    echo "ERROR: currently on base branch '$BRANCH'; switch to a feature branch first" >&2
    exit 2
fi

# If the base is a remote-tracking ref (e.g. origin/develop), refresh it so
# the audit runs against the current remote state — silent staleness would
# undercut the production-safety purpose. Pass --no-fetch to skip.
if [[ "$FETCH" == "true" && "$BASE_BRANCH" == */* ]]; then
    remote="${BASE_BRANCH%%/*}"
    remote_branch="${BASE_BRANCH#*/}"
    if git remote | grep -qx "$remote"; then
        echo "Fetching ${remote}/${remote_branch} to refresh base..." >&2
        git fetch --quiet "$remote" "$remote_branch" 2>/dev/null \
            || echo "WARN: fetch failed; continuing with local ref" >&2
    fi
fi

# Verify the base branch exists (accepts local or remote-tracking refs)
if ! git rev-parse --verify --quiet "$BASE_BRANCH" >/dev/null; then
    echo "ERROR: base branch '$BASE_BRANCH' not found" >&2
    echo "HINT: try -b develop (local) or -b origin/develop" >&2
    exit 2
fi

# Compute the diff for the audit. `git diff <merge-base>` (one ref, no
# --cached) covers the working tree, which subsumes staged changes — a
# staged-but-never-committed new file appears here, and so does a
# staged-then-modified file (the working-tree version wins, which is
# what an audit gate wants: "what would the next push contain after
# git add -A?"). Untracked-but-not-ignored files are still invisible to
# git diff by default; we synthesize an "added" diff for each via
# `git diff --no-index /dev/null <file>` so the brand-new files
# agent_loop frequently produces reach the auditor too.
#
# Why this matters: spec_to_ship.sh runs the audit BEFORE committing the
# implementation (commit happens after the gate clears). A committed-only
# `base...HEAD` diff would silently see nothing and exit 0 with "nothing
# to audit", making the gate a structural no-op. For post-commit callers
# with a clean working tree, the result reduces to `base...HEAD` — no
# regression for that path.
#
# Let git's stderr pass through so a real failure isn't conflated with
# "nothing to audit".
if ! MERGE_BASE="$(git merge-base "$BASE_BRANCH" HEAD)"; then
    echo "ERROR: no merge-base between $BASE_BRANCH and HEAD" >&2
    exit 1
fi
# --no-color so the auditor never receives ANSI escape codes if the
# user has color.ui=always. (Default `auto` already disables color when
# stdout is captured rather than a TTY, but we don't trust the env.)
if ! DIFF_OUTPUT="$(git diff --no-color "$MERGE_BASE")"; then
    echo "ERROR: 'git diff $MERGE_BASE' failed (see message above)" >&2
    exit 1
fi
# NUL-delimited so filenames with embedded newlines (POSIX-permissible,
# rare but real) survive intact — otherwise mapfile -t splits one path
# across multiple array entries and `git diff --no-index` gets a
# truncated path that fails silently behind the `2>/dev/null || true`.
mapfile -t -d '' _UNTRACKED < <(git ls-files -z --others --exclude-standard)
for _u in "${_UNTRACKED[@]}"; do
    [[ -z "$_u" ]] && continue
    # --no-index returns rc=1 when the files differ, which is always
    # true for /dev/null vs an existing file. Tolerate non-zero.
    _u_diff="$(git diff --no-index --no-color -- /dev/null "$_u" 2>/dev/null || true)"
    if [[ -n "$_u_diff" ]]; then
        DIFF_OUTPUT="${DIFF_OUTPUT}"$'\n'"$_u_diff"
    fi
done
if [[ -z "$DIFF_OUTPUT" ]]; then
    echo "No changes vs $BASE_BRANCH (committed + working tree both empty) — nothing to audit." >&2
    exit 0
fi

# Default output path: full branch path with / → - so nested branches don't collide
if [[ -z "$OUTPUT_PATH" ]]; then
    BRANCH_SAFE="${BRANCH//\//-}"
    OUTPUT_PATH="agent_workers/audit/pr-audit-${BRANCH_SAFE}.md"
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"

_FOCUS_BLOCK='Focus areas:
- Breaking changes to public APIs, data contracts, or message schemas
- Database migrations: concurrent-write safety, rollback paths, long locks
- Secrets/credentials: hardcoded values, leaked env vars, logs exposing auth tokens
- Feature-flag / rollback coverage: can this change be disabled without redeploy?
- Error handling at system boundaries (user input, external APIs, network, DB)
- Observability: missing logs/metrics for new failure modes
- Race conditions, resource leaks, auth/authz bypasses

Out of scope (skip these entirely):
- Code style, naming nits, formatting
- General correctness of non-production-critical logic
- Refactoring suggestions
- Test coverage opinions (unless a missing test directly masks a deploy risk)

Output format — strict:

[BLOCKER] <one-line summary>
<2-3 line rationale: what breaks, when, how to fix>

[WARN] <one-line summary>
<2-3 line rationale>

[OK] <one-line summary of what looks safe to deploy>

Rules:
- One tag per finding, each finding separated by a blank line
- If there are no blockers, still emit [OK] with a summary
- Be specific: cite file:line where possible
- Bias toward flagging when uncertain — the human will filter
- Output ONLY the tiered findings. No preamble, no summary paragraph, no trailing commentary.'

PROMPT_CODEX="Audit the git diff provided as <stdin> for PRODUCTION-SAFETY blockers only.

You may read any file in the repository (read-only) to understand context around the changes — e.g. to check whether a new API is referenced elsewhere, or whether a migration affects production data shapes. Focus on the diff itself; do not re-review unchanged code.

${_FOCUS_BLOCK}"

PROMPT_OSS="Audit the git diff provided as <stdin> for PRODUCTION-SAFETY blockers only.

The ONLY source you have access to is the <stdin> diff below. You CANNOT read files, run commands, or browse the repository. Do not claim to have checked any file that is not shown in the diff. If a finding would require looking at surrounding code you do not have, say so explicitly and mark it [WARN] rather than fabricating context.

${_FOCUS_BLOCK}"

CLEANUP_FILES=()
trap 'rm -f "${CLEANUP_FILES[@]}"' EXIT
TMPFILE="$(mktemp)"; CLEANUP_FILES+=("$TMPFILE")
CODEX_LOG="$(mktemp)"; CLEANUP_FILES+=("$CODEX_LOG")
CLAUDE_LOG="$(mktemp)"; CLEANUP_FILES+=("$CLAUDE_LOG")

if [[ "$ENGINE" == "codex" ]]; then
    echo "Auditing ${BRANCH} vs ${BASE_BRANCH}... (codex is thinking)" >&2

    # --output-last-message writes ONLY the model's final response to the file,
    # without CLI framing (session id, token counts, etc). We suppress codex's
    # own stdout/stderr into CODEX_LOG so the saved report and our own stdout
    # contain only the tiered findings — grep-friendly for strict mode and
    # downstream consumers.
    # --sandbox read-only lets codex inspect surrounding files for context
    # without modifying the working tree.
    if ! printf '%s\n' "$DIFF_OUTPUT" \
            | codex exec --sandbox read-only \
                --output-last-message "$TMPFILE" \
                "$PROMPT_CODEX" > "$CODEX_LOG" 2>&1; then
        echo "ERROR: codex exec failed — tail of codex log:" >&2
        tail -30 "$CODEX_LOG" >&2
        exit 1
    fi
elif [[ "$ENGINE" == "claude" ]]; then
    echo "Auditing ${BRANCH} vs ${BASE_BRANCH}... (claude is thinking)" >&2

    # claude -p prints the model's final response to stdout (no CLI framing).
    # --dangerously-skip-permissions sidesteps the interactive permission
    # prompt that would otherwise stall a non-interactive audit. The audit
    # prompt asks only for tiered findings, so unintended file writes are
    # unlikely on trusted feature branches; future hardening (a no-tools
    # flag or sandboxed exec) is tracked in the spec's deferred work.
    # Use the agentic PROMPT_CODEX — claude has the same shell capabilities
    # as codex and benefits from being able to read surrounding files.
    #
    # NOTE: claude -p only reads stdin when no positional prompt argument
    # is given (see agent_workers/lib/agent_sessions.sh: stdin is the
    # prompt when no positional is passed; otherwise stdin is ignored).
    # codex exec accepts both, but claude does not — so we merge prompt +
    # diff into a single stdin stream rather than splitting them like the
    # codex branch does. The diff appears immediately after the prompt
    # body; the model is more than capable of locating it.
    if ! printf '%s\n\n%s' "$PROMPT_CODEX" "$DIFF_OUTPUT" \
            | claude -p --dangerously-skip-permissions \
                > "$TMPFILE" 2> "$CLAUDE_LOG"; then
        echo "ERROR: claude -p failed — tail of claude log:" >&2
        tail -30 "$CLAUDE_LOG" >&2
        exit 1
    fi
else
    # OSS engines (zenmux/fireworks) share the same OpenAI-compatible
    # chat-completions wire format. Model selection uses unprefixed env vars
    # OSS_FLASH_MODEL / OSS_PRO_MODEL / OSS_MODEL whose values carry a
    # `<provider>:<slug>` discriminator. The provider half must match
    # --engine; the slug half goes into the request body. Per-provider URL
    # + API key are still resolved internally from convention (--engine X
    # → X_API_KEY).
    #
    # _parse_oss_model: validates env-var value, prints bare slug on stdout.
    # Empty input → empty output (caller decides whether that is fatal).
    _parse_oss_model() {
        local name="$1" raw="$2"
        [[ -z "$raw" ]] && return 0
        if [[ "$raw" != *:* ]]; then
            echo "ERROR: $name='$raw' must use form <provider>:<slug>" >&2
            exit 2
        fi
        local prov="${raw%%:*}" slug="${raw#*:}"
        case "$prov" in
            fireworks|zenmux) ;;
            *) echo "ERROR: $name has unknown provider '$prov' (expected fireworks|zenmux)" >&2; exit 2 ;;
        esac
        if [[ "$prov" != "$ENGINE" ]]; then
            echo "ERROR: $name has provider '$prov' but --engine=$ENGINE" >&2
            exit 2
        fi
        printf '%s' "$slug"
    }

    # Engine-specific URL + API key + display label. The script picks the
    # provider's API surface; the model itself is supplied entirely by the
    # user via OSS_*_MODEL (no built-in model defaults — env var IS the
    # configuration, and silent fallback to a hardcoded slug invites rot).
    if [[ "$ENGINE" == "zenmux" ]]; then
        OSS_URL="${ZENMUX_CHAT_URL:-https://zenmux.ai/api/v1/chat/completions}"
        API_KEY="$ZENMUX_API_KEY"
        PROVIDER_LABEL="ZenMux"
    else
        OSS_URL="${FIREWORKS_CHAT_URL:-https://api.fireworks.ai/inference/v1/chat/completions}"
        API_KEY="$FIREWORKS_API_KEY"
        PROVIDER_LABEL="Fireworks"
    fi

    # Parse env vars to bare slugs, validating prefix matches engine.
    flash_slug=$(_parse_oss_model OSS_FLASH_MODEL "${OSS_FLASH_MODEL:-}")
    pro_slug=$(_parse_oss_model OSS_PRO_MODEL "${OSS_PRO_MODEL:-}")
    single_slug=$(_parse_oss_model OSS_MODEL "${OSS_MODEL:-}")

    diff_bytes=$(printf '%s' "$DIFF_OUTPUT" | wc -c)

    # Resolve model slug: -M > OSS_MODEL > (auto-tier picks Pro on big diffs) > OSS_FLASH_MODEL.
    # -M takes a bare slug; provider implied by --engine. If the resolved
    # tier is missing, fail loudly — no silent fallback.
    if [[ -n "$MODEL_OVERRIDE" ]]; then
        MODEL="$MODEL_OVERRIDE"
    elif [[ -n "$single_slug" ]]; then
        MODEL="$single_slug"
    elif [[ "$AUTO_TIER" == "true" && "$diff_bytes" -gt 400000 ]]; then
        if [[ -z "$pro_slug" ]]; then
            echo "ERROR: --auto-tier on a ${diff_bytes}-byte diff requires OSS_PRO_MODEL" >&2
            echo "       form: ${ENGINE}:<your model slug>" >&2
            exit 2
        fi
        MODEL="$pro_slug"
    else
        if [[ -z "$flash_slug" ]]; then
            echo "ERROR: --engine $ENGINE requires OSS_FLASH_MODEL (or OSS_MODEL, or -M)" >&2
            echo "       form: ${ENGINE}:<your model slug>" >&2
            exit 2
        fi
        MODEL="$flash_slug"
    fi

    echo "Auditing ${BRANCH} vs ${BASE_BRANCH}... (${PROVIDER_LABEL} ${MODEL} is thinking)" >&2

    REQ_BODY="$(mktemp)"; CLEANUP_FILES+=("$REQ_BODY")
    RESP_BODY="$(mktemp)"; CLEANUP_FILES+=("$RESP_BODY")
    DIFF_FILE="$(mktemp)"; CLEANUP_FILES+=("$DIFF_FILE")

    # Write the diff to a file and read it via --rawfile so jq doesn't take
    # it on argv. --auto-tier diffs regularly exceed the kernel's ARG_MAX.
    printf '%s' "$DIFF_OUTPUT" > "$DIFF_FILE"

    jq -n --arg model "$MODEL" --arg prompt "$PROMPT_OSS" --rawfile diff "$DIFF_FILE" \
        '{model: $model,
          messages: [{role:"user",
                      content: ($prompt + "\n\n<stdin>\n" + $diff + "\n</stdin>")}],
          temperature: 0.1}' > "$REQ_BODY"

    # The API key rides on -H "Authorization: Bearer ..." which means it is
    # visible in `ps aux` (the full curl argv) for the lifetime of the
    # request. Surface this at runtime so the operator can abort if they
    # are on a shared host — same warning the --help text carries.
    echo "NOTE: API key will be visible in ps aux for the duration of this request." >&2

    http_status=$(curl -s -o "$RESP_BODY" -w '%{http_code}' \
        --max-time 120 --connect-timeout 15 \
        -X POST "$OSS_URL" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$REQ_BODY" || echo "000")

    if [[ "$http_status" != "200" ]]; then
        echo "ERROR: ${PROVIDER_LABEL} request failed (HTTP $http_status)" >&2
        echo "--- response body ---" >&2
        head -c 4096 "$RESP_BODY" >&2
        echo "" >&2
        exit 1
    fi

    if ! jq -re '.choices[0].message.content' < "$RESP_BODY" > "$TMPFILE" \
            || [[ ! -s "$TMPFILE" ]]; then
        echo "ERROR: ${PROVIDER_LABEL} response missing .choices[0].message.content" >&2
        echo "--- response body ---" >&2
        head -c 4096 "$RESP_BODY" >&2
        echo "" >&2
        exit 1
    fi
fi

cat "$TMPFILE"
cp "$TMPFILE" "$OUTPUT_PATH"
echo "" >&2
echo "Audit written to: $OUTPUT_PATH" >&2

if [[ "$STRICT" == "true" ]] && grep -q '^\[BLOCKER\]' "$TMPFILE"; then
    echo "STRICT MODE: [BLOCKER] found — exiting non-zero." >&2
    exit 1
fi

exit 0
