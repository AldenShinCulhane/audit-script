#!/bin/bash
# issue_pipeline_helpers.sh — the per-work-item MVP pipeline for issue_sweep.sh.
#
# Sourced by agent_workers/issue_sweep.sh AFTER issue_triage_helpers.sh (for the
# SWEEP_LABEL_* ledger) and review_fix_helpers.sh (for the rf_* inner loop) and
# lib/agent_sessions.sh (for run_agent_turn). Provides the Phase 2 surface that
# takes one triaged, queued, single-repo, code-only work-item all the way to an
# audited PR:
#
#   PATH A    reason+implement on a fresh feat/sweep/<date>/<slug> branch off
#             origin/develop: a planner turn (claude @ SWEEP_PLANNER_MODEL)
#             writes a plan WITHOUT editing, then an implementer turn (the -i
#             fixer, default codex) edits per plan, runs the repo's OWN
#             review/validation and must emit a terminal [PASS] for that gate to
#             pass (a diff WITHOUT [PASS] parks, never pushes) -> commit -> push
#             -> gh pr create (body: Refs #N + sweep:work-item:<id>); label
#             members in-progress. The sweep must run detached/cron (OOM).
#   OUTER     bounded by MAX_PR_ROUNDS: REVIEW-FIX inner loop (rf_*) converges to
#   PR LOOP   only-nits/approve, then audit_pr_review.sh gates approve vs
#             request-changes; request-changes -> codex audit-fix -> single push
#             -> re-enter REVIEW-FIX, then audit -R on the deltas.
#   COLLECT   approve -> mark shippable + summary row; any cap-hit / fatal /
#             no-diff -> park members bot:needs-human + summary row.
#
# A work-item is ATOMIC: it ships or parks as a unit (members share one branch).
# Every failure mode parks the item and CONTINUES the sweep — no item aborts the
# run. The caller invokes sweep_drive_work_item under `|| true` so errexit is
# relaxed across the whole driver subtree; control flow here is explicit.
#
# The sweep run workspace lives OUTSIDE the target repo (SWEEP_RUN_WORKDIR) so
# `git add -A` on PATH A never captures sweep artifacts into the PR diff.

# Rows accumulated for the manual-collect summary, one per driven work-item:
#   "<wid>|<issues>|<route/impl>|<pr>|<verdict>|<disposition>"
SWEEP_SUMMARY_ROWS=()

# Shippable work-items (audit approve) accumulated for the Phase 3 bot-merge
# aggregator, one compact JSON object each:
#   {wid, branch, pr, verdict, issue_numbers}
SWEEP_SHIPPABLE=()

sweep_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

sweep_summary_route_label() {
    local route="$1" impl="${2:-}"
    if [ -z "$impl" ] || [ "$route" = "resume" ]; then
        printf '%s' "$route"
    else
        printf '%s/%s' "$route" "$impl"
    fi
}

# OOM guard (spec "Risks/gates" → OOM; changes.md Phase 2 "agent runs detached
# (no inline claude proc)"). PATH A spawns a heavy Claude Code agent; it must
# NOT run as a child of an interactive Claude Code session — two ~1M-context
# claude procs OOM the 32GB/0-swap box and can kill the interactive CLI. The
# interactive Claude CLI exports CLAUDECODE to its subprocesses, so a non-empty
# CLAUDECODE means this sweep is inline inside one. Refuse to drive PATH A in
# that case (fail fast, before any agent/branch/PR work) unless the operator
# sets SWEEP_DETACHED to acknowledge an approved detached/cron context. Returns
# non-zero to refuse; the caller exits before spawning anything.
sweep_assert_detached() {
    if [ -n "${CLAUDECODE:-}" ] && [ -z "${SWEEP_DETACHED:-}" ]; then
        echo "ERROR: refusing to drive PATH A from inside an interactive Claude Code" >&2
        echo "       session (CLAUDECODE is set). PATH A spawns a Claude Code agent;" >&2
        echo "       running it inline risks OOM (32GB/0 swap, two ~1M-context procs)." >&2
        echo "       Launch the sweep detached / via cron, or export SWEEP_DETACHED=1 to" >&2
        echo "       acknowledge an approved detached context." >&2
        return 1
    fi
    return 0
}

sweep_log() {
    echo "$(date '+%H:%M:%S') $*" >> "${LOGFILE:-/dev/null}"
    echo "    $*" >&2
}

# ── Repo-scoped run lock (audit BLOCKER: overlapping sweeps) ────────────────
# Two cron/detached sweeps on the SAME repo would race branch/label/rollup
# mutations and open duplicate or conflicting PRs. The caller takes a
# NON-BLOCKING, repo-scoped lock for the whole non-dry-run; a second run fails
# fast instead of colliding. The lock is an flock on a file under the repo's
# .git/ — held via an open fd for the process lifetime, so the kernel releases
# it automatically when this process exits (even on a crash), with no stale-lock
# bookkeeping. dry-run takes no lock (it performs zero mutations).
SWEEP_LOCK_FD=""

# Acquire the exclusive repo lock. Returns 0 acquired, 1 contended (another live
# sweep holds it), 2 flock unavailable. On success the fd is parked in the
# SWEEP_LOCK_FD global for sweep_release_repo_lock.
sweep_acquire_repo_lock() {
    local lock_file="$1"
    command -v flock >/dev/null 2>&1 || return 2
    mkdir -p "$(dirname "$lock_file")" || return 2
    exec {SWEEP_LOCK_FD}>"$lock_file" || { SWEEP_LOCK_FD=""; return 2; }
    if ! flock -n "$SWEEP_LOCK_FD"; then
        exec {SWEEP_LOCK_FD}>&- 2>/dev/null || true
        SWEEP_LOCK_FD=""
        return 1
    fi
    return 0
}

# Release the repo lock (trap'd on EXIT). Idempotent; a no-op when unheld.
sweep_release_repo_lock() {
    [ -n "${SWEEP_LOCK_FD:-}" ] || return 0
    flock -u "$SWEEP_LOCK_FD" 2>/dev/null || true
    exec {SWEEP_LOCK_FD}>&- 2>/dev/null || true
    SWEEP_LOCK_FD=""
}

# ── Per-issue atomic claim (audit BLOCKER: overlapping sweeps) ──────────────
# Belt-and-suspenders alongside the repo lock: re-fetch each member issue's
# CURRENT labels right before driving and refuse the work-item if ANY member is
# already claimed (bot:in-progress) or done (bot:shipped) by a concurrent run.
# The repo lock covers same-host races; this narrows the window for a sweep on
# another host (whose filesystem lock is invisible here) that may have claimed
# the issue between this run's triage and drive. A work-item is atomic, so a
# single claimed member skips the whole item. Returns 0 = claimable, 1 = already
# claimed / unverifiable (caller skips WITHOUT mutating labels). A hard gh
# failure is treated as unverifiable (skip) rather than racing blindly.
#
# Audit BLOCKER (bot:needs-human override): this re-fetch is the LAST read before
# the drive's first mutation, so it must refuse EVERY terminal label, including
# bot:needs-human. A human or another run can park an issue AFTER this run's
# triage fetched it; without this guard the stale fresh-partition would still
# relabel it bot:in-progress and ship it, overriding the human/park decision.
sweep_claim_members() {
    local n labels
    for n in "$@"; do
        labels="$(gh issue view "$n" --repo "$REPO_SLUG" --json labels \
            --jq '[.labels[].name]' 2>/dev/null)" || {
            sweep_log "claim: could not re-fetch labels for #$n — skipping work-item (cannot verify)"
            return 1
        }
        # Empty/parse-less output (e.g. an issue with no labels) is claimable;
        # any terminal label (in-progress / shipped / needs-human) means another
        # run — or a human — owns the issue and this run must not touch it.
        if printf '%s' "$labels" | jq -e \
                --arg a "$SWEEP_LABEL_IN_PROGRESS" --arg b "$SWEEP_LABEL_SHIPPED" \
                --arg c "$SWEEP_LABEL_NEEDS_HUMAN" \
                'any(.[]?; . == $a or . == $b or . == $c)' >/dev/null 2>&1; then
            sweep_log "claim: #$n already terminal ($SWEEP_LABEL_IN_PROGRESS/$SWEEP_LABEL_SHIPPED/$SWEEP_LABEL_NEEDS_HUMAN) — skipping work-item"
            return 1
        fi
    done
    return 0
}

# ── Atomic remote claim (audit BLOCKER: cross-host overlapping sweeps) ──────
# The repo flock only coordinates sweeps sharing ONE local .git; two cron runs on
# DIFFERENT hosts have independent filesystems, so sweep_claim_members above is a
# TOCTOU read (both could pass it AND both relabel) and the bot:queued ->
# bot:in-progress relabel is not a compare-and-set. GitHub offers no label CAS,
# but server-side ref creation IS atomic: receive-pack serializes pushes, so a
# push that CREATES a branch under a non-existence lease lets EXACTLY ONE
# concurrent claimant win. We push a per-run-UNIQUE marker commit to a
# per-work-item claim branch (sweep-claim/<date>/<slug>) with a zero-OID lease;
# every other claimant's push is rejected because the ref now exists. A unique
# marker is REQUIRED — two claimants pushing the SAME commit SHA would both
# no-op-"succeed", so the marker embeds host+pid+nonce to guarantee distinct SHAs.
SWEEP_CLAIM_NONCE=0
_sweep_claim_ref() { printf 'sweep-claim/%s/%s' "$SWEEP_DATE" "$1"; }

