#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Opens staging dashboard tunnels and prints dashboard login details.

.DESCRIPTION
    Wrapper around local/open-dashboards.ps1 with staging defaults. It opens
    the staging Grafana, Prometheus, Alertmanager when present, and Kiali
    tunnels. Argo CD and Argo Rollouts are discovered if they exist.
#>

param(
    [string]$ClusterName = "",
    [string]$Region = "eu-west-1",
    [string]$MonitoringNamespace = "monitoring",
    [string]$IstioNamespace = "istio-system",
    [string]$ArgoCdNamespace = "argocd",
    [string]$ArgoRolloutsNamespace = "argo-rollouts",
    [string]$AppNamespace = "year4-project-staging",
    [string]$GrafanaService = "",
    [string]$GrafanaSecret = "grafana-admin",
    [int]$LocalPort = 3000,
    [int]$ServicePort = 80,
    [int]$PrometheusPort = 9090,
    [int]$AlertmanagerPort = 9093,
    [int]$KialiPort = 20001,
    [int]$ArgoCdPort = 8080,
    [int]$ArgoRolloutsPort = 3100,
    [string]$DashboardPath = "/d/year4-operations-hub/year4-operations-hub",
    [switch]$SkipKubeconfigUpdate,
    [switch]$SkipAdminPasswordSync,
    [switch]$SkipArgoDashboards,
    [switch]$SkipRolloutsDashboard,
    [switch]$OpenBrowser,
    [switch]$PrintOnly
)

$parameters = @{
    Environment = "staging"
    ClusterName = $ClusterName
    Region = $Region
    MonitoringNamespace = $MonitoringNamespace
    IstioNamespace = $IstioNamespace
    ArgoCdNamespace = $ArgoCdNamespace
    ArgoRolloutsNamespace = $ArgoRolloutsNamespace
    AppNamespace = $AppNamespace
    GrafanaService = $GrafanaService
    GrafanaSecret = $GrafanaSecret
    LocalPort = $LocalPort
    ServicePort = $ServicePort
    PrometheusPort = $PrometheusPort
    AlertmanagerPort = $AlertmanagerPort
    KialiPort = $KialiPort
    ArgoCdPort = $ArgoCdPort
    ArgoRolloutsPort = $ArgoRolloutsPort
    DashboardPath = $DashboardPath
}

foreach ($switchName in @("SkipKubeconfigUpdate", "SkipAdminPasswordSync", "SkipArgoDashboards", "SkipRolloutsDashboard", "OpenBrowser", "PrintOnly")) {
    if ((Get-Variable $switchName -ValueOnly).IsPresent) {
        $parameters[$switchName] = $true
    }
}

$scriptPath = Join-Path $PSScriptRoot "open-dashboards.ps1"
& $scriptPath @parameters