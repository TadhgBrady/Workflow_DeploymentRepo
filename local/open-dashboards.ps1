#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Opens local tunnels to the project dashboards and prints access details.

.DESCRIPTION
    Updates kubeconfig for staging or production, discovers the installed
    dashboard services, prints credentials stored in Kubernetes Secrets, then
    starts local port-forwards for Grafana, Prometheus, Alertmanager when
    present, Kiali, Argo CD, and the Argo Rollouts dashboard.

    Keep this terminal open while using the dashboards. Press Ctrl+C to stop all
    tunnels started by this script.
#>

param(
    [ValidateSet("staging", "production", "current")]
    [string]$Environment = "staging",
    [string]$ClusterName = "",
    [string]$Region = "eu-west-1",
    [string]$MonitoringNamespace = "monitoring",
    [string]$IstioNamespace = "istio-system",
    [string]$ArgoCdNamespace = "argocd",
    [string]$ArgoRolloutsNamespace = "argo-rollouts",
    [string]$AppNamespace = "",
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

$ErrorActionPreference = "Stop"
$script:StartedProcesses = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$script:DashboardSummaries = New-Object System.Collections.Generic.List[object]
$script:Warnings = 0

function Write-Step($Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-WarningMessage($Message) {
    $script:Warnings++
    Write-Host "WARN: $Message" -ForegroundColor Yellow
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
    for ($port = $PreferredPort; $port -lt ($PreferredPort + 100); $port++) {
        if (Test-LocalPortAvailable $port) {
            return $port
        }
    }
    Write-Error "No available local port found from $PreferredPort to $($PreferredPort + 99)."
}

function ConvertFrom-Base64Utf8($Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Get-KubernetesSecret($Namespace, $SecretName) {
    $secretJson = & kubectl -n $Namespace get secret $SecretName -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$secretJson)) {
        return $null
    }
    return $secretJson | ConvertFrom-Json
}

function Get-SecretDataValue($Secret, $Key) {
    if ($null -eq $Secret -or $null -eq $Secret.data) {
        return $null
    }

    $property = $Secret.data.PSObject.Properties[$Key]
    if ($null -eq $property) {
        return $null
    }

    return ConvertFrom-Base64Utf8 $property.Value
}

function Resolve-ServiceName($Namespace, [string[]]$Candidates, $LabelSelector = "") {
    if (-not (Test-NamespaceExists $Namespace)) {
        return $null
    }

    foreach ($candidate in $Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        $serviceName = & kubectl -n $Namespace get svc $candidate -o jsonpath='{.metadata.name}' 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$serviceName)) {
            return ([string]$serviceName).Trim()
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LabelSelector)) {
        $serviceName = & kubectl -n $Namespace get svc -l $LabelSelector -o jsonpath='{.items[0].metadata.name}' 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$serviceName)) {
            return ([string]$serviceName).Trim()
        }
    }

    return $null
}

function Test-NamespaceExists($Namespace) {
    try {
        $namespaceName = & kubectl get namespace $Namespace -o name --ignore-not-found 2>$null
        return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$namespaceName))
    } catch {
        return $false
    }
}

function Join-LocalUrl($Port, $Path = "") {
    $baseUrl = "http://localhost:$Port"
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $baseUrl
    }
    if ($Path.StartsWith("/")) {
        return "$baseUrl$Path"
    }
    return "$baseUrl/$Path"
}

function New-UrlItem($Label, $Url) {
    return [pscustomobject]@{
        Label = $Label
        Url = $Url
    }
}

function Add-DashboardSummary($Name, $Urls, $Login, $Username = "", $SecretValue = "", $ProcessId = "") {
    $script:DashboardSummaries.Add([pscustomobject]@{
        Name = $Name
        Urls = $Urls
        Login = $Login
        Username = $Username
        SecretValue = $SecretValue
        ProcessId = $ProcessId
    })
}

function Start-ServiceTunnel($Name, $Namespace, $ServiceName, $PreferredLocalPort, $RemotePort) {
    $selectedPort = Get-AvailableLocalPort $PreferredLocalPort
    if ($PrintOnly) {
        return [pscustomobject]@{
            LocalPort = $selectedPort
            ProcessId = "not started (-PrintOnly)"
        }
    }

    $mapping = "${selectedPort}:$RemotePort"
    $arguments = @("-n", $Namespace, "port-forward", "svc/$ServiceName", $mapping)
    Write-Host ("Starting " + $Name + " tunnel: localhost:" + $selectedPort + " -> " + $Namespace + "/svc/" + $ServiceName + ":" + $RemotePort)
    $process = Start-Process -FilePath "kubectl" -ArgumentList $arguments -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2

    if ($process.HasExited) {
        Write-WarningMessage "$Name tunnel process exited immediately. Check service $Namespace/svc/$ServiceName and local port $selectedPort."
        return [pscustomobject]@{
            LocalPort = $selectedPort
            ProcessId = "failed"
        }
    }

    $script:StartedProcesses.Add($process)
    return [pscustomobject]@{
        LocalPort = $selectedPort
        ProcessId = $process.Id
    }
}

