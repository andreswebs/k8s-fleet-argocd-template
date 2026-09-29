# Runbook: validating the k8s-fleet template on k3d

This runbook stands up the template's `local` cluster (WP9) on k3d,
bootstraps Argo CD with GitHub App credentials (WP7), lets Argo CD install
the infrastructure apps, then upgrades Argo CD through Argo CD to prove the
self-management path (WP2). It takes about twenty minutes the first time,
most of it image pulls.

Identifiers of the form `WP1` to `WP10`, and decision ids such as `2.1`, are
labels from the work that produced the current state of this template. They
are kept here so that this runbook and the project's tickets refer to the
same things by the same names. Nothing in this document depends on reading
them: every step below is self-contained.

What it cannot validate, because it needs AWS: `argocd-ingress`
(`TargetGroupBinding` on the Auto Mode API), `secret-stores` (Secrets
Manager), `argocd-secrets` (ECR). Those are EKS-only checks and are listed
at the end.

## 1. Prerequisites

| Tool                           | Version                         | Why this version                                                  |
| ------------------------------ | ------------------------------- | ----------------------------------------------------------------- |
| k3d                            | v5.9.0 or later                 | Current release                                                   |
| Docker or a compatible runtime | any current                     | k3d runs k3s in containers                                        |
| kubectl                        | within one minor of the cluster |                                                                   |
| kustomize                      | 5.8.1                           | Same version Argo CD 3.5.3 bundles, so local renders match Argo's |
| helm                           | 4.x                             | Argo CD 3.5.3 bundles 4.2.1; kustomize invokes the local binary   |
| gh (GitHub CLI)                | any current                     | Only for looking up the App installation id                       |

At least **15 GB free** on the filesystem Docker uses. k3d nodes are
containers, so they share that disk with everything else on the machine, and
a full bootstrap pulls Argo CD, cert-manager, External Secrets,
metrics-server and the OpenTelemetry operator. Below roughly 5 GB free the
kubelet declares `DiskPressure` and evicts the namespace out from under you.
Check with `docker system df` and reclaim with `docker volume prune` (which
removes only anonymous volumes; add `-a` to include named project volumes)
and `docker builder prune`.

A GitHub App with Contents: Read-only, installed on the repository (or
fork) that Argo CD will read from, and its private key on disk. Creating
the App is covered in the template's `docs/github-app-credentials.md`
(WP7). Use a fork you can push to: the runbook edits `repoURL`
placeholders and expects Argo CD to read the result.

Environment used throughout. Set these once:

```sh
export CLUSTER_NAME=local
export K3S_IMAGE=rancher/k3s:v1.36.4-k3s1   # match the EKS target minor
export REPO_URL=https://github.com/${GITHUB_ORG}/${GITHUB_REPO}
export REPO_BRANCH=main
export GITHUB_APP_SLUG=
export GITHUB_APP_ID=
export GITHUB_APP_INSTALLATION_ID=
export GITHUB_APP_PRIVATE_KEY_FILE="${HOME}/.secrets.d/argocd-github-app.pem"
## an array, not a string: unquoted ${VAR} word-splits in bash but not in
## zsh, which is the default shell on macOS. "${ARR[@]}" behaves the same
## in both. arrays are not exported, so run this runbook in one shell.
KUSTOMIZE_FLAGS=(--enable-helm --load-restrictor LoadRestrictionsNone)
```

Pick `K3S_IMAGE` from the k3s releases (on 2026-09-28 the current patch of
each supported minor was `v1.33.13+k3s2`, `v1.34.11+k3s1`, `v1.35.8+k3s1`
and `v1.36.4+k3s1`; the tag replaces `+` with `-`). Matching the EKS minor
you intend to run makes the CRD and API-version checks meaningful.

Two constraints on that choice. Argo CD 3.5 is tested against Kubernetes
1.33 to 1.36, and `kubectl` is supported only within one minor of the
cluster, so a `kubectl` from a much newer Kubernetes will report confusing
client-side errors against an older k3s. Check with `kubectl version` before
picking.

## 2. Create the cluster

k3s bundles Traefik, servicelb and its own metrics-server. Disable Traefik
and metrics-server so they do not collide with the template's apps;
servicelb is harmless and gives `LoadBalancer` Services an address.

```sh
k3d cluster create "${CLUSTER_NAME}" \
  --image "${K3S_IMAGE}" \
  --servers 1 --agents 2 \
  --k3s-arg "--disable=traefik@server:*" \
  --k3s-arg "--disable=metrics-server@server:*" \
  --port "8443:443@loadbalancer" \
  --wait

kubectl config use-context "k3d-${CLUSTER_NAME}"
kubectl get nodes -o wide
```

Expect three Ready nodes on the requested version and no `metrics-server`
or `traefik` pods in `kube-system`:

