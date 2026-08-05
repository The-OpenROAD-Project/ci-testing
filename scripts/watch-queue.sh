#!/usr/bin/env bash
# Live view of the merge queue: live gh-readonly-queue refs, the commit stack of
# each entry, per-SHA status contexts (Actions check runs AND the Jenkins
# 'Public CI' status), and PR auto-merge state.
#
#   scripts/watch-queue.sh          # refresh every 15s until Ctrl-C
#   scripts/watch-queue.sh once

set -euo pipefail
cd "$(dirname "$0")/.."

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
interval=15
QUEUE_LOG=.mq-queue-log        # gitignored; consumed by scripts/verify-merge.sh

render() {
  echo "################ $(date '+%H:%M:%S')  ${repo}"

  echo "--- queue refs (git ls-remote) ---"
  refs="$(git ls-remote origin 'refs/heads/gh-readonly-queue/*' || true)"
  printf '%s\n' "$refs"

  # Record every queue head seen, once. GitHub deletes these refs seconds after
  # the entry merges, so verify-merge.sh cannot compare the landed tree against
  # the validated one unless they are captured live. Also fetch the objects, or
  # the SHAs become unresolvable locally the moment the ref is gone.
  printf '%s\n' "$refs" | while read -r sha ref; do
    [ -n "${sha:-}" ] || continue
    if ! grep -q "^${sha} " "$QUEUE_LOG" 2>/dev/null; then
      printf '%s %s %s\n' "$sha" "${ref#refs/heads/}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$QUEUE_LOG"
      git fetch -q origin "$sha" 2>/dev/null || git fetch -q origin "${ref#refs/heads/}" 2>/dev/null || true
    fi
  done

  # All open PRs, not just mq-test/*: a fixture change routed through the queue
  # is a test run too. mergeStateStatus reads BLOCKED/UNKNOWN mid-flight even
  # when nothing is wrong, so treat it as a hint, not a verdict.
  echo "--- open PRs ---"
  gh pr list --state open --json number,headRefName,mergeStateStatus,autoMergeRequest \
    -q '.[] | "#\(.number) \(.headRefName) merge_state=\(.mergeStateStatus) auto=\(.autoMergeRequest != null)"' || true

  # Ground truth for what the queue actually did, unlike polled PR state:
  # removed_from_merge_queue and merged land ~1s apart.
  echo "--- recent queue timeline events ---"
  for n in $(gh pr list --state all -L 5 --json number -q '.[].number'); do
    gh api "repos/${repo}/issues/${n}/timeline" --paginate \
      -q '.[] | select(.event | test("merge_queue|^merged$")) | "  #'"${n}"' \(.event) \(.created_at)"' \
      2>/dev/null | tail -4
  done

  echo "--- status contexts per queue entry ---"
  # Combined status = the legacy statuses API (where Jenkins reports); check-runs
  # = Actions. The queue needs every REQUIRED name, from either source, on the
  # queue branch head.
  while read -r sha ref; do
    [ -n "${sha:-}" ] || continue
    echo "  ${ref#refs/heads/}"
    echo "    commits: $(gh api "repos/${repo}/commits/${sha}" -q '.commit.message' 2>/dev/null | head -1)"
    gh api "repos/${repo}/commits/${sha}/status" \
      -q '"    combined=\(.state)", (.statuses[]? | "      [status] \(.context) \(.state)")' 2>/dev/null || true
    gh api "repos/${repo}/commits/${sha}/check-runs" \
      -q '(.check_runs[]? | "      [check]  \(.name) \(.status)/\(.conclusion // "-")")' 2>/dev/null || true
  done < <(git ls-remote origin 'refs/heads/gh-readonly-queue/*' | awk '{print $1, $2}')

  echo "--- recent merge_group workflow runs ---"
  gh run list --event merge_group -L 5 \
    --json displayTitle,status,conclusion,headBranch \
    -q '.[] | "  \(.status)/\(.conclusion // "-") \(.headBranch)"' || true
  echo
}

if [ "${1:-loop}" = "once" ]; then
  render
  exit 0
fi

while true; do
  render
  sleep "$interval"
done
