#!/usr/bin/env bash
# Enqueue PRs back to back, so they land in the queue inside one CI duration
# and GitHub is forced to build speculative entries.
#
#   scripts/queue-prs.sh 1 2 3
#   scripts/queue-prs.sh            # every open mq-test/* PR, lowest number first
#
# `gh pr merge --auto` is the enqueue path once a merge_queue rule exists: the
# PR enters the queue as soon as its PR-level required checks are green.

set -euo pipefail
cd "$(dirname "$0")/.."

prs=("$@")
if [ "${#prs[@]}" -eq 0 ]; then
  # No mapfile: macOS ships bash 3.2.
  while read -r n; do
    prs+=("$n")
  done < <(gh pr list --state open --json number,headRefName \
    -q '[.[] | select(.headRefName | startswith("mq-test/")) | .number] | sort | .[]')
fi

if [ "${#prs[@]}" -eq 0 ]; then
  echo "no open mq-test/* PRs" >&2
  exit 1
fi

for pr in "${prs[@]}"; do
  echo "== enqueue #${pr}"
  gh pr merge "$pr" --squash --auto
done

echo
echo "queued: ${prs[*]}   -> watch with scripts/watch-queue.sh"