# Acquire the remote claim for a work-item slug. Returns 0 claimed, 1 lost
# (another live run holds it / push rejected), 2 infra error. The caller skips
# the work-item on any non-zero — never double-drives.
sweep_remote_claim_acquire() {
    local project="$1" slug="$2" wid="$3"; shift 3
    local ref base marker host zero="0000000000000000000000000000000000000000"
    ref="$(_sweep_claim_ref "$slug")"
    git -C "$project" fetch --quiet origin "$SWEEP_PR_BASE" 2>/dev/null || return 2
    base="$(git -C "$project" rev-parse "origin/$SWEEP_PR_BASE" 2>/dev/null)" || return 2
    SWEEP_CLAIM_NONCE=$((SWEEP_CLAIM_NONCE + 1))
    host="$(hostname 2>/dev/null || echo host)"
    # Unique marker => distinct commit SHA per claimant => the zero-OID
    # (must-not-exist) lease admits only the first creator of the ref.
    marker="$(printf 'sweep-claim %s by %s-%s-%s\n\n%ssweep:work-item:%s\n' \
        "$wid" "$host" "$$" "$SWEEP_CLAIM_NONCE" "$(_sweep_refs_block "$@")" "$wid" \
        | git -C "$project" commit-tree "${base}^{tree}" -p "$base" 2>/dev/null)" || return 2
    if git -C "$project" push --force-with-lease="refs/heads/${ref}:${zero}" \
            origin "${marker}:refs/heads/${ref}" >>"${LOGFILE:-/dev/null}" 2>&1; then
        return 0
    fi
    return 1
}

# Release a held remote claim (delete the claim branch) on every exit path after
# a successful acquire. Best-effort: a delete failure is logged, not fatal — a
# hard-killed run that orphans the ref leaves the item bot:in-progress, which the
# resume pass + --resume-stale recover; the claim only ever fails SAFE (skip,
# never double-drive).
sweep_remote_claim_release() {
    local project="$1" slug="$2" ref
    ref="$(_sweep_claim_ref "$slug")"
    git -C "$project" push --quiet origin --delete "$ref" >>"${LOGFILE:-/dev/null}" 2>&1 \
        || sweep_log "claim: WARN could not delete claim ref $ref (best-effort)"
}

# Reap any ORPHAN remote claim ref (sweep-claim/<date>/<slug>) whose marker
# commit references this issue AND is older than SWEEP_CLAIM_TTL seconds (default
# 6h). Without this, a crash/kill AFTER sweep_remote_claim_acquire but BEFORE any
# feat/sweep branch / PR strands the issue: resume discovery (PR + feat/sweep/*
# only) finds nothing, --resume-stale relabels it bot:queued, and the next drive
# then LOSES to the never-deleted claim ref forever (reviewer 02:06:39). The TTL
# is the owner check: a FRESH claim is a live concurrent drive and is PRESERVED
# (deleting it would re-open the double-drive race); only an aged claim left by a
# dead run is reaped, so the retry's acquire can win. Probes claim refs into a
# private local namespace (no push besides the orphan delete). Best-effort;
# always returns 0 so the caller can `&& retry` regardless.
sweep_clear_stale_claim_for_issue() {
    local issue="$1" project="${2:-$PROJECT_ROOT}"
    local ttl="${SWEEP_CLAIM_TTL:-21600}" probe="refs/remotes/sweep-claim-probe" r
    local -a old refs
    mapfile -t old < <(git -C "$project" for-each-ref --format='%(refname)' "${probe}/" 2>/dev/null)
    for r in "${old[@]}"; do [ -z "$r" ] || git -C "$project" update-ref -d "$r" 2>/dev/null || true; done
    git -C "$project" fetch --quiet --force origin \
        "refs/heads/sweep-claim/*:${probe}/*" 2>/dev/null || return 0
    mapfile -t refs < <(git -C "$project" for-each-ref --format='%(refname)' "${probe}/" 2>/dev/null)
    local now body committed age name sha pat="#${issue}([^0-9]|$)"
    now="$(date -u +%s)"
    for r in "${refs[@]}"; do
        [ -z "$r" ] && continue
        body="$(git -C "$project" log -1 "$r" --format='%B' 2>/dev/null)" || continue
        [[ "$body" =~ $pat ]] || continue
        committed="$(git -C "$project" log -1 "$r" --format='%ct' 2>/dev/null)" || continue
        age=$(( now - committed ))
        name="sweep-claim/${r#"${probe}/"}"
        if [ "$age" -lt "$ttl" ]; then
            sweep_log "resume: claim ref $name for #$issue is fresh (age ${age}s < TTL ${ttl}s) — preserving (live drive)"
            continue
        fi
        # Lease the delete against the EXACT orphan SHA we probed (reviewer
        # 02:14:05: two reapers racing). If another host already reaped + reacquired
        # a FRESH claim, the remote ref no longer matches this orphan SHA, the lease
        # fails, and we leave their fresh claim intact — never re-opening the
        # double-drive. Explicit if/else (not A && B || C) keeps shellcheck -x clean
        # (SC2015). Deleting via the ":refs/..." empty-source refspec so the lease
        # applies to the delete.
        sha="$(git -C "$project" rev-parse "$r" 2>/dev/null)" || continue
        if git -C "$project" push --quiet \
                --force-with-lease="refs/heads/${name}:${sha}" \
                origin ":refs/heads/${name}" >>"${LOGFILE:-/dev/null}" 2>&1; then
            sweep_log "resume: reaped orphan claim ref $name (#$issue, age ${age}s >= TTL ${ttl}s)"
        else
            sweep_log "resume: orphan claim ref $name delete lost lease/contended (#$issue) — left intact"
        fi
    done
    return 0
}

# Reject a work_item_id / branch_slug that is not a strict, safe slug. Defense in
# depth for the audit BLOCKER: sweep_decorate_queue already parks unsafe items as
# invalid, but the driver re-checks before turning these untrusted, Claude-produced
# fields into a filesystem path ($workdir) or a git ref (feat/sweep/<date>/<slug>).
# A safe slug is one token of [A-Za-z0-9._-] with no "..", no "/", and no
# leading/trailing punctuation — so it can neither traverse paths nor push an
# unexpected ref. Returns non-zero (refuse) on any violation.
_sweep_is_safe_slug() {
    local s="$1"
    [[ -n "$s" ]] || return 1
    [[ "$s" == *".."* ]] && return 1
    [[ "$s" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]
}

# ── Push sandbox (audit BLOCKER: the agent must not push) ──────────────────
# PATH A's implementer and the codex fixer run with the runner's git/GitHub
# credentials and are only *instructed* (via the prompt) not to push or open PRs.
# Prompt injection or a model error could still push a branch (ANY branch,
# including develop) or open/merge a PR, bypassing the orchestrator's feat/* +
# bot/* -only push policy. Containment is layered, applied to the agent
# subprocess for the duration of the turn and restored before the runner pushes:
#
#   1. PATH shims — git/gh wrappers that DENY push / PR-create-merge / write-api
#      with a clear error and delegate reads to the real binary. Catches the
#      common case and gives an explicit signal.
#   2. Credential + remote lockdown — exported env inherited by ANY binary the
#      agent runs regardless of path (closes the absolute-path bypass of layer 1,
#      reviewer 02:41:56):
#        * GH auth stripped: GH_CONFIG_DIR -> empty dir, GH_TOKEN/GITHUB_TOKEN
#          cleared -> `gh` (even absolute-path) is unauthenticated, so pr
#          create/merge and write `gh api` fail.
#        * git push neutralized: GIT_CONFIG_* injects remote.origin.pushurl ->
#          a dead path and clears credential.helper; GIT_TERMINAL_PROMPT=0 +
#          GIT_ASKPASS denier + SSH_AUTH_SOCK cleared (no ssh-agent) +
#          GIT_SSH_COMMAND denier stop any interactive / agent / ssh-key
#          credential — so `git push` (even absolute-path) cannot authenticate
#          or resolve a push target.
#   3. Value-DESTROYING clears (GH_TOKEN, GITHUB_TOKEN, SSH_AUTH_SOCK -> "") —
#      the erased values cannot be recovered by `env -u <VAR>` (reviewer
#      02:53:39's env-unset bypass): the parent no longer holds the ssh-agent
#      socket path or the API token, so unsetting our override yields empty, not
#      the original secret.
# The agent's OWN model credentials (ANTHROPIC_*/codex config in $HOME) are
# untouched — only GitHub/git push paths are locked.
#
# Residual (documented, NOT closed here): a fully arbitrary-exec agent can still
# `env -u HOME /usr/bin/git push` and reach a RAW on-disk credential (a `store`
# helper's ~/.git-credentials, or a libsecret/keychain daemon) via the libc
# passwd-home fallback that NO env var can stop. Closing that needs an OS sandbox
# (separate uid / mount+user namespace / container) or selective network egress —
# none available on this host (bwrap/firejail absent; `unshare -Urm
# --map-root-user` -> "Operation not permitted"; egress firewall needs root). A
# clean-HOME redirect is unsafe because the agent's own model creds live under
# $HOME. This residual is backstopped by the spec's design (docs/todos/issue-sweep.md
# "Risks/gates" -> Push authorization: pushes target feat/* + bot/* only, never
# develop; "Non-goals": the human bot->develop merge is the only develop gate) and
# is a deployment control (dedicated low-priv service account / container without
# the operator's push token), not a bash-orchestrator fix.
SWEEP_PUSH_SANDBOX_BIN=""

# Build (once, memoized) a bin dir holding the push-denying git/gh shims + the
# deny-askpass / deny-ssh helpers + an empty gh config dir, and print its path.
# Returns non-zero only if the real git/gh cannot be resolved — the caller then
# fails the turn CLOSED rather than running an unsandboxed agent.
sweep_push_sandbox_bin() {
    if [ -n "${SWEEP_PUSH_SANDBOX_BIN:-}" ] && [ -x "$SWEEP_PUSH_SANDBOX_BIN/git" ]; then
        printf '%s' "$SWEEP_PUSH_SANDBOX_BIN"; return 0
    fi
    local real_git real_gh dir
    real_git="$(command -v git)" || return 1
    real_gh="$(command -v gh)" || return 1
    dir="${SWEEP_RUN_WORKDIR:-${TMPDIR:-/tmp}}/.push-sandbox"
    mkdir -p "$dir" "$dir/gh-empty" || return 1
    # git shim: refuse `git push`; pass every other subcommand through. The arg
    # scan skips git's value-taking global options (-C <path>, -c <kv>, ...) so
    # `git -C <dir> push` is still caught while a non-push subcommand is allowed.
    # The exposed real path is harmless: the credential/remote lockdown (below)
    # denies push to the real binary too — the shim is the convenience layer.
    cat > "$dir/git" <<EOF
#!/bin/bash
real=$real_git
skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in
    -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--exec-path) skip=1 ;;
    push) echo "issue-sweep: 'git push' is disabled for the agent; the runner owns all pushes" >&2; exit 1 ;;
    --) : ;;
    -*) : ;;
    *) break ;;
  esac
