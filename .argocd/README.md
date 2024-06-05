# .argocd

Argo CD boostrap configuration, installs the community Helm chart from the Argo
project repository. (TODO: vendor the chart in-repo)

- `base`: contains shared Helm values
- `overlays`: contains overlays Helm values per cluster
  (`overlays/<cluster-name>`)
- `bootstrap`: contains a Kustomization base for the Argo Application which
  deploys Argo CD; the overlays for this base are in the `clusters`
  (`clusters/<cluster-name>`) directory
