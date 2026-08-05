@Library('utils@main') _

// Merge-queue test pipeline.
//
// Status reporting is deliberately NOT done here. The GitHub Branch Source
// plugin's "Custom Github Notification Context" trait, with the job-type suffix
// switched OFF, already posts one context ('Public CI') for PR jobs, branch jobs
// and gh-readonly-queue/* jobs alike — which is what a merge queue needs, since
// GitHub applies a single required-checks list to both PR gating and merge-group
// validation.
//
// An earlier revision posted its own 'jenkins/ci' context from the pipeline. It
// was removed after failing on this instance for two independent reasons, both
// worth remembering before anyone reintroduces it:
//   * the jnlp agent image has no `jq`;
//   * the 'github-token' credential is a fine-grained PAT that gets
//     403 "Resource not accessible by personal access token" on the statuses
//     API — a different identity from the classic token behind the
//     'openroad-ci' credential that the plugin and git operations use.
// See docs/results.md scenario 6.

k8sPodTemplate(dind: false, cpu: '2', memory: '4Gi', cloud: utilPickCloud()) {
    utilSetProperties()

    stage('Checkout') {
        cleanWs()
        Map r = checkout(scm)
        echo "BRANCH_NAME=${env.BRANCH_NAME} CHANGE_ID=${env.CHANGE_ID ?: '-'} GIT_COMMIT=${r.GIT_COMMIT}"
        utilPrettyPrintMap(r)

        if (env.BRANCH_NAME?.startsWith('gh-readonly-queue/')) {
            // The trailing SHA in the ref name is the base branch head at
            // enqueue time, not the PR head.
            echo "MERGE QUEUE build: ${env.BRANCH_NAME}"
            sh 'git --no-pager log --oneline -10'
        }
    }

    stage('Check') {
        sh './ci/check.sh'
    }
}
