# GitHub setup

## Why this repo is public

Merge queue is available in **public** org repos, or private repos on
**Enterprise Cloud**. Both `The-OpenROAD-Project` and
`The-OpenROAD-Project-private` are on the `team` plan:

```console
$ gh api orgs/The-OpenROAD-Project -q .plan.name
team
```

So a private test repo cannot host a merge queue at all — hence a public repo in
the public org, which also happens to be the org the public Jenkins scans.

## 1. Create the repo

```bash
gh repo create The-OpenROAD-Project/ci-testing --public \
  --description 'Scratch repo for testing GitHub merge queue against Actions + Jenkins'

gh api -X PATCH repos/The-OpenROAD-Project/ci-testing \
  -F allow_auto_merge=true -F delete_branch_on_merge=true \
  -F allow_merge_commit=true -F allow_squash_merge=false -F allow_rebase_merge=false
```

**Merge commits only.** The queue's `merge_method` is `MERGE`, the ruleset's
`allowed_merge_methods` is `["merge"]`, and squash/rebase are disabled at the
repo level too. Three layers for one decision, deliberately: it means nothing can
quietly land as a squash, and `gh pr merge --squash` fails loudly rather than
producing history that does not match what the scenarios describe.

Apply the ruleset change **before** the repo-settings change when switching
methods, so there is never a window where the ruleset permits a method the repo
has disabled.

## 2. Push this tree

From the existing local checkout (its `origin` currently points at the empty
private repo):

```bash
cd /Volumes/workspace/openroad-workspace/ci-testing
git remote set-url origin ssh://git@github.com/The-OpenROAD-Project/ci-testing
chmod +x ci/check.sh scripts/*.sh
git add -A
git commit -m 'ci: merge queue test bed for Actions + Jenkins'
git push -u origin main
```

## 3. Ruleset

Apply Actions-only first, so the queue is proven working before the Jenkins
context is allowed to block it:

```bash
jq 'del(.rules[] | select(.type=="required_status_checks")
        | .parameters.required_status_checks[]
        | select(.context=="Public CI"))' docs/ruleset.json \
  | gh api -X POST repos/The-OpenROAD-Project/ci-testing/rulesets --input -
```

Once `Public CI` is confirmed posting on both PR heads and queue branches
(`scripts/fake-queue-branch.sh` proves this without a real queue), swap in the
full ruleset:

```bash
RULESET_ID=$(gh api repos/The-OpenROAD-Project/ci-testing/rulesets -q '.[] | select(.name=="main") | .id')
gh api -X PUT "repos/The-OpenROAD-Project/ci-testing/rulesets/${RULESET_ID}" --input docs/ruleset.json
```

Verify:

```bash
gh api repos/The-OpenROAD-Project/ci-testing/rulesets -q '.[] | "\(.id) \(.name) \(.enforcement)"'
gh api "repos/The-OpenROAD-Project/ci-testing/rulesets/${RULESET_ID}" \
  -q '.rules[] | select(.type=="merge_queue") | .parameters'
```

### Knob meanings

| Parameter | Value | Effect on the tests |
|---|---|---|
| `merge_method` | `MERGE` | Each entry lands as a two-parent merge commit; `scripts/verify-merge.sh` asserts the shape |
| `grouping_strategy` | `ALLGREEN` | An entry merges only if it and everything ahead of it is green |
| `max_entries_to_build` | `5` | How many speculative entries build concurrently — the batching test needs > 1 |
| `min_entries_to_merge` / `..._wait_minutes` | `1` / `2` | Waits up to 2 min to batch, then merges what it has |
| `check_response_timeout_minutes` | `15` | How long the queue waits for a missing status before evicting — the Jenkins-gating test measures this |

## 4. Required check names

- `ci` — the job `name:` in `.github/workflows/ci.yml`.
- `Public CI` — posted by the GitHub Branch Source plugin's *Custom Github
  Notification Context* trait with the job-type suffix off, so one name covers
  PR jobs, branch jobs and `gh-readonly-queue/*` jobs. Deliberately not
  `continuous-integration/jenkins/*`, which is per-job-type and cannot gate both
  PR merges and merge groups. See `docs/jenkins-setup.md`.

`mq-debug` is intentionally **not** required; it is observability only.

## 5. Teardown

```bash
gh api -X DELETE "repos/The-OpenROAD-Project/ci-testing/rulesets/${RULESET_ID}"
scripts/fake-queue-branch.sh --clean
gh pr list --state open -q '.[].number' --json number | xargs -n1 gh pr close
```
