# Observation log

Fill in as scenarios run. Dates absolute.

## Environment

- Repo: `The-OpenROAD-Project/ci-testing` (public — required, org is on `team`)
- Actions check: `ci`
- Jenkins: public instance, standalone multibranch job, context `jenkins/ci`
  (route A — pipeline-posted)
- Ruleset id: _TBD_

## Scenarios

### 1. Baseline queue — _pending_

One PR, `SLEEP_SECONDS=30`.
Expected: Actions `merge_group` run + a Jenkins branch job on
`gh-readonly-queue/main/pr-N-<sha>`; both green; PR merges.

- Queue branch name observed:
- Actions run:
- Jenkins job:
- Time from enqueue to merge:

### 2. Speculative batching — _pending_

Three PRs enqueued inside one CI duration (`SLEEP_SECONDS=180`).
Expected: up to `max_entries_to_build` (5) entries build concurrently, each
stacking the PRs ahead of it. `mq-debug` prints
`git log base_sha..HEAD` — that output is the evidence.

- Entries created:
- Commit stack per entry:
- Merge order:

### 3. Mid-queue eviction — _pending_

PR2 with `QUEUE_ONLY_FAIL=1`; enqueue PR1, PR2, PR3.
Expected: PR2 green as a PR, red in the queue, evicted; PR1 merges; PR3 rebuilt
on a fresh entry without PR2.

- PR2 PR-level result / queue result:
- Did PR3 get a new queue branch:
- Eviction latency:

### 4. Semantic conflict — _pending_

`MAX_ITEMS=2`, one baseline item; PR A and PR B each add one item. Each is at 2
items alone (pass); the entry containing both is at 3 (fail). No textual
conflict — separate files.

- Which PR failed:
- Would PR-level CI alone have caught it: _expected no — this is the value prop_

### 5. Jenkins gating / timeout — _pending_

Required checks include `jenkins/ci`; disable the Jenkins job (or the webhook)
and enqueue a PR.
Expected: the queue waits, then evicts at `check_response_timeout_minutes` (15).

- Observed wait:
- Queue message:

### 6. Jenkins-only probe — _pending_

`scripts/fake-queue-branch.sh` — no real queue involved.

- Was a push to `gh-readonly-queue/*` accepted, or did it fall back to `mq-sim/*`:
- Did Jenkins index the branch, and how fast (webhook vs 1-min scan):
- Did `github-token` post the status (`status POST 201`):

## Route A vs route B

| | A: pipeline-posted `jenkins/ci` | B: unsuffixed plugin context |
|---|---|---|
| Server config needed | none | org folder / job Behaviours |
| Blast radius | this repo only | every repo the folder scans |
| Correct SHA on PR jobs | explicit head lookup | plugin's own choice |
| Failure mode if pipeline dies early | covered by `catch` | plugin still reports |
| Verdict | _TBD_ | _TBD_ |

## Recommendation for the production repos

_TBD — write after scenarios 1-6 and the A/B comparison._

Open cost question to answer here: under a merge queue every PR is built twice
(PR job + queue entry), and speculative entries multiply that further. Quantify
against OpenROAD/ORFS CI durations before proposing the change.
