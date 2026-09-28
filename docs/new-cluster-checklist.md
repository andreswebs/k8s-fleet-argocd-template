# Checklist: adding a cluster, an environment, or a consumer

Every value this template leaves for you to supply, in the order you need it, with where each value comes from and which check catches it if you forget.

The template ships placeholders as per-cluster patch files rather than generating them, so adding a cluster means copying an existing one and editing a small, fixed set of fields. This page is the list of those fields.

Work through the section that matches what you are doing. A new consumer forking this repository does all three, once, in order.

## Per consumer, once

These are done once for the fork, not once per cluster.

| File | Field | Value comes from | Caught by |
| ---- | ----- | ---------------- | --------- |
| `shared-patches/app.yaml` | `value` (the `repoURL`) | The URL of your fork | `scripts/check-placeholders.sh` |
| `shared-patches/appset.yaml` | `value` (the `repoURL`) | The URL of your fork | `scripts/check-placeholders.sh` |
| `clusters/<cluster-name>/root.app.yaml` | `repoURL`, in every cluster you keep | The URL of your fork | `scripts/check-placeholders.sh` |

The URL form must match the credential you created: an HTTPS URL for GitHub App or token credentials, an SSH URL for a deploy key. The comment above each placeholder gives both forms. See [Give Argo CD access to a private GitHub repository with a GitHub App](github-app-credentials.md), and the credential examples under `examples/` for the other types.

If your default branch is not `main`, change `targetRevision` in five places:

```sh
git grep -n 'targetRevision'
```

They are `.argocd/bootstrap/argocd.app.yaml`, `appsets/infra/infra.appset.yaml`, and each cluster's `root.app.yaml`. This is a hard-coded value rather than a placeholder on purpose: most forks keep `main`, and nothing checks it. If you change the branch and miss one, Argo CD reports the Application as unable to resolve its revision.

If you pull Helm charts or container images from a private ECR registry, also fill the four placeholders in `apps/argocd-secrets/`. That application is optional and disabled by default; see [`apps/argocd-secrets/README.md`](../apps/argocd-secrets/README.md) for both the placeholders and how to enable it.

## Per environment

An environment here is a group of clusters sharing a set of values, the way `dev-1` and `dev-2` share the `dev` patches.

The shared patch at `.argocd/overlays/shared-patches/<env>/argocd.helm.values.yaml` holds what every cluster in the environment genuinely shares, such as whether `exec.enabled` is on, and carries the commented opt-in for the chart's NetworkPolicy objects. It holds no placeholder today.

Note that the Argo CD hostname is **not** an environment value. Each cluster runs its own standalone Argo CD, so two clusters cannot share one URL; `global.domain` is per cluster and appears in the next section.

You do choose, per environment, the credential type and therefore the `repoURL` form used above.

## Per cluster

Create four things. Copy an existing cluster; `dev-1` is the reference.

```sh
CLUSTER_NAME="dev-3"
SOURCE_CLUSTER="dev-1"

cp -r ".argocd/overlays/${SOURCE_CLUSTER}" ".argocd/overlays/${CLUSTER_NAME}"
cp -r "clusters/${SOURCE_CLUSTER}" "clusters/${CLUSTER_NAME}"
for a in cert-manager external-secrets metrics-server o11y secret-stores argocd-ingress; do
  cp -r "apps/${a}/overlays/${SOURCE_CLUSTER}" "apps/${a}/overlays/${CLUSTER_NAME}"
done
rm -rf ".argocd/overlays/${CLUSTER_NAME}/charts" apps/*/overlays/"${CLUSTER_NAME}"/charts
```

Then edit. Everything below is what actually differs between two clusters in this repository, plus the two values a copy silently inherits.

### The cluster name

| File | Field | Value comes from | Caught by |
| ---- | ----- | ---------------- | --------- |
| `clusters/<cluster-name>/patches/argocd.app.yaml` | `value`, the path `.argocd/overlays/<cluster-name>` | The name you chose | `scripts/render-all.sh` if the path does not exist |
| `clusters/<cluster-name>/patches/infra.appset.yaml` | `clusterName` | The name you chose | Nothing. A wrong name renders fine and points every Application at another cluster's overlays |
| `clusters/<cluster-name>/root.app.yaml` | `path` | The name you chose | Nothing, same reason |
| `clusters/<cluster-name>/README.md` | Title and first sentence | The name you chose | Nothing |

### The Argo CD hostname

| File | Field | Value comes from | Caught by |
| ---- | ----- | ---------------- | --------- |
| `.argocd/overlays/<cluster-name>/argocd.helm.values.yaml` | `global.domain` | The hostname this cluster's Argo CD is served on | `scripts/check-placeholders.sh` |