```sh
kubectl -n kube-system get pods | grep -E 'metrics-server|traefik' || echo "clean"
```

## 3. Point the fork at itself

The template ships `repoURL` as a placeholder. In your fork, set it in the
three places listed below, using the HTTPS form (GitHub App auth is
HTTPS-only):

```sh
git grep -n 'repoURL' -- shared-patches clusters/local
```

Edit `shared-patches/app.yaml`, `shared-patches/appset.yaml` and
`clusters/local/root.app.yaml` to `${REPO_URL}`.

Then narrow the AppProjects that take their source from the fork. Set the
`sourceRepos` entry marked `TODO` in `appprojects/infra/infra.appproject.yaml`,
`appprojects/root/root.appproject.yaml` and
`appprojects/self/self.appproject.yaml` to the same `${REPO_URL}`, and drop the
marker, then commit and push to `${REPO_BRANCH}`:

```sh
git grep -n 'TODO' -- appprojects
```

Those six are the whole list: `local` sets its own `global.domain` and runs
none of the applications that carry AWS placeholders. Now declare the cluster
finished, by setting `status: complete` in the front matter of
`clusters/local/README.md`, and confirm nothing is left:

```sh
scripts/check-placeholders.sh
```

It must print `ok local` and exit 0. The `status: complete` edit stays in your
fork; the template ships every cluster as `status: template`.

## 4. Render before applying

Every overlay must build locally with the same flags Argo CD uses. This
catches YAML and values mistakes before anything reaches the cluster.

```sh
scripts/render-all.sh
```

Or, for the two kustomizations this runbook applies by hand:

```sh
kustomize build "${KUSTOMIZE_FLAGS[@]}" .argocd/overlays/local > /dev/null && echo "argocd overlay renders"
kustomize build "${KUSTOMIZE_FLAGS[@]}" clusters/local > /dev/null && echo "cluster overlay renders"
```

Pulled charts appear under `.argocd/overlays/local/charts/`; they are
gitignored.

## 5. Bootstrap Argo CD

### 5.1 The regression test first (optional, recommended once)

Prove that the old client-side bootstrap fails on current Argo CD, so the
server-side flags in the next step are understood rather than cargo-culted:

```sh
kustomize build "${KUSTOMIZE_FLAGS[@]}" .argocd/overlays/local | kubectl apply --filename - 2>&1 | grep -i 'too long' \
  && echo "expected: client-side apply rejects the ApplicationSet CRD"
```

Clean up the partial apply before continuing:

```sh
kubectl delete namespace argocd --ignore-not-found --wait
```

### 5.2 Install

```sh
kustomize build "${KUSTOMIZE_FLAGS[@]}" .argocd/overlays/local \
  | kubectl apply --server-side --force-conflicts --filename -

kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
```

Sanity checks that the template's values landed:

```sh
kubectl -n argocd get configmap argocd-cm -o jsonpath='{.data.kustomize\.buildOptions}{"\n"}'
# --enable-helm --load-restrictor LoadRestrictionsNone
kubectl -n argocd get configmap argocd-cm -o jsonpath='{.data.url}{"\n"}'
# https://<global.domain from the local overlay>, not https://%!s(<nil>)
kubectl -n argocd get hpa argocd-server
```

## 6. Repository credentials (GitHub App)

The Secret is created out of band, exactly as it would be by IaC on a real
cluster. `repo-creds` with a URL prefix matches every repository under the
organisation; use `repository` with the full URL to scope it to one.

```sh
kubectl -n argocd create secret generic github-app-repo-creds \
  --from-literal=type=git \
  --from-literal=url="https://github.com/${GITHUB_ORG}" \
  --from-literal=githubAppID="${GITHUB_APP_ID}" \
  --from-literal=githubAppInstallationID="${GITHUB_APP_INSTALLATION_ID}" \
  --from-file=githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY_FILE}" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
  | kubectl apply --filename -
```

If you do not know the installation id, list the organisation's
installations as an organisation owner. The slug is the App's name as it
appears in its URL:

```sh
gh api "/orgs/${GITHUB_ORG}/installations" \
  --jq ".installations[] | select(.app_slug == \"${GITHUB_APP_SLUG}\") | {id, app_id, repository_selection, permissions}"
```

For an App installed on a personal account, use `/user/installations` in
place of `/orgs/${GITHUB_ORG}/installations`.

Verify from inside Argo CD once the root Application exists (section 7);
until then there is nothing to connect to.

## 7. Bootstrap the cluster configuration

```sh
kustomize build "${KUSTOMIZE_FLAGS[@]}" clusters/local \
  | kubectl apply --server-side --force-conflicts --filename -
kubectl apply --server-side --force-conflicts --filename clusters/local/root.app.yaml
```

