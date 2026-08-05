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

### 4. Semantic conflict — **PASS** (2026-08-05)

`MAX_ITEMS=2`, one baseline item. PR #4 `alpha` and PR #5 `bravo`, each adding
one file, enqueued back to back.

- **PR #4 `alpha`**: green as a PR, queue entry green, merged (`ab47802`).
- **PR #5 `bravo`**: PR-level `ci` **SUCCESS** — its branch was cut before
  `alpha` landed, so it saw 2 items. Queue entry
  `gh-readonly-queue/main/pr-5-ab47802` (base = `main` *with* `alpha`) saw 3
  items → `CI` **failure** → `removed_from_merge_queue` 17:59:02, not merged,
  auto-merge cleared.
- **Would PR-level CI have caught it? No.** Git saw no conflict either — the two
  PRs touch different files. Only the queue caught it. This is the value prop,
  demonstrated end to end.
- Aftermath, worth knowing: `bravo` is now permanently unmergeable (`main` is at
  the 2-item limit), so its author has to rebase and deal with it. The queue
  converts a latent broken-`main` into a stuck PR — which is the trade.
- Note these two did **not** co-batch: `pr-5`'s entry was based on `main` *after*
  `alpha` merged, i.e. the queue serialized them rather than speculating. With
  `min_entries_to_merge: 1` and a 60s check, `alpha` merged before `bravo` was
  enqueued. Scenario 2 needs `SLEEP_SECONDS=180` to force real overlap.

### 5. Jenkins gating / timeout — _pending_

Required checks include `jenkins/ci`; disable the Jenkins job (or the webhook)
and enqueue a PR.
Expected: the queue waits, then evicts at `check_response_timeout_minutes` (15).

- Observed wait:
- Queue message:

### 6. Jenkins discovery + status posting — **PARTIAL** (2026-08-05)

The synthetic probe turned out to be unnecessary: the real queue runs already
answered the discovery question. Job `DevOps/ci-testing-Public`.

**Works — the big unknown is settled:** Jenkins discovered and built **every**
`gh-readonly-queue/main/pr-N-<base>` ref with no special configuration —
`pr-2`, `pr-3`, `pr-4` green, `pr-5` red (correctly failing the 3-item count, so
`ci/check.sh` genuinely ran on the queue tree). Indexing kept up with refs that
exist for ~2 minutes.

**Broken — no commit status reached GitHub.** All four queue SHAs and PR #5's
head report `total_count: 0` statuses. Root cause:

- `openroad-ci` (the identity behind the `github-token` credential) has **admin
  on `OpenROAD` but is not a collaborator on `ci-testing`**, and `ci-testing` has
  no teams attached at all.
- The repo is public, so Jenkins could *clone* without credentials; only the
  *write* (statuses API) failed.
- The original `postStatus` used `curl -sS` with no status-code check, so a
  403/404 printed nothing and the build stayed **green**. Fixed: it now prints
  the HTTP code and response body and fails the build.

This is the exact failure mode that would hang a production merge queue for the
full `check_response_timeout_minutes` while Jenkins reports success — a silent
non-posting status is worse than a red build. Any real rollout needs the
loud-failure version.

**Second gap:** the job shows **Pull Requests (0)** with PR #5 open, so
"Discover pull requests from origin" is not in effect. Without PR jobs,
`jenkins/ci` never lands on a PR head, and making it required would block every
PR from being queued at all — the exact deadlock described in
`docs/jenkins-setup.md`. Must be fixed before step 6 of `docs/github-setup.md`.

**Third, as predicted:** the branch list already shows the four queue branches
struck through (orphaned) after two runs. Confirms the orphaned-item strategy is
mandatory, not hygiene.

Fixes required, in order:

```bash
# 1. let the CI identity write statuses on this repo
gh api -X PUT repos/The-OpenROAD-Project/ci-testing/collaborators/openroad-ci \
  -f permission=push
```

2. Job → Configure → Behaviours → add **Discover pull requests from origin**
   (*Merging the pull request with the current target branch revision*), re-scan,
   confirm the Pull Requests tab is non-empty.
3. Merge the loud-failure `Jenkinsfile`, re-run, confirm
   `status POST jenkins/ci=success on <sha> -> HTTP 201`.

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
