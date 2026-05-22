#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Opens production dashboard tunnels and prints dashboard login details.

.DESCRIPTION
    Wrapper around local/open-dashboards.ps1 with production defaults. The
    default local ports are offset from staging so staging and production
    dashboards can be opened at the same time.
#>

param(
    [string]$ClusterName = "",
    [string]$Region = "eu-west-1",
    [string]$MonitoringNamespace = "monitoring",
    [string]$IstioNamespace = "istio-system",
    [string]$ArgoCdNamespace = "argocd",
    [string]$ArgoRolloutsNamespace = "argo-rollouts",
    [string]$AppNamespace = "year4-project",
    [string]$GrafanaService = "",
    [string]$GrafanaSecret = "grafana-admin",
    [int]$LocalPort = 3300,
    [int]$ServicePort = 80,
    [int]$PrometheusPort = 9390,
    [int]$AlertmanagerPort = 9393,
    [int]$KialiPort = 23001,
    [int]$ArgoCdPort = 8081,
    [int]$ArgoRolloutsPort = 3101,
    [string]$DashboardPath = "/d/year4-operations-hub/year4-operations-hub",
    [switch]$SkipKubeconfigUpdate,
    [switch]$SkipAdminPasswordSync,
    [switch]$SkipArgoDashboards,
    [switch]$SkipRolloutsDashboard,
    [switch]$OpenBrowser,
    [switch]$PrintOnly
)

$parameters = @{
    Environment = "production"
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