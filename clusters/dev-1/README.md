---
status: template
apps:
  - cert-manager
  - external-secrets
  - metrics-server
  - secret-stores
  - o11y
  - argocd-ingress
disabled:
  - argocd-secrets
---

# dev-1

`dev-1` is one of the example clusters this template ships with. It is not a real cluster: every value a real cluster needs is left as a placeholder, which is why its `status` is `template`.

Set `status: complete` once every placeholder this cluster reads has a real value. That is the flag `scripts/check-placeholders.sh` looks for: clusters marked `template` are skipped, and a cluster marked `complete` fails the check if any `TODO` remains in its own files or in the shared files it inherits.

The `apps` list mirrors the elements in `patches/infra.appset.yaml`, so a reader can see what this cluster runs without expanding the generator. Keep the two in step when adding or removing an application.

The `disabled` list names applications that have an overlay for this cluster but are not in the generator, such as the optional `argocd-secrets`. `scripts/check-placeholders.sh` neither scans them nor notes them as undeclared. An overlay listed in neither `apps` nor `disabled` gets a note on every run, because the check cannot tell a forgotten application from one kept for later.
