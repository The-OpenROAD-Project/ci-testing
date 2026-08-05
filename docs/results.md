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

## Merge method eras

Scenarios 1 and 4 below ran with `merge_method: SQUASH` — read them as
**squash-era**. One finding is specific to that method: the queue-branch head
became `main`'s commit verbatim. From 2026-08-05 the repo is **merge-commit
only** (queue `MERGE`, ruleset `allowed_merge_methods: ["merge"]`, squash/rebase
disabled on the repo), so everything from scenario 7 onward describes merge
commits, and scenario 8 re-establishes what actually lands.

## Scenarios

### 1. Baseline queue — **PASS** (2026-08-05, Actions only, squash-era)

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

### 4. Semantic conflict — **PASS** (2026-08-05, squash-era)

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

### 7. pr-merge gate blocks entry to the queue — **PASS** (2026-08-05, PR #11)

Purpose: prove the PR-level gate is a **merge-with-target** build, and that a red
one keeps the PR out of the queue.

Sequence as run (`main` at 2 items, `MAX_ITEMS=8`):

1. `scripts/mk-pr.sh foxtrot MAX_ITEMS=3` → 3 items, limit 3, green both alone and
   merged.
2. `scripts/mk-pr.sh golf`, queue **golf** alone → `main` goes to 3 items.
3. **7a, stale green:** foxtrot's checks are not re-run when the base moves, so it
   still shows green while its merged tree is now 4 items against a limit of 3.
   Enqueue is *accepted*; the queue entry is what fails. (Same effect bravo #5
   showed under squash — re-confirm under merge commits.)
4. **7b, fresh red — the gate:** `git commit --allow-empty` on foxtrot so both CIs
   rebuild the current merge ref → both red. Then enqueue and assert it never
   enters the queue: no `added_to_merge_queue` in the timeline, no
   `gh-readonly-queue/*` ref, `mergeStateStatus=BLOCKED`.
5. Unblock (merge `main` in, or raise `MAX_ITEMS`) → enqueues and merges, proving
   the gate releases as well as blocks.

**Result — the gate holds in both directions.**

