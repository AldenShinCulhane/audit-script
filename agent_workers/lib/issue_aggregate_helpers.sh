#!/bin/bash
# issue_aggregate_helpers.sh — the Phase 3 (V2) bot-merge aggregator for
# issue_sweep.sh.
#
# Sourced by agent_workers/issue_sweep.sh AFTER issue_triage_helpers.sh (the
# SWEEP_LABEL_* ledger) and issue_pipeline_helpers.sh (sweep_log,
# _sweep_relabel_members, SWEEP_SHIPPABLE). Once the per-item pipeline has driven
# every work-item to a shippable PR or a park, this collects the approved
# branches onto ONE dated bot branch per repo and opens/updates a single rollup
# PR to develop for a HUMAN to merge:
#
#   git checkout -B bot/auto-fix-<date> origin/develop   (or resume an existing
#                                                          remote bot branch)
#   git merge --no-ff <each approved feat/sweep branch>
#       conflict -> git merge --abort, leave un-merged, flag + bot:needs-human
#   git push origin bot/auto-fix-<date>                  (NEVER pushes develop)
#   gh pr create|edit  (rollup -> develop; body: Closes #N + per-item PR links)
#   label every merged issue bot:shipped
#
# The human bot->develop merge is the ONLY gate that touches develop (Non-goals:
# the sweep never pushes develop). One bot branch per repo (Resolved 8); a bot
# branch only ever merges branches from its own repo. Reruns skip bot:shipped
# items (handled by the Phase 1 partition). The aggregator fails SOFT per
# branch — a conflicting branch is skipped + parked, never aborts the run.

# Default bot branch: one per repo per sweep date. --bot-branch overrides via the
# BOT_BRANCH global (validated by the caller and again by the aggregator).
sweep_bot_branch_name() {
    printf '%s' "${BOT_BRANCH:-bot/auto-fix-$SWEEP_DATE}"
}

