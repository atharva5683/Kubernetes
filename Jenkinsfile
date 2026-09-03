pipeline {
    agent { label 'docker' }

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
    }

    parameters {
        string(name: 'DOCKERHUB_NAMESPACE', defaultValue: 'replace-me', description: 'Docker Hub user or organization', trim: true)
        string(name: 'GITHUB_REPOSITORY', defaultValue: 'https://github.com/atharva5683/Kubernetes', description: 'GitHub owner/repository', trim: true)
        string(name: 'GITOPS_BRANCH', defaultValue: 'gitops', description: 'Branch watched by Argo CD', trim: true)
    }

    environment {
        BACKEND_IMAGE_NAME = 'devops-challenge-backend'
        FRONTEND_IMAGE_NAME = 'devops-challenge-frontend'
        DOCKERHUB_CREDENTIALS_ID = 'dockerhub-credentials'
        GITHUB_CREDENTIALS_ID = 'github-gitops-credentials'
        TRIVY_IMAGE = 'aquasec/trivy:0.74.0'
        HELM_IMAGE = 'alpine/helm:3.18.6'
        YQ_IMAGE = 'mikefarah/yq:4.53.6'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Create immutable version') {
            steps {
                script {
                    if (params.DOCKERHUB_NAMESPACE == 'replace-me') {
                        error('Set the DOCKERHUB_NAMESPACE Jenkins parameter.')
                    }
                    if (!(params.GITHUB_REPOSITORY ==~ /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/)) {
                        error('GITHUB_REPOSITORY must use owner/repository format.')
                    }

                    def baseVersion = readFile(file: 'VERSION').trim()
                    if (!(baseVersion ==~ /[0-9]+\.[0-9]+\.[0-9]+/)) {
                        error('VERSION must contain MAJOR.MINOR.PATCH.')
                    }

                    env.SHORT_SHA = sh(returnStdout: true, script: 'git rev-parse --short=8 HEAD').trim()
                    env.IMAGE_TAG = "${baseVersion}-b${env.BUILD_NUMBER}-${env.SHORT_SHA}"
                    env.BACKEND_REPOSITORY = "${params.DOCKERHUB_NAMESPACE}/${env.BACKEND_IMAGE_NAME}"
                    env.FRONTEND_REPOSITORY = "${params.DOCKERHUB_NAMESPACE}/${env.FRONTEND_IMAGE_NAME}"
                    env.BACKEND_IMAGE = "${env.BACKEND_REPOSITORY}:${env.IMAGE_TAG}"
                    env.FRONTEND_IMAGE = "${env.FRONTEND_REPOSITORY}:${env.IMAGE_TAG}"
                }
                echo "Release version: ${env.IMAGE_TAG}"
            }
        }

        stage('Unit test') {
            steps {
                sh '''
                    set -eu
                    mkdir -p reports
                    docker build --target test --tag "challenge-backend-test:${IMAGE_TAG}" .
                    docker run --rm \
                      --user "$(id -u):$(id -g)" \
                      --volume "${WORKSPACE}/reports:/reports" \
                      "challenge-backend-test:${IMAGE_TAG}" \
                      python -m pytest --quiet --junitxml=/reports/junit.xml
                '''
            }
        }

        stage('Build multi-stage images') {
            steps {
                sh '''
                    set -eu
                    docker build \
                      --target runtime \
                      --build-arg "APP_VERSION=${IMAGE_TAG}" \
                      --label "org.opencontainers.image.revision=${GIT_COMMIT}" \
                      --label "org.opencontainers.image.version=${IMAGE_TAG}" \
                      --tag "${BACKEND_IMAGE}" .

                    docker build \
                      --file Dockerfile.frontend \
                      --target runtime \
                      --build-arg "APP_VERSION=${IMAGE_TAG}" \
                      --label "org.opencontainers.image.revision=${GIT_COMMIT}" \
                      --label "org.opencontainers.image.version=${IMAGE_TAG}" \
                      --tag "${FRONTEND_IMAGE}" .
                '''
            }
        }

        stage('Security and Helm validation') {
            steps {
                sh '''
                    set -eu
                    docker run --rm \
                      --volume "${WORKSPACE}:/workspace" \
                      --workdir /workspace \
                      "${TRIVY_IMAGE}" fs \
                      --scanners vuln,secret \
                      --severity HIGH,CRITICAL \
                      --ignore-unfixed \
                      --exit-code 1 \
                      --skip-dirs .git \
                      .

                    docker run --rm \
                      --volume /var/run/docker.sock:/var/run/docker.sock \
                      "${TRIVY_IMAGE}" image \
                      --severity CRITICAL \
                      --ignore-unfixed \
                      --exit-code 1 \
                      "${BACKEND_IMAGE}"

                    docker run --rm \
                      --volume /var/run/docker.sock:/var/run/docker.sock \
                      "${TRIVY_IMAGE}" image \
                      --severity CRITICAL \
                      --ignore-unfixed \
                      --exit-code 1 \
                      "${FRONTEND_IMAGE}"

                    docker run --rm \
                      --volume "${WORKSPACE}:/apps" \
                      --workdir /apps \
                      "${HELM_IMAGE}" lint helm/devops-challenge
                '''
            }
        }

        stage('Push to Docker Hub') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: env.DOCKERHUB_CREDENTIALS_ID,
                    usernameVariable: 'DOCKERHUB_USERNAME',
                    passwordVariable: 'DOCKERHUB_TOKEN'
                )]) {
                    sh '''
                        set -eu
                        set +x
                        printf '%s' "$DOCKERHUB_TOKEN" | docker login --username "$DOCKERHUB_USERNAME" --password-stdin
                        docker push "$BACKEND_IMAGE"
                        docker push "$FRONTEND_IMAGE"
                        docker tag "$BACKEND_IMAGE" "${BACKEND_REPOSITORY}:latest"
                        docker tag "$FRONTEND_IMAGE" "${FRONTEND_REPOSITORY}:latest"
                        docker push "${BACKEND_REPOSITORY}:latest"
                        docker push "${FRONTEND_REPOSITORY}:latest"
                        docker logout
                    '''
                }
            }
        }

        stage('Update GitOps Helm release') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: env.GITHUB_CREDENTIALS_ID,
                    usernameVariable: 'GITHUB_USERNAME',
                    passwordVariable: 'GITHUB_TOKEN'
                )]) {
                    sh '''
                        set -eu
                        set +x

                        temp_root="$(mktemp -d)"
                        gitops_dir="$temp_root/repository"
                        askpass_file="$temp_root/askpass.sh"

                        cleanup() {
                          git worktree remove --force "$gitops_dir" >/dev/null 2>&1 || true
                          rm -f "$askpass_file"
                          rmdir "$temp_root" >/dev/null 2>&1 || true
                        }
                        trap cleanup EXIT

                        printf '%s\n' \
                          '#!/bin/sh' \
                          'case "$1" in' \
                          '  *Username*) printf "%s\\n" "$GITHUB_USERNAME" ;;' \
                          '  *) printf "%s\\n" "$GITHUB_TOKEN" ;;' \
                          'esac' > "$askpass_file"
                        chmod 700 "$askpass_file"
                        export GIT_ASKPASS="$askpass_file"
                        export GIT_TERMINAL_PROMPT=0

                        repository_url="https://github.com/${GITHUB_REPOSITORY}.git"
                        git fetch "$repository_url" "+refs/heads/${GITOPS_BRANCH}:refs/remotes/origin/${GITOPS_BRANCH}" || true

                        if git show-ref --verify --quiet "refs/remotes/origin/${GITOPS_BRANCH}"; then
                          git worktree add --detach "$gitops_dir" "origin/${GITOPS_BRANCH}"
                          git -C "$gitops_dir" switch --force-create "$GITOPS_BRANCH"
                        else
                          git worktree add -b "$GITOPS_BRANCH" "$gitops_dir" "$GIT_COMMIT"
                        fi

                        git -C "$gitops_dir" checkout "$GIT_COMMIT" -- \
                          helm/devops-challenge \
                          bootstrap \
                          monitoring

                        docker run --rm \
                          --user "$(id -u):$(id -g)" \
                          --env BACKEND_REPOSITORY \
                          --env FRONTEND_REPOSITORY \
                          --env IMAGE_TAG \
                          --volume "$gitops_dir:/work" \
                          "$YQ_IMAGE" -i \
                          '.backend.image.repository = strenv(BACKEND_REPOSITORY) | .backend.image.tag = strenv(IMAGE_TAG) | .frontend.image.repository = strenv(FRONTEND_REPOSITORY) | .frontend.image.tag = strenv(IMAGE_TAG)' \
                          /work/helm/devops-challenge/values-production.yaml

                        docker run --rm \
                          --user "$(id -u):$(id -g)" \
                          --env IMAGE_TAG \
                          --volume "$gitops_dir:/work" \
                          "$YQ_IMAGE" -i \
                          '.appVersion = strenv(IMAGE_TAG)' \
                          /work/helm/devops-challenge/Chart.yaml

                        git -C "$gitops_dir" config user.name "Jenkins GitOps Bot"
                        git -C "$gitops_dir" config user.email "jenkins-gitops@users.noreply.github.com"
                        git -C "$gitops_dir" add helm/devops-challenge bootstrap monitoring
                        git -C "$gitops_dir" commit -m "deploy: ${IMAGE_TAG} [skip ci]"
                        git -C "$gitops_dir" push "$repository_url" "HEAD:${GITOPS_BRANCH}"
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Docker images and GitOps release ${env.IMAGE_TAG} published. Argo CD will reconcile AKS."
        }
        always {
            junit allowEmptyResults: true, testResults: 'reports/junit.xml'
        }
    }
}