function Start-RolloutsDashboard($PreferredLocalPort) {
    $selectedPort = Get-AvailableLocalPort $PreferredLocalPort
    if ($PrintOnly) {
        return [pscustomobject]@{
            LocalPort = $selectedPort
            ProcessId = "not started (-PrintOnly)"
        }
    }

    $arguments = @("argo", "rollouts", "dashboard", "-n", $AppNamespace, "--port", $selectedPort.ToString())
    Write-Host "Starting Argo Rollouts dashboard: http://localhost:$selectedPort"
    $process = Start-Process -FilePath "kubectl" -ArgumentList $arguments -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2

    if ($process.HasExited) {
        Write-WarningMessage "Argo Rollouts dashboard exited immediately. Install kubectl-argo-rollouts or run: kubectl argo rollouts dashboard -n $AppNamespace --port $selectedPort"
        return [pscustomobject]@{
            LocalPort = $selectedPort
            ProcessId = "failed"
        }
    }

    $script:StartedProcesses.Add($process)
    return [pscustomobject]@{
        LocalPort = $selectedPort
        ProcessId = $process.Id
    }
}

function Sync-GrafanaAdminSecret($Namespace, $AdminSecretValue) {
    if ([string]::IsNullOrWhiteSpace($AdminSecretValue)) {
        Write-WarningMessage "Skipping Grafana admin password sync because the password was not found in the secret."
        return
    }

    $deploymentName = & kubectl -n $Namespace get deploy -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$deploymentName)) {
        Write-WarningMessage "Could not find a Grafana deployment in namespace $Namespace."
        return
    }

    $deploymentName = ([string]$deploymentName).Trim()
    Write-Step "Syncing Grafana admin password to $Namespace/deployment/$deploymentName"
    & kubectl -n $Namespace rollout status "deployment/$deploymentName" --timeout=120s | Out-Host
    & kubectl -n $Namespace exec "deployment/$deploymentName" -c grafana -- grafana cli admin reset-admin-password $AdminSecretValue | Out-Host
}

function Write-DashboardSummaries {
    Write-Step "Dashboard access"
    foreach ($summary in $script:DashboardSummaries) {
        Write-Host "$($summary.Name)" -ForegroundColor Green
        foreach ($urlItem in $summary.Urls) {
            Write-Host "  $($urlItem.Label): $($urlItem.Url)"
        }
        Write-Host "  Login: $($summary.Login)"
        if (-not [string]::IsNullOrWhiteSpace($summary.Username)) {
            Write-Host "  Username: $($summary.Username)"
        }
        if (-not [string]::IsNullOrWhiteSpace($summary.SecretValue)) {
            Write-Host "  Password: $($summary.SecretValue)"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$summary.ProcessId)) {
            Write-Host "  Process: $($summary.ProcessId)"
        }
        Write-Host ""
    }

    Write-Host "CloudWatch Logs and GitLab are external browser sessions, so this script does not retrieve passwords for them." -ForegroundColor DarkGray
    if ($script:Warnings -gt 0) {
        Write-Host "$($script:Warnings) warning(s) recorded while opening dashboards." -ForegroundColor Yellow
    }
}

function Open-SelectedUrls {
    foreach ($summary in $script:DashboardSummaries) {
        $primaryUrl = $summary.Urls | Select-Object -First 1
        if ($primaryUrl) {
            Start-Process $primaryUrl.Url
        }
    }
}

function Stop-StartedProcesses {
    foreach ($process in $script:StartedProcesses) {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ClusterName)) {
    if ($Environment -eq "staging") {
        $ClusterName = "yr4-project-staging-eks"
    } elseif ($Environment -eq "production") {
        $ClusterName = "yr4-project-production-eks"
    }
}

if ([string]::IsNullOrWhiteSpace($AppNamespace)) {
    if ($Environment -eq "production") {
        $AppNamespace = "year4-project"
    } elseif ($Environment -eq "staging") {
        $AppNamespace = "year4-project-staging"
    }
}

foreach ($tool in @("kubectl")) {
    if (-not (Test-Tool $tool)) {
        Write-Error "$tool is required. Install it or add it to PATH."
    }
}

