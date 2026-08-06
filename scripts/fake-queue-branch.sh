#!/usr/bin/env bash
# Jenkins-only probe: push a branch that looks like a merge-queue ref, with no
# real queue involved.
#
# Isolates the Jenkins half of the wiring — branch discovery, name filters,
# webhook-driven indexing, and whether 'github-token' can post a commit status
# — before any real queue run depends on it. Also the only way to exercise
# Jenkins if the repo is on a plan where merge queue is unavailable.
#
#   scripts/fake-queue-branch.sh          # then watch Jenkins + the commit status
#   scripts/fake-queue-branch.sh --clean  # delete probe branches
#
# GitHub may reject direct pushes under gh-readonly-queue/*; the script falls
# back to mq-sim/* and tells you to widen the Jenkins branch filter to match.

set -euo pipefail
cd "$(dirname "$0")/.."

base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo main)"

if [ "${1:-}" = "--clean" ]; then
  # Scope to the probe namespace ONLY. `*` in an ls-remote pattern matches across
  # '/', so 'refs/heads/gh-readonly-queue/*' matches every REAL queue entry —
  # running --clean during a scenario would delete live merge-queue refs
  # mid-validation. Never widen these globs. No `|| true`: a refused delete must
  # be visible, not swallowed.
  git ls-remote origin 'refs/heads/gh-readonly-queue/*/pr-999-*' 'refs/heads/mq-sim/*' \
    | awk '{print $2}' | while read -r ref; do
        echo "deleting ${ref}"
        git push origin --delete "${ref#refs/heads/}"
      done
  exit 0
fi

git fetch origin "$base"
short="$(git rev-parse --short "origin/${base}")"
branch="gh-readonly-queue/${base}/pr-999-${short}"

git switch -c "probe-${short}" "origin/${base}"
printf 'synthetic queue probe %s\n' "$short" > items/probe.txt
git add items/probe.txt
git commit -m "probe: synthetic merge-queue branch"

if ! git push origin "HEAD:refs/heads/${branch}"; then
  branch="mq-sim/${base}/pr-999-${short}"
  echo
  echo "gh-readonly-queue/* push refused; retrying as ${branch}"
  echo "-> add 'mq-sim/**' to the Jenkins job's branch name filter for this probe"
  git push origin "HEAD:refs/heads/${branch}"
fi

git switch "$base"
git branch -D "probe-${short}"

cat <<EOF

pushed ${branch}
  Jenkins : expect a branch job for it within ~1 scan/webhook cycle
  GitHub  : gh api repos/\$(gh repo view --json nameWithOwner -q .nameWithOwner)/commits/${branch}/status
  cleanup : scripts/fake-queue-branch.sh --clean
EOF