done
exec "\$real" "\$@"
EOF
    # gh shim: refuse subcommands that can push code or mutate the PR/repo
    # (pr create/merge/..., and any write-method or write-field \`gh api\`); reads
    # pass through. The agent fix turns never need these — the runner owns them.
    cat > "$dir/gh" <<EOF
#!/bin/bash
real=$real_gh
case "\${1:-}" in
  pr)
    case "\${2:-}" in
      create|merge|ready|close|reopen|edit|comment|review)
        echo "issue-sweep: 'gh pr \${2}' is disabled for the agent; the runner owns PR mutations" >&2; exit 1 ;;
    esac ;;
  api)
    want=0
    for a in "\$@"; do
      case "\$a" in
        -X|--method) want=1 ;;
        POST|PATCH|PUT|DELETE) [ "\$want" = 1 ] && { echo "issue-sweep: write 'gh api' is disabled for the agent" >&2; exit 1; }; want=0 ;;
        -f|-F|--field|--raw-field|--input) echo "issue-sweep: write 'gh api' (field/input) is disabled for the agent" >&2; exit 1 ;;
        *) want=0 ;;
      esac
    done ;;
esac
exec "\$real" "\$@"
EOF
    # Credential deniers: any git operation that has to ASK for a credential gets
    # an immediate failure instead of a prompt or an ssh-agent key.
    printf '#!/bin/bash\nexit 1\n' > "$dir/deny-askpass"
    printf '#!/bin/bash\necho "issue-sweep: ssh is disabled for the agent" >&2\nexit 255\n' > "$dir/deny-ssh"
    chmod +x "$dir/git" "$dir/gh" "$dir/deny-askpass" "$dir/deny-ssh" || return 1
    SWEEP_PUSH_SANDBOX_BIN="$dir"
    printf '%s' "$dir"
}

# Env vars the lockdown overrides; snapshotted so the runner's environment is
# restored byte-for-byte (a var unset before stays unset after).
_SWEEP_LOCKDOWN_VARS=(PATH GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN SSH_AUTH_SOCK
    GIT_TERMINAL_PROMPT GIT_ASKPASS GIT_SSH_COMMAND GIT_CONFIG_COUNT
    GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1)
declare -gA _SWEEP_LOCKDOWN_SNAP=()

# Apply the credential/remote lockdown for the agent subprocess, snapshotting the
# prior values into _SWEEP_LOCKDOWN_SNAP for _sweep_lockdown_restore.
_sweep_lockdown_apply() {
    local bin="$1" v
    _SWEEP_LOCKDOWN_SNAP=()
    for v in "${_SWEEP_LOCKDOWN_VARS[@]}"; do
        if [ -n "${!v+x}" ]; then _SWEEP_LOCKDOWN_SNAP["$v"]="s:${!v}"; else _SWEEP_LOCKDOWN_SNAP["$v"]="u"; fi
    done
    export PATH="$bin:$PATH"
    # Value-destroying clears: the agent (and `env -u <VAR>`) cannot recover an
    # API token or the ssh-agent socket path the parent has already erased.
    export GH_CONFIG_DIR="$bin/gh-empty" GH_TOKEN="" GITHUB_TOKEN="" SSH_AUTH_SOCK=""
    export GIT_TERMINAL_PROMPT="0" GIT_ASKPASS="$bin/deny-askpass" GIT_SSH_COMMAND="$bin/deny-ssh"
    export GIT_CONFIG_COUNT="2" \
        GIT_CONFIG_KEY_0="credential.helper"      GIT_CONFIG_VALUE_0="" \
        GIT_CONFIG_KEY_1="remote.origin.pushurl"  GIT_CONFIG_VALUE_1="$bin/PUSH-DISABLED-issue-sweep"
}

# Restore every locked-down var to its pre-turn state (set->value, unset->unset).
_sweep_lockdown_restore() {
    local v val
    for v in "${!_SWEEP_LOCKDOWN_SNAP[@]}"; do
        val="${_SWEEP_LOCKDOWN_SNAP[$v]}"
        if [ "$val" = "u" ]; then unset "$v"; else export "$v=${val#s:}"; fi
    done
    _SWEEP_LOCKDOWN_SNAP=()
}

# Whether a credential-isolated context for the fix agent is guaranteed.
#
# A context a fully arbitrary-exec agent cannot `env -u` its way out of (to reach
# on-disk gh/git credentials and push directly to develop) requires an OS sandbox
# (separate uid / mount+user namespace / container) or a dedicated push-tokenless
# identity — NONE constructible in-bash on this host (no bwrap/firejail;
# `unshare -Urm --map-root-user` -> "Operation not permitted"). The env lockdown
# below is inherited env only and an injected turn can opt out with
# `env -u <VAR> /usr/bin/git push origin HEAD:develop` (reviewer 03:03:58), which
# the human bot->develop gate does NOT protect against.
#
# So by DEFAULT we FAIL CLOSED: refuse to run the credential-bearing fix agent.
# The operator opts in with SWEEP_ALLOW_UNSANDBOXED_AGENT=1 ONLY after providing
# that isolation EXTERNALLY — run the detached sweep inside a container / under a
# service account WITHOUT the operator's push token / behind an egress firewall.
# (Future: auto-detect bwrap/an OS sandbox and wrap the agent in it, which would
# make the opt-in unnecessary.) Reviewer 03:03:58: "make the agent credentialless
# in code or fail closed when impossible."
sweep_agent_isolation_ok() {
    [ "${SWEEP_ALLOW_UNSANDBOXED_AGENT:-}" = "1" ]
}

# Run an agent turn (run_agent_turn <args>) behind the push sandbox + credential
# lockdown so the spawned agent cannot push or open/merge PRs by ANY path
# (PATH-shimmed or absolute). FAILS CLOSED (non-zero, NO agent run) when a
# credential-isolated context is not asserted (default) or the sandbox cannot be
# built — never runs the credential-bearing agent unprotected. Restores the
# runner's environment afterward so the runner's own pushes use real binaries +
# real credentials. Caller sets AGENT_PROJECT_ROOT.
sweep_run_agent_no_push() {
    local bin rc
    if ! sweep_agent_isolation_ok; then
        sweep_log "refusing to run fix agent: no credential-isolated context on this host (no OS sandbox) and SWEEP_ALLOW_UNSANDBOXED_AGENT!=1 — failing closed (an injected turn could push directly to develop via on-disk git/gh creds). Run the sweep inside a container / under a push-tokenless service account, then set SWEEP_ALLOW_UNSANDBOXED_AGENT=1."
        return 1
    fi
    bin="$(sweep_push_sandbox_bin)" || {
        sweep_log "push-sandbox unavailable (git/gh not resolvable) — refusing to run agent with push creds"
        return 1
    }
    _sweep_lockdown_apply "$bin"
    run_agent_turn "$@"
    rc=$?
    _sweep_lockdown_restore
    return "$rc"
}

# ── Naming / message builders (pure) ───────────────────────────────────────

sweep_branch_name() { printf 'feat/sweep/%s/%s' "$SWEEP_DATE" "$1"; }

# Refs lines reference every member issue so a clustered PR/commit is
# discoverable by Phase 1 resume (sweep_pr_for_issue / sweep_commit_marker_branch).
_sweep_refs_block() {
    local n
    for n in "$@"; do printf 'Refs #%s\n' "$n"; done
}

sweep_commit_message() {
    local wid="$1" title="$2"; shift 2
    printf 'sweep: %s\n\n' "$title"
    _sweep_refs_block "$@"
    printf '\nsweep:work-item:%s\n' "$wid"
}

sweep_pr_body() {
    local wid="$1" summary="$2"; shift 2
    printf '%s\n\n' "$summary"
    _sweep_refs_block "$@"
    printf '\nsweep:work-item:%s\n' "$wid"
}

# ── Worktree isolation (Phase 3 / V2) ──────────────────────────────────────
# Each work-item builds in its OWN git worktree off origin/$SWEEP_PR_BASE so
# concurrent or sequential items never share a working tree — no file bleed
# across items (the spec_to_ship shared-tree footgun the sweep deliberately
# dodges). The worktree checkout lives UNDER the item's $workdir (which is itself
# under .git/, a tree the main repo never scans); PATH A's `git add -A` runs
# INSIDE the worktree, so sweep artifacts in the parent $workdir are never
# captured into the PR diff.
#
# Audit BLOCKER: the worktree/branch base is $SWEEP_PR_BASE (NOT a hardcoded
# develop) — the SAME ref the per-item PR and the rollup target — so a repo whose
# SWEEP_PR_BASE is main / a release branch never merges develop-only commits into
# the rollup.

