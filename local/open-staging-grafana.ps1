#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Opens a local port-forward to staging Grafana and prints login details.

.DESCRIPTION
    Updates kubeconfig for the staging EKS cluster, verifies the Grafana
    service and admin secret, syncs Grafana's persisted admin password to the
    secret value, prints the local Grafana URLs and credentials, then runs
    kubectl port-forward in the foreground.

    Keep this terminal open while using Grafana. Press Ctrl+C to stop the
    port-forward.
#>

param(
    [string]$ClusterName = "yr4-project-staging-eks",
    [string]$Region = "eu-west-1",
    [string]$MonitoringNamespace = "monitoring",
    [string]$GrafanaService = "monitoring-grafana",
    [string]$GrafanaSecret = "grafana-admin",
    [int]$LocalPort = 3000,
    [int]$ServicePort = 80,
    [string]$DashboardPath = "/d/year4-k6-staging",
    [switch]$SkipKubeconfigUpdate,
    [switch]$SkipAdminPasswordSync,
    [switch]$OpenBrowser
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-Tool($Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-LocalPortAvailable($Port) {
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

function Get-AvailableLocalPort($PreferredPort) {
    for ($port = $PreferredPort; $port -lt ($PreferredPort + 50); $port++) {
        if (Test-LocalPortAvailable $port) {
            return $port
        }
    }
    Write-Error "No available local port found from $PreferredPort to $($PreferredPort + 49)."
}

function ConvertFrom-Base64Utf8($Value) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

foreach ($tool in @("kubectl")) {
    if (-not (Test-Tool $tool)) {
        Write-Error "$tool is required. Install it or add it to PATH."
    }
}

if (-not $SkipKubeconfigUpdate) {
    if (-not (Test-Tool "aws")) {
        Write-Error "aws CLI is required unless -SkipKubeconfigUpdate is used."
    }

    Write-Step "Updating kubeconfig for $ClusterName"
    aws eks update-kubeconfig --name $ClusterName --region $Region | Out-Host
}

Write-Step "Checking Grafana service"
kubectl -n $MonitoringNamespace get svc $GrafanaService | Out-Host

Write-Step "Reading Grafana admin secret"
$secret = kubectl -n $MonitoringNamespace get secret $GrafanaSecret -o json | ConvertFrom-Json
$user = ConvertFrom-Base64Utf8 $secret.data.'admin-user'
$password = ConvertFrom-Base64Utf8 $secret.data.'admin-password'

if (-not $SkipAdminPasswordSync) {
    Write-Step "Syncing Grafana admin password to secret"
    $grafanaDeployment = kubectl -n $MonitoringNamespace get deploy -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}'
    if (-not $grafanaDeployment) {
        Write-Error "Could not find a Grafana deployment in namespace $MonitoringNamespace. Use -SkipAdminPasswordSync to skip this step."
    }

    kubectl -n $MonitoringNamespace rollout status "deployment/$grafanaDeployment" --timeout=120s | Out-Host
    kubectl -n $MonitoringNamespace exec "deployment/$grafanaDeployment" -c grafana -- grafana cli admin reset-admin-password $password | Out-Host
}

$selectedPort = Get-AvailableLocalPort $LocalPort
$baseUrl = "http://localhost:$selectedPort"
$dashboardUrl = "$baseUrl$DashboardPath"

Write-Step "Grafana access"
Write-Host "Grafana URL:      $baseUrl" -ForegroundColor Green
Write-Host "k6 dashboard URL: $dashboardUrl" -ForegroundColor Green
Write-Host "Username:         $user" -ForegroundColor Green
Write-Host "Password:         $password" -ForegroundColor Green

if ($OpenBrowser) {
    Start-Process $dashboardUrl
}

Write-Step "Starting port-forward"
Write-Host "Forwarding $baseUrl -> svc/$GrafanaService $ServicePort in namespace $MonitoringNamespace"
Write-Host "Keep this terminal open. Press Ctrl+C to stop."
kubectl -n $MonitoringNamespace port-forward "svc/$GrafanaService" "${selectedPort}:$ServicePort"