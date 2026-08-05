#!/usr/bin/env bash
# Create a test PR: adds items/<slug>.txt, optionally overriding ci/config.env.
#
#   scripts/mk-pr.sh alpha
#   scripts/mk-pr.sh bravo QUEUE_ONLY_FAIL=1
#   scripts/mk-pr.sh slow  SLEEP_SECONDS=180
#
# Config overrides are committed on the PR branch, so they apply to that PR and
# to any merge-queue branch that contains it.

set -euo pipefail
cd "$(dirname "$0")/.."

slug="${1:?usage: mk-pr.sh <slug> [KEY=VALUE ...]}"
shift

base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo main)"
branch="mq-test/${slug}"

git fetch origin "$base"

# Re-runnable: a scenario gets replayed a lot, so rebuild the branch from the
# current base instead of failing on leftovers from the previous run.
git switch --detach "origin/${base}"
git branch -D "$branch" 2>/dev/null || true
git switch -c "$branch"

printf 'item %s\n' "$slug" > "items/${slug}.txt"
git add "items/${slug}.txt"

restore=""
for kv in "$@"; do
  key="${kv%%=*}"
  val="${kv#*=}"
  if ! grep -qE "^${key}=" ci/config.env; then
    echo "no such knob in ci/config.env: ${key}" >&2
    exit 1
  fi
  # Remember the pre-override value: merging this PR makes the override the repo
  # default, and whoever cleans up needs to know what to put back.
  restore="${restore}${restore:+ }$(grep -E "^${key}=" ci/config.env | head -1)"
  # BSD and GNU sed disagree on -i, so rewrite via a temp file. -f because `mv`
  # is commonly aliased to `mv -i`, which would prompt and silently no-op the
  # override if this ever runs somewhere aliases are expanded.
  sed "s|^${key}=.*|${key}=${val}|" ci/config.env > ci/config.env.tmp
  mv -f ci/config.env.tmp ci/config.env
  echo "set ${key}=${val}"
done
git add ci/config.env

git commit -m "test(${slug}): add item$([ $# -gt 0 ] && echo " + $*")"

if [ -n "$restore" ]; then
  cat >&2 <<EOF

!! ci/config.env overrides are COMMITTED to this branch, so they become the repo
!! default if this PR merges. That is how main ended up with MAX_ITEMS=4 after
!! scenario 7 and SLEEP_SECONDS=180 after scenario 2.
!! Either close this PR when the scenario ends, or follow up with a PR restoring:
!!   ${restore}

EOF
fi

# The branch was rebuilt from base, so its history is not a fast-forward of any
# previous run of this scenario.
git push -u --force origin "$branch"

state="$(gh pr list --head "$branch" --state all --json number,state -q '.[0].state // ""')"
number="$(gh pr list --head "$branch" --state all --json number,state -q '.[0].number // ""')"

case "$state" in
  OPEN)
    echo "PR #${number} already open for ${branch}, updated in place"
    gh pr view "$number" --json url -q .url
    ;;
  CLOSED)
    echo "reopening closed PR #${number}"
    gh pr reopen "$number"
    gh pr view "$number" --json url -q .url
    ;;
  *)
    # No PR, or the previous one was MERGED (cannot be reopened) -> new PR.
    gh pr create --base "$base" --head "$branch" \
      --title "mq-test: ${slug}$([ $# -gt 0 ] && echo " ($*)")" \
      --body "Merge-queue test PR. Adds \`items/${slug}.txt\`.$([ $# -gt 0 ] && printf '\nOverrides: `%s`' "$*")"
    ;;
esac

git switch "$base"
