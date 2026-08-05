#!/usr/bin/env bash
# Post-merge assertions for a PR that went through the queue with
# merge_method: MERGE.
#
#   scripts/verify-merge.sh <pr-number>
#
# Answers the questions that matter about a merge-commit queue:
#   1. does the commit on main have two parents, with the PR head as the second?
#   2. is that commit the queue-branch head itself, or a new commit?
#   3. either way, is the TREE identical to the one CI validated?
#
# (3) is the property the whole merge queue exists to provide, and it is the one
# worth asserting — (2) is an implementation detail that may differ per merge
# method.
#
# Needs the queue head, which GitHub deletes seconds after the merge; so run
# scripts/watch-queue.sh during the run to populate .mq-queue-log.

set -euo pipefail
cd "$(dirname "$0")/.."

pr="${1:?usage: verify-merge.sh <pr-number>}"
QUEUE_LOG=.mq-queue-log
fail=0

note() { printf '%s\n' "$*"; }
check() {  # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    note "  PASS  $1"
  else
    note "  FAIL  $1"
    note "        expected: $2"
    note "        actual:   $3"
    fail=1
  fi
}

git fetch -q origin

state="$(gh pr view "$pr" --json state -q .state)"
[ "$state" = "MERGED" ] || { note "PR #${pr} is ${state}, not MERGED"; exit 1; }

head_sha="$(gh pr view "$pr" --json headRefOid -q .headRefOid)"
merge_sha="$(gh pr view "$pr" --json mergeCommit -q .mergeCommit.oid)"
note "PR #${pr}"
note "  PR head      : $head_sha"
note "  merge commit : $merge_sha"

git cat-file -e "${merge_sha}^{commit}" 2>/dev/null || git fetch -q origin main

parents="$(git rev-list --parents -1 "$merge_sha" | cut -d' ' -f2-)"
nparents="$(printf '%s' "$parents" | wc -w | tr -d ' ')"
p2="$(printf '%s' "$parents" | cut -d' ' -f2)"
note "  parents      : $nparents ($parents)"

check "merge commit has 2 parents" "2" "$nparents"
check "second parent is the PR head" "$head_sha" "$p2"

# Which queue entry validated this PR? Ref names are gh-readonly-queue/<base>/pr-<n>-<base-sha>.
queue_sha="$(grep -E "/pr-${pr}-" "$QUEUE_LOG" 2>/dev/null | tail -1 | cut -d' ' -f1 || true)"
if [ -z "$queue_sha" ]; then
  note "  SKIP  tree comparison: no queue head for pr-${pr} in ${QUEUE_LOG}"
  note "        (run scripts/watch-queue.sh during the queue run to capture it)"
else
  note "  queue head   : $queue_sha"
  if git cat-file -e "${queue_sha}^{commit}" 2>/dev/null; then
    if [ "$queue_sha" = "$merge_sha" ]; then
      note "  NOTE  main fast-forwarded to the queue head itself"
    else
      note "  NOTE  main got a new commit, not the queue head"
    fi
    # The assertion that actually matters: same tree, regardless of commit identity.
    check "landed tree == validated tree" \
      "$(git rev-parse "${queue_sha}^{tree}")" "$(git rev-parse "${merge_sha}^{tree}")"
  else
    note "  SKIP  tree comparison: object ${queue_sha} not present locally"
  fi
fi

note "--- main history ---"
git --no-pager log --graph --parents --oneline -6 origin/main

exit "$fail"
