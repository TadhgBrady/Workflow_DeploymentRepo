<#
.SYNOPSIS
    Tears down the local Kubernetes development environment.

.PARAMETER KeepInfra
    Keep the PostgreSQL/Redis/Mailpit containers running.

.PARAMETER KeepCluster
    Keep the kind cluster but delete the namespace.

.EXAMPLE
    .\teardown.ps1                # Full teardown
    .\teardown.ps1 -KeepInfra     # Delete cluster but keep DB/Redis
    .\teardown.ps1 -KeepCluster   # Delete namespace only, keep cluster + infra
#>

param(
    [switch]$KeepInfra,
    [switch]$KeepCluster
)

$ErrorActionPreference = "Continue"
$LocalDir = $PSScriptRoot
$CLUSTER_NAME = "local-dev"
$NAMESPACE = "year4-project-local"

function Write-Step($msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

if ($KeepCluster) {
    Write-Step "Deleting namespace $NAMESPACE (keeping cluster)"
    kubectl delete namespace $NAMESPACE --timeout=60s 2>$null
} else {
    Write-Step "Deleting kind cluster '$CLUSTER_NAME'"
    kind delete cluster --name $CLUSTER_NAME 2>$null
}

if (-not $KeepInfra) {
    Write-Step "Stopping infrastructure containers"
    docker compose -f "$LocalDir\docker-compose.infra.yaml" down -v
}

Write-Host "`n    Teardown complete." -ForegroundColor Green
Write-Host ""
