# Jenkins setup

## Required Jenkins components

- Pipeline and Git plugins.
- Credentials Binding plugin.
- JUnit plugin.
- A Linux agent labelled `docker` with Git and Docker CLI access.
- Enough disk for two images and vulnerability databases.

The pipeline runs Helm, Trivy, and `yq` from pinned containers, so those tools do
not need to be installed directly on the agent.

## Credentials

In **Manage Jenkins → Credentials → System → Global credentials**, create:

1. `dockerhub-credentials` as Username with password. Use your Docker Hub user
   and an access token, not the account password.
2. `github-gitops-credentials` as Username with password. Use your GitHub user
   and a fine-grained personal access token limited to this repository with
   Contents read/write permission.

Jenkins passes the tokens through the credentials binding. The Docker Hub token
goes to `docker login --password-stdin`; the GitHub token is supplied through a
temporary `GIT_ASKPASS` helper and is not placed in the repository URL.

## Job

Create a Pipeline from SCM or a Multibranch Pipeline using the GitHub repository.
The script path is `Jenkinsfile`. For a Multibranch job, include only `main` in
branch discovery. The Jenkins-generated `gitops` branch must not start another
build.

Set these parameters on the first run:

```text
DOCKERHUB_NAMESPACE=your-dockerhub-user
GITHUB_REPOSITORY=your-github-user/devops-k8s-challenge
GITOPS_BRANCH=gitops
```

## Pipeline sequence

1. Check out the exact Git commit.
2. Read `VERSION` and create `1.0.0-b<BUILD_NUMBER>-<SHORT_SHA>`.
3. Build the backend test stage and run unit tests.
4. Build the minimal backend and frontend runtime stages.
5. Scan source dependencies and secrets with Trivy.
6. Fail on fixed critical vulnerabilities in either runtime image.
7. Lint the Helm chart.
8. Push immutable images and convenience `latest` tags to Docker Hub.
9. Check out or create `gitops`, copy deployment files from the tested commit,
   update both repositories/tags plus `Chart.yaml.appVersion`, and push.
10. Argo CD observes that commit and reconciles AKS.

If a vulnerability gate fails, no image is published and no GitOps commit is
created. If the Git push fails after images are published, AKS stays on the
previous known-good tag.

## Useful evidence for the recording

```bash
git log --oneline --decorate -5 origin/gitops
git show origin/gitops:helm/devops-challenge/values-production.yaml
docker pull YOUR_USER/devops-challenge-backend:YOUR_IMMUTABLE_TAG
```

Show the Jenkins stage view, the two Docker Hub tags, the automated Git commit,
and the matching Argo CD revision.