Watch the Applications appear and converge. The infra ApplicationSet uses
sync waves, so they come up in order:

```sh
kubectl -n argocd get applications -w
```

Expected end state, all `Synced` and `Healthy`: `root`, `argocd`,
`cert-manager`, `external-secrets`, `metrics-server`, `o11y`. A one-shot
check:

```sh
kubectl -n argocd get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

If any Application sits in `Unknown` with a `ComparisonError`, see section 10.

## 8. Verify each component

Argo CD is managing itself (WP2):

```sh
kubectl -n argocd get application argocd -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n argocd get application argocd -o jsonpath='{.spec.syncPolicy.syncOptions}{"\n"}'
# must include ServerSideApply=true
```

External Secrets serves only `v1` (WP3):

```sh
kubectl get crd externalsecrets.external-secrets.io \
  -o jsonpath='{range .spec.versions[?(@.served==true)]}{.name}{"\n"}{end}'
# v1
kubectl get crd clustersecretstores.external-secrets.io \
  -o jsonpath='{range .spec.versions[?(@.served==true)]}{.name}{"\n"}{end}'
# v1
```

metrics-server (WP6, WP9):

```sh
kubectl top nodes
kubectl -n kube-system get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[0].status}{"\n"}'
# True
```

cert-manager and the OpenTelemetry operator webhook (WP6):

```sh
kubectl -n cert-manager get pods
kubectl -n o11y get certificate
# the operator's serving certificate shows READY True
kubectl -n o11y get pods
```

Argo Rollouts is no longer part of the template (WP2). Confirm nothing
of it was installed:

```sh
kubectl get crd rollouts.argoproj.io 2>&1 | grep -q NotFound && echo "ok: no Rollouts CRD"
kubectl -n argocd get deployment argocd-server -o jsonpath='{.spec.template.spec.initContainers}' | grep -q . && echo "unexpected init container" || echo "ok: no extension init container"
```

GitHub App connectivity (WP7): the Application statuses above already prove
it, since nothing syncs without a working credential. To see it directly:

```sh
export ARGOCD_OPTS="--port-forward --port-forward-namespace argocd --plaintext"
argocd login --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd repocreds list
argocd repo list
```

Let the `argocd` CLI do its own port-forwarding rather than running
`kubectl port-forward` alongside it. A manual forward here drops the
connection as soon as the CLI dials it (`lost connection to pod`, then
`connection refused`), and it binds `[::1]` as well as `127.0.0.1`, so
`localhost` resolving to IPv6 first is a second way to fail.

The `local` overlay sets `server.insecure`, hence `--plaintext`.

`repocreds list` shows the credentials template. **`repo list` is expected to
be empty**: this template configures a `repo-creds` template rather than a
`repository` Secret, so repositories referenced only by Applications are
never registered and never appear there. The proof that the credential works
is an Application reaching `Synced` against the private fork, which the
statuses above already show.

For the UI, run a forward in a separate terminal and open
`http://localhost:8080`:

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

## 9. Upgrade Argo CD through Argo CD

This is the test that the template's self-management survives current CRD
sizes. In the fork, bump the `argo-cd` chart in
`.argocd/overlays/local/kustomization.yaml` to the next available patch or
minor, commit, push, then watch:

```sh
kubectl -n argocd get application argocd -w
```

Expect one `OutOfSync` then `Synced`, and the deployments to roll:

```sh
kubectl -n argocd get deployment argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

The image tag must match the new chart's `appVersion`. The Application must
not report `Too long: may not be more than 262144 bytes`; if it does,
`ServerSideApply=true` is missing from its `syncOptions` and WP2 item 3 was
not applied.

Revert the bump afterwards if the fork is to stay on the pinned version.

## 10. Troubleshooting

| Symptom                                                                                 | Cause                                                                                                                                                     | Fix                                                                                                                                                                        |
| --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `metadata.annotations: Too long: may not be more than 262144 bytes` on apply            | Client-side apply of the ApplicationSet or Application CRD                                                                                                | Use `kubectl apply --server-side --force-conflicts`; for the `argocd` Application, add `ServerSideApply=true`                                                              |
| Application `ComparisonError`: `security: file '...' is not in or below '...'`          | Argo CD's kustomize ran without `--load-restrictor LoadRestrictionsNone`                                                                                  | Check `argocd-cm` `kustomize.buildOptions`; the base values set it, so the bootstrap overlay's values did not apply                                                        |
| Application `ComparisonError`: `must specify --enable-helm`                             | Same, for `--enable-helm`                                                                                                                                 | Same                                                                                                                                                                       |
| Application `ComparisonError`: `repository not accessible` or `authentication required` | Credential Secret missing the `argocd.argoproj.io/secret-type` label, URL prefix does not match `repoURL`, or the App is not installed on that repository | `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type`; compare `url` prefix with `repoURL`; check the installation id with `gh api`                             |
| `metrics-server` Healthy but `kubectl top nodes` errors with TLS verification           | `--kubelet-insecure-tls` not set                                                                                                                          | It belongs in `apps/metrics-server/overlays/local/metrics-server.helm.values.yaml`; check the rendered Deployment args                                                     |
| Two `metrics-server` deployments in `kube-system`                                       | k3s's bundled one was not disabled                                                                                                                        | Recreate the cluster with the `--disable=metrics-server@server:*` argument                                                                                                 |
| `o11y` stuck `Progressing`, webhook certificate not Ready                               | cert-manager not yet Healthy when the operator synced                                                                                                     | Waves handle ordering, but a slow image pull can outlast the retry; `argocd app sync o11y` once cert-manager is up                                                         |
| `argocd` Application `OutOfSync` immediately after bootstrap, before any change         | The imperative bootstrap and Argo's render differ in label or annotation defaults                                                                         | Expected once; the first sync reconciles it. Persistent drift means the bootstrap overlay and the Application's `path` differ; both must point at `.argocd/overlays/local` |
| Helm errors in the repo-server logs mentioning OCI or `--insecure-oci-force-http`       | Helm 4 in Argo CD 3.5 changed OCI defaults                                                                                                                | Not relevant to the template's HTTPS chart repositories; if a consumer added an OCI repository, see the 3.4-to-3.5 upgrade guide                                           |
| Pods `Evicted` or `Pending`, Applications stuck on an old revision | The Docker filesystem filled and the kubelet declared `DiskPressure`, evicting the repo-server so nothing could fetch from git | `kubectl get nodes -o json` and look for `DiskPressure`. Reclaim Docker space, wait about 100s for the condition to clear, then delete the `Evicted` and `ContainerStatusUnknown` pods by hand so the deployments reschedule |

Repo-server logs are the first place to look for render failures:

```sh
kubectl -n argocd logs deployment/argocd-repo-server --since=10m | grep -iE 'error|failed' | tail -20
```

## 11. Tear down

```sh
k3d cluster delete "${CLUSTER_NAME}"
```

Nothing outside the cluster was created. Remove pulled charts if the
working tree should be clean:

```sh
git clean -ndX -- '.argocd/overlays/*/charts/' 'apps/*/overlays/*/charts/'   # dry run
git clean -fdX -- '.argocd/overlays/*/charts/' 'apps/*/overlays/*/charts/'
```

Name the two locations explicitly. A `'**/charts/'` pathspec does **not**
constrain `git clean -X` to chart directories: every gitignored directory is
a candidate for removal, so the dry run also offers to delete `.tickets/` and
anything under `.local/`. Always read the `-n` output before running the
`-f`.

## 12. What this runbook does not cover (EKS only)

| Check                                                                                                                           | Where                                                                                                                                                                                        | Plan reference   |
| ------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| `TargetGroupBinding` objects on `eks.amazonaws.com/v1` register healthy IP targets; target groups tagged `eks:eks-cluster-name` | EKS Auto Mode cluster with an externally owned ALB                                                                                                                                           | WP5              |
| `ClusterSecretStore` reports `Ready` against Secrets Manager                                                                    | EKS with node or pod identity permissions                                                                                                                                                    | WP3              |
| `ECRAuthorizationToken` generator produces a token; the OCI repository Secret connects                                          | EKS with ECR access                                                                                                                                                                          | WP8 (opt-in app) |
| NetworkPolicy behaviour under enforcement                                                                                       | EKS Auto Mode. The template ships `global.networkPolicy.create: false` (decision 2.1); a consumer who opts in can run a partial check here, since k3s enforces NetworkPolicy via kube-router | WP2              |

## 13. Decisions about this runbook

Settled on 2026-09-18, while the upgrade work this runbook validates was
being planned.

| Id  | Question                                    | Decision                                                                                                                                                                                                                                                    |
| --- | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R.1 | Script as well as document?                 | Document now. `scripts/k3d-validate.sh` is written once the manual steps have run twice without edits; the document stays as the explanation                                                                                                                |
| R.2 | Run in CI?                                  | Not on every PR. A `workflow_dispatch` job is added when the script exists; it becomes a required check only if it proves stable. A full bootstrap is ten to fifteen minutes on `ubuntu-latest`, and the GitHub App private key must be a repository secret |
| R.3 | Fork with GitHub App, or public repository? | Private fork with a GitHub App. It is the only way to validate WP7, and the credential path is the most common bootstrap failure                                                                                                                            |
| R.4 | k3s minor                                   | Match the EKS target minor through `K3S_IMAGE`. The point is to catch API removals for that version                                                                                                                                                         |
