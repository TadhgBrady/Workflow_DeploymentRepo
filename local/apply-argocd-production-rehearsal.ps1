#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Applies local Argo CD Applications for a production canary rehearsal.

.DESCRIPTION
    Creates a local-only AppProject plus two Applications that preserve the
    production sync order: service mesh first, application second. The app
    Application points at kubernetes/overlays/production-local-rehearsal so Kind
    can use local Secrets and local Postgres/Redis shims instead of AWS Secrets
    Manager.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "")]
param(
    [string]$RepoUrl = "https://gitlab.comp.dkit.ie/finalproject/Prototypes/yr4-projectdeploymentrepo.git",
    [string]$TargetRevision,
    [string]$ArgocdNamespace = "argocd",
    [string]$AppNamespace = "year4-project",
    [string]$ProjectName = "year4-project-production-rehearsal",
    [string]$MeshApplicationName = "year4-project-service-mesh-production-rehearsal",
    [string]$ApplicationName = "year4-project-production-rehearsal",
    [System.Management.Automation.PSCredential]$RepoCredential,
    [switch]$AllowNonKindContext,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-Step($Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-Tool($Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

if (-not (Test-Tool "kubectl")) {
    Write-Error "kubectl is required to apply the local Argo CD rehearsal Applications."
}

if (-not $TargetRevision) {
    $TargetRevision = git -C $RepoRoot branch --show-current 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $TargetRevision) {
        $TargetRevision = "local-rehearsal"
    }
}

Write-Step "Checking Kubernetes context"
$currentContext = kubectl config current-context 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "kubectl has no current context. Run local/setup.ps1 and local/setup-argocd.ps1 first."
}

if ($currentContext -ne "kind-local-dev" -and -not $AllowNonKindContext) {
    Write-Error "Current kubectl context is '$currentContext'. Re-run with -AllowNonKindContext only if this is an intentional local test cluster."
}

foreach ($crd in @("appprojects.argoproj.io", "applications.argoproj.io", "rollouts.argoproj.io")) {
    kubectl get crd $crd | Out-Null
}

if (-not $DryRun) {
  Write-Step "Preparing namespace and optional repository credentials"
  kubectl create namespace $ArgocdNamespace --dry-run=client -o yaml | kubectl apply -f - | Out-Host
  kubectl create namespace $AppNamespace --dry-run=client -o yaml | kubectl apply -f - | Out-Host

  if ($RepoCredential) {
    $repoUsername = $RepoCredential.UserName
    $repoCredentialSecret = $RepoCredential.GetNetworkCredential().Password
    kubectl -n $ArgocdNamespace create secret generic year4-project-deployment-repo `
      --from-literal=type=git `
      --from-literal=url=$RepoUrl `
      --from-literal=username=$repoUsername `
      --from-literal=password=$repoCredentialSecret `
      --dry-run=client -o yaml | kubectl apply -f - | Out-Host
    kubectl -n $ArgocdNamespace label secret year4-project-deployment-repo `
      argocd.argoproj.io/secret-type=repository --overwrite | Out-Host
  } else {
    Write-Host "Repository credentials were not supplied. Sync will work only if Argo CD can read $RepoUrl." -ForegroundColor Yellow
  }
}

$manifest = @"
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: $ProjectName
  namespace: $ArgocdNamespace
spec:
  description: Local production canary rehearsal for the Year 4 project
  sourceRepos:
    - $RepoUrl
  destinations:
    - namespace: $AppNamespace
      server: https://kubernetes.default.svc
    - namespace: monitoring
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
    - group: scheduling.k8s.io
      kind: PriorityClass
    - group: external-secrets.io
      kind: ClusterSecretStore
    - group: cert-manager.io
      kind: ClusterIssuer
  namespaceResourceWhitelist:
    - group: ""
      kind: Service
    - group: ""
      kind: Endpoints
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Secret
    - group: ""
      kind: ServiceAccount
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
    - group: apps
      kind: Deployment
    - group: batch
      kind: Job
    - group: rbac.authorization.k8s.io
      kind: Role
    - group: rbac.authorization.k8s.io
      kind: RoleBinding
    - group: autoscaling
      kind: HorizontalPodAutoscaler
    - group: policy
      kind: PodDisruptionBudget
    - group: networking.k8s.io
      kind: NetworkPolicy
    - group: external-secrets.io
      kind: ExternalSecret
    - group: argoproj.io
      kind: Rollout
    - group: argoproj.io
      kind: AnalysisTemplate
    - group: networking.istio.io
      kind: Gateway
    - group: networking.istio.io
      kind: VirtualService
    - group: networking.istio.io
      kind: DestinationRule
    - group: networking.istio.io
      kind: ServiceEntry
    - group: security.istio.io
      kind: PeerAuthentication
    - group: security.istio.io
      kind: AuthorizationPolicy
    - group: telemetry.istio.io
      kind: Telemetry
    - group: monitoring.coreos.com
      kind: PodMonitor
    - group: monitoring.coreos.com
      kind: ServiceMonitor
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $MeshApplicationName
  namespace: $ArgocdNamespace
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: $ProjectName
  source:
    repoURL: $RepoUrl
    targetRevision: $TargetRevision
    path: kubernetes/service-mesh/production
  destination:
    server: https://kubernetes.default.svc
    namespace: $AppNamespace
  ignoreDifferences:
    - group: networking.istio.io
      kind: VirtualService
      jqPathExpressions:
        - .spec.http[].route[].weight
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - PrunePropagationPolicy=foreground
      - RespectIgnoreDifferences=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $ApplicationName
  namespace: $ArgocdNamespace
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: $ProjectName
  source:
    repoURL: $RepoUrl
    targetRevision: $TargetRevision
    path: kubernetes/overlays/production-local-rehearsal
  destination:
    server: https://kubernetes.default.svc
    namespace: $AppNamespace
  ignoreDifferences:
    - group: argoproj.io
      kind: Rollout
      jsonPointers:
        - /spec/replicas
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
      - PrunePropagationPolicy=foreground
      - RespectIgnoreDifferences=true
"@

Write-Step "Applying local production rehearsal Applications"
Write-Host "Repository: $RepoUrl"
Write-Host "Revision:   $TargetRevision"
Write-Host "App path:   kubernetes/overlays/production-local-rehearsal"

if ($DryRun) {
    $manifest
} else {
    $manifest | kubectl apply -f - | Out-Host
    kubectl get appprojects.argoproj.io -n $ArgocdNamespace | Out-Host
    kubectl get applications.argoproj.io -n $ArgocdNamespace | Out-Host
    Write-Host "Watch sync: kubectl get applications.argoproj.io -n $ArgocdNamespace -w"
}