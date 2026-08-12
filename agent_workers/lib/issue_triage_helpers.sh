#!/bin/bash
# issue_triage_helpers.sh — triage + label-ledger helpers for issue_sweep.sh.
#
# Sourced by agent_workers/issue_sweep.sh. Provides the Phase 1 surface:
#   * fetch open issues (gh issue list) and partition fresh vs in-progress
#   * one claude triage turn -> queue.json (cluster + classify into work-items)
#   * jq schema validation + routing gate (decorate each work-item)
#   * label ledger (bot:queued / bot:in-progress / bot:shipped / bot:needs-human)
#   * idempotent resume discovery (feat/sweep/<date>/<slug> branch or
#     sweep:work-item:<id> PR/commit marker)
#
# All functions fail fast (return non-zero) on error; the caller decides
# whether that is fatal or a per-item park. No bare fallbacks.
#
# Mutation helpers (label create/edit) are NEVER called by this lib on their
# own — the caller gates them behind the non-dry-run branch so --dry-run stays
# mutation-free.

# ── Lifecycle labels ──────────────────────────────────────────────────────
# Exported as readonly so both the caller and the helpers share one source.
readonly SWEEP_LABEL_QUEUED="bot:queued"
readonly SWEEP_LABEL_IN_PROGRESS="bot:in-progress"
readonly SWEEP_LABEL_SHIPPED="bot:shipped"
readonly SWEEP_LABEL_NEEDS_HUMAN="bot:needs-human"

# ── Issue fetch + partition ────────────────────────────────────────────────

# Fetch up to <limit> open issues as a JSON array with the triage fields.
# Fails fast if gh errors — an empty backlog returns "[]", which is distinct
# from a gh failure.
sweep_fetch_open_issues() {
    local limit="$1"
    gh issue list --state open --limit "$limit" \
        --json number,title,body,labels,assignees,milestone,updatedAt,url \
        || { echo "ERROR: 'gh issue list' failed" >&2; return 1; }
}

# Partition fetched issues into {fresh, in_progress}.
#   fresh       = carries none of bot:shipped / bot:needs-human / bot:in-progress
#                 (bot:queued is re-triaged — relabeling it is idempotent)
#   in_progress = carries bot:in-progress (handled by resume discovery)
# Shipped / needs-human are intentionally absent from both: reruns skip them.
sweep_partition_issues() {
    local issues_json="$1"
    printf '%s' "$issues_json" | jq -c '
        def has_label($n): any(.labels[].name; . == $n);
        {
          fresh: [ .[] | select(
            (has_label("bot:shipped") or has_label("bot:needs-human")
             or has_label("bot:in-progress")) | not) ],
          in_progress: [ .[] | select(has_label("bot:in-progress")) ]
        }' \
        || { echo "ERROR: failed to partition issues by label" >&2; return 1; }
}

# ── Triage turn ────────────────────────────────────────────────────────────

# Build the triage prompt. One claude turn clusters AND classifies the open
# issues into work-items matching the queue.json schema. Conservative default
# = needs-human; misclassification is the top failure mode.
sweep_triage_prompt() {
    local issues_json="$1" repo_slug="$2"
    cat <<EOF
You are the triage classifier for an automated GitHub issue sweep on the
single repository ${repo_slug}. Cluster AND classify the open issues below
into "work-items". A work-item is 1+ issues that will be fixed on ONE branch
and ONE PR.

Output ONLY a JSON array (no prose, no code fences) of work-items, each:
{
  "work_item_id": "${repo_slug##*/}-001",
  "issue_numbers": [123],
  "title": "Short imperative title",
  "summary": "Implementation-oriented problem summary.",
  "size": "S|M|L",
  "scope": "single-repo|cross-repo",
  "complexity": "simple|medium|very-complex|very-complex-needs-product-decision",
  "automatable": "yes|no",
  "target_repo": "${repo_slug}",
  "branch_slug": "issue-123-short-slug",
  "rationale": "Why clustered/routed this way."
}

Rules:
- target_repo MUST be exactly "${repo_slug}". Any issue needing edits outside
  this repo is scope="cross-repo".
- Cluster only when it clearly helps (same module/file, tightly related, or
  several small adjacent fixes). Never force-combine unrelated issues.
- Each issue number appears in AT MOST ONE work-item (no duplicates).
- When unsure about scope/complexity/automatable, pick the conservative value
  that routes to a human (scope=cross-repo or automatable=no).

Open issues (JSON):
${issues_json}
EOF
}

