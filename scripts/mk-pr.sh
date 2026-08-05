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
git switch -c "$branch" "origin/${base}"

printf 'item %s\n' "$slug" > "items/${slug}.txt"
git add "items/${slug}.txt"

for kv in "$@"; do
  key="${kv%%=*}"
  val="${kv#*=}"
  if ! grep -qE "^${key}=" ci/config.env; then
    echo "no such knob in ci/config.env: ${key}" >&2
    exit 1
  fi
  # BSD and GNU sed disagree on -i, so rewrite via a temp file.
  sed "s|^${key}=.*|${key}=${val}|" ci/config.env > ci/config.env.tmp
  mv ci/config.env.tmp ci/config.env
  echo "set ${key}=${val}"
done
git add ci/config.env

git commit -m "test(${slug}): add item$([ $# -gt 0 ] && echo " + $*")"
git push -u origin "$branch"

gh pr create --base "$base" --head "$branch" \
  --title "mq-test: ${slug}$([ $# -gt 0 ] && echo " ($*)")" \
  --body "Merge-queue test PR. Adds \`items/${slug}.txt\`.$([ $# -gt 0 ] && printf '\nOverrides: `%s`' "$*")"

git switch "$base"
