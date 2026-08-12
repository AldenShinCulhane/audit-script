#!/bin/bash
# review_fix_helpers.sh — the lean review-fix inner loop for issue_sweep.sh.
#
# Sourced by agent_workers/issue_sweep.sh (alongside issue_triage_helpers.sh and
# issue_pipeline_helpers.sh). Provides the Phase 2 review-fix surface:
#   * poll the server-side reviewer check (REVIEW_CHECK_NAME, default
#     claude-review) on the EXACT pushed head_sha until it reaches a terminal
#     state — name matched exactly or by " / " segment, with a
#     first-registration grace window (REVIEW_REGISTER_GRACE)
#   * fetch the current review round's comments (author = review bot, after
#     round_started_at OR tied to head_sha), excluding the sweep's own
#     <!-- sweep:self --> replies
#   * classify each finding nit vs non-nit: explicit severity tags first, a
#     best-effort codex pass for the unclear ones, conservative default = non-nit
#   * batch-fix ALL non-nit findings with codex in one turn, post rebuttal
#     replies for disagreements, then a SINGLE push per round (empty commit when
#     the round is rebuttal-only) so each push triggers exactly one review
#   * no local reviewer fallback: when the server-side reviewer is absent, fail
#     closed so an untrusted diff is not reviewed by a credential-bearing local
#     agent with repository tools available
#
# Reviewer = Claude (GitHub Action on push, server-side — NOT a local process).
# Fixer    = codex (local). The reviewer is the impl-quality gate; this loop is
# the inner convergence (audit is the outer gate). All functions fail fast
# (return non-zero) on error; the driver decides park vs continue. No bare
# fallbacks, no silent defaults beyond the documented conservative nit default.
#
# Pure helpers (jq/bash only) are unit-testable without gh/git/codex; the IO
# helpers below them wrap gh/git/codex and are exercised via PATH stubs.

# Hidden marker on every comment the sweep itself posts (rebuttals). The next
# round's fetch excludes any comment containing it — pattern lifted from
# pr_loop.sh's PR_LOOP_MARKER so the sweep never re-triages its own replies.
readonly RF_SELF_MARKER="<!-- sweep:self -->"

# ── Pure: reviewer-check state ─────────────────────────────────────────────

# jq prelude shared by every check-run name comparison. Matching is prioritized:
# exact name first, then the trailing segment of a reusable-workflow composed
# name ("<caller job> / <callee job>"), then a legacy any-segment fallback. The
# priority keeps "review / lint" from winning over "review / review" when the
# operator passes --review-check-name review, while preserving older
# caller-segment configurations when no exact or trailing-segment match exists.
# Segment EQUALITY, not substring: target "review" must not match a check named
# "claude-review". Requires jq to be invoked with --arg n <name>.
# shellcheck disable=SC2016 # $n is a jq --arg binding, not a shell variable.
readonly RF_NAME_MATCH_JQ='
def rf_segments: (. // "") | split(" / ");
def rf_exact_name_matches: (. // "") == $n;
def rf_trailing_segment_matches: (rf_segments | .[-1]) == $n;
def rf_segment_name_matches: rf_segments | index($n) != null;
def rf_name_matches: rf_exact_name_matches or rf_segment_name_matches;
def rf_preferred_matching_runs:
    [ .[] | select(.name | rf_exact_name_matches) ] as $exact
    | if ($exact | length) > 0 then $exact
      else
        [ .[] | select(.name | rf_trailing_segment_matches) ] as $trailing
        | if ($trailing | length) > 0 then $trailing
          else [ .[] | select(.name | rf_segment_name_matches) ]
          end
      end;
def rf_has_preferred_name_match: (rf_preferred_matching_runs | length) > 0;'

# Conclusion of the named check across a check_runs array (the `.check_runs`
# field of GET /repos/{slug}/commits/{sha}/check-runs). A run counts when its
# name matches by the prioritized rules in RF_NAME_MATCH_JQ. Prints the
# conclusion of the LATEST completed preferred matching run, or "" when no run
# matches or any preferred matching run is still in flight (treat in-flight as
# not-yet-ready).
rf_check_conclusion() {
    local checks_json="$1" name="$2"
    printf '%s' "$checks_json" | jq -r --arg n "$name" "${RF_NAME_MATCH_JQ}"'
        rf_preferred_matching_runs as $runs
        | if ($runs | length) == 0 then ""
          elif any($runs[]; .status != "completed") then ""
          else ($runs | sort_by(.completed_at // "") | last | .conclusion // "") end' \
        2>/dev/null || { echo "ERROR: rf_check_conclusion jq failed" >&2; return 1; }
}

# Map a check conclusion to a loop action: ready (fetch comments), park (fatal
# reviewer failure → needs-human), or pending (not terminal yet — keep polling).
rf_classify_check_state() {
    case "$1" in
        success|neutral|skipped) printf 'ready' ;;
        failure|cancelled|timed_out|action_required|startup_failure|stale)
            printf 'park' ;;
        "") printf 'pending' ;;
        *)  printf 'park' ;;
    esac
}

