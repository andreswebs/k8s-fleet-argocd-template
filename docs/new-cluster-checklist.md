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
| `appprojects/infra/infra.appproject.yaml` | `sourceRepos` | The URL of your fork, or a glob over your organisation | `scripts/check-placeholders.sh` |
| `appprojects/root/root.appproject.yaml` | `sourceRepos` | Same | `scripts/check-placeholders.sh` |
| `appprojects/self/self.appproject.yaml` | `sourceRepos` | Same | `scripts/check-placeholders.sh` |

The three AppProjects ship accepting any source repository, marked `TODO`, because every Application in them takes its source from the fork. The Helm charts the overlays inflate need no entry: kustomize pulls them inside the repo-server, and `sourceRepos` governs only an Application's own source. Adding a chart repository there does nothing unless an Application's source is that repository itself. `appprojects/workloads` is left open, since workloads commonly live in their own repositories.

The URL form must match the credential you created: an HTTPS URL for GitHub App or token credentials, an SSH URL for a deploy key. The comment above each placeholder gives both forms. See [Give Argo CD access to a private GitHub repository with a GitHub App](github-app-credentials.md), and the credential examples under `examples/` for the other types.

If your default branch is not `main`, change `targetRevision` in five places:

```sh
git grep -n 'targetRevision'
```

They are `.argocd/bootstrap/argocd.app.yaml`, `appsets/infra/infra.appset.yaml`, and each cluster's `root.app.yaml`. This is a hard-coded value rather than a placeholder on purpose: most forks keep `main`, and nothing checks it. If you change the branch and miss one, Argo CD reports the Application as unable to resolve its revision.

If you pull Helm charts or container images from a private ECR registry, also fill the four placeholders in `apps/argocd-secrets/`. That application is optional and disabled by default; see [`apps/argocd-secrets/README.md`](../apps/argocd-secrets/README.md) for both the placeholders and how to enable it.

## Per environment

An environment here is a group of clusters sharing a set of values, the way `dev-1` and `dev-2` share the `dev` patches.

The shared patch at `.argocd/overlays/shared-patches/<env>/argocd.helm.values.yaml` holds what every cluster in the environment genuinely shares, such as whether `exec.enabled` is on, and carries the commented opt-in for the chart's NetworkPolicy objects. Neither of the two that ship holds a placeholder today.

A cluster reads exactly one of these, named in the `additionalValuesFiles` of its `.argocd/overlays/<cluster-name>/kustomization.yaml`, and `scripts/check-placeholders.sh` scans only that one. `dev-1` and `dev-2` share `shared-patches/dev`; `local` has its own `shared-patches/local`, because a throwaway k3d cluster is not a dev cluster and should not inherit that environment's values. A new environment is a new directory here plus the reference from each of its clusters.

Note that the Argo CD hostname is **not** an environment value. Each cluster runs its own standalone Argo CD, so two clusters cannot share one URL; `global.domain` is per cluster and appears in the next section.

You do choose, per environment, the credential type and therefore the `repoURL` form used above.

## Per cluster

Create four things. Copy an existing cluster; `dev-1` is the reference.

```sh
CLUSTER_NAME="dev-3"
SOURCE_CLUSTER="dev-1"

cp -r ".argocd/overlays/${SOURCE_CLUSTER}" ".argocd/overlays/${CLUSTER_NAME}"
cp -r "clusters/${SOURCE_CLUSTER}" "clusters/${CLUSTER_NAME}"
for a in cert-manager external-secrets metrics-server o11y secret-stores argocd-ingress argocd-secrets; do
  cp -r "apps/${a}/overlays/${SOURCE_CLUSTER}" "apps/${a}/overlays/${CLUSTER_NAME}"
done
rm -rf ".argocd/overlays/${CLUSTER_NAME}/charts" apps/*/overlays/"${CLUSTER_NAME}"/charts

# rename the cluster inside the copies too, not just the directories
grep -rlF -- "${SOURCE_CLUSTER}" ".argocd/overlays/${CLUSTER_NAME}" \
  "clusters/${CLUSTER_NAME}" apps/*/overlays/"${CLUSTER_NAME}" \
  | xargs perl -pi -e "s/\Q${SOURCE_CLUSTER}\E/${CLUSTER_NAME}/g"
```