# Run the claude triage turn. Empty backlog short-circuits to "[]" without
# spending a turn. claude prints the JSON array to stdout; we strip any
# accidental ``` fences before returning it.
sweep_run_triage() {
    local issues_json="$1" repo_slug="$2" prompt raw
    if [[ "$(printf '%s' "$issues_json" | jq 'length')" == "0" ]]; then
        printf '[]'
        return 0
    fi
    prompt="$(sweep_triage_prompt "$issues_json" "$repo_slug")"
    raw="$(printf '%s' "$prompt" | claude -p --dangerously-skip-permissions \
            --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' 2>/dev/null)" \
        || { echo "ERROR: triage claude turn failed" >&2; return 1; }
    printf '%s' "$raw" | sed -e '/^```/d'
}

# ── Schema validation + routing gate ───────────────────────────────────────

# True if the triage output is a JSON array. A non-array is a triage failure
# the caller treats as fatal (it cannot map a malformed blob to issues).
sweep_is_json_array() {
    printf '%s' "$1" | jq -e 'type == "array"' >/dev/null 2>&1
}

# Decorate each work-item with {valid, reason, route}. The routing gate keys
# on complexity (NOT size — size is the --sizes filter axis):
#   invalid              -> reason set; route="invalid"
#   cross-repo / needs-product-decision / automatable=no -> route="needs-human"
#   very-complex single-repo code-only                   -> route="path-b"
#   simple|medium single-repo code-only                  -> route="path-a"
# A work-item whose member issue appears in another work-item is flagged
# "duplicate-membership"; a target_repo != <repo> is "target-repo-mismatch".
#
# Audit BLOCKER hardening (the triage turn is untrusted output that goes on to
# drive label/PR/rollup mutations):
#   * "unknown-issue-number" — a member issue_number not in the fetched fresh set
#     ($3, a JSON array of integers). Stops a prompt-injected/hallucinated number
#     from being labeled or referenced in Refs/Closes. Skipped when $3 is omitted
#     (null) so pure schema-only callers keep the old behaviour.
#   * "invalid:work_item_id-unsafe" / "invalid:branch_slug-unsafe" — these fields
#     later become a filesystem path ($workdir) and a git ref
#     (feat/sweep/<date>/<slug>), so they must be a strict single safe slug (no
#     "/", no "..", no leading/trailing punctuation) — guards path traversal and
#     unexpected ref pushes.
#   * "duplicate-work-item-id" / "duplicate-branch-slug" — two work-items sharing
#     a work_item_id (shippable-record key) or a branch_slug (the feat/sweep ref)
#     would let a LATER item reset an already-audited branch, so the aggregator
#     could ship wrong/unaudited code. Every item carrying a repeated id/slug is
#     flagged invalid so the whole collision parks rather than racing one branch.
sweep_decorate_queue() {
    local queue_json="$1" repo_slug="$2" fetched_json="${3:-null}"
    printf '%s' "$queue_json" | jq -c --arg repo "$repo_slug" --argjson fetched "$fetched_json" '
      def is_str: (type == "string") and (length > 0);
      # Strict slug: one safe path/ref token. Rejects "/", leading/trailing
      # punctuation, and (via the explicit ".." guard) any path-traversal or
      # invalid-git-ref sequence.
      def is_slug: is_str
                   and test("^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$")
                   and ((test("\\.\\."))|not);
      ( [ .[] | (.issue_numbers // []) | .[] ]
        | group_by(.) | map(select(length > 1) | .[0]) ) as $dupes
      | ( [ .[] | .work_item_id // empty ]
          | group_by(.) | map(select(length > 1) | .[0]) ) as $dup_ids
      | ( [ .[] | .branch_slug // empty ]
          | group_by(.) | map(select(length > 1) | .[0]) ) as $dup_slugs
      | [ .[] as $it
        | ($it.issue_numbers // []) as $nums
        | (
            if ($it.work_item_id | is_str | not) then "missing:work_item_id"
            elif ($nums | type != "array") or ($nums | length == 0) then "missing:issue_numbers"
            elif ($nums | any((type != "number") or (. != (. | floor)) or (. < 1))) then "invalid:issue_numbers-not-integers"
            elif ($it.title | is_str | not) then "missing:title"
            elif ($it.summary | is_str | not) then "missing:summary"
            elif ($it.branch_slug | is_str | not) then "missing:branch_slug"
            elif ($it.target_repo | is_str | not) then "missing:target_repo"
            elif ($it.rationale | is_str | not) then "missing:rationale"
            elif ($it.work_item_id | is_slug | not) then "invalid:work_item_id-unsafe"
            elif ($it.branch_slug | is_slug | not) then "invalid:branch_slug-unsafe"
            elif (["S","M","L"] | index($it.size) | not) then "enum-mismatch:size"
            elif (["single-repo","cross-repo"] | index($it.scope) | not) then "enum-mismatch:scope"
            elif (["simple","medium","very-complex","very-complex-needs-product-decision"] | index($it.complexity) | not) then "enum-mismatch:complexity"
            elif (["yes","no"] | index($it.automatable) | not) then "enum-mismatch:automatable"
            elif ($it.target_repo != $repo) then "target-repo-mismatch"
            elif ($dup_ids | index($it.work_item_id)) then "duplicate-work-item-id"
            elif ($dup_slugs | index($it.branch_slug)) then "duplicate-branch-slug"
            elif ($fetched != null and ($nums | any(. as $n | ($fetched | index($n)) == null))) then "unknown-issue-number"
            elif ($nums | any(. as $n | $dupes | index($n))) then "duplicate-membership"
            else "" end
          ) as $reason
        | {
            work_item_id: ($it.work_item_id // ""),
            issue_numbers: $nums,
            size: ($it.size // "?"),
            valid: ($reason == ""),
            reason: $reason,
            route: (
              if $reason != "" then "invalid"
              elif ($it.scope == "cross-repo"
                    or $it.complexity == "very-complex-needs-product-decision"
                    or $it.automatable == "no") then "needs-human"
              elif ($it.complexity == "very-complex") then "path-b"
              else "path-a" end)
          }
        ]' \
        || { echo "ERROR: failed to decorate queue" >&2; return 1; }
}

# ── Label ledger (mutations — non-dry-run only) ────────────────────────────

# Idempotently ensure the four lifecycle labels exist before any edit.
sweep_ensure_labels() {
    local lbl
    for lbl in "$SWEEP_LABEL_QUEUED" "$SWEEP_LABEL_IN_PROGRESS" \
               "$SWEEP_LABEL_SHIPPED" "$SWEEP_LABEL_NEEDS_HUMAN"; do
        gh label create "$lbl" --color BFD4F2 --force >/dev/null 2>&1 || true
    done
}

# Add <label> to each issue number passed after it.
sweep_add_label() {
    local label="$1"; shift
    local n
    for n in "$@"; do
        gh issue edit "$n" --add-label "$label" >/dev/null \
            || { echo "ERROR: failed to add $label to issue #$n" >&2; return 1; }
    done
}

# Swap one label for another on a single issue (used for stale in-progress).
sweep_relabel() {
    local issue="$1" remove="$2" add="$3"
    gh issue edit "$issue" --remove-label "$remove" --add-label "$add" >/dev/null \
        || { echo "ERROR: failed to relabel issue #$issue" >&2; return 1; }
}

# ── Resume discovery ───────────────────────────────────────────────────────

# Open PR whose body carries the sweep:work-item: marker AND references this
# issue (Refs/Closes/bare #<n>). The durable, reliable key: a clustered PR
# references every member issue, so this matches regardless of branch_slug.
sweep_pr_for_issue() {
    local issue="$1"
    gh pr list --state open --json number,body \
        --jq ".[] | select(.body|test(\"sweep:work-item:\")) \
                   | select(.body|test(\"#${issue}([^0-9]|\$)\")) | .number" \
        2>/dev/null | head -n1
}

# Remote feat/sweep/* branch carrying a commit with the sweep:work-item:
# trailer that references this issue. Covers the branch-pushed-before-PR window
# AND clustered branches whose slug omits the issue number (the branch-name
# heuristic below would falsely park those). Fetches the sweep branches into a
# private probe namespace — local refs only, no push, no GitHub mutation.
sweep_commit_marker_branch() {
    local issue="$1" probe="refs/remotes/sweep-resume" r
    # Clear the probe namespace before fetching so a since-deleted remote
    # feat/sweep/* branch leaves NO stale local ref to resolve — otherwise the
    # in-progress item would never fall through to the --resume-stale gate.
    local -a stale
    mapfile -t stale < <(git for-each-ref --format='%(refname)' "${probe}/" 2>/dev/null)
    for r in "${stale[@]}"; do
        [[ -z "$r" ]] && continue
        git update-ref -d "$r" 2>/dev/null || true
    done
    git fetch --quiet --force origin \
        "refs/heads/feat/sweep/*:${probe}/*" 2>/dev/null || return 0
    local -a refs
    mapfile -t refs < <(git for-each-ref --format='%(refname)' "${probe}/" 2>/dev/null)
    # Capture marker-commit bodies and match with a pipe-free bash regex. A
    # `git log … | grep -q` pipeline false-negatives under `set -o pipefail`:
    # grep closes the pipe on an early match, git log dies on SIGPIPE, and the
    # non-zero pipeline status would mark the branch stale. `%x00` is dropped —
    # $(…) strips NUL anyway, so plain %B substring-search is what runs.
    local body pat="#${issue}([^0-9]|$)"
    for r in "${refs[@]}"; do
        [[ -z "$r" ]] && continue
        body="$(git log --grep="sweep:work-item:" "$r" --format='%B' 2>/dev/null)" || body=""
        if [[ "$body" =~ $pat ]]; then
            printf 'feat/sweep/%s' "${r#"${probe}/"}"
            return 0
        fi
    done
    return 0
}

# Last-resort heuristic: a feat/sweep/* branch whose name embeds issue-<n>.
# Weakest signal (clustered branches may omit the number) — tried only after
# the PR and commit-marker paths, so it never overrides a reliable match.
sweep_branch_name_match() {
    local issue="$1"
    git ls-remote --heads origin 2>/dev/null | awk '{print $2}' \
        | sed 's|^refs/heads/||' \
        | grep -E "^feat/sweep/.*issue-${issue}([^0-9]|\$)" | head -n1
}

# Resolve an in-progress issue to a resume target. Prints "pr:#<n>" or
# "branch:<ref>" if found, nothing if stale. Most reliable signal first.
sweep_find_resume_target() {
    local issue="$1" pr ref
    pr="$(sweep_pr_for_issue "$issue")" || pr=""
    if [[ -n "$pr" ]]; then
        printf 'pr:#%s' "$pr"
        return 0
    fi
    ref="$(sweep_commit_marker_branch "$issue")" || ref=""
    if [[ -n "$ref" ]]; then
        printf 'branch:%s' "$ref"
        return 0
    fi
    ref="$(sweep_branch_name_match "$issue")" || ref=""
    if [[ -n "$ref" ]]; then
        printf 'branch:%s' "$ref"
    fi
}
