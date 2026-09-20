# .argocd

Argo CD bootstrap configuration. This configuration installs the community Helm chart from the Argo
project repository.

- `base`: contains shared Helm values for all environments
- `overlays`: contains overlays per cluster (`overlays/<cluster-name>`) to deploy the ArgoCD Helm charts. `overlays/local` targets a throwaway k3d cluster and is the only one that turns off TLS on the server; see [the k3d validation runbook](../docs/k3d-validation.md)
- `bootstrap`: contains a Kustomization base for the Argo Application which self-manages Argo CD; the overlays for this base are in the `clusters` (`clusters/<cluster-name>`) directory

## Argo CD self-management application

The Application manifest [bootstrap/argocd.app.yaml](bootstrap/argocd.app.yaml) bootstraps the Argo CD self-management configuration.

This Application syncs with `ServerSideApply=true`, and the bootstrap that
creates it uses `kubectl apply --server-side --force-conflicts`. Both are
required rather than preferred: the `ApplicationSet` CRD shipped by the chart
is larger than the 262144-byte limit on the annotation that client-side apply
writes, so a client-side apply of this configuration fails outright. See the
[Argo CD 3.2 to 3.3 upgrade guide](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/3.2-3.3/).
