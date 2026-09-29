# secret-stores

This application gives External Secrets two `ClusterSecretStore` objects, one per AWS service it can read from:

| Store | Service | Reads |
| ----- | ------- | ----- |
| `aws-secrets-manager` | `SecretsManager` | AWS Secrets Manager secrets |
| `aws-parameter-store` | `ParameterStore` | SSM Parameter Store parameters, including `SecureString` |

An `ExternalSecret` names one of them in `secretStoreRef`. A cluster that uses only one service can keep both: a store nothing refers to makes no AWS calls.

The IAM role External Secrets runs as is the consumer's to build, normally in the same infrastructure-as-code that creates the cluster. This page states that contract, because nothing in this repository can verify it.

## What this application does

Both stores are in `base/`, with the region patched in per cluster from `overlays/<cluster-name>/patches/`. Each region is marked `TODO` and has to be replaced with the region holding that cluster's secrets or parameters before the cluster is marked complete. The two regions are independent, so the stores can read from different regions.

Neither store has an `auth` block. The External Secrets controller therefore uses its own credentials, found through the AWS SDK's default credential chain, and every IAM requirement below is a requirement on the controller's role.

## What the consumer must provide

### An identity for the controller

EKS Pod Identity is the recommended way to give the controller a role. The association must match what `apps/external-secrets` installs:

| Field | Value |
| ----- | ----- |
| Namespace | `external-secrets` |
| Service account | `external-secrets` |

The service account name is set in `apps/external-secrets/base/external-secrets.helm.values.yaml`. Changing it there breaks the association.

A pod receives its credentials when it is created. If the association is added after External Secrets is already running, restart the controller so that it picks them up:

```sh
kubectl --namespace external-secrets rollout restart deployment external-secrets
```

IAM Roles for Service Accounts works too, through an `eks.amazonaws.com/role-arn` annotation on the same service account under `serviceAccount.annotations` in those values.

### Permissions for Secrets Manager

Scoped to the ARNs of the secrets the cluster reads:

- `secretsmanager:GetSecretValue`
- `secretsmanager:DescribeSecret`
- `secretsmanager:GetResourcePolicy`
- `secretsmanager:ListSecretVersionIds`

On `Resource: "*"`, because they support no resource-level scoping. They are used when an `ExternalSecret` finds secrets with `dataFrom` by name prefix or by tags:

- `secretsmanager:ListSecrets`
- `secretsmanager:BatchGetSecretValue`

### Permissions for Parameter Store

Scoped to the ARNs of the parameters the cluster reads:

- `ssm:GetParameter*`, which covers `GetParameter`, `GetParameters` and `GetParametersByPath`

On `Resource: "*"`, used when an `ExternalSecret` finds parameters with `dataFrom`, for example by tags:

- `ssm:DescribeParameters`
- `tag:GetResources`

### Permissions for ECR, if `argocd-secrets` is enabled

The optional `argocd-secrets` application mints ECR tokens as the same controller, so it adds ECR permissions to this role. [`apps/argocd-secrets/README.md`](../argocd-secrets/README.md) lists them.

### Decrypting with a customer-managed KMS key

A secret, or a `SecureString` parameter, encrypted with the AWS-managed key needs nothing further. One encrypted with a customer-managed key also needs `kms:Decrypt` on that key, granted in the role's policy and allowed by the key policy.

This is easy to miss, because the role works in every other respect. A role without it can list and describe everything and still fails every read, with an access-denied error naming KMS rather than Secrets Manager or SSM.

## Verifying it

Rendering is the only check this repository can make:

```sh
CLUSTER_NAME="dev-1"
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone \
  "apps/secret-stores/overlays/${CLUSTER_NAME}"
```

On a real cluster, both stores must report `Ready`:

```sh
kubectl get clustersecretstores
```

A store only proves that the controller can reach the service. An `ExternalSecret` that syncs is what proves the role can read and decrypt a value.

## Example: the role in Terraform

An example of the contract, not something this repository applies. Adapt it to your own module conventions, and narrow the ARNs to what the cluster actually reads.

```hcl
data "aws_iam_policy_document" "external_secrets_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "external-secrets-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust.json
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = var.secret_arns
  }

  statement {
    actions   = ["ssm:GetParameter*"]
    resources = var.parameter_arns
  }

  statement {
    actions = [
      "secretsmanager:ListSecrets",
      "secretsmanager:BatchGetSecretValue",
      "ssm:DescribeParameters",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = var.kms_key_arns
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}
```

Drop the `kms:Decrypt` statement if every secret and parameter uses the AWS-managed key, since an empty `resources` list is rejected.
