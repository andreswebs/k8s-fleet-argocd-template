# AGENTS.md

This document provides essential guidance for AI coding agents working on the `k8s-fleet` repository. It outlines the architecture, workflows, and conventions specific to this project to ensure productive contributions.

## Project Overview

The `k8s-fleet` repository manages configurations for a fleet of Kubernetes clusters, each using Argo CD in standalone mode. The repository is structured to support the "App of Apps" pattern, where a root Argo CD Application (`root.app.yaml`) bootstraps the cluster configuration.

### Key Components

1. **Argo CD Bootstrap**

   - Located in `.argocd/`.
   - Uses Kustomize to install Argo CD via the community Helm chart.
   - Post-bootstrap, Argo CD becomes self-managing.

2. **Cluster Configurations**

   - Found under `clusters/<cluster-name>/`.
   - Each cluster has a `root.app.yaml` file and a Kustomization manifest.

3. **Applications and Overlays**

   - Applications are organized under `apps/`.
   - Overlays for environments (e.g., `dev-1`, `dev-2`) are used to customize configurations.

4. **Shared Patches**
   - Common patches are stored in `shared-patches/`.

## Developer Workflows

### Render a specific kustomization (overlay)

```sh
KUSTOMIZATION_DIR="overlays/<cluster-name>" # <-- this is must be set to the relative path to the overlay to render
## example:
# KUSTOMIZATION_DIR=".argocd/overlays/dev-1"
```

```sh
kustomize build --load-restrictor LoadRestrictionsNone --enable-helm "${KUSTOMIZATION_DIR}"
```

### Accessing Argo CD UI

Expose the Argo CD UI locally:

```sh
kubectl port-forward --namespace argocd svc/argocd-server 8080:443
```

Fetch the temporary admin password:

```sh
kubectl --namespace argocd get secret argocd-initial-admin-secret \
  --output jsonpath="{.data.password}" | base64 -d; echo
```

## Conventions and Patterns

- **Kustomize with Helm**: Helm charts are wrapped in Kustomizations. Use `--enable-helm` and `--load-restrictor LoadRestrictionsNone` flags with `kustomize`.
- **Secrets Management**: Secrets for Git repository access must be created outside this repository, typically via an IaC pipeline.
- **Environment Overlays**: Use overlays (e.g., `dev-1`, `dev-2`) for environment-specific configurations.

## Key Files and Directories

- `.argocd/`: Argo CD bootstrap configurations.
- `clusters/`: Cluster-specific configurations.
- `apps/`: Application configurations.
- `shared-patches/`: Common patches for reuse.

## External Dependencies

- **Argo CD**: Manages cluster configurations.
- **Kustomize**: Used for templating Kubernetes manifests.
- **Helm**: Used for managing application charts.

## Notes for AI Agents

- This repo follows the "App of Apps" pattern for managing ArgoCD configurations.
- Ensure compatibility with Kustomize and Helm when modifying manifests.
- Reference the `README.md` for additional context on workflows and examples.