# Create a fresh DETACHED worktree at $tree off origin/$SWEEP_PR_BASE.
# sweep_path_a_branch then creates the feat/sweep branch inside it. Idempotent: a
# stale worktree left at $tree by a prior run is removed first. Returns non-zero
# on any git failure.
sweep_worktree_add() {
    local project="$1" tree="$2"
    git -C "$project" fetch --quiet origin "$SWEEP_PR_BASE" || return 1
    sweep_worktree_remove "$project" "$tree"
    mkdir -p "$(dirname "$tree")" || return 1
    git -C "$project" worktree add --detach --quiet "$tree" "origin/$SWEEP_PR_BASE" || return 1
}

# Remove a work-item's worktree (on completion or park) and prune stale metadata.
# The feat/sweep branch ref SURVIVES removal — the aggregator merges it later.
# Idempotent: a missing worktree is not an error.
sweep_worktree_remove() {
    local project="$1" tree="$2"
    [ -n "$tree" ] || return 0
    if [ -e "$tree" ]; then
        git -C "$project" worktree remove --force "$tree" >/dev/null 2>&1 \
            || rm -rf "$tree"
    fi
    git -C "$project" worktree prune >/dev/null 2>&1 || true
}

# ── PATH A ─────────────────────────────────────────────────────────────────

# Hard-reset + clean the working tree. Run at the start of every work-item (so a
# prior parked item's uncommitted/untracked edits are never carried forward onto
# the next item's fresh branch) and on park (so the repo is left clean). The run
# workspace lives under .git/, which `git clean` never touches.
sweep_reset_worktree() {
    local project="$1"
    git -C "$project" reset --hard --quiet 2>/dev/null || return 1
    git -C "$project" clean -fd --quiet 2>/dev/null || return 1
}

# Fresh branch off origin/$SWEEP_PR_BASE. Sequential MVP: every item starts clean
# from the remote base (worktree isolation is Phase 3/V2). The reset+clean below
# discards any edits a previous parked item's agent left in the tree, so nothing
# bleeds across work-items (checkout -B would otherwise carry local mods over).
# The base is $SWEEP_PR_BASE (audit BLOCKER) — the same ref the PR/rollup target —
# not a hardcoded develop, so a non-develop base never ships develop-only commits.
sweep_path_a_branch() {
    local project="$1" branch="$2"
    git -C "$project" fetch --quiet origin "$SWEEP_PR_BASE" || return 1
    sweep_reset_worktree "$project" || return 1
    git -C "$project" checkout -B "$branch" "origin/$SWEEP_PR_BASE" --quiet || return 1
}

# Planner prompt (pure). The planner analyzes and plans but must NOT edit —
# file edits belong to the implementer turn, whose [PASS] output is the only
# thing the push gate reads; an editing planner would smear authorship across
# two agents and make the gate attest work it never validated.
_sweep_plan_prompt() {
    local title="$1" summary="$2" nums="$3"
    cat <<EOF
You are the planning half of a two-agent implementer fixing GitHub issues
${nums} in this repository. Work-item: ${title}

${summary}

Analyze the relevant code and produce a concrete implementation plan for the
smallest correct fix: which files to change, what to change in each, and how to
validate with the repository's OWN review/validation (lint, type-check, and
tests as the repo defines them). Do NOT edit any files, and do NOT commit,
push, or open a PR — reply with the plan only.
EOF
}

# Implementer prompt (reads the plan file). Ends with the SAME [PASS]/[BLOCKED]
# terminal-signal contract the old single-turn implementer had, so
# sweep_path_a's output_has_final_signal gate needs no change.
_sweep_impl_prompt() {
    local title="$1" summary="$2" nums="$3" plan_file="$4"
    cat <<EOF
You are an autonomous implementer fixing GitHub issues ${nums} in this
repository. Work-item: ${title}

${summary}

A planning agent already analyzed this repository and produced the
implementation plan below. Implement it by editing the repository in place
(deviate only where the plan is factually wrong, and say so).

--- PLAN ---
$(cat "$plan_file")
--- END PLAN ---

Then run the repository's OWN review/validation (lint, type-check, and tests
as the repo defines them). Do NOT commit, push, or open a PR — the runner
handles git; edit files in place only.

Only if your changes are complete AND that validation PASSES, end your final
message with a line containing exactly:
[PASS]
If you could not make validation pass, end instead with a line containing
[BLOCKED] and do not claim success.
EOF
}

# Default implementation: a two-turn reason+implement pair replacing the old
# single Claude Code turn. Turn 1 (planner: claude @ SWEEP_PLANNER_MODEL,
# default claude-fable-5) reads the repo and writes a plan WITHOUT editing;
# turn 2 (implementer: the -i fixer agent, default codex — codex ignores model
# overrides, its model comes from ~/.codex/config) edits in place per that
# plan and must emit the terminal [PASS]/[BLOCKED] signal. $out holds the
# IMPLEMENTER's output — the same file sweep_path_a's [PASS] gate reads, so
# the gate contract is unchanged. Both turns run behind the push sandbox with
# AGENT_PROJECT_ROOT pinned to the item's worktree; the runner owns git. A
# failed, empty, or editing planner turn hard-fails (parks) rather than
# degrading to plan-less implementation or letting planner edits ride on the
# implementer's validation signal: park-and-continue makes that cheap, and a
# silent fallback would mask planner outages behind seemingly-normal ships.
sweep_reason_implement() {
    local project="$1" item="$2" out="$3"
    local wid title summary nums plan_out prompt
    wid="$(jq -r '.work_item_id' <<<"$item")"
    title="$(jq -r '.title' <<<"$item")"
    summary="$(jq -r '.summary' <<<"$item")"
    nums="$(jq -r '.issue_numbers | map("#\(.)") | join(", ")' <<<"$item")"
    plan_out="${out%/*}/plan.md"
    prompt="$(_sweep_plan_prompt "$title" "$summary" "$nums")"
    if ! AGENT_PROJECT_ROOT="$project" sweep_run_agent_no_push claude \
            "planA_${wid}" "$prompt" "$plan_out" "${SWEEP_PLANNER_MODEL:-claude-fable-5}"; then
        sweep_log "reason-implement: planner turn failed — parking"
        return 1
    fi
    if [ ! -s "$plan_out" ]; then
        sweep_log "reason-implement: planner produced an empty plan — parking"
        return 1
    fi
    if rf_has_worktree_changes "$project"; then
        sweep_log "reason-implement: planner modified the worktree — parking"
        return 1
    fi
    prompt="$(_sweep_impl_prompt "$title" "$summary" "$nums" "$plan_out")"
    # Run behind the push sandbox (audit BLOCKER): the agent edits in place; the
    # runner — not the agent — owns commit/push/PR.
    AGENT_PROJECT_ROOT="$project" sweep_run_agent_no_push "${FIXER_AGENT:-codex}" \
        "implA_${wid}" "$prompt" "$out"
}

# Commit all changes (dirty + untracked) into the item, push the branch, open
# the PR. Prints the PR number on success. Body/commit carry Refs + marker.
sweep_path_a_open_pr() {
    local project="$1" branch="$2" item="$3"
    local wid title summary url pr_num
    wid="$(jq -r '.work_item_id' <<<"$item")"
    title="$(jq -r '.title' <<<"$item")"
    summary="$(jq -r '.summary' <<<"$item")"
    local -a nums
    mapfile -t nums < <(jq -r '.issue_numbers[]' <<<"$item")

    git -C "$project" add -A || return 1
    git -C "$project" commit --quiet \
        -m "$(sweep_commit_message "$wid" "$title" "${nums[@]}")" || return 1
    git -C "$project" push --quiet -u origin "$branch" || return 1
    url="$(gh pr create --repo "$REPO_SLUG" --base "$SWEEP_PR_BASE" --head "$branch" \
        --title "$title" \
        --body "$(sweep_pr_body "$wid" "$summary" "${nums[@]}")" 2>/dev/null)" || return 1
    pr_num="$(printf '%s' "$url" | sed -nE 's#.*/pull/([0-9]+).*#\1#p' | head -n1)"
    [ -n "$pr_num" ] || return 1
    printf '%s' "$pr_num"
}

# Full PATH A. Prints the PR number; returns 0 PR open, 2 park (validation gate
# failed / no diff / agent failed), 1 git/gh error (also parked by the caller).
# The quality gate is the explicit [PASS] validation signal from the
# IMPLEMENTER turn's output AND a non-empty
# diff — a diff WITHOUT [PASS] (validation failed) parks and is NOT pushed.
sweep_path_a() {
    local project="$1" branch="$2" item="$3" workdir="$4"
    local out="$workdir/pathA_out.txt"
    if ! sweep_path_a_branch "$project" "$branch"; then
        sweep_log "PATH A: could not create $branch off origin/$SWEEP_PR_BASE"; return 1
    fi
    if ! sweep_reason_implement "$project" "$item" "$out"; then
        sweep_log "PATH A: reason+implement failed"; return 2
    fi
    if ! output_has_final_signal "$(cat "$out" 2>/dev/null)" "PASS"; then
        sweep_log "PATH A: agent did not emit [PASS] — validation not passed, parking (no push)"
        return 2
    fi
    if ! rf_has_worktree_changes "$project"; then
        sweep_log "PATH A: validation passed but no diff to ship — parking"; return 2
    fi
    sweep_path_a_open_pr "$project" "$branch" "$item"
}