Worth filling even before you have a load balancer. Left empty it does not fail: it renders `url: https://%!s(<nil>)` into `argocd-cm`, which Argo CD then uses in generated links. Render the overlay and read it back to confirm:

```sh
CLUSTER_NAME="dev-1"
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone \
  ".argocd/overlays/${CLUSTER_NAME}" \
  | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="argocd-cm") | .data.url'
```

Apart from that one value, `.argocd/overlays/<cluster-name>/` needs no per-cluster edit: the `dev-1` and `dev-2` copies are otherwise identical. It exists per cluster so that a cluster can also pin its own Argo CD chart version, which is what makes the staged upgrade in `README.md` possible.

### Values a copy inherits and you must change

These are the dangerous ones. They are already filled in with something that looks real, so nothing about the rendered output suggests they are wrong.

| File | Field | Value comes from | Caught by |
| ---- | ----- | ---------------- | --------- |
| `apps/argocd-ingress/overlays/<cluster-name>/patches/argocd.tgb.yaml` | `value`, the target group ARN | Your infrastructure-as-code output for this cluster's web target group | `scripts/check-placeholders.sh` |
| `apps/argocd-ingress/overlays/<cluster-name>/patches/argocd-grpc.tgb.yaml` | `value`, the target group ARN | Same, for the gRPC target group | `scripts/check-placeholders.sh` |
| `apps/secret-stores/overlays/<cluster-name>/patches/secrets-manager.clustersecretstore.yaml` | `value`, the region | The AWS region holding this cluster's secrets | `scripts/check-placeholders.sh` |

The target groups themselves are yours to create. [`apps/argocd-ingress/README.md`](../apps/argocd-ingress/README.md) states the full contract: protocols, protocol versions, tags and the security group rule.

### The cluster's inventory

| File | Field | Value comes from | Caught by |
| ---- | ----- | ---------------- | --------- |
| `clusters/<cluster-name>/patches/infra.appset.yaml` | The element list | Which applications this cluster runs | `scripts/render-all.sh` if a path does not exist |
| `clusters/<cluster-name>/README.md` | `apps` front matter | The same list, mirrored so it can be read without expanding the generator | Nothing. Keep them in step by hand |
| `clusters/<cluster-name>/README.md` | `status` | `template` until every placeholder above is filled, then `complete` | This is the switch that turns the placeholder check on |

Two applications are optional and are not in the default list:

- `argocd-secrets`, only for private ECR. See [`apps/argocd-secrets/README.md`](../apps/argocd-secrets/README.md).
- `argocd-ingress`, only on EKS Auto Mode. The `local` cluster omits it, along with `secret-stores`, for that reason.

## What the placeholder check cannot see

`scripts/check-placeholders.sh` finds the string `TODO` in tracked YAML. That covers every placeholder in this repository today, but the class it cannot cover is worth naming, because this checklist is the only control for it.

**A copied value that looks real.** A per-cluster patch copied from `dev-1` and left unedited is valid YAML holding a plausible value. Nothing distinguishes it from a value you chose. The three rows in "Values a copy inherits" are all of this kind, which is why each one carries a `TODO` marker beside the plausible value rather than being left bare. If you add a per-cluster value of your own, mark it the same way.

**The cluster name, once it renders.** A `clusterName` still reading `dev-1` inside `clusters/dev-3` renders perfectly and produces Applications pointing at `dev-1`'s overlays. No check catches it. Re-read the three cluster-name rows above after copying.

Two limitations of the check itself:

**It only sees tracked files.** `git grep` is what it scans with, so a brand new cluster's own files are invisible to it until they are staged. This matters most in exactly the case the check is for. Run `git add` on the new directories before running it, or run it after committing.

**It scans every application's shared files.** Including those of applications your cluster does not run. If your cluster does not use ECR, you will still be shown the four `argocd-secrets` placeholders, because they live under `apps/argocd-secrets/base/` and `apps/argocd-secrets/shared-patches/`, which the check treats as shared by all clusters.

## Verify

In this order.

```sh
CLUSTER_NAME="dev-3"

# 1. everything still builds, including the new overlays
scripts/render-all.sh

# 2. make the new cluster's files visible to the check
git add ".argocd/overlays/${CLUSTER_NAME}" "clusters/${CLUSTER_NAME}" apps/*/overlays/"${CLUSTER_NAME}"

# 3. declare it complete, then confirm nothing is left
#    edit clusters/${CLUSTER_NAME}/README.md: status: template -> status: complete
scripts/check-placeholders.sh
```

`check-placeholders.sh` exits 0 and prints `ok <cluster-name>` when nothing remains. Until then it lists every file and line still holding a placeholder, for every cluster marked complete.

Then bootstrap. Either follow [the k3d validation runbook](k3d-validation.md) against the `local` cluster first, which exercises the same path without AWS, or go straight to the cluster bootstrap in the repository's `README.md`.
