#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Installs Argo CD and Argo Rollouts into the local Kind cluster.

.DESCRIPTION
    This is the local PowerShell equivalent of the production bootstrap script's
    controller install step. It deliberately does not apply production Argo CD
    Applications; use apply-argocd-production-rehearsal.ps1 after choosing a
    rehearsal Git branch.
#>

param(
    [string]$ArgocdNamespace = "argocd",
    [string]$ArgoRolloutsNamespace = "argo-rollouts",
    [string]$AppNamespace = "year4-project",
    [string]$ArgocdChartVersion = "7.6.12",
    [string]$ArgoRolloutsChartVersion = "2.37.6",
    [switch]$AllowNonKindContext,
    [switch]$SkipHelmRepoUpdate,
    [switch]$SkipWait
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-Tool($Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

foreach ($tool in @("kubectl", "helm")) {
    if (-not (Test-Tool $tool)) {
        Write-Error "$tool is required for local Argo CD setup."
    }
}

Write-Step "Checking Kubernetes context"
$currentContext = kubectl config current-context 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "kubectl has no current context. Run local/setup.ps1 first."
}

if ($currentContext -ne "kind-local-dev" -and -not $AllowNonKindContext) {
    Write-Error "Current kubectl context is '$currentContext'. Re-run with -AllowNonKindContext only if this is an intentional local test cluster."
}

Write-Step "Creating Argo namespaces"
foreach ($namespace in @($ArgocdNamespace, $ArgoRolloutsNamespace, $AppNamespace)) {
    kubectl create namespace $namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Host
}

Write-Step "Adding Helm repository"
helm repo add argo https://argoproj.github.io/argo-helm | Out-Host
if (-not $SkipHelmRepoUpdate) {
    helm repo update argo | Out-Host
}

Write-Step "Installing Argo CD"
helm upgrade --install argocd argo/argo-cd `
    --version $ArgocdChartVersion `
    --namespace $ArgocdNamespace `
    --create-namespace `
    --set configs.params."server\.insecure"=true `
    --set server.service.type=ClusterIP `
    --wait --timeout 600s | Out-Host

Write-Step "Installing Argo Rollouts"
helm upgrade --install argo-rollouts argo/argo-rollouts `
    --version $ArgoRolloutsChartVersion `
    --namespace $ArgoRolloutsNamespace `
    --create-namespace `
    --wait --timeout 300s | Out-Host

if (-not $SkipWait) {
    Write-Step "Waiting for controller workloads"
    kubectl rollout status deployment/argocd-repo-server -n $ArgocdNamespace --timeout=300s | Out-Host
    kubectl rollout status statefulset/argocd-application-controller -n $ArgocdNamespace --timeout=300s | Out-Host
    kubectl rollout status deployment/argo-rollouts -n $ArgoRolloutsNamespace --timeout=300s | Out-Host
}

Write-Step "Local Argo CD setup complete"
Write-Host "Next: .\local\apply-argocd-production-rehearsal.ps1 -TargetRevision <rehearsal-branch>"
Write-Host "UI:   kubectl port-forward service/argocd-server -n $ArgocdNamespace 8080:443"