# ── PATH B (very-complex → spec_to_ship.sh; opt-in via --spec-to-ship) ─────
# With --spec-to-ship set, a very-complex single-repo code-only work-item gets
# spec refinement before implementation: PATH B routes it through
# spec_to_ship.sh (its OWN
# spec_loop -> agent_loop -> dev-stage audit-pr.sh -> push -> PR) instead of
# the default reason+implement turns. The PR spec_to_ship opens then
# enters the SAME outer PR loop (review-fix + audit_pr_review.sh) as a PATH A
# PR — two distinct audits, both intended (Resolved 1: the dev-stage audit-pr.sh
# inside spec_to_ship is NOT the PR-stage audit_pr_review.sh gate).
#
# The contract mirrors PATH A so the downstream driver stays route-agnostic:
# build in the item's isolated worktree on the SAME feat/sweep/<date>/<slug>
# branch (so the aggregator merges it and resume discovery finds it identically),
# and the sweep itself stays detached/cron — spec_to_ship spawns a Claude Code
# agent, and the OOM guard (sweep_assert_detached) already refused an inline run.
# spec_to_ship runs --use-current-branch so it implements on OUR branch instead
# of cutting its own feat/<slug>; after it opens the PR we annotate the body with
# the sweep:work-item marker + Refs so cross-run resume keys on it exactly like a
# PATH A PR.

# Seed file for spec_to_ship: the work-item's title + summary as a minimal spec
# with a '# H1' heading (spec_to_ship derives its commit/PR title from that H1).
sweep_path_b_seed() {
    local item="$1" title summary nums
    title="$(jq -r '.title' <<<"$item")"
    summary="$(jq -r '.summary' <<<"$item")"
    nums="$(jq -r '.issue_numbers | map("#\(.)") | join(", ")' <<<"$item")"
    cat <<EOF
# $title

## Problem

$summary

## Context

Automated issue-sweep work-item resolving GitHub issues ${nums} in ${REPO_SLUG}.
Implement the smallest correct fix that resolves them. Follow the project's
.claude/principles.md if present.
EOF
}

# Invoke spec_to_ship.sh on the item's branch inside its worktree. Implementer
# is claude (consistent with PATH A's agentic Claude Code coder); the sweep's
# fixer agent (-i, default codex) drives spec_to_ship's reviewer + auditor seats.
# stderr -> run.log; spec_to_ship's only stdout is the final PR URL, which this
# prints. Returns spec_to_ship's exit code (non-zero -> the caller parks).
sweep_path_b_spec_to_ship() {
    local project="$1" slug="$2" seed="$3"
    local sts="$SCRIPT_DIR/spec_to_ship.sh"
    if [ ! -x "$sts" ]; then
        sweep_log "PATH B: spec_to_ship.sh not executable: $sts"; return 1
    fi
    if ! sweep_agent_isolation_ok; then
        sweep_log "PATH B: refusing to run spec_to_ship.sh without externally asserted credential isolation (SWEEP_ALLOW_UNSANDBOXED_AGENT!=1)"
        return 1
    fi
    # Do not wrap the whole spec_to_ship.sh process in _sweep_lockdown_apply:
    # that script owns the PATH B branch push and PR creation after its nested
    # agents run, so the PATH A in-process push-deny shim would also block the
    # runner-owned publish. PATH B is therefore allowed only when the operator
    # has asserted the same external credential isolation gate above.
    ( cd "$project" && "$sts" \
        --seed-file "$seed" --slug "$slug" \
        --use-current-branch --base-branch "origin/$SWEEP_PR_BASE" \
        -i claude -r "${FIXER_AGENT:-codex}" -a "${FIXER_AGENT:-codex}" \
        2>>"${LOGFILE:-/dev/null}" )
}

# Append the sweep:work-item marker + Refs lines to the spec_to_ship PR body so
# resume discovery (sweep_pr_for_issue) keys on it like a PATH A PR. Idempotent:
# a body already carrying the marker (same-run retry) is left untouched.
# Best-effort — an annotate failure is logged by the caller, not fatal.
sweep_path_b_annotate_pr() {
    local pr="$1" wid="$2"; shift 2
    local body
    body="$(gh pr view "$pr" --repo "$REPO_SLUG" --json body --jq '.body' 2>/dev/null)" || body=""
    if printf '%s' "$body" | grep -qF "sweep:work-item:$wid"; then
        return 0
    fi
    body="$(printf '%s\n\n%ssweep:work-item:%s\n' \
        "$body" "$(_sweep_refs_block "$@")" "$wid")"
    gh pr edit "$pr" --repo "$REPO_SLUG" --body "$body" >/dev/null 2>&1 || return 1
}

# Full PATH B. Prints the PR number; returns 0 PR open, 2 park (spec_to_ship
# failed / no parseable PR), 1 git error (also parked by the caller). The branch
# is created off origin/$SWEEP_PR_BASE here (PATH A's reset+branch contract) so the
# worktree starts clean; spec_to_ship then implements + audits + pushes + opens
# the PR on it.
sweep_path_b() {
    local project="$1" branch="$2" item="$3" workdir="$4"
    local wid slug seed url pr_num
    wid="$(jq -r '.work_item_id' <<<"$item")"
    slug="$(jq -r '.branch_slug' <<<"$item")"
    local -a nums
    mapfile -t nums < <(jq -r '.issue_numbers[]' <<<"$item")

    if ! sweep_path_a_branch "$project" "$branch"; then
        sweep_log "PATH B: could not create $branch off origin/$SWEEP_PR_BASE"; return 1
    fi
    seed="$workdir/issue.md"
    sweep_path_b_seed "$item" > "$seed" || return 1
    if ! url="$(sweep_path_b_spec_to_ship "$project" "$slug" "$seed")"; then
        sweep_log "PATH B: spec_to_ship pipeline failed — parking"; return 2
    fi
    pr_num="$(printf '%s' "$url" | sed -nE 's#.*/pull/([0-9]+).*#\1#p' | head -n1)"
    if [ -z "$pr_num" ]; then
        sweep_log "PATH B: spec_to_ship opened no parseable PR — parking"; return 2
    fi
    sweep_path_b_annotate_pr "$pr_num" "$wid" "${nums[@]}" \
        || sweep_log "PATH B: WARN PR #$pr_num annotate failed (resume may fall back to branch-name match)"
    printf '%s' "$pr_num"
}

# ── REVIEW-FIX inner loop ──────────────────────────────────────────────────

# Resolve, classify, and (best-effort) codex-label one review round's comments.
# Prints the classified array (unknowns defaulted to non-nit). Returns 1 to park
# (reviewer reported a fatal terminal state).
sweep_collect_round() {
    local pr="$1" branch="$2" project="$3" workdir="$4" head_sha="$5" since="$6"
    local state classified
    state="$(rf_poll_review "$REPO_SLUG" "$head_sha" "$REVIEW_CHECK_NAME")"
    case "$state" in
        park)
            sweep_log "review check '$REVIEW_CHECK_NAME' terminal-failed on $head_sha"; return 1 ;;
        ready)
            classified="$(rf_fetch_round_comments "$REPO_SLUG" "$pr" "$since" "$head_sha" \
                "${SWEEP_REVIEW_BOT:-}")" || return 1 ;;
        absent)
            sweep_log "no server-side reviewer — parking (local /code-review fallback disabled)"
            rf_local_review_fallback "$project" "$SWEEP_PR_BASE" \
                "$workdir/review_comments.json" || return 1 ;;
    esac
    if [ "$(rf_unknown_count "$classified")" != "0" ]; then
        classified="$(rf_codex_classify_unknowns "$project" "$classified" \
            "classify_${pr}" "$workdir")"
    fi
    classified="$(rf_default_unknowns_nonnit "$classified")"
    printf '%s' "$classified" > "$workdir/review_comments.json"
    printf '%s' "$classified"
}

