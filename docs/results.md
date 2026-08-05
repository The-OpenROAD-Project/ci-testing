# Observation log

Fill in as scenarios run. Dates absolute.

## Environment

- Repo: `The-OpenROAD-Project/ci-testing` (public — required, org is on `team`)
- Actions check: `ci`
- Jenkins: public instance, standalone multibranch job
  `DevOps/ci-testing-Public`, context **`Public CI`** (plugin trait, unsuffixed —
  route B; route A rejected, see scenario 6).
- Ruleset id: `20469423`, `enforcement=active`. Required checks: `ci` alone for
  scenarios 1 and 4; **`ci` + `Public CI`** from 2026-08-05 18:46 onward, so both
  CI systems gate the queue.
- `MAX_ITEMS` raised 2 → 8 after scenario 4, otherwise every later item PR fails
  on count and the batching/eviction runs are unreadable.

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

Once `openroad-ci` was granted `push` on the repo, statuses started flowing —
but from the **plugin**, not the pipeline: context `Public CI`, unsuffixed. The
*Custom Github Notification Context* trait was already configured on the job; it
had been failing silently for the same permission reason.

**Route A is dead.** The `main` build console (build #6) shows both of its
independent failure modes at once:

```
+ jq -n --arg s pending --arg c jenkins/ci ...
script.sh.copy: 2: jq: not found
+ code=403
status POST jenkins/ci=pending on 248f2e3… -> HTTP 403
{ "message": "Resource not accessible by personal access token", ... }
```

- The jnlp agent image has **no `jq`** — my assumption in the original design.
- `github-token` is a **fine-grained PAT** without commit-status write. It is a
  different identity from the classic token behind the `openroad-ci` credential
  that the plugin and all git operations use — so granting `openroad-ci` write
  did nothing for it.

The loud-failure rewrite did its job: instead of a green build with no status, it
surfaced the exact HTTP code and body. That diagnostic is the only reason this
was found in minutes rather than as a 15-minute queue stall in production.
`postStatus`/`ghApi` have since been removed from the `Jenkinsfile` entirely.

**New defect found — one context, two writers.** After PR discovery started
working, PR #5's head received `Public CI` twice:

| time | job | state | correct? |
|---|---|---|---|
| 18:11:14 | `PR-5` (merged with target, 3 items) | `error` | yes |
| 18:11:38 | `mq-test/bravo` (branch alone, 2 items) | `success` | yes |

Both results were right for what they built; the later write overwrote the
earlier, so GitHub displayed **green** for a PR whose merge-with-target build had
failed. Cause: *Discover branches: All branches* builds a PR head as a branch
*and* as a PR, and with the suffix disabled both write the same context name.
Fix: *Exclude branches that are also filed as PRs*.

Under a merge queue the consequence is bounded but real — such a PR enters the
queue on a false green, and the queue entry catches it, so `main` stays safe.
It burns a queue cycle and lies to the author.

Also confirmed as predicted: five orphaned (struck-through) queue-branch jobs
after three scenarios.

## Status-reporting decision

| | A: pipeline-posted `jenkins/ci` | B: unsuffixed plugin context `Public CI` |
|---|---|---|
| Server config needed | none | job/folder Behaviours |
| Works on this instance | **no** — no `jq`, and `github-token` 403s | **yes** |
| Credential | `github-token` (fine-grained PAT, insufficient) | `openroad-ci` (classic, already works) |
| Covers PR + branch + queue refs | by construction | **verified** — same name on all three |
| Blast radius | this repo only | every repo the folder scans (use a standalone job) |
| Extra failure surface | pipeline code, `jq`, token scope | none beyond the plugin |
| **Verdict** | **rejected** | **adopted** |

Route B wins outright here. Route A's only advantage — no server-side config —
does not survive contact with an agent image that lacks `jq` and a credential
that cannot write statuses. Required check name is therefore `Public CI`, and it
depends on exactly one job writing it per commit.

## Recommendation for the production repos

_TBD — write after scenarios 1-6 and the A/B comparison._

Open cost question to answer here: under a merge queue every PR is built twice
(PR job + queue entry), and speculative entries multiply that further. Quantify
against OpenROAD/ORFS CI durations before proposing the change.
