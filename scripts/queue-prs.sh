#!/usr/bin/env bash
# Enqueue PRs back to back, so they land in the queue inside one CI duration
# and GitHub is forced to build speculative entries.
#
#   scripts/queue-prs.sh 1 2 3
#   scripts/queue-prs.sh            # every open mq-test/* PR, lowest number first
#
# `gh pr merge --auto` is the enqueue path once a merge_queue rule exists — the
# equivalent of clicking "Merge when ready". It is accepted immediately; GitHub
# only adds the PR to the queue once the required checks on the PR head are
# green, and those are merge-with-target builds (see docs/results.md scenario 7).
#
# --merge, not --squash, for honesty rather than effect: once a merge_queue rule
# exists the flag is inert. `gh pr merge --squash` is accepted with a warning
# ("The merge strategy for main is set by the merge queue") and the queue's
# merge_method decides regardless. See docs/results.md, scenario 8 aside.

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

# Under a merge queue, enqueue and merge are the SAME action: --auto is the
# enqueue path, and a green entry merges. So a PR carrying a ci/config.env
# override cannot be "queued but not merged" — enqueueing it is deciding to make
# its override the repo default. That is how MAX_ITEMS=4 (reverting a deliberate
# 8) and SLEEP_SECONDS=180 (twice) reached main. Overrides are skipped unless
# named explicitly on the command line.
explicit=$#
for pr in "${prs[@]}"; do
  # Ask GitHub what the PR touches rather than diffing local refs, which may not
  # be fetched and go stale after a force-push.
  if [ "$explicit" -eq 0 ] && \
     gh pr view "$pr" --json files -q '.files[].path' | grep -qx 'ci/config.env'; then
    echo "== SKIP #${pr}: changes ci/config.env — merging it would change the repo default."
    echo "   Close it when the scenario ends, or pass the number explicitly to force."
    continue
  fi
  echo "== enqueue #${pr}"
  gh pr merge "$pr" --merge --auto
done

echo
echo "queued: ${prs[*]}   -> watch with scripts/watch-queue.sh"