if (-not $SkipKubeconfigUpdate -and $Environment -ne "current") {
    if (-not (Test-Tool "aws")) {
        Write-Error "aws CLI is required unless -SkipKubeconfigUpdate is used."
    }

    Write-Step "Updating kubeconfig for $ClusterName"
    & aws eks update-kubeconfig --name $ClusterName --region $Region | Out-Host
}

try {
    Write-Step "Discovering dashboard services"

    $grafanaCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($GrafanaService)) {
        $grafanaCandidates += $GrafanaService
    }
    $grafanaCandidates += @("monitoring-grafana", "kube-prometheus-stack-grafana", "grafana")

    $grafanaServiceName = Resolve-ServiceName `
        -Namespace $MonitoringNamespace `
        -Candidates $grafanaCandidates `
        -LabelSelector "app.kubernetes.io/name=grafana"
    if ($grafanaServiceName) {
        $grafanaSecretObject = Get-KubernetesSecret $MonitoringNamespace $GrafanaSecret
        $grafanaUser = Get-SecretDataValue $grafanaSecretObject "admin-user"
        $grafanaPassword = Get-SecretDataValue $grafanaSecretObject "admin-password"

        if ([string]::IsNullOrWhiteSpace($grafanaUser)) {
            $grafanaUser = "admin"
            Write-WarningMessage "Grafana admin user was not found in secret $MonitoringNamespace/$GrafanaSecret; using admin as the likely username."
        }
        if ([string]::IsNullOrWhiteSpace($grafanaPassword)) {
            Write-WarningMessage "Grafana admin password was not found in secret $MonitoringNamespace/$GrafanaSecret."
        }

        if (-not $SkipAdminPasswordSync -and -not $PrintOnly) {
            Sync-GrafanaAdminSecret $MonitoringNamespace $grafanaPassword
        }

        $grafanaTunnel = Start-ServiceTunnel "Grafana" $MonitoringNamespace $grafanaServiceName $LocalPort $ServicePort
        $grafanaUrls = @(
            (New-UrlItem "Home" (Join-LocalUrl $grafanaTunnel.LocalPort "")),
            (New-UrlItem "Operations Hub" (Join-LocalUrl $grafanaTunnel.LocalPort $DashboardPath)),
            (New-UrlItem "Istio Mesh" (Join-LocalUrl $grafanaTunnel.LocalPort "/d/year4-istio-mesh/year4-istio-mesh"))
        )
        if ($Environment -ne "production") {
            $grafanaUrls += (New-UrlItem "k6 Staging Evidence" (Join-LocalUrl $grafanaTunnel.LocalPort "/d/year4-k6-staging/year4-staging-k6-load-gate"))
        }

        Add-DashboardSummary `
            -Name "Grafana" `
            -Urls $grafanaUrls `
            -Login "Grafana admin secret $MonitoringNamespace/$GrafanaSecret" `
            -Username $grafanaUser `
            -SecretValue $grafanaPassword `
            -ProcessId $grafanaTunnel.ProcessId
    } else {
        Write-WarningMessage "Grafana service was not found in namespace $MonitoringNamespace."
    }

    $prometheusServiceName = Resolve-ServiceName `
        -Namespace $MonitoringNamespace `
        -Candidates @("kube-prometheus-stack-prometheus", "prometheus-operated", "prometheus") `
        -LabelSelector "app.kubernetes.io/name=prometheus"
    if ($prometheusServiceName) {
        $prometheusTunnel = Start-ServiceTunnel "Prometheus" $MonitoringNamespace $prometheusServiceName $PrometheusPort 9090
        Add-DashboardSummary `
            -Name "Prometheus" `
            -Urls @((New-UrlItem "UI" (Join-LocalUrl $prometheusTunnel.LocalPort ""))) `
            -Login "No dashboard password; access is protected by kubeconfig plus local port-forward." `
            -ProcessId $prometheusTunnel.ProcessId
    } else {
        Write-WarningMessage "Prometheus service was not found in namespace $MonitoringNamespace."
    }

    $alertmanagerServiceName = Resolve-ServiceName `
        -Namespace $MonitoringNamespace `
        -Candidates @("kube-prometheus-stack-alertmanager", "alertmanager-operated", "alertmanager") `
        -LabelSelector "app.kubernetes.io/name=alertmanager"
    if ($alertmanagerServiceName) {
        $alertmanagerTunnel = Start-ServiceTunnel "Alertmanager" $MonitoringNamespace $alertmanagerServiceName $AlertmanagerPort 9093
        Add-DashboardSummary `
            -Name "Alertmanager" `
            -Urls @((New-UrlItem "UI" (Join-LocalUrl $alertmanagerTunnel.LocalPort ""))) `
            -Login "No dashboard password; access is protected by kubeconfig plus local port-forward." `
            -ProcessId $alertmanagerTunnel.ProcessId
    } else {
        Write-WarningMessage "Alertmanager service was not found. This is expected in production because Alertmanager is disabled there."
    }

    $kialiServiceName = Resolve-ServiceName `
        -Namespace $IstioNamespace `
        -Candidates @("kiali") `
        -LabelSelector "app.kubernetes.io/name=kiali"
    if ($kialiServiceName) {
        $kialiTunnel = Start-ServiceTunnel "Kiali" $IstioNamespace $kialiServiceName $KialiPort 20001
        Add-DashboardSummary `
            -Name "Kiali" `
            -Urls @(
                (New-UrlItem "UI" (Join-LocalUrl $kialiTunnel.LocalPort "/kiali")),
                (New-UrlItem "Root" (Join-LocalUrl $kialiTunnel.LocalPort ""))
            ) `
            -Login "Anonymous view-only access from kubernetes/service-mesh/kiali-values.yaml; no password." `
            -ProcessId $kialiTunnel.ProcessId
    } else {
        Write-WarningMessage "Kiali service was not found in namespace $IstioNamespace."
    }

    if (-not $SkipArgoDashboards) {
        $argoCdServiceName = Resolve-ServiceName `
            -Namespace $ArgoCdNamespace `
            -Candidates @("argocd-server") `
            -LabelSelector "app.kubernetes.io/name=argocd-server"
        if ($argoCdServiceName) {
            $argoSecret = Get-KubernetesSecret $ArgoCdNamespace "argocd-initial-admin-secret"
            $argoPassword = Get-SecretDataValue $argoSecret "password"
            if ([string]::IsNullOrWhiteSpace($argoPassword)) {
                Write-WarningMessage "Argo CD initial admin password was not found in $ArgoCdNamespace/argocd-initial-admin-secret. Use an existing Argo CD account or reset the admin password."
            }

            $argoTunnel = Start-ServiceTunnel "Argo CD" $ArgoCdNamespace $argoCdServiceName $ArgoCdPort 80
            Add-DashboardSummary `
                -Name "Argo CD" `
                -Urls @((New-UrlItem "UI" (Join-LocalUrl $argoTunnel.LocalPort ""))) `
                -Login "Argo CD local admin account" `
                -Username "admin" `
                -SecretValue $argoPassword `
                -ProcessId $argoTunnel.ProcessId
        } else {
            Write-WarningMessage "Argo CD service was not found in namespace $ArgoCdNamespace. This is expected until production GitOps bootstrap has run."
        }
    }

    if (-not $SkipArgoDashboards -and -not $SkipRolloutsDashboard) {
        if ([string]::IsNullOrWhiteSpace($AppNamespace)) {
            Write-WarningMessage "Skipping Argo Rollouts dashboard because AppNamespace is not set."
        } elseif (-not (Test-NamespaceExists $ArgoRolloutsNamespace)) {
            Write-WarningMessage "Argo Rollouts namespace $ArgoRolloutsNamespace was not found. This is expected until production GitOps bootstrap has run."
        } elseif (-not (Test-Tool "kubectl-argo-rollouts")) {
            Write-WarningMessage "kubectl-argo-rollouts is not installed, so the Argo Rollouts dashboard cannot be started."
        } else {
            $rolloutsTunnel = Start-RolloutsDashboard $ArgoRolloutsPort
            Add-DashboardSummary `
                -Name "Argo Rollouts" `
                -Urls @((New-UrlItem "UI" (Join-LocalUrl $rolloutsTunnel.LocalPort ""))) `
                -Login "No dashboard password; it uses your kubectl context." `
                -ProcessId $rolloutsTunnel.ProcessId
        }
    }

    Write-DashboardSummaries

    if ($OpenBrowser) {
        Open-SelectedUrls
    }

    if ($PrintOnly) {
        return
    }

    Write-Step "Tunnels running"
    Write-Host "Keep this terminal open. Press Ctrl+C to stop all local tunnels."
    while ($true) {
        foreach ($process in $script:StartedProcesses) {
            if ($process.HasExited) {
                Write-WarningMessage "A dashboard process exited: PID $($process.Id). Re-run the script if a tunnel stopped."
            }
        }
        Start-Sleep -Seconds 15
    }
} finally {
    Stop-StartedProcesses
}