# Apply codex fixes for all non-nit findings (retry up to MAX_FIX_ATTEMPTS),
# post rebuttals, single push. Returns 1 to park (fix exhausted / push failed).
sweep_apply_fixes() {
    local pr="$1" branch="$2" project="$3" workdir="$4" classified="$5"
    local attempt=0 ok=false
    while [ "$attempt" -lt "$MAX_FIX_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        if rf_codex_batch_fix "$project" "$classified" "fix_${pr}" "$workdir"; then
            ok=true; break
        fi
        sweep_log "codex batch-fix attempt $attempt/$MAX_FIX_ATTEMPTS failed"
    done
    [ "$ok" = true ] || { sweep_log "codex batch-fix exhausted — parking"; return 1; }
    rf_post_rebuttals "$pr" "$workdir/rebuttals.txt" || sweep_log "WARN: rebuttal post failed"
    rf_push_round "$project" "$branch" "sweep: address review round" || {
        sweep_log "push failed during review-fix"; return 1; }
}

# Converge the server-side review to only-nits/approve. Returns 0 converged,
# 1 park. Bounded by MAX_REVIEW_ROUNDS (and MAX_FIX_ATTEMPTS inside the fix).
sweep_review_fix_loop() {
    local pr="$1" branch="$2" project="$3" workdir="$4"
    local round=0 head_sha since classified
    while [ "$round" -lt "$MAX_REVIEW_ROUNDS" ]; do
        round=$((round + 1))
        head_sha="$(git -C "$project" rev-parse HEAD)" || return 1
        since="$(sweep_now)"
        sweep_log "review-fix round $round/$MAX_REVIEW_ROUNDS (sha=${head_sha:0:8})"
        classified="$(sweep_collect_round "$pr" "$branch" "$project" "$workdir" \
            "$head_sha" "$since")" || return 1
        if ! rf_has_non_nit "$classified"; then
            sweep_log "review-fix converged (only nits / approve)"; return 0
        fi
        sweep_apply_fixes "$pr" "$branch" "$project" "$workdir" "$classified" || return 1
    done
    sweep_log "review-fix hit MAX_REVIEW_ROUNDS with non-nit findings — parking"
    return 1
}

# ── AUDIT + audit-fix ──────────────────────────────────────────────────────

# Run audit_pr_review.sh (independent reviewer gate) and print its verdict
# (approve | request-changes). resume=true adds -R so re-audits only score the
# deltas. Prints "error" when the audit did not produce a FRESH recommendation.
#
# Audit BLOCKER (stale-approval reuse): audit_pr_review.sh only writes
# recommendation.md / final_report.md at its final phase, so a run that fails
# earlier leaves a PRIOR run's `approve` in the reused workspace — which would
# mark an unaudited PR shippable. Two defenses: (1) delete the prior verdict +
# report BEFORE each run so no stale file can survive, and (2) require a clean
# exit AND a freshly-written recommendation.md — a non-zero exit is "error", not
# a silent re-read. The resume state (.state) is preserved so -R still works.
sweep_run_audit() {
    local project="$1" pr="$2" workdir="$3" resume="$4"
    local audit_ws="$workdir/audit" verdict audit_script
    mkdir -p "$audit_ws"
    rm -f "$audit_ws/recommendation.md" "$audit_ws/final_report.md"
    audit_script="${SWEEP_AUDIT_PR_REVIEW:-$SCRIPT_DIR/audit_pr_review.sh}"
    local -a args=("$audit_script" -p "$pr" -d "$project" -w "$audit_ws" --no-post)
    [ "$resume" = true ] && args+=(-R)
    if ! "${args[@]}" >>"${LOGFILE:-/dev/null}" 2>&1; then
        sweep_log "audit_pr_review.sh exited non-zero — no fresh recommendation, treating as error"
        printf 'error'; return 0
    fi
    if [ ! -f "$audit_ws/recommendation.md" ]; then
        sweep_log "audit_pr_review.sh produced no recommendation.md — treating as error"
        printf 'error'; return 0
    fi
    verdict="$(tr -d '[:space:]' < "$audit_ws/recommendation.md")"
    case "$verdict" in
        approve|request-changes) printf '%s' "$verdict" ;;
        *) printf 'error' ;;
    esac
}

# codex addresses the audit's request-changes findings (from final_report.md),
# retry up to MAX_FIX_ATTEMPTS, single push. Returns 1 to park.
sweep_audit_fix() {
    local project="$1" pr="$2" branch="$3" workdir="$4"
    local report="$workdir/audit/final_report.md" prompt out attempt=0 ok=false
    [ -f "$report" ] || { sweep_log "audit report missing — parking"; return 1; }
    out="$workdir/.audit_fix_out.txt"
    prompt="The production-safety audit below requested changes before this PR can
merge. Address every blocking finding by editing the repository in place. Make
the smallest correct change. Do NOT commit, push, or open PRs — the runner
handles git.

Audit report:
$(cat "$report")"
    while [ "$attempt" -lt "$MAX_FIX_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        # Push sandbox (audit BLOCKER): the fixer edits in place; the runner pushes.
        if AGENT_PROJECT_ROOT="$project" sweep_run_agent_no_push "${FIXER_AGENT:-codex}" \
                "auditfix_${pr}" "$prompt" "$out"; then
            ok=true; break
        fi
        sweep_log "codex audit-fix attempt $attempt/$MAX_FIX_ATTEMPTS failed"
    done
    [ "$ok" = true ] || { sweep_log "codex audit-fix exhausted — parking"; return 1; }
    rf_push_round "$project" "$branch" "sweep: address audit findings" || {
        sweep_log "push failed during audit-fix"; return 1; }
}

# Outer PR loop: interleave REVIEW-FIX (inner convergence) and AUDIT (outer
# gate). Each audit-fix push re-enters REVIEW-FIX before the next -R re-audit.
# Prints the final verdict; returns 0 shippable, 1 park. Bounded by
# MAX_PR_ROUNDS and MAX_AUDIT_ROUNDS.
sweep_outer_pr_loop() {
    local pr="$1" branch="$2" project="$3" workdir="$4"
    local pr_round=0 audit_round=0 verdict resume=false
    while [ "$pr_round" -lt "$MAX_PR_ROUNDS" ]; do
        pr_round=$((pr_round + 1))
        sweep_log "outer PR round $pr_round/$MAX_PR_ROUNDS"
        if ! sweep_review_fix_loop "$pr" "$branch" "$project" "$workdir"; then
            printf 'review-fix-parked'; return 1
        fi
        if [ "$audit_round" -ge "$MAX_AUDIT_ROUNDS" ]; then
            sweep_log "hit MAX_AUDIT_ROUNDS — parking"; printf 'audit-cap'; return 1
        fi
        audit_round=$((audit_round + 1))
        verdict="$(sweep_run_audit "$project" "$pr" "$workdir" "$resume")"
        resume=true
        sweep_log "audit verdict (round $audit_round): $verdict"
        case "$verdict" in
            approve) printf 'approve'; return 0 ;;
            request-changes)
                if ! sweep_audit_fix "$project" "$pr" "$branch" "$workdir"; then
                    printf 'audit-fix-parked'; return 1
                fi ;;
            *) sweep_log "audit produced no usable verdict — parking"; printf 'audit-error'; return 1 ;;
        esac
    done
    sweep_log "hit MAX_PR_ROUNDS — parking"; printf 'pr-cap'; return 1
}

# ── Resume discovered in-progress PRs ──────────────────────────────────────

