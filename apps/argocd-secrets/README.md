# argocd-secrets

Optional. This application is not enabled on any cluster by default, because it only applies to consumers who pull Helm charts or container images from a private Amazon ECR registry. A cluster that does not use ECR should leave it out; it cannot be configured without an ECR account, and its placeholders can never be filled.

## What it does

ECR does not issue long-lived credentials. It issues an authorization token that expires every twelve hours, so a static Secret in the cluster goes stale. This application uses External Secrets to mint that token continuously and publish it in the two shapes Argo CD needs:

- `aws-ecr-token-dockerconfig`, a `kubernetes.io/dockerconfigjson` Secret, for pulling container images from ECR.
- `aws-ecr-token-oci`, a Secret labelled `argocd.argoproj.io/secret-type: repository` with `enableOCI: "true"`, so Argo CD can pull Helm charts from an ECR OCI repository. This exists because kustomize cannot inflate a Helm chart from a private OCI repository itself, so Argo CD has to hold the credential.

Both are refreshed every 30 minutes from a single `ECRAuthorizationToken` generator.

## Enabling it on a cluster

1. Add this element to the generator list in `clusters/<cluster-name>/patches/infra.appset.yaml`, where the commented placeholder for it sits:

   ```yaml
   - name: argocd-secrets
     namespace: argocd
     path: apps/argocd-secrets/overlays/{{ .clusterName }}
     wave: 2
   ```

   Wave 2 places it after `external-secrets` and the secret stores it depends on.

2. Move `argocd-secrets` from the `disabled` list to the `apps` list in `clusters/<cluster-name>/README.md`, which mirrors that generator list.

3. Fill the four placeholders listed below.

4. Render the overlay to confirm the values landed:

   ```sh
   CLUSTER_NAME="dev-1"
   kustomize build --enable-helm --load-restrictor LoadRestrictionsNone \
     "apps/argocd-secrets/overlays/${CLUSTER_NAME}"
   ```

## Placeholders to fill

Four values have to be supplied before this application does anything useful. All four are marked in place.

| File | What to supply |
| ---- | -------------- |
| `shared-patches/all/default.ecr-auth-token.yaml` | The AWS region of the ECR registry, as the generator's `spec.region`. |
| `shared-patches/all/aws-ecr-token-dockerconfig.externalsecret.yaml` | The registry host in the `auths` key, which is the account ID and region of the registry holding the images. |
| `shared-patches/all/aws-ecr-token-oci.externalsecret.yaml` | The OCI repository URL, which is the same registry host plus the path prefix the charts live under. |
| `base/aws-ecr-token-oci.externalsecret.yaml` | The repository name Argo CD shows for that OCI registry, which is a label of your choosing rather than an AWS value. |

The first three are per-consumer AWS values and belong in the shared patch, so there is one copy of each. The fourth is cosmetic and sits in the base.

Note that the shared patches live under `shared-patches/all/`, so they apply to every cluster that enables this application. A consumer with more than one ECR registry needs per-cluster patches instead.
