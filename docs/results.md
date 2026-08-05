# Observation log

Fill in as scenarios run. Dates absolute.

## Environment

- Repo: `The-OpenROAD-Project/ci-testing` (public — required, org is on `team`)
- Actions check: `ci`
- Jenkins: public instance, standalone multibranch job, context `jenkins/ci`
  (route A — pipeline-posted). **Not yet configured** as of scenario 1.
- Ruleset id: `20469423`, `enforcement=active`. Required checks: `ci` only so
  far; `jenkins/ci` added later, after the Jenkins probe.

Confirmed on 2026-08-05: merge queue **is** available on a `team`-plan org for a
public repo. The plan restriction is about private repos only.

The ruleset blocks direct pushes to `main` for org admins too — the first thing
it caught was a maintenance commit to `scripts/mk-pr.sh`, which then had to go
through the queue itself (that became scenario 1). Worth knowing before enabling
this on a repo where someone expects to hotfix `main`.

## Scenarios

### 1. Baseline queue — **PASS** (2026-08-05, Actions only)

Run against PR #2 (`fix/mk-pr-rerunnable`) rather than a synthetic item PR,
because the ruleset had already blocked the direct push that change needed.
`SLEEP_SECONDS=60` (repo default).

- **Queue branch:**
  `gh-readonly-queue/main/pr-2-141870d0b65a77508a1fb6bf99532c5a315437be`
  → the trailing SHA is the **base branch head** at enqueue time (`141870d` was
  `main`), *not* the PR head. Confirmed by comparison with `main`'s log. Any
  tooling that parses these refs must not assume a PR SHA.
- **Queue branch head** `db4b4b0` became the merge commit on `main` verbatim —
  the queue fast-forwards `main` to the entry it validated, so the merged code
  is byte-identical to what CI tested. This is the property that PR-level CI
  cannot offer.
- **Actions:** both `merge_group` workflows ran on the queue ref — `CI` (`ci`,
  required) and `MQ debug` (observability). The `pull_request` run of `ci` was
  separate, so this PR consumed two `ci` runs total.
- **Jenkins:** not configured yet — n/a for this run.
- **Timeline:** `auto_merge_enabled` 17:48:04 → `added_to_merge_queue` 17:48:40
  → `removed_from_merge_queue` 17:50:48 → `merged` 17:50:49 →
  `head_ref_deleted` 17:50:50. **2m09s enqueue-to-merge** against a 60s check,
  so `min_entries_to_merge_wait_minutes: 2` dominated the wall clock, not CI.
- **Gotcha for observers:** `gh pr view` reported `state=OPEN` and the queue ref
  was still listed within the same minute the merge landed; `removed_from_merge_queue`
  and `merged` are 1s apart. Read the issue timeline
  (`gh api repos/.../issues/N/timeline`) for ground truth — polling
  `mergeStateStatus` mid-flight shows `BLOCKED`/`UNKNOWN` and reads like a
  failure when nothing is wrong.

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
