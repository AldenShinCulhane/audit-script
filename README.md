# Agent Workers — Multi-Agent PR Audit & Automation Loops

Standalone toolkit of agent-driven development loops built around the `claude` (Claude Code) and `codex` CLIs. The centerpiece is `audit_pr_review.sh` — a multi-agent PR audit with cross-pollination — plus companion loops for issue sweeping, spec-first implementation, and PR-driving.

Extracted from an internal automation repo I built and operated in production (final state as of 2026-07-28). Self-contained: every `source` resolves via `$SCRIPT_DIR` to `lib/` inside this repo — no external files required at runtime.

```
agent_workers/   the 8 loop scripts + extract_sections.py + lib/   (paths below are relative to here)
scripts/         audit-pr.sh (self-contained OSS/codex/claude production-safety audit; curl-based, no further file deps)
macos-run.sh     bash-5/GNU-tools shim — ./macos-run.sh agent_workers/<script> ...
```

## Entry points

| Script | Purpose |
|---|---|
| `audit_pr_review.sh` | **The audit script.** Multi-agent PR audit with cross-pollination: two agents (claude primary, codex co-agent) independently audit a PR, cross-pollinate findings over multiple rounds, then draft a GitHub review + approve/request-changes recommendation. Posts to GitHub by default; `--no-post` for local-only. Large diffs auto-partition into subsystem groups, each running the full pipeline in parallel, then a consolidation turn merges drafts. |
| `issue_sweep.sh` | Autonomous GitHub-issue backlog drainer. Pipeline: fetch open issues → toolless triage turn → cluster/classify → jq schema gate → per-item isolated worktree → PATH A (single agent turn, must emit `[PASS]` from repo's own lint/tests) or PATH B (`spec_to_ship.sh`, very-complex only) → review-fix loop → audit gate (`audit_pr_review.sh --no-post`) → merge approved branches onto `bot/auto-fix-<date>` → one rollup PR. Human merges the rollup. |
| `agent_loop.sh` | Single-agent implementation loop against a repo (validation-gated). |
| `pr_loop.sh` | PR-driving loop (implement → push → iterate on review feedback). Targets a new PR by title (`-t`) or any open PR (`-p <pr>`). |
| `spec_loop.sh` / `spec_to_ship.sh` | Spec-first pipeline: iterate a spec (≤10 rounds), then drive implementation phase-by-phase (`extract_sections.py` slices phase specs). |
| `agent_research.sh` | Research/goal-file agent runs. |
| `lib/` | Sourced helpers: `agent_sessions.sh` (agent spawn/wait/retry/hang-cap), `audit_pr_review_helpers.sh`, `issue_{triage,pipeline,aggregate}_helpers.sh`, `review_fix_helpers.sh`, `oss_agents.sh`. |

`scripts/audit-pr.sh` sits at the repo root's `scripts/` (not inside `agent_workers/`) because `spec_to_ship.sh` resolves it at `$SCRIPT_DIR/../scripts/audit-pr.sh` — keep the layout intact.

## Runtime dependencies

- bash ≥ 4 (macOS ships 3.2 — `brew install bash` and run via `macos-run.sh`)
- `git`, `jq`, `python3`
- `gh` CLI, authenticated against the target GitHub host/org
- `claude` CLI (Claude Code) — primary agent engine (subscription auth works; no API key needed)
- `codex` CLI — co-agent / batch fixer (swap via `-i` on issue_sweep, `--co-agent` style flags where exposed)

The target repo is whatever `-d <path>` points at (or the cwd) — repo slug, base branch, and PR metadata are derived at runtime via `gh`/`git`, so the tools run against any repository your `gh` auth can reach.

## Usage

```bash
# PR audit, local-only (no GitHub comment posted):
./agent_workers/audit_pr_review.sh -p <PR#> -d /path/to/repo --no-post

# Issue sweep — dry run (safe: one triage turn, zero mutations):
cd /path/to/repo && /path/to/agent_workers/issue_sweep.sh -d . --dry-run --max 50

# Issue sweep — real run (detached; see security notes first):
cd /path/to/repo && SWEEP_DETACHED=1 SWEEP_ALLOW_UNSANDBOXED_AGENT=1 \
  setsid nohup /path/to/agent_workers/issue_sweep.sh -d . --max 50 > ~/sweep.log 2>&1 &
```

Key caps/knobs (env or flags): `MAX_REVIEW_ROUNDS=5`, `MAX_PR_ROUNDS=3`, `MAX_AUDIT_ROUNDS=2`, `MAX_FIX_ATTEMPTS=5`, `REVIEW_POLL_TIMEOUT=1800`, `FULL_DIFF_MAX_BYTES=200000`, `CHUNK_MAX_BYTES=60000`, `MAX_PARALLEL_GROUPS=2`, `--max N` (issue fetch cap, default 200), `--review-check-name`, `--group-config` (glob→group overrides for diff partitioning).

Note: `pr_loop`/`agent_loop`/`spec_loop`/`agent_research` take `-h` (not `--help`).

## Running on macOS

Scripts target Linux: bash ≥4 (shebangs say `/bin/bash`), GNU `grep -P` (agent_loop, pr_loop), GNU `sed -i "0,/…"` (agent_loop), `flock` (real issue_sweep runs only — dry-run works without and fails clean otherwise). One-time setup + wrapper:

```bash
brew install bash grep gnu-sed util-linux
./macos-run.sh agent_workers/audit_pr_review.sh -p <PR#> -d <repo> --no-post
```

`macos-run.sh` puts Homebrew bash 5 + GNU gnubin dirs first in PATH and execs the target script. `setsid` doesn't exist on macOS — for detached sweep launches use plain `nohup … &`. On any Linux box everything runs as-is.

## Portability caveats (origin-org assumptions)

- `issue_sweep.sh` review-fix stage expects a **server-side `claude-review` GitHub Action check** on the target repo (name overridable via `--review-check-name`); the local fallback is deliberately disabled. Without it every path-a item parks `bot:needs-human`.
- Assumes `develop` as integration base branch and a `bot:*` label namespace by default. Adjust flags/env for other conventions.
- **Known bug (open at extraction time):** review-poll race — `rf_poll_review` declares the server-side reviewer "absent" at t≈0, before the GH Action registers its check (~15–45s queue delay); the check then passes minutes later, too late → every item parks needs-human, nothing ships. Fix needed: grace window / registration retry before declaring the reviewer absent. Until fixed, `--dry-run` is useful for triage preview; real runs park 100% on repos using the claude-review Action.
- `issue_sweep.sh` refuses to run inside an interactive Claude Code session (`CLAUDECODE` env set) — launch detached (exit 2 otherwise).
- Issue/PR references of the form `mesh#NN` in code comments refer to issues in the (private) origin repo — kept for context, not resolvable here.

## Security notes

- `SWEEP_ALLOW_UNSANDBOXED_AGENT=1` is required for real sweep runs and is **dangerous on a box without OS-level isolation**: an injected/hallucinated agent turn over attacker-authored issue text could push directly via on-disk git credentials. Set it only inside a container / push-tokenless service account / egress-firewalled host. PATH B (`spec_to_ship.sh`) is not wrapped in the in-process push-deny shim at all.
- Sweep items run sequentially (one at a time); each path-a item historically cost ~0.5–2M agent tokens.
