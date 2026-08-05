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
   - **Discover branches** → strategy **All branches**.
     The queue refs `gh-readonly-queue/main/pr-N-<sha>` are ordinary branches,
     not PR heads, so "Exclude branches that are also filed as PRs" does not
     hide them — but *All branches* removes all doubt.
   - **Discover pull requests from origin** → **Merging the pull request with
     the current target branch revision**.
     This is why the `Jenkinsfile` resolves the PR head SHA via the API: with
     this strategy `GIT_COMMIT` is a throwaway merge commit, and a status posted
     there gates nothing.
   - Recommended: **Add → Filter by name (with wildcards)**, *Include*:
     ```
     main gh-readonly-queue/main/**
     ```
     Keeps the job from indexing every scratch branch while still admitting
     queue refs. Get this pattern wrong and the merge queue simply never
     receives a Jenkins status. (The filter applies to branches, not PRs.)
   - Do **not** add *Custom Github Notification Context* yet — that is route B.

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

7. **Save**. The initial scan builds `main`. Confirm in the build log:
   - `status POST 201` from the `postStatus` helper, and
   - the `jenkins/ci` context on the `main` commit in GitHub.

8. **Webhook check** — GitHub repo → *Settings* → *Webhooks*: a hook to
   `https://jenkins.openroad.tools/github-webhook/`, content type
   `application/json`, delivering at least **push**, **pull request**,
   **create**, **delete**. Jenkins creates it automatically if the credential
   holds `admin:repo_hook` and *Manage Jenkins → System → GitHub Servers* has
   "Manage hooks" enabled; otherwise add it by hand.
   `merge_group` is a GitHub Actions concern — Jenkins is driven by the **push**
   to the queue branch.

9. **Route B, only after route A is proven working.** On a clone of this job (or
   the org folder, accepting the blast radius): *Configure* → Behaviours →
   **Add → Custom Github Notification Context**, label `Public CI`, and leave
   **"Use job type as context suffix" unchecked** so PR and branch jobs share
   one context. Re-scan and compare with route A in `docs/results.md`.
   If done on the shared org folder, update branch protection **first** or open
   PRs block on contexts nobody posts — same ordering warning as
   `archive/jenkins-ci/github-status-context-migration.md`.

## Why the Jenkinsfile posts its own status (route A)

The GitHub Branch Source plugin posts per-job-type contexts:
`continuous-integration/jenkins/pr-merge` on PR jobs,
`continuous-integration/jenkins/branch` on branch jobs. GitHub applies **one**
required-status-checks list to both PR gating and merge-group validation, so:

- require `.../pr-merge` → queue entries never get it → queue times out;
- require `.../branch` → PR heads never get it → PRs can never be queued.

Route A posts `jenkins/ci` from the pipeline on every job type, which satisfies
both. Route B achieves the same with an unsuffixed plugin context instead.

## Known interactions (already verified against the shared library)

- `gh-readonly-queue/...` does not match the `PR-`/`pull/` special case in
  `jenkins-ci/vars/gitClone.groovy:22`, so a queue branch clones through the
  default `+refs/heads/*` refspec as a plain branch — correct.
- `utilIsTrunk()` is false for queue refs, so short artifact retention applies
  (`utilSetProperties`).
- The Jenkinsfile needs `jq` and `curl` on the jnlp agent image. If `jq` is
  absent, build the JSON body with `printf` instead.
- Both a PR job and a queue-branch job run for every merged PR, so CI cost per
  PR roughly doubles under a merge queue. Worth quantifying before enabling
  this on OpenROAD.
