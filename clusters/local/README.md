---
status: template
apps:
  - cert-manager
  - external-secrets
  - metrics-server
  - o11y
---

# local

`local` is not a deployment target. It exists so that the template can be validated on a throwaway k3d cluster before anything is applied to a real one, following [the k3d validation runbook](../../docs/k3d-validation.md).

It runs the four applications that work without AWS: cert-manager, external-secrets, metrics-server and the OpenTelemetry operator. The three the other clusters run are absent, because `secret-stores` reads AWS Secrets Manager, `argocd-secrets` mints an ECR authorization token, and `argocd-ingress` needs the EKS Auto Mode controller. Its Argo CD overlay is the only one that sets `server.insecure`, since nothing terminates TLS in front of Argo CD on k3d, and it reads its own `.argocd/overlays/shared-patches/local/` rather than the `dev` environment's, because a throwaway k3d cluster is not a dev cluster.

It ships as `status: template`, like every cluster in this repository, because it inherits the `repoURL` placeholder from `shared-patches/` and the template cannot fill that in. The runbook has you fork the repository, set `repoURL` to your fork, and flip this to `status: complete`, which is what turns the placeholder check on for this cluster.

## Removing it

If you do not want a local validation cluster, delete it entirely:

```sh
rm -rf clusters/local .argocd/overlays/local \
       .argocd/overlays/shared-patches/local
rm -rf apps/cert-manager/overlays/local \
       apps/external-secrets/overlays/local \
       apps/metrics-server/overlays/local \
       apps/o11y/overlays/local
```

Nothing else refers to it. `scripts/render-all.sh` picks up overlays by walking the tree, so it simply finds fewer of them afterwards.
