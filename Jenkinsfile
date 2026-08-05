@Library('utils@main') _

// Merge-queue test pipeline.
//
// Reports a SINGLE status context ('jenkins/ci') for every job type. GitHub
// applies one required-status-checks list to both PR gating and merge-group
// validation, but the GitHub Branch Source plugin posts different contexts per
// job type ('continuous-integration/jenkins/pr-merge' on PR jobs vs
// '.../branch' on branch jobs — and gh-readonly-queue/* refs are branch jobs).
// Requiring either plugin context alone therefore deadlocks the other side.
// Posting our own fixed context from the pipeline sidesteps that entirely.

String REPO    = 'The-OpenROAD-Project/ci-testing'
String CONTEXT = 'jenkins/ci'

k8sPodTemplate(dind: false, cpu: '2', memory: '4Gi', cloud: utilPickCloud()) {
    utilSetProperties()

    String sha = null

    try {
        stage('Checkout') {
            cleanWs()
            Map r = checkout(scm)
            echo "BRANCH_NAME=${env.BRANCH_NAME} CHANGE_ID=${env.CHANGE_ID ?: '-'} GIT_COMMIT=${r.GIT_COMMIT}"
            utilPrettyPrintMap(r)

            if (env.CHANGE_ID) {
                // PR jobs are configured to build the PR merged with the target
                // branch, so GIT_COMMIT is a throwaway merge commit; a status
                // posted there gates nothing. Report on the PR head instead.
                sha = ghApi("repos/${REPO}/pulls/${env.CHANGE_ID}", '.head.sha')
            } else {
                // Branch job. For a queue ref this is the queue branch head,
                // which is exactly the SHA the merge queue watches.
                sha = r.GIT_COMMIT
            }
            echo "Reporting '${CONTEXT}' on ${sha}"

            if (env.BRANCH_NAME?.startsWith('gh-readonly-queue/')) {
                echo "MERGE QUEUE build: ${env.BRANCH_NAME}"
            }
        }

        // Every path from here must end in a terminal status. If none arrives
        // the queue stalls until check_response_timeout_minutes, so the catch
        // below is load-bearing, not hygiene.
        postStatus(REPO, sha, CONTEXT, 'pending', "Build ${env.BUILD_NUMBER} running")

        stage('Check') {
            sh './ci/check.sh'
        }

        postStatus(REPO, sha, CONTEXT, 'success', 'Checks passed')
    } catch (err) {
        if (sha) {
            postStatus(REPO, sha, CONTEXT, 'failure', "Failed: ${err.message ?: 'error'}")
        }
        throw err
    }
}

// --- helpers, local to this test repo (deliberately not in the shared library) ---

// The available credential is secret-text ('github-token', used the same way in
// jenkins-ci/vars/utilPoolPRLabels.groovy), and a raw API call keeps the context
// name and target SHA fully under this repo's control.
String ghApi(String path, String jqFilter) {
    withCredentials([string(credentialsId: 'github-token', variable: 'GH_TOKEN')]) {
        return sh(returnStdout: true, script: """
            curl -sSf -H "Authorization: Bearer \$GH_TOKEN" \
                 -H 'Accept: application/vnd.github+json' \
                 'https://api.github.com/${path}' | jq -r '${jqFilter}'
        """).trim()
    }
}

void postStatus(String repo, String sha, String context, String state, String description) {
    withCredentials([string(credentialsId: 'github-token', variable: 'GH_TOKEN')]) {
        withEnv(["ST=${state}", "CTX=${context}",
                 "DESC=${description.take(130)}", "SHA=${sha}", "REPO=${repo}"]) {
            sh '''
                jq -n --arg s "$ST" --arg c "$CTX" --arg d "$DESC" --arg u "$BUILD_URL" \
                   '{state:$s, context:$c, description:$d, target_url:$u}' \
                | curl -sS -X POST -o /dev/null -w 'status POST %{http_code}\\n' \
                    -H "Authorization: Bearer $GH_TOKEN" \
                    -H 'Accept: application/vnd.github+json' \
                    --data @- "https://api.github.com/repos/$REPO/statuses/$SHA"
            '''
        }
    }
}