# Bot branch refs are the only branch refs this helper pushes directly. Keep
# them inside the bot/ namespace and valid as refs/heads/* so a bad CLI/env value
# can never fast-forward main/develop/release branches.
sweep_bot_branch_is_safe() {
    local ref="$1"
    [[ "$ref" == bot/* ]] || return 1
    [[ "$ref" != *".."* && "$ref" != *"//"* ]] || return 1
    [[ "$ref" =~ ^bot/[A-Za-z0-9]([A-Za-z0-9._/-]*[A-Za-z0-9])?$ ]] || return 1
    git check-ref-format "refs/heads/$ref" >/dev/null 2>&1
}

# ── Pure: rollup PR text ───────────────────────────────────────────────────

sweep_rollup_pr_title() {
    printf 'chore(sweep): rollup auto-fix %s (%s work-item(s))' "$SWEEP_DATE" "$1"
}

# Rollup PR body (pure). Carries a Closes #N keyword for EVERY merged issue (so
# merging the rollup into develop closes them all) plus a per-item line linking
# the audited per-item PR. $merged_json = array of {wid,pr,verdict,issue_numbers}.
# $3 (prior_closes, default []) = issue numbers from prior rollup metadata that
# were revalidated against the issue-label ledger before this pure builder was
# called. Do NOT pass numbers scraped from commit history; commit messages can be
# prompt-influenced.
sweep_rollup_pr_body() {
    local merged_json="$1" slug="$2" prior_closes="${3:-[]}"
    printf '%s' "$merged_json" | jq -r --arg slug "$slug" --argjson prior "$prior_closes" '
      ([ "Automated issue-sweep rollup. Each approved per-item branch was merged",
         "with --no-ff onto this bot branch. A human reviews and merges this PR",
         "into develop — the sweep itself never pushes develop.",
         "",
         "Closing keywords:" ]
       + ( ([ .[].issue_numbers[] ] + $prior) | unique | map("Closes #\(.)") )
       + [ "", "Merged work-items:" ]
       + ( map("- \(.wid): PR #\(.pr) (https://github.com/\($slug)/pull/\(.pr)) "
               + "— audit: \(.verdict) — issues "
               + (.issue_numbers | map("#\(.)") | join(", "))) )
      ) | .[]' \
        2>/dev/null || { echo "ERROR: rollup PR body build failed" >&2; return 1; }
}

# Issue numbers carried as "Closes #N" in an existing rollup PR body. These are
# candidates only: callers must revalidate them against ledger metadata before
# feeding them back into sweep_rollup_pr_body. Prints a JSON array of integers
# (unique; "[]" when none).
sweep_existing_closes() {
    local body="$1"
    # Single jq pass (no grep, so no pipefail double-emit): read the whole body as
    # one raw string and scan for the Closes #N captures.
    printf '%s' "$body" | jq -Rsc '
        [ scan("Closes #([0-9]+)"; "i") | .[0] | tonumber ] | unique
    ' 2>/dev/null || printf '[]'
}

# Keep only existing-rollup candidates whose issues already carry the shipped
# label. That label is the sweep ledger for a prior successful rollup publish; a
# manually edited PR body or prompt-influenced commit message cannot add a close
# keyword unless the issue is also in that ledger state.
sweep_filter_closes_by_shipped_label() {
    local candidates="$1"
    local kept="[]" n labels next
    while IFS= read -r n; do
        [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
        labels="$(gh issue view "$n" --repo "$REPO_SLUG" --json labels \
            --jq '[.labels[].name]' 2>/dev/null)" || continue
        if printf '%s' "$labels" | jq -e --arg shipped "$SWEEP_LABEL_SHIPPED" \
                'any(.[]?; . == $shipped)' >/dev/null 2>&1; then
            next="$(jq -c --argjson n "$n" '. + [$n]' <<<"$kept")" && kept="$next"
        fi
    done < <(printf '%s' "$candidates" | jq -r '.[]?' 2>/dev/null)
    printf '%s' "$kept" | jq -c 'unique' 2>/dev/null || printf '[]'
}

# ── IO: single-branch merge ────────────────────────────────────────────────

# Merge ONE approved branch into the already-checked-out bot branch with --no-ff,
# pinned to the EXACT audited head SHA when one was recorded.
# Returns 0 merged (or already up to date), 2 the branch ref no longer points at
# the audited head (refuse — never merge unaudited code), 1 conflict (merge
# already aborted). No labeling here — the caller owns the ledger so this stays
# pure-git + testable.
#
# Audit BLOCKER (mutable-ref merge): the shippable record carries the head_sha the
# outer PR loop got `approve` on. A duplicate branch_slug or any post-audit reset
# could move the branch ref onto a different commit; merging the mutable ref would
# then ship code that was never audited. We verify the ref still equals the
# audited SHA and merge that SHA explicitly. $head_sha is optional for backward
# compatibility (older shippable records without it fall back to merging the ref).
sweep_bot_merge_one() {
    local project="$1" branch="$2" head_sha="${3:-}"
    local target="$branch"
    if [ -n "$head_sha" ]; then
        local current
        current="$(git -C "$project" rev-parse --verify "$branch" 2>/dev/null)" \
            || current="$(git -C "$project" rev-parse --verify "origin/$branch" 2>/dev/null)" \
            || return 2
        if [ "$current" != "$head_sha" ]; then
            return 2
        fi
        target="$head_sha"
    fi
    if git -C "$project" merge --no-ff --no-edit "$target" >>"${LOGFILE:-/dev/null}" 2>&1; then
        return 0
    fi
    git -C "$project" merge --abort >>"${LOGFILE:-/dev/null}" 2>&1 || true
    return 1
}

# Roll the remote bot branch back after a rollup-PR failure that followed a
# successful push. If the branch existed on origin before this run, reset it to
# its prior tip ($pre_sha) — dropping THIS run's merges while leaving any prior
# rollup PR's head intact. If it did NOT exist before (we just created it), delete
# it from origin.
#
# Audit BLOCKER: this MUST be concurrent-write safe. A blind `--force`/`--delete`
# would destroy commits another sweep or a human pushed to the bot branch after
# this run's push. We therefore lease against $pushed_sha — the exact tip THIS run
# pushed — so the rollback only fires while the remote is still at our tip;
# anyone else's update fails the lease and is left intact. Without a known pushed
# tip we cannot lease safely, so we SKIP the rollback rather than clobber blindly.
# Best-effort: a rollback failure (incl. a lost lease) is logged, not fatal.
sweep_bot_branch_rollback() {
    local project="$1" bot_branch="$2" pre_sha="$3" existed="$4" pushed_sha="${5:-}"
    if [ -z "$pushed_sha" ]; then
        sweep_log "aggregator: WARN no pushed SHA for $bot_branch — skipping rollback (cannot lease safely)"
        return 0
    fi
    local lease="refs/heads/${bot_branch}:${pushed_sha}"
    if [ "$existed" = true ] && [ -n "$pre_sha" ]; then
        git -C "$project" push --quiet --force-with-lease="$lease" \
            origin "${pre_sha}:refs/heads/${bot_branch}" 2>>"${LOGFILE:-/dev/null}" \
            || sweep_log "aggregator: WARN bot branch rollback (lease force to $pre_sha) failed/contended for $bot_branch"
    else
        git -C "$project" push --quiet --force-with-lease="$lease" \
            origin ":refs/heads/${bot_branch}" 2>>"${LOGFILE:-/dev/null}" \
            || sweep_log "aggregator: WARN bot branch rollback (lease delete) failed/contended for $bot_branch"
    fi
}

# ── IO: rollup PR open-or-update ────────────────────────────────────────────

# Open a new rollup PR or update the existing one (idempotent across same-date
# reruns). Prints the PR number; returns non-zero on a gh failure.
sweep_rollup_open_or_update() {
    local bot_branch="$1" title="$2" body="$3" existing url pr_num
    existing="$(gh pr list --repo "$REPO_SLUG" --head "$bot_branch" --base "$SWEEP_PR_BASE" \
        --state open --json number --jq '.[0].number' 2>/dev/null)" || existing=""
    if [ -n "$existing" ]; then
        gh pr edit "$existing" --repo "$REPO_SLUG" --title "$title" --body "$body" \
            >/dev/null 2>&1 || return 1
        printf '%s' "$existing"
        return 0
    fi
    url="$(gh pr create --repo "$REPO_SLUG" --base "$SWEEP_PR_BASE" --head "$bot_branch" \
        --title "$title" --body "$body" 2>/dev/null)" || return 1
    pr_num="$(printf '%s' "$url" | sed -nE 's#.*/pull/([0-9]+).*#\1#p' | head -n1)"
    [ -n "$pr_num" ] || return 1
    printf '%s' "$pr_num"
}

# ── Aggregation driver ─────────────────────────────────────────────────────

# Aggregate every shippable branch onto the bot branch and open/update the rollup
# PR. $shippable_json = JSON array of {wid,branch,pr,verdict,issue_numbers}.
# Labels merged issues bot:shipped, conflicting issues bot:needs-human. Prints
# the aggregation summary table. Always returns 0 — a conflict is a normal,
# per-branch outcome and must not abort the run.
sweep_aggregate() {
    local project="$1" bot_branch="$2" shippable_json="$3"
    local count
    count="$(printf '%s' "$shippable_json" | jq 'length' 2>/dev/null)" || count=0
    if [ "$count" = "0" ]; then
        sweep_log "aggregator: no shippable work-items — nothing to merge"
        return 0
    fi
    if ! sweep_bot_branch_is_safe "$bot_branch"; then
        sweep_log "aggregator: unsafe bot branch '$bot_branch' — must be a valid refs/heads/bot/* ref; skipping aggregation"
        local item
        while IFS= read -r item; do
            [ -z "$item" ] && continue
            local -a nums
            mapfile -t nums < <(jq -r '.issue_numbers[]' <<<"$item")
            _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
        done < <(printf '%s' "$shippable_json" | jq -c '.[]')
        return 0
    fi
    local start_ref
    start_ref="$(git -C "$project" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
        || start_ref="$(git -C "$project" rev-parse --verify HEAD 2>/dev/null)" \
        || start_ref=""
    sweep_log "aggregator: building $bot_branch off origin/$SWEEP_PR_BASE for $count shippable item(s)"
    git -C "$project" fetch --quiet origin "$SWEEP_PR_BASE" 2>/dev/null || {
        sweep_log "aggregator: could not fetch origin/$SWEEP_PR_BASE — skipping aggregation"; return 0; }
    # Resume an existing remote bot branch (preserve prior same-date merges) so
    # the push stays fast-forwardable; else branch fresh off the base.
    local base_ref="origin/$SWEEP_PR_BASE" bot_existed_remote=false
    if git -C "$project" fetch --quiet origin "$bot_branch" 2>/dev/null; then
        base_ref="origin/$bot_branch"; bot_existed_remote=true
    fi
    git -C "$project" checkout -B "$bot_branch" "$base_ref" --quiet 2>>"${LOGFILE:-/dev/null}" || {
        sweep_log "aggregator: could not create $bot_branch off $base_ref — skipping"; return 0; }
    # Remote tip BEFORE this run's merges — used to roll the bot branch back if the
    # rollup PR fails AFTER a successful push, so parked (un-rolled-up) commits
    # never ride a later same-date aggregation's resumed base.
    local pre_sha; pre_sha="$(git -C "$project" rev-parse HEAD 2>/dev/null)" || pre_sha=""

    local merged_json="[]"
    local -a conflict_rows=()
    local item wid branch pr head_sha merge_rc
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        branch="$(jq -r '.branch' <<<"$item")"
        pr="$(jq -r '.pr' <<<"$item")"
        head_sha="$(jq -r '.head_sha // ""' <<<"$item")"
        sweep_bot_merge_one "$project" "$branch" "$head_sha"; merge_rc=$?
        if [ "$merge_rc" = "0" ]; then
            # Merged LOCALLY only. The bot:shipped relabel is DEFERRED until the
            # bot branch is pushed AND the rollup PR is open (below), so a push or
            # PR failure never leaves an issue marked shipped with no durable
            # bot branch / rollup PR carrying its Closes #N.
            merged_json="$(jq -c --argjson it "$item" '. + [$it]' <<<"$merged_json")"
            sweep_log "aggregator: merged $branch (#$pr) [local — shipped label deferred]"
        else
            # A conflict (rc 1) or an unaudited-head ref (rc 2) is terminal
            # regardless of push/PR — park it immediately. rc 2 means the branch
            # ref no longer points at the SHA the audit approved, so merging it
            # would ship unaudited code (audit BLOCKER).
            wid="$(jq -r '.wid' <<<"$item")"
            local -a nums
            mapfile -t nums < <(jq -r '.issue_numbers[]' <<<"$item")
            _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
            if [ "$merge_rc" = "2" ]; then
                conflict_rows+=("$wid|${nums[*]}|$branch|#$pr|UNAUDITED-HEAD (needs-human)")
                sweep_log "aggregator: $branch moved off audited head ${head_sha:0:8} — skipped + parked bot:needs-human (refusing unaudited code)"
            else
                conflict_rows+=("$wid|${nums[*]}|$branch|#$pr|CONFLICT (needs-human)")
                sweep_log "aggregator: merge conflict on $branch — skipped + parked bot:needs-human"
            fi
        fi
    done < <(printf '%s' "$shippable_json" | jq -c '.[]')

    # Publish: push the bot branch, then open/update the rollup PR. bot:shipped is
    # applied ONLY when BOTH succeed; on any publish failure the merged issues are
    # PARKED bot:needs-human (see finalize loop) — leaving them bot:in-progress
    # would strand them (the next run's triage partition excludes in-progress
    # issues and resume discovery does not rebuild shippable JSON / re-aggregate).
    local merged_count rollup_pr="-" ship_ok=false
    merged_count="$(jq 'length' <<<"$merged_json")"
    if [ "$merged_count" -gt 0 ]; then
        if git -C "$project" push --quiet -u origin "$bot_branch" 2>>"${LOGFILE:-/dev/null}"; then
            # The exact tip we just pushed — the lease value rollback uses to stay
            # concurrent-write safe (audit BLOCKER).
            local pushed_sha; pushed_sha="$(git -C "$project" rev-parse HEAD 2>/dev/null)" || pushed_sha=""
            local title body prior_body pr_closes prior_closes
            title="$(sweep_rollup_pr_title "$merged_count")"
            # Closing-keyword preservation: only current shippable issue_numbers
            # and prior rollup-body candidates that are revalidated against the
            # bot:shipped label ledger can become Closes keywords. Never scrape
            # bot-branch commit messages; PATH B / prompt-influenced commits can
            # mention unrelated issue numbers.
            prior_body="$(gh pr list --repo "$REPO_SLUG" --head "$bot_branch" --base "$SWEEP_PR_BASE" \
                --state open --json body --jq '.[0].body' 2>/dev/null)" || prior_body=""
            pr_closes="$(sweep_existing_closes "$prior_body")"
            prior_closes="$(sweep_filter_closes_by_shipped_label "$pr_closes")"
            body="$(sweep_rollup_pr_body "$merged_json" "$REPO_SLUG" "$prior_closes")" || body=""
            if rollup_pr="$(sweep_rollup_open_or_update "$bot_branch" "$title" "$body")"; then
                ship_ok=true
            else
                rollup_pr="-"
                sweep_log "aggregator: rollup PR open/update failed — rolling back $bot_branch on origin + parking bot:needs-human"
                # The push already published this run's merges to origin/$bot_branch
                # but no rollup PR carries their Closes #N. Roll the remote branch
                # back so a later same-date resume does not ship these (now parked)
                # commits inside a rollup whose body omits them.
                sweep_bot_branch_rollback "$project" "$bot_branch" "$pre_sha" "$bot_existed_remote" "$pushed_sha"
            fi
        else
            sweep_log "aggregator: push of $bot_branch failed — merged issues parked bot:needs-human"
        fi
    else
        sweep_log "aggregator: all shippable branches conflicted — no bot branch pushed"
    fi

    # Finalize the merged-item ledger + rows now that publish has fully succeeded
    # or failed. A publish failure must NOT leave issues bot:in-progress: the next
    # run skips in-progress issues from triage and resume discovery only logs the
    # target (it does not re-aggregate), so they would be silently stranded.
    # Park them bot:needs-human instead — a visible, terminal state a human
    # retries (conservative default; spec "Triage spec" — unsure -> bot:needs-human,
    # the human bot->develop merge is the backstop).
    local -a merged_rows=()
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        wid="$(jq -r '.wid' <<<"$item")"
        branch="$(jq -r '.branch' <<<"$item")"
        pr="$(jq -r '.pr' <<<"$item")"
        local -a nums
        mapfile -t nums < <(jq -r '.issue_numbers[]' <<<"$item")
        if [ "$ship_ok" = true ]; then
            _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_SHIPPED" "${nums[@]}"
            merged_rows+=("$wid|${nums[*]}|$branch|#$pr|merged")
        else
            _sweep_relabel_members "$SWEEP_LABEL_IN_PROGRESS" "$SWEEP_LABEL_NEEDS_HUMAN" "${nums[@]}"
            merged_rows+=("$wid|${nums[*]}|$branch|#$pr|merged-local (publish failed -> needs-human)")
        fi
    done < <(printf '%s' "$merged_json" | jq -c '.[]')

    if [ -n "$start_ref" ]; then
        git -C "$project" checkout --quiet "$start_ref" 2>>"${LOGFILE:-/dev/null}" \
            || sweep_log "aggregator: WARN could not restore starting checkout '$start_ref'"
    fi

    local -a summary_rows=()
    local row
    if [ "${#merged_rows[@]}" -gt 0 ]; then
        for row in "${merged_rows[@]}"; do summary_rows+=("$row"); done
    fi
    if [ "${#conflict_rows[@]}" -gt 0 ]; then
        for row in "${conflict_rows[@]}"; do summary_rows+=("$row"); done
    fi
    if [ "${#summary_rows[@]}" -gt 0 ]; then
        sweep_print_aggregate_summary "$bot_branch" "$rollup_pr" "${summary_rows[@]}"
    else
        sweep_print_aggregate_summary "$bot_branch" "$rollup_pr"
    fi
    return 0
}

# Print the bot-merge aggregation summary table (work-item, member issues,
# branch, per-item PR, merged?). The bot branch + rollup PR head the table.
sweep_print_aggregate_summary() {
    local bot_branch="$1" rollup_pr="$2"; shift 2
    echo ""
    echo "===== bot-merge aggregation ($SWEEP_DATE) ====="
    echo "bot branch: $bot_branch    rollup PR: $rollup_pr"
    if [ "$#" -eq 0 ]; then
        echo "(no shippable branches to aggregate)"
    else
        printf '%-16s | %-12s | %-34s | %-6s | %s\n' \
            "work-item" "issues" "branch" "pr" "merged?"
        echo "-----------------+--------------+------------------------------------+--------+--------------------"
        local row
        for row in "$@"; do
            IFS='|' read -r c_wid c_iss c_branch c_pr c_state <<<"$row"
            printf '%-16s | %-12s | %-34s | %-6s | %s\n' \
                "$c_wid" "$c_iss" "$c_branch" "$c_pr" "$c_state"
        done
    fi
    echo "==============================================="
}
