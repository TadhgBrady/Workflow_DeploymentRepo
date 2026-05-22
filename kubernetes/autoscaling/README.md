# Kubernetes Autoscaling

This repository uses a layered autoscaling model.

## Current Layer

- `metrics-server` is installed as an EKS managed addon from the infrastructure
  repo. It provides the resource metrics required by HPA.
- Staging HPAs target `Deployment` resources.
- Production HPAs target Argo Rollouts. The production Argo CD Application
  ignores Rollout `spec.replicas` drift so HPA can scale without Argo CD
  resetting replica counts during sync.
- All application HPAs use CPU and memory resource metrics. Keep one HPA per
  workload and tune metrics inside that HPA rather than creating duplicate HPAs.
- Karpenter provisions EC2 worker nodes when pods cannot be scheduled and
  consolidates empty or underused nodes when load falls.
- Karpenter and CoreDNS are selected onto EKS Fargate profiles so the autoscaler
  and cluster DNS can remain available when EC2 worker capacity is scaled to
  zero.
- Production keeps `minReplicas: 2` so Istio ingress, canary analysis, and basic
  availability stay warm.
- Production overlays include PDBs, PriorityClass assignments, and topology
  spread constraints so Karpenter consolidation and node upgrades preserve
  critical paths. Staging includes targeted PDB/topology coverage for the
  multi-replica job/customer paths.
- Grafana dashboard `/d/year4-autoscaling` tracks HPA replica pressure, pending
  pods, Karpenter-labelled nodes, and cluster capacity versus requests.

## Operating Rules

- Staging may scale worker nodes to zero when idle.
- Production should normally keep warm worker capacity and should not be scaled
  to zero unless planned downtime is acceptable.
- Do not scale down while Argo Rollouts, migrations, k6 jobs, Terraform apply,
  or production validation are active.
- Do not autoscale migration Jobs, ExternalSecrets, or schema-change workflows.

## Validation

After deployment, verify:

```sh
kubectl top nodes
kubectl top pods -n year4-project-staging
kubectl get hpa -n year4-project-staging
kubectl get hpa -n year4-project
kubectl get pdb -n year4-project
kubectl get nodepool,ec2nodeclass
kubectl get pods -n karpenter -o wide
sh scripts/deployment/validate-autoscaling.sh staging
sh scripts/deployment/validate-autoscaling.sh production
```

Under load, HPA should increase desired replicas. If there is not enough worker
capacity, Karpenter should create nodes for the pending pods. When load falls,
HPA scale-down is delayed by the stabilization window, then Karpenter can
consolidate empty or underused nodes.

## Scale-To-Zero Notes

Karpenter can wake EC2 worker capacity from zero because its controller runs on
Fargate. Application HPAs still keep at least one staging replica and two
production replicas while workloads are deployed, so a true application idle-to-
zero mode would require a traffic/event autoscaler such as KEDA HTTP or Knative.