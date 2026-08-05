# ci-testing

Throwaway repo for exercising **GitHub's merge queue** against both CI systems
used by OpenROAD:

- **GitHub Actions** — via the `merge_group` event (`.github/workflows/ci.yml`)
- **Jenkins** (public instance) — via branch builds of the ephemeral
  `gh-readonly-queue/<base>/pr-N-<sha>` refs (`Jenkinsfile`)

`<sha>` there is the **base branch head** at enqueue time, not the PR head —
verified in `docs/results.md` scenario 1. Don't build tooling that assumes
otherwise.

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
   Requiring either name alone deadlocks the other side. Solved server-side with
   the *Custom Github Notification Context* trait, suffix off, so every job type
   posts one `Public CI` — and exactly one job may write it per commit.
   → `docs/jenkins-setup.md`

## Layout

```
ci/check.sh              the only pass/fail logic; run verbatim by BOTH CIs
ci/config.env            MAX_ITEMS, SLEEP_SECONDS, FORCE_FAIL, QUEUE_ONLY_FAIL
items/*.txt              one file per test PR; the count is what check.sh gates on
.github/workflows/ci.yml required check `ci` (pull_request + merge_group + push)
.github/workflows/mq-debug.yml  merge_group observability, not required
Jenkinsfile              k8sPodTemplate + ci/check.sh (status comes from the plugin)
scripts/                 drivers: mk-pr, queue-prs, watch-queue, verify-merge, fake-queue-branch
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
| 5 | Jenkins gating | require `Public CI`, then disable the Jenkins job | queue waits, evicts at `check_response_timeout_minutes` |
| 6 | Jenkins-only probe | `scripts/fake-queue-branch.sh` | Jenkins indexes and builds a synthetic queue ref and posts status — no queue needed |
| 7 | pr-merge gate | PR with `MAX_ITEMS=<n>`, land another PR to move the base, then push an empty commit | rebuilt merge-with-target goes red and the PR **never enters the queue**; "Merge when ready" can still be clicked, which is the point |
| 8 | Merge-commit shape | any queue run + `scripts/verify-merge.sh <pr>` | `main` gets a 2-parent commit whose second parent is the PR head, and whose **tree** equals the queue entry CI validated |

Watch any of them with:

```bash
scripts/watch-queue.sh        # queue refs, per-SHA contexts, PR auto-merge state
```

`watch-queue.sh` also records every queue head it sees to `.mq-queue-log`
(gitignored) and fetches the objects, because GitHub deletes those refs seconds
after an entry merges — without that, scenario 8's tree comparison is impossible.

## Merge method

Merge commits, enforced in three places: queue `merge_method: MERGE`, ruleset
`allowed_merge_methods: ["merge"]`, and squash/rebase disabled on the repo. The
earlier results in `docs/results.md` marked *squash-era* were taken under
`SQUASH`, where the queue-branch head became `main`'s commit verbatim; that
specific property does not carry over.

## The pr-merge gate

Both CI systems already test the **merged** tree on a PR, not the branch alone —
Actions' `pull_request` event runs against `refs/pull/N/merge`, and the Jenkins PR
job uses *Merging the pull request with the current target branch revision*. So
`ci` and `Public CI` on a PR head are pr-merge results, and since both are
required, a PR cannot enter the queue until they pass.

Two things worth being precise about:

- **"Merge when ready" is always clickable.** Per GitHub's docs, you may click it
  before requirements pass; GitHub adds the PR to the queue *when they are met*.
  The gate is entry into the queue, not the button.
- **A PR-only required check would deadlock the queue.** Any required context
  that never reports on `merge_group` stalls every entry for
  `check_response_timeout_minutes` and then evicts it. That is why the gate is the
  same shared context on both sides rather than a separate `pr-merge` check.

`ci/check.sh` prints `merge build : yes|no` from HEAD's parent count on every run,
so a regression to branch-only testing is visible in the log.

Local sanity check of the logic itself:

```bash
SLEEP_SECONDS=0 ./ci/check.sh
```

Record outcomes in `docs/results.md`.
