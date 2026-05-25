<#
.SYNOPSIS
    Delete one Kubernetes pod to demonstrate automatic recovery.

.DESCRIPTION
    Selects one Ready/Running pod from a label selector, deletes it, and can
    wait until the workload has recovered to the same number of Ready pods.

    This is intended for demo failure injection. The default target is the
    auth-service workload because production normally runs more than one
    replica, so traffic should continue through the remaining pod while the
    replacement starts.

.EXAMPLE
    .\local\pod-deleter.ps1 -DryRun

.EXAMPLE
    .\local\pod-deleter.ps1 -Force -WaitForRecovery

.EXAMPLE
    .\local\pod-deleter.ps1 -Environment staging -Namespace year4-project-staging -Force -WaitForRecovery
#>

[CmdletBinding()]
param(
    [ValidateSet("production", "staging", "current")]
    [string]$Environment = "production",

    [string]$Namespace,
    [string]$LabelSelector = "app.kubernetes.io/name=auth-service",
    [string]$PodName,

    [string]$ProductionClusterName = "yr4-project-production-eks",
    [string]$StagingClusterName = "yr4-project-staging-eks",
    [string]$AwsRegion = "eu-west-1",

    [ValidateRange(30, 1800)]
    [int]$TimeoutSeconds = 300,

    [switch]$NoKubeconfigUpdate,
    [switch]$DryRun,
    [switch]$Force,
    [Alias("Wait")]
    [switch]$WaitForRecovery
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Get-PodList {
    param(
        [Parameter(Mandatory = $true)][string]$TargetNamespace,
        [Parameter(Mandatory = $true)][string]$Selector
    )

    $json = kubectl -n $TargetNamespace get pods -l $Selector -o json | ConvertFrom-Json
    return @($json.items)
}

function Test-PodReady {
    param([Parameter(Mandatory = $true)]$Pod)

    if ($Pod.metadata.deletionTimestamp) { return $false }
    if ($Pod.status.phase -ne "Running") { return $false }
    if (-not $Pod.status.containerStatuses) { return $false }

    $notReady = @($Pod.status.containerStatuses | Where-Object { -not $_.ready })
    return $notReady.Count -eq 0
}

function Format-PodSummary {
    param([Parameter(Mandatory = $true)]$Pod)

    $readyContainers = @($Pod.status.containerStatuses | Where-Object { $_.ready }).Count
    $totalContainers = @($Pod.status.containerStatuses).Count
    return "{0} ready={1}/{2} phase={3} node={4}" -f $Pod.metadata.name, $readyContainers, $totalContainers, $Pod.status.phase, $Pod.spec.nodeName
}

if (-not $Namespace) {
    switch ($Environment) {
        "staging" { $Namespace = "year4-project-staging" }
        default { $Namespace = "year4-project" }
    }
}

if (-not $NoKubeconfigUpdate -and $Environment -ne "current") {
    $clusterName = if ($Environment -eq "staging") { $StagingClusterName } else { $ProductionClusterName }
    Write-Host "Updating kubeconfig for $clusterName in $AwsRegion..."
    Invoke-Checked aws "eks" "update-kubeconfig" "--name" $clusterName "--region" $AwsRegion | Out-Null
}

$context = kubectl config current-context
Write-Host "Context: $context"
Write-Host "Namespace: $Namespace"
Write-Host "Selector: $LabelSelector"

if ($PodName) {
    $targetPod = kubectl -n $Namespace get pod $PodName -o json | ConvertFrom-Json
    $matchingPods = Get-PodList -TargetNamespace $Namespace -Selector $LabelSelector
} else {
    $matchingPods = Get-PodList -TargetNamespace $Namespace -Selector $LabelSelector
    if (-not $matchingPods -or $matchingPods.Count -eq 0) {
        throw "No pods found in namespace '$Namespace' for selector '$LabelSelector'."
    }

    $targetPod = @($matchingPods | Where-Object { Test-PodReady $_ } | Sort-Object { $_.metadata.creationTimestamp } | Select-Object -First 1)[0]
    if (-not $targetPod) {
        $targetPod = @($matchingPods | Where-Object { $_.status.phase -eq "Running" -and -not $_.metadata.deletionTimestamp } | Sort-Object { $_.metadata.creationTimestamp } | Select-Object -First 1)[0]
    }
    if (-not $targetPod) {
        throw "No Running pod found in namespace '$Namespace' for selector '$LabelSelector'."
    }
}

$readyBefore = @($matchingPods | Where-Object { Test-PodReady $_ }).Count
$targetName = [string]$targetPod.metadata.name

Write-Host ""
Write-Host "Current matching pods:"
kubectl -n $Namespace get pods -l $LabelSelector -o wide
Write-Host ""
Write-Host "Selected pod: $(Format-PodSummary $targetPod)"
Write-Host "Ready pods before deletion: $readyBefore"

if ($DryRun) {
    Write-Host "Dry run only. No pod was deleted."
    exit 0
}

if (-not $Force) {
    $answer = Read-Host "Type DELETE to delete pod '$targetName'"
    if ($answer -ne "DELETE") {
        throw "Cancelled. Pod '$targetName' was not deleted."
    }
}

Write-Host "Deleting pod '$targetName'..."
Invoke-Checked kubectl "-n" $Namespace "delete" "pod" $targetName

if (-not $WaitForRecovery) {
    Write-Host "Pod delete requested. Use 'kubectl -n $Namespace get pods -l $LabelSelector -w' to watch recovery."
    exit 0
}

Write-Host "Waiting for recovery to at least $readyBefore Ready pod(s)..."
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

while ((Get-Date) -lt $deadline) {
    $currentPods = Get-PodList -TargetNamespace $Namespace -Selector $LabelSelector
    $readyNow = @($currentPods | Where-Object { Test-PodReady $_ }).Count
    $targetStillActive = @($currentPods | Where-Object { $_.metadata.name -eq $targetName -and -not $_.metadata.deletionTimestamp }).Count -gt 0

    Write-Host ("{0} ready={1}/{2}" -f (Get-Date -Format "HH:mm:ss"), $readyNow, $readyBefore)

    if (-not $targetStillActive -and $readyNow -ge $readyBefore) {
        Write-Host ""
        Write-Host "Recovery complete."
        kubectl -n $Namespace get pods -l $LabelSelector -o wide
        exit 0
    }

    Start-Sleep -Seconds 5
}

kubectl -n $Namespace get pods -l $LabelSelector -o wide
throw "Timed out after $TimeoutSeconds seconds waiting for pod recovery."