**7a, stale green (observed, not merely reasoned about).** With `main` at 3 items
after golf (#12) landed, foxtrot (#11) still showed `ci` **pass** + `Public CI`
**pass**, while the union of its tree with `main` was 4 items against its own
`MAX_ITEMS=3`:

```
main items    : alpha baseline golf
foxtrot items : alpha baseline foxtrot
merged union  : alpha baseline foxtrot golf   -> 4 vs MAX_ITEMS=3
```

Nothing re-ran those checks when the base moved. Clicking Merge when ready here
would have enqueued the PR on that stale green, leaving the **queue entry** as
the only thing standing between it and a broken `main`.

**7b, fresh red — the gate.** An empty commit (`629fcf2`) forced both CIs onto
the current merge ref. `ci/check.sh` from the Actions log:

```
parents     : 2 (79f934cb… 629fcf2…)
merge build : yes  <- yes = testing the merged tree, not the branch alone
item count: 4 (max 3)
FAIL: 4 items exceeds MAX_ITEMS=3
```

The count of 4 is unreachable from foxtrot's branch alone (3 items), so the
gating build is provably the merged tree. Both checks went red
(`ci=FAILURE Public CI=ERROR`). Then `gh pr merge 11 --merge --auto`:

| assertion | result |
|---|---|
| `auto_merge_enabled` in timeline | present, 21:46:33 |
| `added_to_merge_queue` | **absent** |
| `gh-readonly-queue/*` refs | none |
| `mergeStateStatus` | `BLOCKED` |

**Step 5, release.** Raising foxtrot's `MAX_ITEMS` to 4 (`b038cde`) turned both
checks green; the still-armed auto-merge fired on its own, entry
`gh-readonly-queue/main/pr-11-79f934cb` (head `66f8f9ee`) appeared, and it merged.
So the gate releases as well as blocks — it is not simply a stuck PR.

Latency, from the timeline: Merge when ready was clicked at **21:46:33** with both
checks red, and the PR was held outside the queue for **20 minutes** — entering at
**22:06:35**, two seconds after the last required check turned green
(`Public CI` at 22:06:33). The hold is not a poll interval or a retry; it is the
merge request sitting armed until the gate opens.

**What this does and does not give you.** GitHub's docs are explicit that *"You
can click Merge when ready before all requirements pass"* — the button cannot be
disabled. The enforceable gate is **entry into the queue**, and it is enforced by
the ordinary required-status-checks list. Since both CI systems build PRs as
merged-with-target already (Actions checks out `refs/pull/N/merge`; the Jenkins
PR job uses *merging the PR with the current target branch revision*), the
existing `ci` + `Public CI` requirement **is** the pr-merge gate. No extra check
is needed — and a new required check that ran only on `pull_request` would stall
every merge group for `check_response_timeout_minutes`, so adding one would be
actively harmful.

**Trap this exposed.** A `ci/config.env` override used to shape a scenario
**lands on `main`** with the PR. After #11, `main` carries `MAX_ITEMS=4` with
exactly 4 items, so the next item PR would fail merged-with-target for reasons
unrelated to the test. Raise the limit on `main` before scenarios 2 and 3, and
treat per-branch overrides as temporary only for PRs that get closed, not merged.

### 8. What a merge-commit queue lands — **PASS** (2026-08-05, PR #9)

`scripts/verify-merge.sh 9`, all three assertions green:

```
  PR head      : 337c1ac
  merge commit : 38de906
  parents      : 2 (65aa7bf 337c1ac)
  PASS  merge commit has 2 parents
  PASS  second parent is the PR head
  NOTE  main fast-forwarded to the queue head itself
  PASS  landed tree == validated tree
```

- **The queue builds the merge commit itself**, inside the queue branch, before
  any check runs. The queue head `38de906` is titled *"Merge pull request #9
  from …"* with parents `65aa7bf` (`main`) + `337c1ac` (PR head). Under `SQUASH`
  that same position held a single-parent commit. So CI validates the exact
  commit object that will land, not merely an equivalent tree.
- **`main` fast-forwards to the queue head verbatim** — the same property as the
  squash era, so it is a merge-queue invariant rather than a merge-method
  artefact. `merge commit == queue head == what CI tested`.
- History shape is a normal merge bubble per entry:
  ```
  *   38de906 65aa7bf 337c1ac  Merge pull request #9 from ...
  |\
  | * 337c1ac 65aa7bf  ci: pivot merge queue to merge commits...
  |/
  * 65aa7bf 5912dad  ci: raise MAX_ITEMS to 8 (#8)   <- squash-era, single parent
  ```
- **Replicated on PR #12** (`golf`): merge commit `79f934c`, parents
  `f026c73` (`main`) + `3cfbcdc` (PR head), `main` again fast-forwarded to the
  queue head, tree identical. Three for three, so the shape is stable rather than
  a one-off.
- Speculative stacking with `max_entries_to_build: 5` is still unobserved — needs
  scenario 2 (three overlapping PRs).

**Both CI systems confirmed testing the merged tree**, from the `ci/check.sh`
parent block:

| event | parents | `merge build` | `merge queue` |
|---|---|---|---|
| `pull_request` | `65aa7bf 337c1ac` | yes | 0 |
| `merge_group` | `65aa7bf 337c1ac` | yes | 1 |

Identical parents in both, because `main` did not move between them — which is
exactly the setup in which stale green is invisible. When the base *does* move,
only the queue run's parents change; the PR run is not redone. That asymmetry is
the whole reason the queue exists, and scenario 7 exercises it deliberately.

### Aside: the merge-method flag is inert once a queue exists

`gh pr merge 9 --squash --auto` was **not rejected**, despite
`allowed_merge_methods: ["merge"]` and `allow_squash_merge=false`. GitHub replied
*"The merge strategy for main is set by the merge queue"* and enqueued the PR
normally; the queue's `merge_method` then decided. So per-PR method flags cannot
override a queue, and the repo/ruleset method restrictions are not enforced at
enqueue time — they matter for merges that bypass the queue. Verify method
behaviour by inspecting what lands, never by expecting the CLI to refuse.

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
