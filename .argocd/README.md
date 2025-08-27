# .argocd

Argo CD boostrap configuration. This configuration installs the community Helm chart from the Argo
project repository.

- `base`: contains shared Helm values for all environments
- `overlays`: contains overlays per cluster (`overlays/<cluster-name>`) to deploy the ArgoCD Helm charts
- `bootstrap`: contains a Kustomization base for the Argo Application which self-manages Argo CD; the overlays for this base are in the `clusters` (`clusters/<cluster-name>`) directory

## Argo CD self-management application

The Application manifest [bootstrap/argocd.app.yaml](bootstrap/argocd.app.yaml) bootstraps the Argo CD self-management configuration.
