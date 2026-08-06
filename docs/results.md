# Observation log

Fill in as scenarios run. Dates absolute.

## Environment

- Repo: `The-OpenROAD-Project/ci-testing` (public — required, org is on `team`)
- Actions check: `ci`
- Jenkins: public instance, standalone multibranch job
  `DevOps/ci-testing-Public`, context **`Public CI`** (plugin trait, unsuffixed —
  route B; route A rejected, see scenario 6).
- Ruleset id: `20469423`, `enforcement=active`. Required checks: `ci` alone for
  scenarios 1 and 4; **`ci` + `Public CI`** from somewhere in
  **(18:33:38Z, 18:49:16Z]** onward, so both CI systems gate the queue. The
  ruleset API exposes only the latest `updated_at`, so the change cannot be
  timestamped exactly; the bracket comes from PR #7 merging 3s *before* its
  `Public CI` posted (so not yet required) and PR #8 merging 15s *after* its
  did. An earlier revision said "18:46", which was a `-03:00` local stamp
  mis-transcribed as UTC.
- `MAX_ITEMS` path: 2 → 8 (PR #8, deliberate) → **4 (PR #11, an accidental
  lowering that reverted #8)** → 12 (PR #13). Currently 12 with 9 items.
  Keep it above the item count or every item PR fails merged-with-target for
  reasons unrelated to the scenario under test.

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
  separate. **Three `ci` runs, not two:** `pull_request` 17:47:32,
  `merge_group` 17:49:01, and `push` to main 17:50:53 — the workflow also fired
  on `push: [main]` at the time. That third run was removed in PR #21; see the
  duplicate-writer finding in scenario 6.
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

### 2. Speculative batching — **PASS** (2026-08-05, merge-commit era)

PRs #14 `charlie`, #15 `delta`, #16 `echo`, all cut from `a788a1d` with
`SLEEP_SECONDS=180`, enqueued back to back by `scripts/queue-prs.sh`.

**Entries are speculative — each builds on the one ahead of it.** The base SHA in
each queue ref is the *previous entry's head*, not `main`:

| entry | ref base | = |
|---|---|---|
| `pr-14-a788a1d…` | `a788a1d` | `main` at enqueue |
| `pr-15-192ec44…` | `192ec44` | **pr-14's queue head** |
| `pr-16-407b5d6…` | `407b5d6` | **pr-15's queue head** |

So entry 3 was validated against a tree containing PRs 1 and 2. Note this is not
special to `SLEEP_SECONDS=180`: scenario 4 speculated at 60s too (that entry's
claim to the contrary has been retracted). The long check made the stacking
*easy to observe*, nothing more.

**Timings** (all three enqueued within 32s):

| PR | added | merged | total |
|---|---|---|---|
| #14 | 22:41:23 | 22:45:21 | 3m58s |
| #15 | 22:41:32 | 22:45:21 | 3m49s |
| #16 | 22:41:55 | 22:46:01 | 4m06s |

#14 and #15 merged in the **same second** — the queue merged a batch, not a
sequence. Three PRs landed in **4m38s** wall-clock against a 180s check.

Serialized comparison, measured rather than modelled: a lone entry with a 180s
check took **~4m15s** end to end (juliet's second entry, born ~03:00:52, merged
03:05:08), so three of them ≈ **12m45s** → **~2.75× speedup**. Do *not* model it
as `3 × (check + min_entries_to_merge_wait_minutes)`: scenario 1 shows a 60s
check plus a 2-minute wait producing 2m09s total, i.e. the wait overlaps the
check rather than adding to it.

**Resulting history** is a clean first-parent spine of merge commits, each PR's
own commit hanging off it:

```
*   fc3e369 407b5d6 4cac11c  Merge pull request #16 (echo)
|\
| * 4cac11c a788a1d          test(echo): add item
* |   407b5d6 192ec44 0f1cfb1  Merge pull request #15 (delta)
|\ \
| * | 0f1cfb1 a788a1d        test(delta): add item
* |   192ec44 a788a1d 637f471  Merge pull request #14 (charlie)
```

Note every PR head's parent is `a788a1d`: the branches were never rebased. The
queue built the *merge*, not a rewritten branch, which is why the PR commits keep
their original parentage.

**Jenkins under concurrent load:** three `gh-readonly-queue` jobs ran at once,
each holding a 2-CPU pod, and all reported in time — no agent-pool contention at
this size. That says nothing about OpenROAD-sized builds; the open question is
whether pods queue long enough to approach `check_response_timeout_minutes: 15`.

**Bug this run exposed — config overrides leak to `main`.** All three PRs merged,
so their `SLEEP_SECONDS=180` became the repo default, making every subsequent run
on every branch pay three minutes. Identical to the `MAX_ITEMS=4` leak after
scenario 7, so it is systemic, not a slip: `mk-pr.sh` must commit overrides for
them to travel into the queue, and merging the PR then promotes them. Mitigated
by having `mk-pr.sh` print the pre-override values and a restore reminder;
the real rule is **close scenario PRs rather than merging them** when they carry
overrides.

### 3. Mid-queue eviction — **PASS** (2026-08-06, merge-commit era)

PRs #18 `hotel`, #19 `india` (`QUEUE_ONLY_FAIL=1`), #20 `juliet`, all at
`SLEEP_SECONDS=180`, enqueued together.

**India was green as a PR and red only in the queue** — exactly the split
`QUEUE_ONLY_FAIL` exists to create:

```
Public CI  pass   .../job/PR-19/1/
ci         pass   3m3s
```

…yet it never merged. Timeline: `added_to_merge_queue` 02:56:39 →
`removed_from_merge_queue` **03:00:51**, no `merged` event. **Eviction latency
4m12s**, of which the check itself was 3m17s (02:56:48 → 03:00:05).

**Eviction is not immediate on failure — it happens on the queue's next tick.**
india's `ci` concluded 03:00:05 and `Public CI` errored 03:00:21, but removal
came at 03:00:51: **30–46s later**, in the same second PR #18 merged. Juliet's
first entry is the sharper case — it went red at 02:59:56, 55s before anything
moved. Budget for that lag when sizing `check_response_timeout_minutes`; a
failing entry occupies the queue for most of a minute after its verdict is
already public.

**The rebuild is the finding.** Queue heads recorded by `watch-queue.sh`:

| entry | base | contains |
|---|---|---|
| `pr-18-14e500a` | `main` | hotel |
| `pr-19-6d3f547` | pr-18's head | hotel + india |
| `pr-20-88c9660` | pr-19's head | hotel + india + juliet |
| **`pr-20-6d3f547`** | **pr-18's head** | **hotel + juliet — india dropped** |

Juliet's first entry was speculative on top of india, and **went red itself**
(`ci` FAILURE + `Public CI` error on `282360a`) because it inherited india's
`QUEUE_ONLY_FAIL=1` — that red is the mechanism that triggers the rebuild, not a
mark against juliet. When india failed, that entry was discarded and juliet's
was **rebuilt in place within ~3s** (the new entry's Actions run was created
03:00:54). Note juliet was *not* re-enqueued: its timeline has a single
`added_to_merge_queue` at 02:56:43 and no second one — the PR never left the
queue. An earlier revision said "re-entered 7 seconds later (03:00:58)", which
was `watch-queue.sh`'s poll timestamp, not the ref's birth; do not source
timings from `.mq-queue-log`. The rebuilt entry was based on hotel alone, then
merged as `b23f79d`. So a mid-queue failure costs the PRs behind it a rebuild,
not a rejection — nothing red ever landed on PR #20's own head, and `main` never
saw india's tree.

**Cost note for production sizing:** juliet was built twice — once speculatively
with india, once without. That is the price of speculation, and it scales with
how often entries fail. On a repo where a queue build costs an hour rather than
three minutes, `max_entries_to_build: 5` means up to five concurrent builds and a
re-run of everything behind any failure.

**Keep #19 open or close it — do not merge it.** Its branch carries
`QUEUE_ONLY_FAIL=1`; merging would make queue-only failure the repo default and
break every subsequent queue entry. Same class of leak as scenario 2's
`SLEEP_SECONDS`.

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
- Aftermath: `bravo` was unmergeable *until the limit moved* — `MAX_ITEMS` went
  to 8 at 18:51 the same evening, and it was simply closed at 22:37. The queue
  converts a latent broken-`main` into a stuck PR, which is the trade; "stuck"
  lasts only as long as the constraint does.
- **These two DID co-batch** — an earlier version of this entry claimed the
  opposite and it was wrong, with consequences. `bravo` was
  `added_to_merge_queue` at **17:57:19**, its entry was built at 17:57:37, and
  `alpha` merged at **17:59:02** — so bravo was enqueued 1m43s *before* alpha
  landed, and `ab47802` in its ref name is alpha's **queue head**, not "main
  after alpha merged". Speculation was already happening at `SLEEP_SECONDS=60`.
- The retracted claim caused real damage: it produced the conclusion "scenario 2
  needs `SLEEP_SECONDS=180` to force real overlap", scenario 2 was then run at
  180, and that override leaked onto `main` twice (see scenario 2). A wrong
  inference here became a config bug three hours later.

### 5. Jenkins unavailable — queue stalls, then evicts — **PASS** (2026-08-06)

PR #25 `lima`. Both required checks green on the PR head **first**, then the
Jenkins job disabled, *then* enqueued — so the entry was created with no Jenkins
in existence to build it.

```
added_to_merge_queue      11:44:37
removed_from_merge_queue  12:00:40      (no `merged` event)
queue head d85747b: ci=success, mq-debug=success, Public CI = ABSENT
PR #25 afterwards: OPEN, mergeStateStatus=CLEAN
```

- **Observed timeout: 16m03s** against `check_response_timeout_minutes: 15`. The
  extra ~1 minute matches the queue-tick latency measured in scenario 3 — the
  configured value is a floor, not a deadline.
- **A missing required check does not fail fast.** Actions finished in ~1 min and
  was green; the entry then sat for another 15 minutes on a context that was
  never going to arrive. GitHub cannot distinguish "provider is down" from
  "provider is slow".
- **The PR looks fine afterwards.** `mergeStateStatus=CLEAN`, both head checks
  green, no red anywhere — the author sees a healthy PR that silently did not
  merge. The only evidence is `removed_from_merge_queue` with no `merged`, in the
  timeline. Anyone monitoring PR state rather than queue events would miss this
  entirely.
- **Blast radius is the whole queue, not one PR.** The doomed entry occupies the
  queue for the full timeout, and everything behind it waits. With a 15-minute
  timeout and a provider that is down rather than flaky, throughput collapses to
  four merges/hour until someone notices and drops the requirement. That is the
  argument for keeping this timeout well under the "someone notices" time, not
  for making it generous.

**Two findings from the first, failed attempt (PR #24) — both worth keeping:**

1. **Disabling a Multibranch Pipeline does not abort in-flight builds.** The
   first attempt disabled Jenkins *after* `added_to_merge_queue`. Jenkins had
   already picked up the queue ref 33s later, and that build ran to completion
   and posted `Public CI=success` at 11:20:58 — the entry merged normally at
   11:21:06. Disabling a job is not an emergency stop for work already
   dispatched.
2. **The enqueue → Jenkins pickup window is ~33s**, so "disable it after you see
   the enqueue" is not a reliable way to starve an entry. Because required checks
   are evaluated on the **PR head**, the correct order is: get the head green,
   disable, *then* enqueue.

Not tested: whether a status stuck at `pending` (rather than absent) times out
identically. #24 suggests the stuck-pending path resolves whenever the build was
already dispatched, but a build that hangs forever was not exercised.

### 6. Jenkins discovery + status posting — **PARTIAL** (2026-08-05)

The synthetic probe turned out to be unnecessary: the real queue runs already
answered the discovery question. Job `DevOps/ci-testing-Public`.

**Works — the big unknown is settled:** Jenkins discovered and built **every**
`gh-readonly-queue/main/pr-N-<base>` ref with no special configuration.
Independently verifiable for pr-9, 11, 14, 15, 16, 18, 19 and both pr-20 entries
via `Public CI` statuses whose `target_url` points at the queue-ref job.
Indexing kept up with refs that exist for ~2 minutes.

*Unverifiable, recorded from the Jenkins UI at the time and not re-checkable —
the instance is not publicly reachable:* the specific "pr-2, pr-3, pr-4 green,
pr-5 red" reading (no statuses were posted then), the count of five orphaned
jobs, and the build-#6 console text quoted below. The build-#6 **outcome** is
verifiable and is the stronger citation: `Public CI = error` on `248f2e3` from
`job/main/6` at 18:09:22.

**Broken — no commit status reached GitHub.** All four queue SHAs and PR #5's
head reported `total_count: 0` statuses **as observed at ~18:0x, before the
permission fix** — both SHAs have statuses now, from later builds, so the claim
is only true with that timestamp attached. Root cause:

- `openroad-ci` **was not a collaborator on `ci-testing`**, and `ci-testing` has
  no teams attached at all. (Its access level on `OpenROAD` cannot be confirmed
  from here — `orgs/.../memberships/openroad-ci` needs `admin:org` and returns
  403; it is a plain org member. An earlier revision asserted "admin on
  OpenROAD" without evidence.) Note this identity backs the *plugin*; the
  `github-token` credential used by the old pipeline route is a different,
  fine-grained PAT — which is why granting `openroad-ci` push did not fix it.
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

**That fix was incomplete — the same defect has a second form, and it fires on
every merge.** Because the queue fast-forwards `main` to the queue head verbatim,
the merged SHA *is* both a queue head and `main`. Both CI systems then build it
again and rewrite the same required context. Measured on `0380065` (PR #21):

| time | writer | state |
|---|---|---|
| 09:25:38 | queue job `gh-readonly-queue/main/pr-21-b23f79d` | **success** ← the queue's verdict |
| 09:26:03 | Jenkins `main/19` | pending |
| 09:26:18 | Jenkins `main/19` | pending |
| 09:27:28 | Jenkins `main/19` | success |

For ~2 minutes after every merge, the validated SHA reads `pending`; if a `main`
build ever fails or flakes, a SHA the queue passed reads red permanently. The
Actions half was the same (`ci` ran on both `merge_group` and `push`) and was
removed in PR #21 by dropping `push: [main]` from `ci.yml`. **The Jenkins half is
still live** and needs `main` excluded from that job's branch discovery — it is
pure duplication, since the queue validated that exact commit.

Generalised for the production repos: *a branch or push build must never write a
context that the merge queue requires.* Under an unsuffixed shared context that
means the default branch itself must not be built by the same job.

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

`scripts/verify-merge.sh 9`, all three assertions green (SHAs abbreviated here;
the real output prints 40-char SHAs and a `queue head :` line before the NOTE):

```
  PR head      : 337c1ac
  merge commit : 38de906
  parents      : 2 (65aa7bf 337c1ac)
  PASS  merge commit has 2 parents
  PASS  second parent is the PR head
  queue head   : 38de906
  NOTE  main fast-forwarded to the queue head itself
  PASS  landed tree == validated tree
```

⚠️ **The third assertion is vacuous as written.** `verify-merge.sh` compares
`queue_sha^{tree}` against `merge_sha^{tree}`, and those have been the *same
commit* in every run to date — it compares a tree to itself. It can only fail if
`main` stops fast-forwarding to the queue head, which has never happened here.
Treat "landed tree == validated tree" as untested, not as evidence.

- **The queue builds the merge commit itself**, inside the queue branch, before
  any check runs. The queue head `38de906` is titled *"Merge pull request #9
  from …"* with parents `65aa7bf` (`main`) + `337c1ac` (PR head). Under `SQUASH`
  that same position held a single-parent commit. So CI validates the exact
  commit object that will land, not merely an equivalent tree.
- **`main` fast-forwards to the queue head verbatim** — the same property as the
  squash era. Observed on **16/16** merged PRs (#2 through #20) across both merge
  methods: every `merge_group` run's `headSha` equals the PR's `mergeCommit.oid`.
  Two caveats: two merge methods on one repo is not proof of a product
  invariant, and for co-merged batches the head becomes an *ancestor* rather
  than a tip — when #14 and #15 merged together, `192ec44` was never a `main`
  tip; the single push event was to `407b5d6`. Byte-identical either way.
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
  queue head, tree identical. **16/16 across every merged PR**, so the shape is
  stable rather than a one-off.
- Speculative stacking has since been observed in scenarios 2, 3 and 4, but never
  deeper than **3** entries. `max_entries_to_build: 5` remains untested at its
  limit — five overlapping PRs would be needed.

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
| Extra failure surface | pipeline code, `jq`, token scope | plugin only — **but silent**: see below |
| **Verdict** | **rejected** | **adopted, with a caveat** |

The "extra failure surface" row understates route B. Scenario 6 was diagnosed in
minutes precisely *because* route A's pipeline printed its own HTTP 403. With
posting delegated to the plugin, a rejected POST leaves a green build and no
status — the failure mode this very document calls "worse than a red build" —
and nothing in the pipeline can detect it. If route B goes to the production
repos, add a non-gating post-build read-back
(`gh api repos/$R/commits/$SHA/status`) so a missing context fails loudly.

Route B wins outright here. Route A's only advantage — no server-side config —
does not survive contact with an agent image that lacks `jq` and a credential
that cannot write statuses. Required check name is therefore `Public CI`, and it
depends on exactly one job writing it per commit.

## Recommendation for the production repos

All eight scenarios are complete. Summary of what a merge queue would buy and
cost OpenROAD, and what must be configured first.

### Does it work with our Jenkins? Yes, with three mandatory settings

1. **One status context, unsuffixed** — *Custom Github Notification Context*
   with the job-type suffix **off**, so PR jobs, branch jobs and
   `gh-readonly-queue/*` jobs all post the same name. The plugin's default
   per-job-type contexts (`.../pr-merge`, `.../branch`) **cannot** gate a merge
   queue: GitHub applies one required-checks list to both PR merges and merge
   groups, so requiring either name deadlocks the other side.
2. **Exactly one job may write that context per commit.** Two aliasing paths
   both violate this and both were observed here:
   - a PR head built as *both* a branch and a PR → fix with *Discover branches:
     Exclude branches that are also filed as PRs*;
   - the merged SHA is simultaneously a queue head **and** `main`, because the
     queue fast-forwards → fix by excluding `main` from discovery (name filter
     include `gh-readonly-queue/main/** PR-*`) and dropping `push: [main]` from
     the Actions workflow.
   Generalised: **a branch or push build must never write a context the merge
   queue requires.**
3. **The CI identity needs write access on the repo** (commit statuses). A
   public repo lets Jenkins clone with no credential, so this fails *only* on the
   write, and the plugin fails silently — green builds, no statuses.

Also required, and cheap: an orphaned-item discard policy. Every queue entry
leaves a dead branch job behind (28 jobs after ~20 entries here).

### What it costs

| | per PR |
|---|---|
| Actions runs | 2 (`pull_request` + `merge_group`) |
| Jenkins builds | 2 (PR job + queue job) |
| **total** | **4** — was 6 before the duplicate-writer fixes |

Speculation adds more: an entry behind a failure is rebuilt (scenario 3, juliet
built twice). Budget roughly *2× steady state, plus one extra build per PR behind
each failure*.

### What it buys

- **Catches semantic conflicts that PR CI structurally cannot** (scenario 4):
  two PRs, each green alone, red when combined, no textual conflict for git to
  find. This is the entire value proposition and it reproduces reliably.
- **~2.75× throughput vs serialized merging** at three concurrent PRs
  (4m38s vs ~12m45s measured, scenario 2), because entries build speculatively
  on top of each other rather than one at a time.
- **What lands is byte-identical to what was validated** — 16/16 merged PRs,
  `main` fast-forwarded to the exact queue head.

### The risks, in order

1. **A required-check provider that is down blocks the entire queue**, not just
   one PR, for `check_response_timeout_minutes` per entry (scenario 5: 16m03s
   observed at a 15-minute setting). At OpenROAD volume that is a merge freeze.
   Keep the timeout short and have a documented "drop the requirement" runbook.
2. **Silent failure is the dominant failure mode.** A green Jenkins build that
   posted no status, and an evicted PR that still reads `CLEAN`, both occurred
   here. Any rollout needs a post-build read-back asserting the context actually
   landed, and monitoring on `removed_from_merge_queue` **without** a following
   `merged`.
3. **Cost scales with queue-build duration.** Everything above was measured with
   a 60–180s check. An OpenROAD queue build is closer to an hour, so a
   5-deep speculative queue is 5 concurrent hour-long builds, and one failure
   rebuilds everything behind it.

### Suggested rollout order

Start with **one** repo and **Actions-only** required checks to prove the queue
mechanics, then add the Jenkins context once a read-back check is in place. Do
not enable it on a repo where anyone expects to push to the default branch
directly — the ruleset blocks admins too.

**Measured cost per PR**, corrected — the earlier "built twice" was wrong:

| | before PR #21 | now | achievable |
|---|---|---|---|
| Actions `ci` runs | 3 (`pull_request`, `merge_group`, `push`) | 2 | 2 |
| Jenkins builds | 3 (PR job, queue job, `main` job) | 3 | 2 |
| **total** | **6** | **5** | **4** |

The `push`/`main` builds are pure duplication: the queue validated that exact
commit object. Dropping `push: [main]` removed one; excluding `main` from the
Jenkins job removes the other. Speculation multiplies the queue-side number
further — scenario 3 shows an entry behind a failure gets rebuilt, so juliet was
built twice for one merge.

**Measured speedup:** three PRs merged in 4m38s vs ~12m45s serialized
(**~2.75×**), derived from a measured lone-entry cycle of ~4m15s, not from an
additive model — see scenario 2 for why the additive model is wrong.

Before proposing this for OpenROAD, weigh those against per-build cost there,
where a queue build is an hour rather than three minutes.
