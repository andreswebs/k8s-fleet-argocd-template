# k8s-fleet

This repository contains configuration for a fleet of k8s clusters where each cluster is using Argo CD in standalone mode.

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

This template does not install Argo Rollouts or any Argo CD UI extension. See
[Add an Argo CD UI extension](docs/argocd-extensions.md) for how to add one,
including what Argo CD 3.5 requires of an extension build.

### Pre-requisites

This template targets an EKS cluster in Auto Mode, whose managed load balancing replaces the self-managed AWS Load Balancer Controller that the template used to install. Consumers running on a cluster without Auto Mode must add that controller back themselves; the application directory this template used to carry for it, under `apps/`, is recoverable from this repository's history and is the place to start.

Create a k8s Secret for private Git repository access. This is done differently
for each Git provider.

The examples below describe how to do it manually, but it should normally be done by an Infrastructure-as-Code tool such as Terraform, OpenTofu or Pulumi.

Specifically, the Secret must be securely created outside this repo, for example from an IaC pipeline. Usually this is done at the moment of cluster creation.

Argo will detect the Secret through the required `argocd.argoproj.io/secret-type=repo-creds` label.

#### Example: Secret for Azure DevOps (SSH)

1. create SSH key pair:

   ```sh
   ssh-keygen -t rsa -b 4096 -f "${KEY_DIR}/${KEY_NAME}" -q -N "" -C "" < /dev/null
   ```

2. store the public key on Azure DevOps

3. create a k8s Secret containing the private key on the cluster

This is the Secret's structure:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: azure-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds ## required
stringData:
  type: git
  ## using a prefix for the `url` field, this becomes a credentials template for Argo
  url: ssh://git@ssh.dev.azure.com/v3/example-org/example-proj
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    bAAAAAAAAAetcetc ....
    -----END OPENSSH PRIVATE KEY-----
```

The Secret must be securely created outside this repo, for example from an IaC
pipeline. Usually this is done at the moment of cluster creation.

Argo will detect the Secret through the required
`argocd.argoproj.io/secret-type=repo-creds` label.

#### Example: Secret for GitHub (SSH)

1. create SSH key pair:

   ```sh
   ssh-keygen -t ed25519 -f "${KEY_DIR}/${KEY_NAME}" -q -N "" -C "" < /dev/null
   ```

2. store the public key on the GitHub repository as a "deploy key"

3. create k8s Secret containing the private key on the cluster

This is the Secret's structure:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: github-k8s-admin
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds ## required
stringData:
  type: git
  url: ssh://git@github.com/example-org/example-repo
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    bAAAAAAAAAetcetc ....
    -----END OPENSSH PRIVATE KEY-----
```

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

This step is run a single time for each cluster in it's entire lifetime, and can
be executed from the IaC pipeline to bootstrap a cluster. It consists in
applying the `root.app.yaml` (Application) manifest to a cluster with Argo CD
installed.

After the `root` Application is installed on the cluster's Argo server, Argo
will install the full cluster configuration on that cluster.

### Example: Cluster bootstrap running the commands imperatively from a shell

```sh
KUSTOMIZATION_DIR="clusters/dev-1"
kustomize build --load-restrictor LoadRestrictionsNone --enable-helm "${KUSTOMIZATION_DIR}" | kubectl apply --server-side --force-conflicts --filename -
kubectl apply --server-side --force-conflicts --filename "${KUSTOMIZATION_DIR}/root.app.yaml"
```

## Authors

**Andre Silva** - [@andreswebs](https://github.com/andreswebs)

## License

This project is licensed under the [Unlicense](UNLICENSE).