# ── Pure: comment normalization + classification ───────────────────────────

# Normalize the two reviewer payloads (inline review comments from
# /pulls/{n}/comments and review summaries from /pulls/{n}/reviews) into one
# unified array of {id, author, body, path, line, commit_id, created_at}.
rf_unify_comments() {
    local inline_json="$1" reviews_json="$2"
    jq -sc '
        ( .[0] // [] | map({
            id: .id, author: (.user.login // ""),
            body: (.body // ""), path: (.path // null),
            line: (.line // .original_line // null),
            commit_id: (.commit_id // ""),
            created_at: (.updated_at // .created_at // "")
        }))
        + ( .[1] // [] | map(select((.body // "") != "")) | map({
            id: .id, author: (.user.login // ""),
            body: (.body // ""), path: null, line: null,
            commit_id: (.commit_id // ""),
            created_at: (.submitted_at // "")
        }))' \
        <(printf '%s' "$inline_json") <(printf '%s' "$reviews_json") \
        2>/dev/null || { echo "ERROR: rf_unify_comments jq failed" >&2; return 1; }
}

# Keep only the CURRENT review round: drop the sweep's own replies (self
# marker), keep comments authored by the review bot (when known), and require
# the comment to be newer than round_started_at OR tied to this head_sha.
# Older reviewer comments are context only — a finding stays blocking solely by
# being re-raised in the current round.
rf_filter_current_round() {
    local comments_json="$1" since="$2" head_sha="$3" bot="$4"
    printf '%s' "$comments_json" | jq -c \
        --arg since "$since" --arg sha "$head_sha" --arg bot "$bot" --arg m "sweep:self" '
        [ .[]
          | select((.body // "") | contains($m) | not)
          | select(($bot == "") or (.author == $bot))
          | select(((.created_at // "") > $since) or ((.commit_id // "") == $sha))
        ]' 2>/dev/null || { echo "ERROR: rf_filter_current_round jq failed" >&2; return 1; }
}

# Add a .severity (nit|non-nit|unknown) to each comment using explicit tags
# only. Low-severity markers (nit/minor/style/...) => nit; high-severity
# (blocker/major/bug/...) => non-nit and WIN when both appear; otherwise
# unknown (handed to codex, then defaulted). Markers are matched at a word
# boundary followed by ':' or ' ' so "minority" / "buggy" do not false-match.
rf_classify_comments() {
    printf '%s' "$1" | jq -c '
        def sev:
          ((.body // "") | ascii_downcase) as $l
          | if ($l | test("(^|[^a-z0-9])(blocker|major|critical|security|must[ -]?fix|bug|important)[: ]"))
              then "non-nit"
            elif ($l | test("(^|[^a-z0-9])(nit|nitpick|minor|style|trivial|optional|typo)[: ]"))
              then "nit"
            else "unknown" end;
        [ .[] | . + {severity: sev} ]' \
        2>/dev/null || { echo "ERROR: rf_classify_comments jq failed" >&2; return 1; }
}

# Conservative default: any finding still "unknown" after tags + codex becomes
# non-nit. Misclassifying a real blocker as a nit is the costly error; the human
# bot->develop gate is the backstop for the reverse.
rf_default_unknowns_nonnit() {
    printf '%s' "$1" | jq -c '[ .[] | if .severity == "unknown" then .severity = "non-nit" else . end ]' \
        2>/dev/null || { echo "ERROR: rf_default_unknowns_nonnit jq failed" >&2; return 1; }
}

# True (exit 0) when the classified array contains at least one non-nit finding.
rf_has_non_nit() {
    printf '%s' "$1" | jq -e 'any(.[]; .severity == "non-nit")' >/dev/null 2>&1
}

# Count of findings still tagged unknown (drives whether a codex classify pass
# is worth spending).
rf_unknown_count() {
    printf '%s' "$1" | jq '[ .[] | select(.severity == "unknown") ] | length' 2>/dev/null \
        || { echo "0"; return 1; }
}

# Apply a codex-produced {id: "nit"|"non-nit"} label map to still-unknown
# findings. Any off-schema value is ignored so the conservative unknown->non-nit
# default still applies later.
rf_apply_codex_labels() {
    local classified="$1" labels="$2"
    printf '%s' "$classified" | jq -c --argjson lbl "$labels" '
        [ .[]
          | if .severity == "unknown" then
              (.id | tostring) as $k
              | ($lbl[$k] // "") as $v
              | if ($v == "nit" or $v == "non-nit")
                  then .severity = $v
                  else .
                end
            else .
            end ]' \
        2>/dev/null || printf '%s' "$classified"
}

# ── IO: reviewer-check polling ─────────────────────────────────────────────

# Fetch the check_runs array for an exact commit. Empty array on a gh failure
# is distinct from "[]" (no runs) only in the return code — the caller keeps
# polling on a transient gh error rather than parking.
rf_fetch_check_runs() {
    local slug="$1" sha="$2"
    gh api "repos/${slug}/commits/${sha}/check-runs" --jq '.check_runs' 2>/dev/null \
        || return 1
}

# Poll the named reviewer check on head_sha until terminal or timeout.
# Prints exactly one of: ready | park | absent (printed to stdout).
#   ready  — terminal success/neutral/skipped → fetch comments
#   park   — terminal failure/cancelled/... OR registered but not terminal
#            within REVIEW_POLL_TIMEOUT
#   absent — the check never registered → caller may fall back (disabled → park)
# Name matching follows RF_NAME_MATCH_JQ's priority: exact name, then trailing
# composed segment, then legacy any-segment fallback.
# Two windows share ONE elapsed counter:
#   * REVIEW_REGISTER_GRACE (default 120s) bounds FIRST REGISTRATION: while the
#     check has never been seen, absent is declared only once grace has elapsed
#     AND on the evidence of a successful check-runs fetch — GH Actions need
#     ~15-45s post-push to create the check run, and a transient gh error must
#     never masquerade as absence. The fetch precedes the gate, so even
#     REVIEW_REGISTER_GRACE=0 performs at least one appearance check.
#   * REVIEW_POLL_TIMEOUT (default 1800s) is the overall hard cap: once seen it
#     bounds the wait for a terminal state (park); under persistent gh failure
#     it also caps the whole poll (park/absent by whether the check was ever
#     seen), so the effective registration window is min(grace, timeout).
# Env: REVIEW_POLL_TIMEOUT (default 1800s), REVIEW_POLL_INTERVAL (default 30s),
#      REVIEW_REGISTER_GRACE (default 120s).
rf_poll_review() {
    local slug="$1" sha="$2" name="$3"
    local timeout="${REVIEW_POLL_TIMEOUT:-1800}" interval="${REVIEW_POLL_INTERVAL:-30}"
    local grace="${REVIEW_REGISTER_GRACE:-120}"
    local elapsed=0 seen=false runs concl state names
    while :; do
        runs="$(rf_fetch_check_runs "$slug" "$sha")" || runs=""
        if [ -n "$runs" ]; then
            concl="$(rf_check_conclusion "$runs" "$name")" || concl=""
            # Distinguish "registered but running" (a matching run exists) from
            # "absent" so the fallback only fires when there is truly no
            # server-side reviewer.
            if printf '%s' "$runs" | jq -e --arg n "$name" \
                    "${RF_NAME_MATCH_JQ}"' rf_has_preferred_name_match' \
                    >/dev/null 2>&1; then
                seen=true
            fi
            state="$(rf_classify_check_state "$concl")"
            if [ "$state" != "pending" ]; then
                printf '%s' "$state"
                return 0
            fi
            if [ "$seen" = false ] && [ "$elapsed" -ge "$grace" ]; then
                names="$(printf '%s' "$runs" | jq -r '[.[].name] | unique | join(", ")' 2>/dev/null)" || names="?"
                echo "WARN: reviewer check '$name' never registered on $sha within ${elapsed}s; check runs present: ${names:-none}" >&2
                printf 'absent'
                return 0
            fi
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            [ "$seen" = true ] && printf 'park' || printf 'absent'
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
}

# ── IO: fetch + classify a round ───────────────────────────────────────────

# Paginated GET of a GitHub list endpoint, with a bounded retry. Prints ONE
# merged JSON array on success; returns non-zero (caller parks/retries) if every
# attempt fails or the payload is un-parseable.
#
# Audit BLOCKER (review API failures = "no blocking comments"): two distinct
# bugs are closed here. (1) GitHub list endpoints page at 30 items, so a PR with
# >30 review comments would silently drop the tail and the loop could converge
# with blockers unseen — `--paginate` walks every page. (2) A transient gh
# failure (rate limit / auth / network) must NEVER degrade to an empty array; it
# returns non-zero so the round parks, never "no non-nits". The endpoint is the
# first positional arg so the same call shape works under a stubbed `gh`.
# Env: RF_FETCH_RETRIES (default 3), RF_FETCH_RETRY_DELAY seconds (default 3).
rf_gh_fetch_list() {
    local endpoint="$1"
    local attempts="${RF_FETCH_RETRIES:-3}" delay="${RF_FETCH_RETRY_DELAY:-3}"
    local i raw merged
    for ((i = 1; i <= attempts; i++)); do
        if raw="$(gh api "$endpoint" --paginate 2>/dev/null)"; then
            # --paginate concatenates each page's JSON array back-to-back; slurp
            # the whole stream and `add` merges the pages into one array (and
            # yields [] for a single empty page, via `// []`).
            if merged="$(printf '%s' "$raw" | jq -sc 'add // []' 2>/dev/null)" \
               && printf '%s' "$merged" | jq -e 'type == "array"' >/dev/null 2>&1; then
                printf '%s' "$merged"
                return 0
            fi
        fi
        [ "$i" -lt "$attempts" ] && sleep "$delay"
    done
    echo "ERROR: gh list fetch failed/un-parseable for $endpoint after $attempts attempt(s)" >&2
    return 1
}

# Fetch, unify, current-round-filter, and classify (tags + default) the review
# comments for one round. Prints the classified array. A fetch failure returns
# non-zero (the driver parks the work-item) rather than treating a failed API
# call as an empty comment set. The codex classify pass for unknowns is layered
# on top by the driver (rf_codex_classify_unknowns) before the conservative
# default is applied.
rf_fetch_round_comments() {
    local slug="$1" pr="$2" since="$3" sha="$4" bot="$5"
    local inline reviews unified current
    inline="$(rf_gh_fetch_list "repos/${slug}/pulls/${pr}/comments")" || return 1
    reviews="$(rf_gh_fetch_list "repos/${slug}/pulls/${pr}/reviews")" || return 1
    unified="$(rf_unify_comments "$inline" "$reviews")" || return 1
    current="$(rf_filter_current_round "$unified" "$since" "$sha" "$bot")" || return 1
    rf_classify_comments "$current"
}

# ── IO: local /code-review fallback ────────────────────────────────────────

# A local reviewer fallback would need a credentialless, read-only sandbox with
# tools disabled. The current sweep has a push-deny wrapper for fix agents, but
# not a true read-only/toolless reviewer sandbox; a prompt-injected diff could
# otherwise make the local Claude turn edit the worktree or reach repo creds.
# Fail closed when the server-side reviewer is absent.
rf_local_review_fallback() {
    local project_dir="$1" base_ref="$2" out_json="$3"
    if [ -z "$project_dir" ] || [ -z "$base_ref" ] || [ -z "$out_json" ]; then
        echo "ERROR: local /code-review fallback called with missing arguments" >&2
        return 1
    fi
    echo "ERROR: server-side review check absent and local /code-review fallback is disabled (no read-only credentialless sandbox with tools disabled)" >&2
    return 1
}

# ── IO: codex classify (best-effort) + batch-fix ───────────────────────────

# Best-effort codex pass over the still-unknown findings. Prints the classified
# array with as many unknowns resolved as codex could label; on ANY failure it
# prints the input unchanged (the caller then applies the conservative default).
rf_codex_classify_unknowns() {
    local project_dir="$1" classified="$2" session_key="$3" workdir="$4"
    local unknowns prompt out labels
    unknowns="$(printf '%s' "$classified" | jq -c '[ .[] | select(.severity == "unknown") | {id, body} ]')" \
        || { printf '%s' "$classified"; return 0; }
    if [ "$(printf '%s' "$unknowns" | jq 'length')" = "0" ]; then
        printf '%s' "$classified"; return 0
    fi
    out="$workdir/.classify_out.txt"
    prompt="Classify each PR review finding as a nit (ignorable style/polish) or
non-nit (must address before merge). Output ONLY a JSON object mapping each
finding's id to \"nit\" or \"non-nit\" (no prose, no fences). When unsure, use
\"non-nit\". Findings:
${unknowns}"
    if ! AGENT_PROJECT_ROOT="$project_dir" rf_run_fixer_no_push "${FIXER_AGENT:-codex}" \
            "$session_key" "$prompt" "$out" >/dev/null 2>&1; then
        printf '%s' "$classified"; return 0
    fi
    labels="$(sed -e '/^```/d' "$out" | jq -c '.' 2>/dev/null)" || { printf '%s' "$classified"; return 0; }
    if ! printf '%s' "$labels" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf '%s' "$classified"; return 0
    fi
    rf_apply_codex_labels "$classified" "$labels"
}

# Render the codex batch-fix prompt from the classified findings. Lists every
# non-nit finding with its path:line so codex resolves them ALL in one turn.
# $rebuttals_path is an ABSOLUTE path OUTSIDE the repo, so codex's disagreement
# notes never show up as working-tree changes (which would defeat the
# rebuttal-only empty-commit branch in rf_push_round).
rf_render_fix_prompt() {
    local classified="$1" rebuttals_path="$2"
    local findings
    findings="$(printf '%s' "$classified" | jq -r '
        [ .[] | select(.severity == "non-nit") ] | to_entries[]
        | "\(.key + 1). " + ((.value.path // "general")
            + (if .value.line then ":\(.value.line)" else "" end))
            + " — " + (.value.body | gsub("\n"; " ") | .[0:500])')"
    cat <<EOF
You are fixing a pull request in response to its code review. Address ALL of the
non-nit review findings below by editing the repository in place. Make the
smallest correct change per finding. Do NOT commit, push, or open PRs — the
runner handles git.

If you genuinely disagree with a finding and will NOT change code for it, append
one line to the file ${rebuttals_path} (absolute path) in the form:
  <finding-number>\t<your concise rebuttal>
Leave that file untouched if you addressed everything.

Findings:
${findings}
EOF
}

# Run an agent turn behind issue_sweep's push sandbox when it is available
# (audit BLOCKER: the fixer must not push — the runner owns git/GitHub). The
# sandbox helper lives in issue_pipeline_helpers.sh. If this file is sourced on
# its own, fail closed rather than running a credential-bearing agent directly.
# Forwards every arg unchanged.
rf_run_fixer_no_push() {
    if declare -f sweep_run_agent_no_push >/dev/null 2>&1; then
        sweep_run_agent_no_push "$@"
    else
        echo "ERROR: sweep_run_agent_no_push unavailable; refusing to run agent without the sweep sandbox" >&2
        return 1
    fi
}

# Run the codex batch-fix turn against the project. Codex writes any rebuttals
# to $workdir/rebuttals.txt (outside the repo). Returns codex's rc.
rf_codex_batch_fix() {
    local project_dir="$1" classified="$2" session_key="$3" workdir="$4"
    local prompt out rebuttals_path
    out="$workdir/.fix_out.txt"
    rebuttals_path="$workdir/rebuttals.txt"
    : > "$rebuttals_path"
    prompt="$(rf_render_fix_prompt "$classified" "$rebuttals_path")"
    AGENT_PROJECT_ROOT="$project_dir" rf_run_fixer_no_push "${FIXER_AGENT:-codex}" \
        "$session_key" "$prompt" "$out"
}

# ── IO: rebuttals + single push ────────────────────────────────────────────

# Post each rebuttal line (codex's "<n>\t<text>") as a self-marked PR comment so
# the next round excludes it. Returns 0 even if there are none.
rf_post_rebuttals() {
    local pr="$1" rebuttals_file="$2"
    [ -s "$rebuttals_file" ] || return 0
    local line text
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        text="${line#*$'\t'}"
        gh pr comment "$pr" --body "${RF_SELF_MARKER}
${text}" >/dev/null 2>&1 \
            || { echo "ERROR: failed to post rebuttal on PR #$pr" >&2; return 1; }
    done < "$rebuttals_file"
}

# A round produced file edits if the working tree is dirty or has new untracked
# files. Drives the empty-commit-when-rebuttal-only branch in rf_push_round.
rf_has_worktree_changes() {
    local project_dir="$1"
    ! git -C "$project_dir" diff --quiet HEAD -- 2>/dev/null \
        || [ -n "$(git -C "$project_dir" ls-files --others --exclude-standard)" ]
}

# SINGLE push per round (one push = one server-side review). Commits all edits;
# if the round was rebuttal-only (no file diff) creates one empty commit so the
# reviewer re-runs. Prints nothing; returns non-zero on push failure.
rf_push_round() {
    local project_dir="$1" branch="$2" msg="$3"
    if rf_has_worktree_changes "$project_dir"; then
        git -C "$project_dir" add -A
        git -C "$project_dir" commit --quiet -m "$msg" || return 1
    else
        git -C "$project_dir" commit --quiet --allow-empty -m "$msg" || return 1
    fi
    git -C "$project_dir" push --quiet origin "$branch" || return 1
}
