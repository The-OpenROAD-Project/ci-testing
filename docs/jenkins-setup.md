# Jenkins setup (public instance)

Jenkins job and branch-source configuration on these controllers is **UI-only,
unversioned state on the controller VM** — there is no JCasC/Job DSL/Terraform
for it (the provisioner only pushes k8s clouds and two credentials via the
Script Console). This file exists so the configuration is at least reproducible.

Target instance: public Jenkins, `jenkins.openroad.tools`, which scans the
`The-OpenROAD-Project` org (`jenkins-ci/vars/utilGetRepoURL.groovy`).

## Use a standalone Multibranch Pipeline, not the org folder

Behaviours on the shared GitHub Organization folder apply to **every** repo it
scans, so experimenting there — especially route B below — would change status
contexts for OpenROAD / ORFS / OpenSTA as a side effect. Build a dedicated job.

## Steps

1. **New Item** → name `ci-testing` → **Multibranch Pipeline** → OK.
   (Place it beside the existing repo jobs; the `DevOps/<job>` folder convention
   is visible in `jenkins-ci/vars/utilGetJobFolderName.groovy`.)

2. **Branch Sources** → **Add source** → **GitHub**
   - *Credentials*: `openroad-ci`
   - *Repository HTTPS URL*: `https://github.com/The-OpenROAD-Project/ci-testing`
   - **Validate** must come back green — that proves the credential can see the
     repo.

3. **Behaviours** — this is what decides whether merge queue works at all.
   - **Discover branches** → strategy **Exclude branches that are also filed as
     PRs**.
     Queue refs `gh-readonly-queue/main/pr-N-<base-sha>` are ordinary branches,
     not PR heads, so they are still discovered. Do **not** use *All branches*:
     with a single shared status context (below), the branch job and the PR job
     both write that context on the same commit and the later one wins, masking
     the other's result. Observed on 2026-08-05 — see `docs/results.md`
     scenario 6.
   - **Discover pull requests from origin** → **Merging the pull request with
     the current target branch revision**. Without PR jobs, the shared context
     never lands on a PR head and no PR can enter the queue.
   - **Add → Custom Github Notification Context**, label `Public CI`, with
     **"Use job type as context suffix" UNCHECKED**. This is what makes one
     context cover PR jobs, branch jobs and queue-ref jobs — see the section
     below.
   - Do **not** add *Filter by name (with wildcards)*. It filters **all** SCM
     heads, not just branches: PRs are heads named `PR-<n>`, so an include list
     of `main gh-readonly-queue/main/**` silently hides every pull request
     (observed here as *Pull Requests (0)* with an open PR). Queue-ref discovery
     needs no filter at all.

4. **Build Configuration**: *by Jenkinsfile*, Script Path `Jenkinsfile`.

5. **Scan Multibranch Pipeline Triggers**: check **Periodically if not otherwise
   run**, interval **1 minute**. Webhooks are the real trigger; this is only a
   backstop, and anything slower than a minute is useless against branches that
   exist for a couple of minutes.

6. **Orphaned Item Strategy**: **Discard old items**, *Days to keep* `1`,
   *Max # of old items to keep* `10`.
   Every queue entry leaves behind a branch job that is orphaned the moment
   GitHub deletes the ref. Without pruning these grow without bound — a real
   finding for the production repos, not just test hygiene.

7. **Save**. The initial scan builds `main`. Confirm the `Public CI` context
   appears on the `main` commit in GitHub:
   ```bash
   gh api repos/The-OpenROAD-Project/ci-testing/commits/main/status \
     -q '.statuses[] | "\(.context)=\(.state)"'
   ```

8. **Webhook check** — GitHub repo → *Settings* → *Webhooks*: a hook to
   `https://jenkins.openroad.tools/github-webhook/`, content type
   `application/json`, delivering at least **push**, **pull request**,
   **create**, **delete**. Jenkins creates it automatically if the credential
   holds `admin:repo_hook` and *Manage Jenkins → System → GitHub Servers* has
   "Manage hooks" enabled; otherwise add it by hand.
   `merge_group` is a GitHub Actions concern — Jenkins is driven by the **push**
   to the queue branch.