The rename uses `perl -pi` rather than `sed -i`, whose in-place flag differs between GNU and BSD `sed`. It replaces every occurrence, so if the source name is a prefix of another string in those files, such as `dev-1` inside `dev-10`, read the result back.

Then edit. Everything below is what actually differs between two clusters in this repository, plus the two values a copy silently inherits.

### The cluster name

| File | Field | Value comes from | Caught by |
| ---- | ----- | ---------------- | --------- |
| `clusters/<cluster-name>/patches/argocd.app.yaml` | `value`, the path `.argocd/overlays/<cluster-name>` | The name you chose | `scripts/check-cluster-names.sh` |
| `clusters/<cluster-name>/patches/infra.appset.yaml` | `clusterName` | The name you chose | `scripts/check-cluster-names.sh`. A wrong name renders fine and points every Application at another cluster's overlays |
| `clusters/<cluster-name>/root.app.yaml` | `path` | The name you chose | `scripts/check-cluster-names.sh` |
| `clusters/<cluster-name>/README.md` | Title and first sentence | The name you chose | Nothing |

The rename in the copy block above fills all four. The check compares each of the first three with the cluster's directory name, so it catches a rename that failed or was skipped.

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
| `apps/secret-stores/overlays/<cluster-name>/patches/parameter-store.clustersecretstore.yaml` | `value`, the region | The AWS region holding this cluster's parameters | `scripts/check-placeholders.sh` |

The IAM role External Secrets reads those secrets and parameters with is yours to create too. [`apps/secret-stores/README.md`](../apps/secret-stores/README.md) states that contract, including the `kms:Decrypt` a customer-managed key needs.

The target groups themselves are yours to create. [`apps/argocd-ingress/README.md`](../apps/argocd-ingress/README.md) states the full contract: protocols, protocol versions, tags and the security group rule.

### The cluster's inventory

| File | Field | Value comes from | Caught by |
| ---- | ----- | ---------------- | --------- |
| `clusters/<cluster-name>/patches/infra.appset.yaml` | The element list | Which applications this cluster runs | `scripts/render-all.sh` if a path does not exist |
| `clusters/<cluster-name>/README.md` | `apps` front matter | The same list, mirrored so it can be read without expanding the generator | Nothing. Keep them in step by hand |
| `clusters/<cluster-name>/README.md` | `disabled` front matter | Applications with an overlay for this cluster that it does not run, such as an optional one kept for later | `scripts/check-placeholders.sh` notes an overlay listed in neither |
| `clusters/<cluster-name>/README.md` | `status` | `template` until every placeholder above is filled, then `complete` | This is the switch that turns the placeholder check on |

Two applications are optional and are not in the default list:

- `argocd-secrets`, only for private ECR. See [`apps/argocd-secrets/README.md`](../apps/argocd-secrets/README.md).
- `argocd-ingress`, only on EKS Auto Mode. The `local` cluster omits it, along with `secret-stores`, for that reason.

## What the placeholder check cannot see

`scripts/check-placeholders.sh` finds the string `TODO` in tracked YAML. That covers every placeholder in this repository today, but the class it cannot cover is worth naming, because this checklist is the only control for it.

**A copied value that looks real.** A per-cluster patch copied from `dev-1` and left unedited is valid YAML holding a plausible value. Nothing distinguishes it from a value you chose. The three rows in "Values a copy inherits" are all of this kind, which is why each one carries a `TODO` marker beside the plausible value rather than being left bare. If you add a per-cluster value of your own, mark it the same way.

**The cluster name, once it renders.** A `clusterName` still reading `dev-1` inside `clusters/dev-3` renders perfectly and produces Applications pointing at `dev-1`'s overlays. The placeholder check cannot see it, because nothing is marked; `scripts/check-cluster-names.sh` is the check that does.

