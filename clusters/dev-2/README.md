---
status: template
apps:
  - cert-manager
  - external-secrets
  - metrics-server
  - secret-stores
  - o11y
  - argocd-ingress
---

# dev-2

`dev-2` is one of the example clusters this template ships with. It is not a real cluster: every value a real cluster needs is left as a placeholder, which is why its `status` is `template`.

Set `status: complete` once every placeholder this cluster reads has a real value. That is the flag `scripts/check-placeholders.sh` looks for: clusters marked `template` are skipped, and a cluster marked `complete` fails the check if any `TODO` remains in its own files or in the shared files it inherits.

The `apps` list mirrors the elements in `patches/infra.appset.yaml`, so a reader can see what this cluster runs without expanding the generator. Keep the two in step when adding or removing an application.