9. If this is ever applied to the shared org folder instead of a standalone job,
   update branch protection **first** or open PRs block on contexts nobody posts
   — same ordering warning as
   `archive/jenkins-ci/github-status-context-migration.md`.

## Why one unsuffixed context, and why not per-job-type

By default the GitHub Branch Source plugin posts per-job-type contexts:
`continuous-integration/jenkins/pr-merge` on PR jobs,
`continuous-integration/jenkins/branch` on branch jobs. GitHub applies **one**
required-status-checks list to both PR gating and merge-group validation, so
under a merge queue:

- require `.../pr-merge` → queue entries never get it → queue times out;
- require `.../branch` → PR heads never get it → PRs can never be queued.

The fix is the *Custom Github Notification Context* trait with the job-type
suffix **off**: every job type posts the same `Public CI`, which satisfies both
sides. This is the recommended configuration.

Two rejected alternatives, for the record:

- **Pipeline-posted context (`githubNotify` or a raw statuses-API call in the
  `Jenkinsfile`).** Tried first, since it needs no server-side config. Failed on
  this instance twice over: no `jq` on the jnlp agent, and the `github-token`
  credential is a fine-grained PAT that returns 403 *"Resource not accessible by
  personal access token"* on the statuses API — a different identity from the
  classic token behind `openroad-ci`. Viable only with a token fixed for
  commit-status write, and it duplicates what the trait already does.
- **Per-stage GitHub Checks (`withChecks`).** Needs a GitHub App credential and
  two distinct apps across the two controllers, per
  `archive/jenkins-ci/github-status-context-migration.md`.

**The trap that comes with one shared context:** exactly one job must write it
per commit. With *Discover branches: All branches*, a PR head is built by both a
branch job and a PR job; both post `Public CI` on the same SHA and the later
write wins, masking the other result. Hence *Exclude branches that are also filed
as PRs* in step 3.

## Verified on 2026-08-05 (job `DevOps/ci-testing-Public`)

- **Queue-ref discovery needs nothing special.** Jenkins picked up and built
  every `gh-readonly-queue/main/pr-N-<base>` ref, including ones that existed for
  only ~2 minutes. The `gh-readonly-queue/main/**` name filter is optional, not
  load-bearing.
- **The CI identity needs write access on the repo.** `openroad-ci` had admin on
  `OpenROAD` but was not a collaborator on this repo, and the repo had no teams —
  so Jenkins cloned fine (public repo, no creds needed) and every statuses-API
  POST was rejected. Builds stayed green with zero statuses on GitHub:
  ```bash
  gh api -X PUT repos/The-OpenROAD-Project/ci-testing/collaborators/openroad-ci \
    -f permission=push
  ```
- **A wildcard name filter hides pull requests.** The job showed
  *Pull Requests (0)* with an open PR, because the filter applies to all SCM
  heads and PRs are heads named `PR-<n>`. Removing the filter fixed it.
- **One context, two writers.** With *All branches*, PR #5's head got
  `Public CI=error` from job `PR-5` (18:11:14) and `Public CI=success` from job
  `mq-test/bravo` (18:11:38). Both were individually correct — the PR job builds
  merged-with-target (3 items, fails), the branch job builds the branch alone
  (2 items, passes) — but the second overwrote the first, so GitHub showed
  green. Fixed by *Exclude branches that are also filed as PRs*.
- **Orphaned jobs pile up immediately** — five struck-through queue branches
  after three scenarios. The orphaned-item strategy in step 6 is mandatory.

## Known interactions (already verified against the shared library)

- `gh-readonly-queue/...` does not match the `PR-`/`pull/` special case in
  `jenkins-ci/vars/gitClone.groovy:22`, so a queue branch clones through the
  default `+refs/heads/*` refspec as a plain branch — correct.
- `utilIsTrunk()` is false for queue refs, so short artifact retention applies
  (`utilSetProperties`).
- The jnlp agent image (`us-docker.pkg.dev/foss-fpga-tools-ext-openroad/jenkins/jnlp-agent:latest`)
  has **no `jq`**. Anything in a pipeline that assumes it will fail with
  `jq: not found`.
- Both a PR job and a queue-branch job run for every merged PR, so CI cost per
  PR roughly doubles under a merge queue. Worth quantifying before enabling
  this on OpenROAD.
