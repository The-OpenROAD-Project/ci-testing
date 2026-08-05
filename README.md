# ci-testing

Throwaway repo for exercising **GitHub's merge queue** against both CI systems
used by OpenROAD:

- **GitHub Actions** — via the `merge_group` event (`.github/workflows/ci.yml`)
- **Jenkins** (public instance) — via branch builds of the ephemeral
  `gh-readonly-queue/<base>/pr-N-<sha>` refs (`Jenkinsfile`)

Nothing here is production. The point is to make every merge-queue behaviour
reproducible in minutes and to settle how Jenkins should report status under a
merge queue before touching the real repos.

## Two facts that shaped this setup

1. **Merge queue needs a public repo here.** It is available in public org repos
   or private repos on Enterprise Cloud; both OpenROAD orgs are on the `team`
   plan. Hence a public repo. → `docs/github-setup.md`
2. **Jenkins' default status contexts cannot gate both sides.** The GitHub
   Branch Source plugin posts `continuous-integration/jenkins/pr-merge` on PR
   jobs and `.../branch` on branch jobs, but GitHub applies one
   required-checks list to both PR gating *and* merge-group validation.
   Requiring either name alone deadlocks the other side, so the `Jenkinsfile`
   posts its own fixed `jenkins/ci` context instead. → `docs/jenkins-setup.md`

## Layout

```
ci/check.sh              the only pass/fail logic; run verbatim by BOTH CIs
ci/config.env            MAX_ITEMS, SLEEP_SECONDS, FORCE_FAIL, QUEUE_ONLY_FAIL
items/*.txt              one file per test PR; the count is what check.sh gates on
.github/workflows/ci.yml required check `ci` (pull_request + merge_group + push)
.github/workflows/mq-debug.yml  merge_group observability, not required
Jenkinsfile              k8sPodTemplate + ci/check.sh + `jenkins/ci` status
scripts/                 drivers: mk-pr, queue-prs, watch-queue, fake-queue-branch
docs/github-setup.md     repo + ruleset commands, ruleset knob meanings
docs/jenkins-setup.md    Jenkins Web UI walkthrough
docs/ruleset.json        the ruleset, re-appliable verbatim
docs/results.md          observation log
```

## Scenarios

Each is driven by committing a `ci/config.env` override on a PR branch, so
behaviour travels with the PR into the queue.

| # | Scenario | Drive it | Expect |
|---|---|---|---|
| 1 | Baseline | `scripts/mk-pr.sh one SLEEP_SECONDS=30` → `scripts/queue-prs.sh` | Actions `merge_group` run + Jenkins job on the queue ref; both green; merges |
| 2 | Speculative batching | 3 PRs with `SLEEP_SECONDS=180`, enqueued back to back | Several queue entries at once, each stacking the PRs ahead of it |
| 3 | Mid-queue eviction | middle PR gets `QUEUE_ONLY_FAIL=1` | green as a PR, red in the queue → evicted; others rebuilt without it |
| 4 | Semantic conflict | two PRs, each adding one item, `MAX_ITEMS=2` | each passes alone at 2 items, the batch fails at 3 — what PR-level CI cannot catch |
| 5 | Jenkins gating | require `jenkins/ci`, then disable the Jenkins job | queue waits, evicts at `check_response_timeout_minutes` |
| 6 | Jenkins-only probe | `scripts/fake-queue-branch.sh` | Jenkins indexes and builds a synthetic queue ref and posts status — no queue needed |

Watch any of them with:

```bash
scripts/watch-queue.sh        # queue refs, per-SHA contexts, PR auto-merge state
```

Local sanity check of the logic itself:

```bash
SLEEP_SECONDS=0 ./ci/check.sh
```

Record outcomes in `docs/results.md`.
