# argocd-secrets

Optional. This application is not enabled on any cluster by default, because it only applies to consumers who pull Helm charts or container images from a private Amazon ECR registry. A cluster that does not use ECR should leave it out; it cannot be configured without an ECR account, and its placeholders can never be filled.

## What it does

ECR does not issue long-lived credentials. It issues an authorization token that expires every twelve hours, so a static Secret in the cluster goes stale. This application uses External Secrets to mint that token continuously and publish it in the two shapes Argo CD needs:

- `aws-ecr-token-dockerconfig`, a `kubernetes.io/dockerconfigjson` Secret, for pulling container images from ECR. Nothing in this template refers to it: no pod names it in `imagePullSecrets`, and on EKS the nodes pull images with the node role rather than with a Secret. It is there for a tool in the `argocd` namespace that reads a registry through a pull secret, such as Argo CD Image Updater, which this template does not install. Without such a tool it does nothing, and it can be removed from `base/kustomization.yaml` together with its shared patch.
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

4. Grant the External Secrets controller's role the ECR permissions in [Permissions](#permissions). Without them every refresh of both ExternalSecrets fails.

5. Render the overlay to confirm the values landed:

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

## Permissions

The `ECRAuthorizationToken` generator has no `auth` block, so it runs as the External Secrets controller, with the same identity the secret stores use: the Pod Identity association on namespace `external-secrets`, service account `external-secrets`. [`apps/secret-stores/README.md`](../secret-stores/README.md) describes that identity. This application adds permissions to the same role.

An ECR authorization token carries the identity of the principal that requested it. Argo CD pulling with the token can pull exactly what the controller's role may pull, and nothing more. So the role needs two things, not one:

- `ecr:GetAuthorizationToken`, on `Resource: "*"`, since it supports no resource-level scoping. This alone mints a token that authenticates and then cannot read anything.
- Read-only pull on the repositories Argo CD reads, scoped to their ARNs, for example `arn:aws:ecr:<region>:<acct-id>:repository/<prefix>/*`:
  - `ecr:BatchCheckLayerAvailability`
  - `ecr:BatchGetImage`
  - `ecr:DescribeImages`
  - `ecr:GetDownloadUrlForLayer`
  - `ecr:ListImages`

The token works for any registry the role may read, including one in another account. A registry in another account must also allow the cluster's account in each repository's policy. A grant to the account root is enough, since the role's own policy then decides which of that account's principals may pull.

A repository encrypted with a customer-managed KMS key also needs `kms:Decrypt` on that key.

Without these grants, enabling the application produces two ExternalSecrets that fail on every refresh, and the Applications reading from the registry fail to authenticate.

### Example: the grant in Terraform

An example of the contract, not something this repository applies. It adds to the role in the `apps/secret-stores` example; adapt it to your own module conventions.

```hcl
data "aws_iam_policy_document" "external_secrets_ecr" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:ListImages",
    ]
    resources = [
      "arn:aws:ecr:${var.ecr_region}:${var.ecr_account_id}:repository/${var.ecr_repository_prefix}/*",
    ]
  }
}

resource "aws_iam_role_policy" "external_secrets_ecr" {
  name   = "pull-ecr"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets_ecr.json
}
```

When the registry is in another account, each repository there also needs a policy admitting the cluster's account, applied in the registry's account:

```hcl
data "aws_iam_policy_document" "ecr_pull_from_cluster_account" {
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:ListImages",
    ]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.cluster_account_id}:root"]
    }
  }
}

resource "aws_ecr_repository_policy" "pull_from_cluster_account" {
  for_each   = toset(var.ecr_repository_names)
  repository = each.value
  policy     = data.aws_iam_policy_document.ecr_pull_from_cluster_account.json
}
```
