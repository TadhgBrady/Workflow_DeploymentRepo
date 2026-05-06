#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates the local Kind observability stack end to end.

.DESCRIPTION
    Checks Kubernetes workload readiness, optionally generates local app traffic,
    port-forwards Prometheus and Loki, and validates that metrics and logs are
    queryable. Run after local/setup.ps1 and local/setup-observability.ps1.
#>

param(
    [string]$AppBaseUrl = "http://localhost:30080",
    [string]$MonitoringNamespace = "monitoring",
    [string]$LoggingNamespace = "logging",
    [string]$AppNamespace = "year4-project-local",
    [int]$AppPortForwardPort = 30081,
    [switch]$SkipTraffic,
    [switch]$KeepPortForwards
)

$ErrorActionPreference = "Stop"
$warnings = 0
$failures = 0
$portForwards = @()

function Write-Step($Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Add-Warning($Message) {
    $script:warnings++
    Write-Host "WARN: $Message" -ForegroundColor Yellow
}

function Add-Failure($Message) {
    $script:failures++
    Write-Host "FAIL: $Message" -ForegroundColor Red
}

function Test-AppBaseUrl($BaseUrl) {
    $base = $BaseUrl.TrimEnd("/")
    try {
        Invoke-WebRequest -Uri "${base}/health" -UseBasicParsing -TimeoutSec 10 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Invoke-AppTraffic($BaseUrl) {
    $base = $BaseUrl.TrimEnd("/")
    foreach ($path in @("/health", "/ready")) {
        try {
            Invoke-WebRequest -Uri "${base}${path}" -UseBasicParsing -TimeoutSec 15 | Out-Null
            Write-Host "Traffic OK: $path" -ForegroundColor Green
        } catch {
            Add-Warning "Could not call $path on ${base}: $($_.Exception.Message)"
        }
    }

    try {
        Invoke-WebRequest `
            -Uri "$base/api/v1/auth/login" `
            -Method Post `
            -ContentType "application/json" `
            -UseBasicParsing `
            -Body '{"email":"observability-local@example.com","password":"wrong-password"}' `
            -TimeoutSec 15 | Out-Null
        Add-Warning "Unexpected successful login response from ${base}/api/v1/auth/login"
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -ge 400 -and $statusCode -lt 500) {
            Write-Host "Traffic OK: generated expected failed auth attempt (HTTP $statusCode)" -ForegroundColor Green
        } else {
            Add-Warning "Could not generate auth traffic through ${base}: $($_.Exception.Message)"
        }
    }
}

function Start-PortForward($Name, $Namespace, $Service, $Mapping) {
    Write-Host "Starting port-forward for $Name ($Service $Mapping)"
    $process = Start-Process -FilePath "kubectl" `
        -ArgumentList @("-n", $Namespace, "port-forward", $Service, $Mapping) `
        -PassThru `
        -WindowStyle Hidden
    $script:portForwards += $process
    Start-Sleep -Seconds 4
    return $process
}

function Resolve-AppTrafficBaseUrl {
    $configuredBaseUrl = $AppBaseUrl.TrimEnd("/")
    if (Test-AppBaseUrl $configuredBaseUrl) {
        return $configuredBaseUrl
    }

    Add-Warning "Could not reach ${configuredBaseUrl}/health; falling back to kubectl port-forward for nginx-gateway."
    Start-PortForward "App gateway" $AppNamespace "svc/nginx-gateway" "${AppPortForwardPort}:80" | Out-Null

    $forwardedBaseUrl = "http://127.0.0.1:${AppPortForwardPort}"
    if (Test-AppBaseUrl $forwardedBaseUrl) {
        return $forwardedBaseUrl
    }

    Add-Failure "Could not reach app gateway through ${configuredBaseUrl} or ${forwardedBaseUrl}."
    return $forwardedBaseUrl
}

function Invoke-PrometheusQuery($Query) {
    $encoded = [uri]::EscapeDataString($Query)
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:9090/api/v1/query?query=$encoded" -TimeoutSec 20
    if ($response.status -ne "success") {
        throw "Prometheus query failed: $Query"
    }
    return $response.data.result
}

function Invoke-LokiQuery($Query) {
    $encoded = [uri]::EscapeDataString($Query)
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:3100/loki/api/v1/query_range?query=$encoded&limit=20" -TimeoutSec 20
    if ($response.status -ne "success") {
        throw "Loki query failed: $Query"
    }
    return $response.data.result
}

try {
    Write-Step "Checking Kubernetes workloads"
    kubectl get pods -n $AppNamespace | Out-Host
    kubectl get pods -n $MonitoringNamespace | Out-Host
    kubectl get pods -n $LoggingNamespace | Out-Host

    kubectl wait --for=condition=Ready pods --all -n $MonitoringNamespace --timeout=300s | Out-Host
    kubectl wait --for=condition=Ready pods --all -n $LoggingNamespace --timeout=180s | Out-Host

    if (-not $SkipTraffic) {
        Write-Step "Generating local app traffic"
        $trafficBaseUrl = Resolve-AppTrafficBaseUrl
        Invoke-AppTraffic $trafficBaseUrl
    }

    Write-Step "Querying Prometheus"
    Start-PortForward "Prometheus" $MonitoringNamespace "svc/kube-prometheus-stack-prometheus" "9090:9090" | Out-Null

    $mandatoryPromQueries = @(
        "up",
        "up{namespace=`"$AppNamespace`"}",
        "up{namespace=`"$LoggingNamespace`"}",
        "fluentbit_input_records_total"
    )

    foreach ($query in $mandatoryPromQueries) {
        try {
            $result = Invoke-PrometheusQuery $query
            if ($result.Count -eq 0) {
                Add-Failure "Prometheus query returned no results: $query"
            } else {
                Write-Host "PASS Prometheus query has $($result.Count) result(s): $query" -ForegroundColor Green
            }
        } catch {
            Add-Failure $_.Exception.Message
        }
    }

    $informationalPromQueries = @(
        "http_requests_total{namespace=`"$AppNamespace`"}",
        "http_request_duration_seconds_bucket{namespace=`"$AppNamespace`"}",
        "db_query_duration_seconds_bucket",
        "db_pool_connections",
        "cache_hits_total",
        "cache_operation_duration_seconds_bucket",
        "auth_attempts_total",
        "auth_token_validations_total"
    )

    foreach ($query in $informationalPromQueries) {
        try {
            $result = Invoke-PrometheusQuery $query
            if ($result.Count -eq 0) {
                Add-Warning "Prometheus query returned no results yet: $query"
            } else {
                Write-Host "PASS Prometheus query has $($result.Count) result(s): $query" -ForegroundColor Green
            }
        } catch {
            Add-Warning $_.Exception.Message
        }
    }

    Write-Step "Querying Loki"
    Start-PortForward "Loki" $MonitoringNamespace "svc/loki-gateway" "3100:80" | Out-Null

    foreach ($query in @('{environment="local"}', '{cluster="kind-local",environment="local"}')) {
        try {
            $result = Invoke-LokiQuery $query
            if ($result.Count -eq 0) {
                Add-Failure "Loki query returned no log streams: $query"
            } else {
                Write-Host "PASS Loki query has $($result.Count) stream(s): $query" -ForegroundColor Green
            }
        } catch {
            Add-Failure $_.Exception.Message
        }
    }

    Write-Step "Validation summary"
    if ($warnings -gt 0) {
        Write-Host "$warnings warning(s) recorded. These usually mean no traffic has hit a metric path yet." -ForegroundColor Yellow
    }

    if ($failures -gt 0) {
        Write-Host "$failures failure(s) recorded." -ForegroundColor Red
        exit 1
    }

    Write-Host "Local observability validation passed." -ForegroundColor Green
} finally {
    if (-not $KeepPortForwards) {
        foreach ($process in $portForwards) {
            if ($process -and -not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}