Two limitations of the check itself:

**It only sees tracked files.** `git grep` is what it scans with, so a brand new cluster's own files are invisible to it until they are staged. This matters most in exactly the case the check is for. Run `git add` on the new directories before running it, or run it after committing.

**It trusts the README's lists.** It scans only the applications named under `apps` in the cluster's README front matter, so an application the cluster runs but does not list is not checked. An overlay for the cluster that is listed under neither `apps` nor `disabled` produces a `note:` line on every run, which is the prompt to put it in one or the other.

## Verify

In this order.

```sh
CLUSTER_NAME="dev-3"

# 1. everything still builds, including the new overlays
scripts/render-all.sh

# 2. make the new cluster's files visible to the check
git add ".argocd/overlays/${CLUSTER_NAME}" "clusters/${CLUSTER_NAME}" apps/*/overlays/"${CLUSTER_NAME}"

# 3. every cluster names itself, not the cluster it was copied from
scripts/check-cluster-names.sh

# 4. declare it complete, then confirm nothing is left
#    edit clusters/${CLUSTER_NAME}/README.md: status: template -> status: complete
scripts/check-placeholders.sh
```

`check-cluster-names.sh` prints `ok <cluster-name>` for every cluster. `check-placeholders.sh` exits 0 and prints `ok <cluster-name>` when nothing remains. Until then it lists every file and line still holding a placeholder, for every cluster marked complete.

Then bootstrap. Either follow [the k3d validation runbook](k3d-validation.md) against the `local` cluster first, which exercises the same path without AWS, or go straight to the cluster bootstrap in the repository's `README.md`.

## Adopting into an existing repository

Everything above assumes a fresh fork. Adopting the template into a repository that already has its own files raises three questions: what to copy, what to merge, and what to drop.

**Copy as a set.** These directories reference each other by relative path and only work together:

- `.argocd/`
- `appprojects/`
- `appsets/`
- `apps/`
- `clusters/`
- `shared-patches/`
- `scripts/`

The `.github/workflows/pull-request.yaml` jobs run those scripts; copy the jobs into your own workflow if you already have one.

**Merge by hand.** These are configuration your repository probably already has. Take the template's lines into yours rather than replacing the file:

| File | What the template's copy carries |
| ---- | -------------------------------- |
| `.gitignore` | The pulled-chart directories and `.render/` |
| `.yamllint.yaml` | The same chart directories, and the relaxed inline-comment spacing the `# TODO` markers rely on |
| `.markdownlint-cli2.yaml` | The same chart directories |
| `.pre-commit-config.yaml` | The `detect-private-key` exclusion for the credential examples |
| `.editorconfig` | Formatting only; keep yours if it exists |
| `README.md`, `AGENTS.md` | Documentation of the layout; fold what you need into your own |

**Watch the `charts/` pattern.** Kustomize writes the charts it pulls into a `charts/` directory next to each kustomization, and the template ignores exactly those locations, `.argocd/overlays/*/charts/` and `apps/*/overlays/*/charts/`. Do not widen that to `**/charts/` when merging: `charts/` is the most common directory name in a Kubernetes repository, and a broad pattern silently stops your own charts' new files from being tracked and their READMEs from being linted. If your layout puts kustomizations elsewhere, add a line for each place rather than a wildcard.

**Safe to drop.**

- `clusters/local`, its overlays and `docs/k3d-validation.md`, if you will not validate on k3d. [`clusters/local/README.md`](../clusters/local/README.md) lists every path to delete.
- `clusters/dev-1` and `clusters/dev-2` and their overlays, once your own cluster has been copied from one of them.
- `examples/`, once your repository credential exists.
- `apps/argocd-secrets` and `apps/argocd-ingress`, if you do not use private ECR or EKS Auto Mode.

After merging, run the three checks in the "Verify" section. They are the fastest way to find a relative path the move broke.
