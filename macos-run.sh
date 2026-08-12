#!/bin/sh
# macOS shim — run any script in this folder with Homebrew bash 5 + GNU tools
# first in PATH. Scripts here target Linux (bash >=4, GNU grep/sed, flock);
# stock macOS ships bash 3.2 and BSD tools, so invoke through this wrapper.
#
# One-time setup:  brew install bash grep gnu-sed util-linux
# Usage:           ./macos-run.sh agent_workers/audit_pr_review.sh -p 123 -d ../some-repo --no-post
#                  ./macos-run.sh agent_workers/issue_sweep.sh -d ../some-repo --dry-run --max 50
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"
PATH="$BREW/opt/grep/libexec/gnubin:$BREW/opt/gnu-sed/libexec/gnubin:$BREW/opt/util-linux/bin:$BREW/bin:$PATH"
export PATH
exec "$BREW/bin/bash" "$@"