sweep_resume_branch_is_safe() {
    local branch="$1"
    [[ "$branch" == feat/sweep/* ]] || return 1
    [[ "$branch" != *".."* && "$branch" != *"//"* ]] || return 1
    git check-ref-format "refs/heads/$branch" >/dev/null 2>&1
}

sweep_resume_pr_head_branch() {
    local pr="$1"
    gh pr view "$pr" --repo "$REPO_SLUG" --json headRefName --jq '.headRefName' 2>/dev/null
}

sweep_resume_slug_from_branch() {
    local branch="$1" slug
    slug="${branch##*/}"
    _sweep_is_safe_slug "$slug" || return 1
    printf '%s' "$slug"
}

sweep_resume_acquire_claim() {
    local project="$1" slug="$2" wid="$3"; shift 3
    local first="${1:-}" claim_rc
    sweep_remote_claim_acquire "$project" "$slug" "$wid" "$@"; claim_rc=$?
    if [ "$claim_rc" = "0" ]; then
        return 0
    fi
    if [ -n "$first" ]; then
        sweep_clear_stale_claim_for_issue "$first" "$project"
    fi
    if sweep_remote_claim_acquire "$project" "$slug" "$wid" "$@"; then
        sweep_log "[$wid] reaped an orphan claim ref and re-acquired"
        return 0
    fi
    sweep_log "[$wid] lost resume claim for $slug (rc=$claim_rc) — another live run owns this resume target; skipping"
    return 1
}

sweep_resume_worktree_add() {
    local project="$1" tree="$2" branch="$3"
    git -C "$project" fetch --quiet origin \
        "refs/heads/${branch}:refs/remotes/origin/${branch}" || return 1
    sweep_worktree_remove "$project" "$tree"
    mkdir -p "$(dirname "$tree")" || return 1
    git -C "$project" worktree add --detach --quiet "$tree" "origin/$branch" || return 1
}

sweep_resume_branch_work_item_id() {
    local project="$1" branch="$2" fallback="$3"
    local body wid
    git -C "$project" fetch --quiet origin \
        "refs/heads/${branch}:refs/remotes/origin/${branch}" 2>/dev/null || true
    body="$(git -C "$project" log --grep="sweep:work-item:" \
        "origin/$branch" --format='%B' 2>/dev/null)" || body=""
    wid="$(printf '%s\n' "$body" | sed -nE 's/.*sweep:work-item:([A-Za-z0-9._-]+).*/\1/p' | head -n1)"
    if _sweep_is_safe_slug "$wid"; then
        printf '%s' "$wid"
        return 0
    fi
    printf 'resume-%s' "$fallback"
}

sweep_resume_branch_pr_body() {
    local wid="$1" branch="$2"; shift 2
    printf 'Resuming issue-sweep branch %s.\n\n' "$branch"
    _sweep_refs_block "$@"
    printf '\nsweep:work-item:%s\n' "$wid"
}

sweep_resume_open_pr() {
    local branch="$1" wid="$2"; shift 2
    local existing title body url pr_num nums
    existing="$(gh pr list --repo "$REPO_SLUG" --head "$branch" --base "$SWEEP_PR_BASE" \
        --state open --json number --jq '.[0].number' 2>/dev/null)" || existing=""
    if [ -n "$existing" ]; then
        printf '%s' "$existing"
        return 0
    fi
    nums="$(printf '#%s ' "$@")"
    title="sweep: resume ${nums% }"
    body="$(sweep_resume_branch_pr_body "$wid" "$branch" "$@")" || return 1
    url="$(gh pr create --repo "$REPO_SLUG" --base "$SWEEP_PR_BASE" --head "$branch" \
        --title "$title" --body "$body" 2>/dev/null)" || return 1
    pr_num="$(printf '%s' "$url" | sed -nE 's#.*/pull/([0-9]+).*#\1#p' | head -n1)"
    [ -n "$pr_num" ] || return 1
    printf '%s' "$pr_num"
}

sweep_resume_workdir() {
    local wid="$1"
    local base_canon work_canon
    base_canon="$(realpath -m "$SWEEP_RUN_WORKDIR" 2>/dev/null)" || base_canon=""
    work_canon="$(realpath -m "$SWEEP_RUN_WORKDIR/$wid" 2>/dev/null)" || work_canon=""
    [ -n "$base_canon" ] && [ "$work_canon" = "$base_canon/$wid" ] || return 1
    printf '%s' "$work_canon"
}

# Re-drive an already-open per-item PR discovered from bot:in-progress ledger
# state. This assumes the caller holds the resume claim. The normal review-fix +
# audit gate runs in a throwaway detached worktree, then approved heads are added
# to SWEEP_SHIPPABLE so the existing aggregator performs the durable publish.
sweep_drive_resume_pr_locked() {
    local pr="$1" branch="$2"; shift 2
    local -a nums=("$@")
    local wid="resume-pr-$pr" workdir tree head_sha issue_json
    if ! [[ "$pr" =~ ^[1-9][0-9]*$ ]] || [ "${#nums[@]}" -eq 0 ]; then
        sweep_log "resume: invalid PR target '$pr' or empty issue set — skipping"
        return 0
    fi
    if ! sweep_resume_branch_is_safe "$branch"; then
        sweep_log "resume: PR #$pr head '$branch' is not a safe feat/sweep/* branch — parking"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|#$pr|-|parked (unsafe resume branch)")
        return 0
    fi
    workdir="$(sweep_resume_workdir "$wid")" || {
        sweep_log "[$wid] resume workdir resolves outside run base — parking"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|#$pr|-|parked (resume workdir escape)")
        return 0
    }
    tree="$workdir/tree"
    mkdir -p "$workdir"
    sweep_log "==> [$wid] resuming PR #$pr for issues ${nums[*]} on $branch"
    if ! sweep_resume_worktree_add "$PROJECT_ROOT" "$tree" "$branch"; then
        sweep_log "[$wid] could not create resume worktree for $branch — parking"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|#$pr|-|parked (resume worktree)")
        return 0
    fi
    if sweep_outer_pr_loop "$pr" "HEAD:$branch" "$tree" "$workdir" >/dev/null; then
        head_sha="$(git -C "$tree" rev-parse --verify HEAD 2>/dev/null)" || head_sha=""
        git -C "$PROJECT_ROOT" fetch --quiet origin \
            "refs/heads/${branch}:refs/remotes/origin/${branch}" 2>>"${LOGFILE:-/dev/null}" \
            || head_sha=""
        if [ -z "$head_sha" ]; then
            sweep_log "[$wid] could not pin approved resume head — parking"
            _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
            SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|#$pr|approve|parked (resume head)")
        else
            issue_json="$(printf '%s\n' "${nums[@]}" | jq -Rsc 'split("\n")[:-1] | map(tonumber)')"
            SWEEP_SHIPPABLE+=("$(jq -cn --arg w "$wid" --arg b "$branch" --arg s "$head_sha" \
                --argjson p "$pr" --argjson n "$issue_json" \
                '{wid:$w, branch:$b, head_sha:$s, pr:$p, verdict:"approve", issue_numbers:$n}')")
            SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|#$pr|approve|shippable")
            sweep_log "[$wid] PR #$pr SHIPPABLE after resume (head ${head_sha:0:8})"
        fi
    else
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|#$pr|request-changes|parked (needs-human)")
        sweep_log "[$wid] PR #$pr PARKED after resume"
    fi
    sweep_worktree_remove "$PROJECT_ROOT" "$tree"
    return 0
}

sweep_drive_resume_pr() {
    local pr="$1"; shift
    local -a nums=("$@")
    local wid="resume-pr-$pr" branch slug
    if ! [[ "$pr" =~ ^[1-9][0-9]*$ ]] || [ "${#nums[@]}" -eq 0 ]; then
        sweep_log "resume: invalid PR target '$pr' or empty issue set — skipping"
        return 0
    fi
    branch="$(sweep_resume_pr_head_branch "$pr")" || branch=""
    if ! sweep_resume_branch_is_safe "$branch"; then
        sweep_log "resume: PR #$pr head '$branch' is not a safe feat/sweep/* branch — parking"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|#$pr|-|parked (unsafe resume branch)")
        return 0
    fi
    slug="$(sweep_resume_slug_from_branch "$branch")" || {
        sweep_log "[$wid] resume branch '$branch' has no safe claim slug — parking"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|#$pr|-|parked (unsafe resume slug)")
        return 0
    }
    if ! sweep_resume_acquire_claim "$PROJECT_ROOT" "$slug" "$wid" "${nums[@]}"; then
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|#$pr|-|skipped (claimed concurrently)")
        return 0
    fi
    sweep_drive_resume_pr_locked "$pr" "$branch" "${nums[@]}"
    sweep_remote_claim_release "$PROJECT_ROOT" "$slug"
    return 0
}

sweep_drive_resume_branch() {
    local branch="$1"; shift
    local -a nums=("$@")
    local slug wid pr
    if ! sweep_resume_branch_is_safe "$branch"; then
        sweep_log "resume: branch target '$branch' is not a safe feat/sweep/* branch — parking"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("resume-branch|${nums[*]}|resume|-|-|parked (unsafe resume branch)")
        return 0
    fi
    slug="$(sweep_resume_slug_from_branch "$branch")" || {
        sweep_log "resume: branch target '$branch' has no safe claim slug — parking"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("resume-branch|${nums[*]}|resume|-|-|parked (unsafe resume slug)")
        return 0
    }
    wid="$(sweep_resume_branch_work_item_id "$PROJECT_ROOT" "$branch" "$slug")"
    if ! sweep_resume_acquire_claim "$PROJECT_ROOT" "$slug" "$wid" "${nums[@]}"; then
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|-|-|skipped (claimed concurrently)")
        return 0
    fi
    if ! pr="$(sweep_resume_open_pr "$branch" "$wid" "${nums[@]}")"; then
        sweep_log "[$wid] could not open resume PR for $branch — parking"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|resume|-|-|parked (resume PR create)")
        sweep_remote_claim_release "$PROJECT_ROOT" "$slug"
        return 0
    fi
    sweep_drive_resume_pr_locked "$pr" "$branch" "${nums[@]}"
    sweep_remote_claim_release "$PROJECT_ROOT" "$slug"
    return 0
}

# ── Per-work-item driver + pipeline pass ───────────────────────────────────

# Relabel every member issue (queued -> in-progress at start, or -> needs-human
# on park). Best-effort: a label failure is logged, not fatal.
_sweep_relabel_members() {
    local remove="$1" add="$2"; shift 2
    local n
    for n in "$@"; do
        sweep_relabel "$n" "$remove" "$add" || sweep_log "WARN: relabel #$n failed"
    done
}

# Drive ONE queued work-item (path-a or path-b) end to end inside its OWN git
# worktree. Every item builds via the default two-turn reason+implement pair;
# --spec-to-ship (SPEC_TO_SHIP=true) opts path-b (very-complex) items into
# spec_to_ship.sh instead. The worktree, outer PR loop, and aggregator
# handoff are route-agnostic below.
# Appends a summary row; on audit approve also appends a SWEEP_SHIPPABLE record
# for the aggregator. Always returns 0 — park is a normal outcome and must not
# abort the sweep. The worktree is torn down on every exit path (ship or park);
# the feat/sweep branch ref survives for the aggregator to merge.
sweep_drive_work_item() {
    local item="$1"
    local wid title route workdir branch pr verdict tree summary_route
    wid="$(jq -r '.work_item_id' <<<"$item")"
    title="$(jq -r '.title' <<<"$item")"
    # Routing keys on complexity (decided in Phase 1's sweep_decorate_queue):
    # path-a = simple/medium; path-b = very-complex. Default path-a if absent.
    # The IMPLEMENTER is decided here, once, in $pathlbl — both the dispatch
    # below and the summary/log labels key on it so they can never drift:
    # spec_to_ship ONLY when the operator opted in (--spec-to-ship) AND triage
    # said very-complex; everything else — including path-b with the flag off —
    # builds via the default reason+implement pair, and its rows must say so.
    route="$(jq -r '.route // "path-a"' <<<"$item")"
    [ "$route" = "path-b" ] || route="path-a"
    local pathlbl="reason-implement"
    if [ "$route" = "path-b" ] && [ "${SPEC_TO_SHIP:-false}" = true ]; then
        pathlbl="spec-to-ship"
    fi
    summary_route="$(sweep_summary_route_label "$route" "$pathlbl")"
    local -a nums
    mapfile -t nums < <(jq -r '.issue_numbers[]' <<<"$item")
    local slug; slug="$(jq -r '.branch_slug' <<<"$item")"
    # Audit BLOCKER (defense in depth): refuse to build a $workdir path or a git
    # ref from an unsafe work_item_id/branch_slug. Members are still bot:queued
    # here, so park them needs-human WITHOUT spawning an agent or touching the FS.
    if ! _sweep_is_safe_slug "$wid" || ! _sweep_is_safe_slug "$slug"; then
        sweep_log "[$wid] unsafe work_item_id/branch_slug — refusing to drive (defense in depth)"
        _sweep_relabel_members "$SWEEP_LABEL_QUEUED" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|$summary_route|-|-|parked (unsafe slug)")
        return 0
    fi
    # Canonicalize $workdir UNDER $SWEEP_RUN_WORKDIR before any mkdir / worktree use
    # (reviewer / audit BLOCKER). The slug regex stops a traversing $wid, but a
    # pre-existing symlink or stale path AT $SWEEP_RUN_WORKDIR/$wid could still make
    # tree="$workdir/tree" resolve OUTSIDE the run base. realpath -m resolves any
    # symlinks along the path (without requiring the leaf to exist yet); since $wid
    # is a strict slug (no "/"), the only legitimate resolution is "$base_canon/$wid"
    # — anything else means a symlink/escape, so refuse and park.
    local base_canon work_canon
    base_canon="$(realpath -m "$SWEEP_RUN_WORKDIR" 2>/dev/null)" || base_canon=""
    work_canon="$(realpath -m "$SWEEP_RUN_WORKDIR/$wid" 2>/dev/null)" || work_canon=""
    if [ -z "$base_canon" ] || [ "$work_canon" != "$base_canon/$wid" ]; then
        sweep_log "[$wid] workdir resolves outside run base ($work_canon) — refusing to drive (defense in depth)"
        _sweep_relabel_members "$SWEEP_LABEL_QUEUED" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|$summary_route|-|-|parked (workdir escape)")
        return 0
    fi
    workdir="$work_canon"
    # Label pre-check (cheap TOCTOU read): skip an item another run already
    # claimed/shipped before doing any work. The AUTHORITATIVE arbiter is the
    # atomic remote claim below — this only avoids needless churn on the common
    # case (audit BLOCKER: overlapping sweeps).
    if ! sweep_claim_members "${nums[@]}"; then
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|$summary_route|-|-|skipped (claimed concurrently)")
        return 0
    fi
    branch="$(sweep_branch_name "$slug")"
    sweep_log "==> [$wid] driving '${title}' (issues ${nums[*]}) via $pathlbl (route=$route) on $branch (isolated worktree)"

    # Mark in-progress FIRST so a crash mid-drive leaves a RESUMABLE bot:in-progress
    # item (resume discovery + --resume-stale recover it), THEN take the ATOMIC
    # remote claim — the cross-host compare-and-set the local flock cannot provide.
    # A lost/failed claim means another LIVE run owns this work-item; back off
    # WITHOUT relabeling (the owner keeps it in-progress and drives it). This is
    # the real fix for "two runs both pass claim, both relabel, both drive".
    _sweep_relabel_members "$SWEEP_LABEL_QUEUED" "$SWEEP_LABEL_IN_PROGRESS" "${nums[@]}"
    sweep_remote_claim_acquire "$PROJECT_ROOT" "$slug" "$wid" "${nums[@]}"; local claim_rc=$?
    if [ "$claim_rc" != "0" ]; then
        # The held ref may be an AGED ORPHAN from a crashed run (resume discovery
        # cannot see claim refs). TTL-gated reap deletes only an aged claim — a
        # fresh one (a live concurrent drive) is preserved — then retry once so an
        # orphan self-heals immediately instead of looping (reviewer 02:06:39).
        sweep_clear_stale_claim_for_issue "${nums[0]}" "$PROJECT_ROOT"
        if ! sweep_remote_claim_acquire "$PROJECT_ROOT" "$slug" "$wid" "${nums[@]}"; then
            sweep_log "[$wid] lost atomic remote claim (rc=$claim_rc) — another live run owns this work-item; skipping"
            SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|$summary_route|-|-|skipped (claimed concurrently)")
            return 0
        fi
        sweep_log "[$wid] reaped an orphan claim ref and re-acquired"
    fi

    mkdir -p "$workdir"
    # Isolated per-item worktree under $workdir (see "Worktree isolation" above).
    tree="$workdir/tree"

    if ! sweep_worktree_add "$PROJECT_ROOT" "$tree"; then
        sweep_log "[$wid] could not create isolated worktree off origin/$SWEEP_PR_BASE — parking"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        sweep_worktree_remove "$PROJECT_ROOT" "$tree"
        sweep_remote_claim_release "$PROJECT_ROOT" "$slug"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|$summary_route|-|-|parked (worktree)")
        return 0
    fi

    local pa_rc=0
    if [ "$pathlbl" = "spec-to-ship" ]; then
        pr="$(sweep_path_b "$tree" "$branch" "$item" "$workdir")" || pa_rc=$?
    else
        pr="$(sweep_path_a "$tree" "$branch" "$item" "$workdir")" || pa_rc=$?
    fi
    if [ "$pa_rc" != "0" ] || [ -z "$pr" ]; then
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        # Tear down the worktree so the failed/blocked agent's uncommitted edits
        # never bleed into another item (the main tree was never touched).
        sweep_worktree_remove "$PROJECT_ROOT" "$tree"
        sweep_remote_claim_release "$PROJECT_ROOT" "$slug"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|$summary_route|-|-|parked ($pathlbl)")
        return 0
    fi
    sweep_log "[$wid] PR #$pr open"

    if sweep_outer_pr_loop "$pr" "$branch" "$tree" "$workdir" >/dev/null; then
        verdict="approve"
        # Record the shippable branch for the bot-merge aggregator. The members
        # keep bot:in-progress here; the aggregator flips them to bot:shipped
        # once the branch is merged onto the bot branch (or to bot:needs-human on
        # a merge conflict). --no-aggregate leaves them bot:in-progress.
        #
        # Audit BLOCKER: also pin the EXACT audited head SHA (the branch tip the
        # outer PR loop just got `approve` on). The aggregator merges that SHA and
        # refuses to merge if the branch ref has since moved off it — so a later
        # item (or any reset) can never substitute unaudited code under an audited
        # branch name. Resolve the ref from the shared store (PROJECT_ROOT) so it
        # is valid after the worktree is torn down below.
        local head_sha
        head_sha="$(git -C "$PROJECT_ROOT" rev-parse --verify "$branch" 2>/dev/null)" || head_sha=""
        SWEEP_SHIPPABLE+=("$(jq -cn --arg w "$wid" --arg b "$branch" --arg s "$head_sha" \
            --argjson p "$pr" --argjson n "$(jq -c '.issue_numbers' <<<"$item")" \
            '{wid:$w, branch:$b, head_sha:$s, pr:$p, verdict:"approve", issue_numbers:$n}')")
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|$summary_route|#$pr|approve|shippable")
        sweep_log "[$wid] PR #$pr SHIPPABLE (audit approve, head ${head_sha:0:8})"
    else
        verdict="parked"
        _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        SWEEP_SUMMARY_ROWS+=("$wid|${nums[*]}|$summary_route|#$pr|request-changes|parked (needs-human)")
        sweep_log "[$wid] PR #$pr PARKED (needs-human)"
    fi
    # Worktree teardown on completion (worktree-isolation cleanup). The branch
    # ref persists locally + on origin for the aggregator. Release the atomic
    # remote claim now that the drive is done — the bot:in-progress label + the
    # feat/sweep branch already guard against a re-drive of this (no-longer-queued)
    # item, so the transient claim ref is no longer needed.
    sweep_worktree_remove "$PROJECT_ROOT" "$tree"
    sweep_remote_claim_release "$PROJECT_ROOT" "$slug"
    return 0
}

# Print the manual-collect summary table (per-item PR + audit result).
sweep_print_summary() {
    echo ""
    echo "===== issue-sweep summary ($(date +%Y-%m-%d)) ====="
    if [ "${#SWEEP_SUMMARY_ROWS[@]}" -eq 0 ]; then
        echo "(no work-items driven this run)"
    else
        printf '%-16s | %-12s | %-24s | %-6s | %-15s | %s\n' \
            "work-item" "issues" "route/impl" "pr" "audit" "disposition"
        echo "-----------------+--------------+--------------------------+--------+-----------------+-------------------"
        local row
        for row in "${SWEEP_SUMMARY_ROWS[@]}"; do
            IFS='|' read -r c_wid c_iss c_route c_pr c_audit c_disp <<<"$row"
            printf '%-16s | %-12s | %-24s | %-6s | %-15s | %s\n' \
                "$c_wid" "$c_iss" "$c_route" "$c_pr" "$c_audit" "$c_disp"
        done
    fi
    echo "==================================================="
}

# Drive every eligible queued work-item (valid, route=path-a OR path-b,
# size-selected). Items build via the two-turn reason+implement pair by
# default; --spec-to-ship routes path-b
# (very-complex) items through spec_to_ship.sh instead — both feed the same outer
# PR loop + aggregator. needs-human / invalid items were already dispositioned by
# the caller's ledger pass. The --sizes filter is applied here per item,
# independent of route (routing keys on complexity, not size).
sweep_pipeline() {
    local drive_items="$1"
    local item size
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        size="$(jq -r '.size' <<<"$item")"
        if ! size_selected "$size"; then
            continue
        fi
        sweep_drive_work_item "$item" || true
    done < <(printf '%s' "$drive_items" | jq -c '.[]')

    # Phase 3 bot-merge aggregation. --no-aggregate (AGGREGATE=false) leaves the
    # shippable branches as bot:in-progress per-item PRs for a manual collect
    # (the Phase 2 behaviour); the sweep NEVER pushes develop either way.
    if [ "${AGGREGATE:-true}" = true ]; then
        local ship_json="[]"
        if [ "${#SWEEP_SHIPPABLE[@]}" -gt 0 ]; then
            ship_json="$(printf '%s\n' "${SWEEP_SHIPPABLE[@]}" | jq -sc '.')"
        fi
        sweep_aggregate "$PROJECT_ROOT" "$(sweep_bot_branch_name)" "$ship_json" || true
    else
        sweep_log "aggregation skipped (--no-aggregate); ${#SWEEP_SHIPPABLE[@]} shippable item(s) left bot:in-progress"
    fi

    sweep_print_summary
}
