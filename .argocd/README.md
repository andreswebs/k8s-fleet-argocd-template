# Argo CD Bootstrap

This directory contains a Kustomization to install Argo CD using the community
Helm chart.

Subsequently, this kustomization is taken over by an Argo Application, and Argo
becomes self-managing. The configurations in this directory remain active, and
can be modified by changing the `argocd.helm.values.yaml` files under the
`.argocd/overlays/<cluster>` directories.

## Bootstrap:

Run the commands manually (example for `./.argocd/overlays/dev`):

```sh
KUSTOMIZATION_DIR="./.argocd/overlays/dev"
kustomize build --load-restrictor LoadRestrictionsNone --enable-helm "${KUSTOMIZATION_DIR}" | kubectl apply --filename -
```

### Temporary access to the UI:

```sh
kubectl port-forward --namespace argocd svc/argocd-server 8080:443
```

```sh
kubectl --namespace argocd get secret argocd-initial-admin-secret \
  --output jsonpath="{.data.password}" | base64 -d; echo
```

(Connect to the UI on [`https://localhost:8080`](https://localhost:8080), and
accept the insecure certificate warning for now. This gets fixed when the Argo
managed applications get bootstrapped in a further step.)
