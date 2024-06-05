# k8s-fleet

This repository contains configuration for a set of k8s clusters using Argo CD.

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

### Pre-requisites

Create a k8s Secret for private Git repository access. This is done differently
for each Git provider.

#### Example: Secret for Azure DevOps (SSH):

0. create SSH key pair:

```sh
ssh-keygen -t rsa -b 4096 -f "${KEY_DIR}/${KEY_NAME}" -q -N "" -C "" < /dev/null
```

1. store the public key on Azure DevOps

2. create k8s Secret containing the private key on the cluster

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

### Example: Argo bootstrap running the commands imperatively from a shell:

This will install the Argo CD Helm chart on the `dev` cluster:

```sh
KUSTOMIZATION_DIR="./.argocd/overlays/dev"

# this emulates, at the shell, Argo's behavior about Helm charts - by defaukt it inflates Helm charts before applying them
kustomize build --load-restrictor LoadRestrictionsNone --enable-helm "${KUSTOMIZATION_DIR}" | kubectl apply --filename -

# `--load-restrictor LoadRestrictionsNone`: used to support the directory structure of this repo, based on Helm charts wrapped in Kustomizations ## TODO: ADR, expl.
# `--enable-helm`: enable Helm charts wrapped in Kustomizations
# both flags are also configured for Argo on the chart values
```

### Temporary access to the UI:

Expose Argo UI on localhost via port-forward:

```sh
kubectl port-forward --namespace argocd svc/argocd-server 8080:443
```

Fetch temporary `admin` password:

```sh
kubectl --namespace argocd get secret argocd-initial-admin-secret \
  --output jsonpath="{.data.password}" | base64 -d; echo
```

(Connect to the UI on [`https://localhost:8080`](https://localhost:8080), and
accept the insecure certificate warning for now. This gets fixed when the Argo
managed applications get bootstrapped in a further step. Username is `admin`.)

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

### Example: Cluster bootstrap running the commands imperatively from a shell:

```sh
KUSTOMIZATION_DIR="clusters/dev"
kubectl apply --kustomize "${KUSTOMIZATION_DIR}"
kubectl apply --filename "${KUSTOMIZATION_DIR}/root.app.yaml"
```

## Authors

**Andre Silva** - [@andreswebs](https://github.com/andreswebs)

## License

This project is licensed under the [Unlicense](UNLICENSE.md).
