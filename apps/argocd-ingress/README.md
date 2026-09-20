# argocd-ingress

This application exposes the Argo CD server through a load balancer that this repository does not create. It contains two `TargetGroupBinding` objects and nothing else. Each one tells EKS Auto Mode to keep a target group's registered targets in step with the pods behind the `argocd-server` Service.

Everything on the AWS side is the consumer's to build, normally in the same infrastructure-as-code that creates the cluster. This page states that contract exactly, because nothing in this repository can verify it.

## What the consumer must provide

### One application load balancer

One ALB, with an HTTPS listener and an ACM certificate for the hostname Argo CD is served on. The client's TLS session ends at the ALB. Everything described below concerns only the second hop, from the ALB to the pod.

### Two target groups per cluster

| Target group | Protocol | Protocol version | Port | Purpose |
| ------------ | -------- | ---------------- | ---- | ------- |
| `argocd-<cluster-name>` | HTTPS | HTTP1 | 8080 | The web UI and the REST API |
| `argocd-grpc-<cluster-name>` | HTTPS | GRPC | 8080 | The gRPC API used by the `argocd` CLI |

Both are `targetType: ip` and both resolve to the same pods on the same port. The `argocd-server` container serves HTTP and gRPC on port 8080 and tells them apart itself, so the split exists only because an ALB target group carries a single protocol version. Route to them with a listener rule, conventionally on the `Content-Type: application/grpc` header for the gRPC one.

An ALB offers the GRPC protocol version only over HTTPS, which is why the gRPC target group cannot be plain HTTP.

### Why HTTPS to the pod works without a real certificate

Argo CD serves its own self-signed certificate on 8080. An ALB re-encrypts to an HTTPS target and does not validate the certificate the target presents, so the self-signed one is accepted and no certificate has to be provisioned inside the cluster.

If you would rather not have the second TLS hop for web traffic, the alternative is two edits: set the web target group to protocol HTTP on port 8080, and set `configs.params."server.insecure": true` in the Argo CD values under `.argocd`, so the server stops serving TLS on that port. The gRPC target group stays HTTPS with protocol version GRPC either way.

### Tags

Each target group must be tagged:

```text
eks:eks-cluster-name=<cluster-name>
```

Auto Mode's controller will not manage a target group that is not tagged for the cluster.

### A security group rule

The load balancer's security group must be allowed to reach the pod IPs on TCP 8080.

Write this rule yourself. Under the self-managed AWS Load Balancer Controller the binding carried a `spec.networking` block that made the controller manage this rule, and this repository used to fill it with a placeholder security group ID. Auto Mode's `TargetGroupBinding` does not support that block, so the rule is now part of the same infrastructure-as-code that creates the load balancer, which is where it belongs: the security group is the consumer's object and this repository never knew its ID.

## What this application does

The two bindings are in `base/`, with the per-cluster target group ARNs patched in from `overlays/<cluster-name>/patches/`.

Each ARN is a placeholder marked `TODO` and has to be replaced with the real target group ARN before the cluster is marked complete. They are ARNs rather than names because Auto Mode's `TargetGroupBinding` does not accept `spec.targetGroupName`.

Both bindings carry:

```yaml
argocd.argoproj.io/sync-options: Prune=false
```

This matters more than it looks. Deleting a `TargetGroupBinding` deletes the target group it refers to, and that target group belongs to the consumer's load balancer rather than to this application. Without `Prune=false`, removing this application from a cluster's ApplicationSet would destroy AWS resources that this repository did not create. The same happens when the cluster itself is deleted, which no annotation can prevent, so treat the target groups as owned by the cluster's lifecycle.

## Verifying it

This application cannot be tested on a local cluster: there is no Auto Mode controller and no AWS. Rendering is the only check this repository can make.

```sh
CLUSTER_NAME="dev-1"
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone \
  "apps/argocd-ingress/overlays/${CLUSTER_NAME}"
```

On a real cluster, confirm that both bindings report their targets as registered and that the target groups show healthy targets on port 8080.

## Example: the target groups in Terraform

An example of the contract, not something this repository applies. Adapt it to your own module conventions.

```hcl
resource "aws_lb_target_group" "argocd" {
  name        = "argocd-${var.cluster_name}"
  port        = 8080
  protocol    = "HTTPS"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path     = "/healthz"
    protocol = "HTTPS"
    matcher  = "200"
  }

  tags = {
    "eks:eks-cluster-name" = var.cluster_name
  }
}

resource "aws_lb_target_group" "argocd_grpc" {
  name             = "argocd-grpc-${var.cluster_name}"
  port             = 8080
  protocol         = "HTTPS"
  protocol_version = "GRPC"
  target_type      = "ip"
  vpc_id           = var.vpc_id

  health_check {
    path     = "/grpc.health.v1.Health/Check"
    protocol = "HTTPS"
    matcher  = "0-99"
  }

  tags = {
    "eks:eks-cluster-name" = var.cluster_name
  }
}
```

The ARNs these produce are what go into `overlays/<cluster-name>/patches/`.
