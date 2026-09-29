# k8s-fleet

This repository contains configuration for a fleet of k8s clusters where each cluster is using Argo CD in standalone mode.

## Documentation

- [Checklist: adding a cluster, an environment, or a consumer](docs/new-cluster-checklist.md). Start here when forking this template or adding a cluster: every value you have to supply, and which check catches it if you forget.
- [Give Argo CD access to a private GitHub repository with a GitHub App](docs/github-app-credentials.md).
- [Runbook: validating the k8s-fleet template on k3d](docs/k3d-validation.md). Exercises the bootstrap and self-management path locally, without AWS.
- [Add an Argo CD UI extension](docs/argocd-extensions.md).

Two applications carry their own contract and are documented beside the code: [`apps/argocd-ingress`](apps/argocd-ingress/README.md), which states what the consumer's load balancer must provide, and [`apps/argocd-secrets`](apps/argocd-secrets/README.md), which is optional and only for private ECR.

## Argo CD Bootstrap

The `.argocd` directory contains a Kustomization to install Argo CD using the
community Helm chart.

Subsequently, after the Cluster Bootstrap, this kustomization is taken over by
an Argo CD Application, and Argo becomes self-managing. The configurations (Helm
values for the deployed Argo CD chart) in the `.argocd` directory remain active,
and can be modified by changing the `argocd.helm.values.yaml` files under the
`.argocd/overlays/<cluster>` directories.

Upgrades to Argo CD can be initiated by changing the chart version in
`.argocd/overlays/<cluster>/kustomization.yaml`.

Argo CD 3.0 changed the default resource tracking method from labels to
annotations. A cluster bootstrapped from this template is unaffected, because
it starts on annotations. An existing installation upgraded from Argo CD 2.x
is: after the upgrade, Applications that set `ApplyOutOfSyncOnly=true`, which
this template's infra ApplicationSet does, must be synced explicitly once, so
that Argo CD writes the new tracking annotations on resources it now sees as
already in sync. See the
[Argo CD 2.14 to 3.0 upgrade guide](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/).

This template installs no Argo CD UI extension. See
[Add an Argo CD UI extension](docs/argocd-extensions.md) for how to add one,
including what Argo CD 3.5 requires of an extension build.

### Pre-requisites

This template targets an EKS cluster in Auto Mode, whose managed load balancing replaces the self-managed AWS Load Balancer Controller that the template used to install. Consumers running on a cluster without Auto Mode must add that controller back themselves; the application directory this template used to carry for it, under `apps/`, is recoverable from this repository's history and is the place to start.

Create a k8s Secret for private Git repository access. This is done differently
for each Git provider and credential type.

The Secret must be securely created outside this repo, for example from an IaC
pipeline such as Terraform, OpenTofu or Pulumi. Usually this is done at the
moment of cluster creation.

Argo will detect the Secret through the required
`argocd.argoproj.io/secret-type=repo-creds` label. Without that label the
Secret is invisible to Argo CD, whatever else it contains.

The `repoURL` the Applications use must match the credential: an HTTPS URL for
GitHub App or token credentials, an SSH URL for a deploy key.

**GitHub, using a GitHub App.** The credential to prefer for a fleet: scoped to
chosen repositories, short-lived tokens, and it outlives the person who created
it. See [Give Argo CD access to a private GitHub repository with a GitHub
App](docs/github-app-credentials.md) for creating the App and finding the two
identifiers it needs. Manifest:
[`examples/repo-creds.github-app.yaml`](examples/repo-creds.github-app.yaml).

**GitHub, using an SSH deploy key.** Generate a key pair, store the public half
on the repository as a deploy key, and put the private half in the Secret:

```sh
ssh-keygen -t ed25519 -f "${KEY_DIR}/${KEY_NAME}" -q -N "" -C "" < /dev/null
```

Manifest:
[`examples/repo-creds.github-ssh.yaml`](examples/repo-creds.github-ssh.yaml).

**Azure DevOps, using SSH.** Generate a key pair, store the public half on Azure
DevOps, and put the private half in the Secret:

```sh
ssh-keygen -t rsa -b 4096 -f "${KEY_DIR}/${KEY_NAME}" -q -N "" -C "" < /dev/null
```

Manifest:
[`examples/repo-creds.azure-ssh.yaml`](examples/repo-creds.azure-ssh.yaml).

In each example the `url` field is a prefix, which makes the Secret a
credentials template covering every repository underneath it. Use the full
repository URL, with `secret-type: repository`, to scope it to one.

### Example: Argo bootstrap running the commands imperatively from a shell

This will install the Argo CD Helm chart on the `dev-1` cluster:

```sh
KUSTOMIZATION_DIR="./.argocd/overlays/dev-1"

kustomize build --load-restrictor LoadRestrictionsNone --enable-helm "${KUSTOMIZATION_DIR}" | kubectl apply --server-side --force-conflicts --filename -
```

The command above emulates, at the shell, Argo's behavior about Helm charts - by default it inflates Helm charts before applying them.

`--server-side --force-conflicts` is required, not optional. The `ApplicationSet` CRD shipped by the Argo CD chart is larger than the 262144-byte limit on the `kubectl.kubernetes.io/last-applied-configuration` annotation that client-side apply writes, so a plain `kubectl apply` fails on it. `--force-conflicts` lets the bootstrap take ownership of fields that a previous client-side apply already claimed. The same flags are used for every apply in this document, and the `argocd` Application that takes the installation over carries the matching `ServerSideApply=true` sync option.

Note the flags passed to the `kustomize` command:

- `--load-restrictor LoadRestrictionsNone`: this is used to support the directory structure of this repo, based on Helm charts wrapped in Kustomizations
- `--enable-helm`: enable Helm charts wrapped in Kustomizations

Both flags are also configured for Argo on the chart values. In this way, the behavior of the imperative command will match the behavior of Argo when self-managing the installation after the bootstrap.

### Temporary access to the UI

Expose Argo UI on localhost via port-forward:

```sh
kubectl port-forward --namespace argocd svc/argocd-server 8080:443
```

Fetch the temporary `admin` password:

```sh
kubectl --namespace argocd get secret argocd-initial-admin-secret \
  --output jsonpath="{.data.password}" | base64 -d; echo
```

(Connect to the UI on [https://localhost:8080](https://localhost:8080), and
accept the insecure certificate warning for now. This gets fixed when the Argo
managed applications get bootstrapped in a further step. The username is `admin`.)

## Cluster Bootstrap

Clusters are bootstrapped from a single Argo CD Application named `root`,
declared at `clusters/<cluster-name>/root.app.yaml` for each cluster. The
`clusters/<cluster-name>` directory contains a Kustomization which becomes
managed by the `root` Application ("App of Apps" pattern).

This step is run a single time for each cluster in its entire lifetime, and can
be executed from the IaC pipeline to bootstrap a cluster. It consists in
applying the `root.app.yaml` (Application) manifest to a cluster with Argo CD
installed.

After the `root` Application is installed on the cluster's Argo server, Argo
will install the full cluster configuration on that cluster.

The `argocd` Application that `root` manages carries
`argocd.argoproj.io/sync-options: Delete=false`, so deleting `root` leaves Argo
CD installed. Removing Argo CD from a cluster is therefore two deliberate
steps: delete `root`, then delete `argocd`.

Applications track `targetRevision: main`, which is hard-coded rather than
left as a placeholder because most forks keep that branch name. If yours does
not, [the checklist](docs/new-cluster-checklist.md) names every place to
change it.

### Example: Cluster bootstrap running the commands imperatively from a shell

```sh
KUSTOMIZATION_DIR="clusters/dev-1"
kustomize build --load-restrictor LoadRestrictionsNone --enable-helm "${KUSTOMIZATION_DIR}" | kubectl apply --server-side --force-conflicts --filename -
kubectl apply --server-side --force-conflicts --filename "${KUSTOMIZATION_DIR}/root.app.yaml"
```

A few minutes after this, while Argo CD is installing metrics-server, most
`kubectl` commands may pause for a while or seem to hang. This is not a broken
bootstrap. The `v1beta1.metrics.k8s.io` APIService is registered before the
metrics-server pod behind it is ready, and `kubectl` waits on that unavailable
aggregated API during discovery. It clears by itself once the pod is up, which
this shows as `True` under `AVAILABLE`:

```sh
kubectl get apiservice v1beta1.metrics.k8s.io
```

## Validating changes locally

Every overlay in this repository must build with the flags Argo CD renders
with. That is what CI checks, and you can run it yourself:

```sh
scripts/render-all.sh
```

Rendering proves the manifests are well formed, not that they work. To
exercise the bootstrap, Argo CD's self-management and the applications that do
not need AWS, stand up the `local` cluster on k3d and follow
[the k3d validation runbook](docs/k3d-validation.md). It takes about twenty
minutes and is the cheapest way to catch a broken upgrade before a real
cluster sees it.

Before adding a cluster, read
[the checklist](docs/new-cluster-checklist.md), which lists every value you
must supply and ends with the same render plus `scripts/check-placeholders.sh`
and `scripts/check-cluster-names.sh`, the other two checks CI runs.

## Authors

**Andre Silva** - [@andreswebs](https://github.com/andreswebs)

## License

This project is licensed under the [Unlicense](UNLICENSE).
