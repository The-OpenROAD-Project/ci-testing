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
# A missing comparison is a FAILED verification, never a pass. This check is the
# whole reason the script exists ("landed tree == validated tree"); if it cannot
# run, exiting 0 would report success having verified nothing — the same
# silent-green shape the Jenkinsfile was fixed for in scenario 6.
# A PR can have MORE THAN ONE queue entry: a speculative entry is discarded and
# rebuilt when something ahead of it fails (scenario 3 produced two for pr-20).
# `tail -1` would pick whichever the watcher happened to log last — ordered by
# ls-remote's lexicographic ref names, not by which one merged — and comparing
# against a discarded entry reports FAIL on the repo's headline claim. Prefer
# the entry whose head IS the merge commit; fall back only if none matches.
queue_sha="$(awk -v p="/pr-${pr}-" -v m="$merge_sha" '$2 ~ p && $1 == m {print $1}' "$QUEUE_LOG" 2>/dev/null | tail -1 || true)"
if [ -z "$queue_sha" ]; then
  queue_sha="$(awk -v p="/pr-${pr}-" '$2 ~ p {print $1}' "$QUEUE_LOG" 2>/dev/null | tail -1 || true)"
  [ -z "$queue_sha" ] || note "  NOTE  no logged entry matches the merge commit; using last-seen entry"
fi
if [ -z "$queue_sha" ]; then
  note "  FAIL  tree comparison NOT PERFORMED: no queue head for pr-${pr} in ${QUEUE_LOG}"
  note "        (run scripts/watch-queue.sh during the queue run to capture it)"
  fail=1
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
    note "  FAIL  tree comparison NOT PERFORMED: object ${queue_sha} was pruned"
    note "        (queue heads are unreachable objects; watch-queue.sh now pins"
    note "         them under refs/mq-queue/* so gc cannot collect them)"
    fail=1
  fi
fi

note "--- main history ---"
git --no-pager log --graph --parents --oneline -6 origin/main

exit "$fail"
