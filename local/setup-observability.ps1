#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Installs the local Kind observability stack.

.DESCRIPTION
    Installs kube-prometheus-stack, Loki, Fluent Bit, local ServiceMonitors,
    local PrometheusRules, and the local Grafana dashboard. This is designed
    for the local Kind app namespace year4-project-local and does not use AWS,
    CloudWatch, S3, KMS, or IRSA.
#>

param(
    [string]$MonitoringNamespace = "monitoring",
    [string]$LoggingNamespace = "logging",
    [string]$AppNamespace = "year4-project-local",
    [string]$GrafanaAdminUser = "admin",
    [string]$GrafanaAdminPassword = "local-admin-password",
    [switch]$SkipHelmRepoUpdate,
    [switch]$SkipWait
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-Step($Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-Tool($Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

foreach ($tool in @("kubectl", "helm")) {
    if (-not (Test-Tool $tool)) {
        Write-Error "$tool is required for local observability setup."
    }
}

Write-Step "Checking local cluster context"
$currentContext = kubectl config current-context 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "kubectl has no current context. Run local/setup.ps1 first."
}

if ($currentContext -ne "kind-local-dev") {
    Write-Host "Current kubectl context is '$currentContext'. Expected 'kind-local-dev'." -ForegroundColor Yellow
    Write-Host "Continuing because you may be using a custom local context." -ForegroundColor Yellow
}

$appNamespaceExists = kubectl get namespace $AppNamespace 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "App namespace '$AppNamespace' was not found. Run local/setup.ps1 before validating app metrics/logs." -ForegroundColor Yellow
}

Write-Step "Adding Helm repositories"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts | Out-Host
helm repo add grafana https://grafana.github.io/helm-charts | Out-Host
if (-not $SkipHelmRepoUpdate) {
    helm repo update prometheus-community grafana | Out-Host
}

Write-Step "Creating observability namespaces and Grafana secret"
$namespaceManifest = Join-Path $RepoRoot "kubernetes\observability\local\namespaces.yaml"
kubectl apply -f $namespaceManifest | Out-Host

$grafanaSecretYaml = kubectl create secret generic grafana-admin `
    --namespace $MonitoringNamespace `
    --from-literal=admin-user=$GrafanaAdminUser `
    --from-literal=admin-password=$GrafanaAdminPassword `
    --dry-run=client -o yaml
$grafanaSecretYaml | kubectl apply -f - | Out-Host

Write-Step "Installing kube-prometheus-stack"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
    -f (Join-Path $RepoRoot "helm\kube-prometheus-stack\values-local.yaml") `
    --namespace $MonitoringNamespace --create-namespace `
    --wait --timeout 600s | Out-Host

Write-Step "Installing Loki"
helm upgrade --install loki grafana/loki `
    -f (Join-Path $RepoRoot "helm\loki\values-local.yaml") `
    --namespace $MonitoringNamespace --create-namespace `
    --wait --timeout 600s | Out-Host

Write-Step "Installing Fluent Bit"
helm upgrade --install fluent-bit (Join-Path $RepoRoot "helm\fluent-bit") `
    -f (Join-Path $RepoRoot "helm\fluent-bit\values-local.yaml") `
    --namespace $LoggingNamespace --create-namespace `
    --wait --timeout 300s | Out-Host

Write-Step "Applying local ServiceMonitors, rules, and dashboard"
kubectl apply -k (Join-Path $RepoRoot "kubernetes\observability\local") | Out-Host
kubectl apply -f (Join-Path $RepoRoot "kubernetes\observability\dashboard-logging-troubleshooting.yaml") | Out-Host
kubectl apply -f (Join-Path $RepoRoot "kubernetes\observability\dashboard-system-metrics.yaml") | Out-Host

if (-not $SkipWait) {
    Write-Step "Waiting for observability workloads"
    kubectl rollout status daemonset/fluent-bit -n $LoggingNamespace --timeout=180s | Out-Host
    kubectl rollout status deployment -l app.kubernetes.io/name=grafana -n $MonitoringNamespace --timeout=300s | Out-Host
    kubectl rollout status deployment/loki-gateway -n $MonitoringNamespace --timeout=300s | Out-Host
}

Write-Step "Local observability setup complete"
Write-Host "Grafana:    kubectl port-forward -n $MonitoringNamespace svc/monitoring-grafana 3000:80"
Write-Host "Prometheus: kubectl port-forward -n $MonitoringNamespace svc/kube-prometheus-stack-prometheus 9090:9090"
Write-Host "Loki:       kubectl port-forward -n $MonitoringNamespace svc/loki-gateway 3100:80"
Write-Host "Grafana login: $GrafanaAdminUser / $GrafanaAdminPassword"