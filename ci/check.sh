#!/usr/bin/env bash
# Single source of truth for pass/fail in this test bed.
#
# Run verbatim by .github/workflows/ci.yml and by the Jenkinsfile, so any
# scenario behaves identically on both CI systems and differences in outcome
# are differences in the CI wiring, not in the check.

set -euo pipefail

cd "$(dirname "$0")/.."

# The committed config is the default; anything already in the environment wins,
# so a knob can be overridden for a one-off local run without editing the file.
_env_max="${MAX_ITEMS:-}"
_env_sleep="${SLEEP_SECONDS:-}"
_env_force="${FORCE_FAIL:-}"
_env_qonly="${QUEUE_ONLY_FAIL:-}"

# shellcheck source=ci/config.env
. ci/config.env

MAX_ITEMS="${_env_max:-${MAX_ITEMS:-2}}"
SLEEP_SECONDS="${_env_sleep:-${SLEEP_SECONDS:-60}}"
FORCE_FAIL="${_env_force:-${FORCE_FAIL:-0}}"
QUEUE_ONLY_FAIL="${_env_qonly:-${QUEUE_ONLY_FAIL:-0}}"

# Validate the knobs before anything uses them. `[ "$n" -gt "$m" ]` returns 2 on
# a non-integer operand, and `if` treats 2 as false — so a stray character
# (CRLF checkout, a typo, a sed-mangled value) SILENTLY SKIPS the item-count
# gate and the script prints PASS. Same for the sleep. `set -e` does not help:
# it is explicitly exempt inside an `if` condition. Fail loudly instead.
case "${MAX_ITEMS}${SLEEP_SECONDS}" in
  ''|*[!0-9]*)
    echo "FATAL: non-integer knob (MAX_ITEMS='${MAX_ITEMS}' SLEEP_SECONDS='${SLEEP_SECONDS}')" >&2
    echo "       refusing to run: a bad value would skip the gate and report PASS" >&2
    exit 2 ;;
esac
for _b in "FORCE_FAIL=$FORCE_FAIL" "QUEUE_ONLY_FAIL=$QUEUE_ONLY_FAIL"; do
  case "${_b#*=}" in
    0|1) ;;
    *) echo "FATAL: ${_b%%=*} must be 0 or 1, got '${_b#*=}'" >&2
       echo "       (FORCE_FAIL=true would run entirely green and read as 'no eviction')" >&2
       exit 2 ;;
  esac
done

# --- context detection -------------------------------------------------------
# Actions sets GITHUB_*; Jenkins multibranch sets BRANCH_NAME / GIT_COMMIT.
event="${GITHUB_EVENT_NAME:-}"
ref="${GITHUB_REF:-${BRANCH_NAME:-}}"
sha="${GITHUB_SHA:-${GIT_COMMIT:-$(git rev-parse --verify -q HEAD 2>/dev/null || echo unknown)}}"

if [ -n "${JENKINS_URL:-}" ]; then
  system="jenkins"
elif [ -n "${GITHUB_ACTIONS:-}" ]; then
  system="actions"
else
  system="local"
fi

# A merge-queue run is either the Actions merge_group event, or a branch build
# of the ephemeral gh-readonly-queue/<base>/pr-N-<sha> ref that GitHub pushes
# for third-party CI.
in_queue=0
case "$event" in merge_group) in_queue=1 ;; esac
case "$ref" in
  refs/heads/gh-readonly-queue/*|gh-readonly-queue/*) in_queue=1 ;;
esac

# Parent count proves *what tree* is under test. Both CI systems build a PR as
# the PR merged with its target (Actions checks out refs/pull/N/merge; the
# Jenkins PR job uses "merging the PR with the current target branch revision"),
# so a PR run must show 2 parents. One parent on a PR run would mean the branch
# is being tested in isolation and the queue gate is worthless.
# `cut -s` so a parentless line yields empty instead of echoing HEAD back as if
# it were its own parent (root commit, or a shallow graft).
parents="$(git rev-list --parents -1 HEAD 2>/dev/null | cut -s -d' ' -f2- || echo '')"
nparents="$(printf '%s' "$parents" | wc -w | tr -d ' ')"
merge_build=no
[ "$nparents" -ge 2 ] && merge_build=yes
# A shallow clone truncates HEAD's parents, so a genuine merge commit reports
# one parent. Report "unknown", not "no": "no" asserts the CI is testing the
# branch in isolation, and a false alarm there invites someone to "fix" the PR
# discovery strategy and destroy the real gate.
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
  merge_build=unknown
fi

echo "=============================================="
echo " ci/check.sh"
echo " system      : $system"
echo " event       : ${event:-<none>}"
echo " ref         : ${ref:-<none>}"
echo " sha         : $sha"
echo " parents     : ${nparents} ${parents:+(${parents})}"
echo " merge build : $merge_build  <- yes = testing the merged tree, not the branch alone"
echo " merge queue : $in_queue"
echo " config      : MAX_ITEMS=$MAX_ITEMS SLEEP_SECONDS=$SLEEP_SECONDS" \
     "FORCE_FAIL=$FORCE_FAIL QUEUE_ONLY_FAIL=$QUEUE_ONLY_FAIL"
echo "=============================================="

# The commit stack proves what the queue actually batched: a speculative entry
# contains the PRs ahead of it in the queue, not just its own commit.
echo "--- last commits ---"
git --no-pager log --oneline -10 || true

echo "--- items ---"
ls -1 items/ || true
count=$(find items -maxdepth 1 -name '*.txt' | wc -l | tr -d ' ')
echo "item count: $count (max $MAX_ITEMS)"

# --- padding -----------------------------------------------------------------
if [ "$SLEEP_SECONDS" -gt 0 ]; then
  echo "sleeping ${SLEEP_SECONDS}s (queue-formation window)"
  sleep "$SLEEP_SECONDS"
fi

# --- verdicts ----------------------------------------------------------------
rc=0

if [ "$FORCE_FAIL" = "1" ]; then
  echo "FAIL: FORCE_FAIL=1"
  rc=1
fi

if [ "$QUEUE_ONLY_FAIL" = "1" ] && [ "$in_queue" = "1" ]; then
  echo "FAIL: QUEUE_ONLY_FAIL=1 and this is a merge-queue run"
  rc=1
fi

if [ "$count" -gt "$MAX_ITEMS" ]; then
  echo "FAIL: $count items exceeds MAX_ITEMS=$MAX_ITEMS"
  echo "      (semantic conflict — each PR was under the limit on its own)"
  rc=1
fi

if [ "$rc" = "0" ]; then
  echo "PASS"
fi
exit "$rc"
