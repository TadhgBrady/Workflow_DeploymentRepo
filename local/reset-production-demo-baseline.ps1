<#
.SYNOPSIS
    Reset production to the demo baseline version.

.DESCRIPTION
    Rewrites the production GitOps image pins to the known demo baseline,
    validates the rendered production overlay, commits and pushes the change,
    then optionally starts synthetic mesh traffic and asks Argo CD to sync.

    Use this after a demo promotion when production needs to be put back to
    the pre-demo baseline for the next run.

.EXAMPLE
    .\local\reset-production-demo-baseline.ps1

.EXAMPLE
    .\local\reset-production-demo-baseline.ps1 -DryRun

.EXAMPLE
    .\local\reset-production-demo-baseline.ps1 -SkipArgoSync -SkipTraffic
#>

[CmdletBinding()]
param(
    [ValidatePattern("^[0-9a-fA-F]{7,40}$")]
    [string]$BaselineVersion = "097716b7",

    [string]$ImageRepository = $(if ($env:IMAGE_REPOSITORY) { $env:IMAGE_REPOSITORY } else { "bencev04/4th-year-proj-tadgh-bence" }),

    [string]$ClusterName = "yr4-project-production-eks",
    [string]$AwsRegion = "eu-west-1",
    [string]$Namespace = "year4-project",
    [string]$ArgocdNamespace = "argocd",
    [string]$ApplicationName = "year4-project-production",
    [string]$GitRemote = "origin",
    [string]$GitBranch = "main",
    [string]$CommitMessage,

    [ValidateRange(1, 240)]
    [int]$TrafficMinutes = 45,

    [ValidateRange(1, 60)]
    [int]$TrafficIntervalSeconds = 5,

    [int]$ArgoTimeoutSeconds = 900,
    [int]$RolloutTimeoutSeconds = 1800,

    [switch]$NoKubeconfigUpdate,
    [switch]$SkipServerDryRun,
    [switch]$SkipCommit,
    [switch]$SkipPush,
    [switch]$SkipArgoSync,
    [switch]$SkipTraffic,
    [switch]$SkipRolloutWait,
    [switch]$AllowDirty,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ProductionOverlay = Join-Path $RepoRoot "kubernetes\overlays\production"
$ImagePinsDir = Join-Path $ProductionOverlay "image-pins"
$KustomizationPath = Join-Path $ProductionOverlay "kustomization.yaml"
$LocalBinDir = Join-Path $PSScriptRoot "bin"
$TrafficScript = Join-Path $PSScriptRoot "start-production-canary-traffic.ps1"
$BaselineVersion = $BaselineVersion.ToLowerInvariant()

if (Test-Path $LocalBinDir) {
    $env:PATH = "$LocalBinDir;$env:PATH"
}

$Services = @(
    @{ File = "nginx-gateway"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "nginx-gateway"; Container = "nginx"; Tag = "nginx" },
    @{ File = "auth-service"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "auth-service"; Container = "auth-service"; Tag = "auth-service" },
    @{ File = "user-bl-service"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "user-bl-service"; Container = "user-bl-service"; Tag = "user-bl-service" },
    @{ File = "user-db-access-service"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "user-db-access-service"; Container = "user-db-access-service"; Tag = "user-db-access-service" },
    @{ File = "job-bl-service-deployment"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "job-bl-service-deployment"; Container = "job-bl-service"; Tag = "job-bl-service" },
    @{ File = "job-db-access-service-deployment"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "job-db-access-service-deployment"; Container = "job-db-access-service"; Tag = "job-db-access-service" },
    @{ File = "customer-bl-service"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "customer-bl-service"; Container = "customer-bl-service"; Tag = "customer-bl-service" },
    @{ File = "customer-db-access-service"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "customer-db-access-service"; Container = "customer-db-access-service"; Tag = "customer-db-access-service" },
    @{ File = "admin-bl-service"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "admin-bl-service"; Container = "admin-bl-service"; Tag = "admin-bl-service" },
    @{ File = "maps-access-service"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "maps-access-service"; Container = "maps-access-service"; Tag = "maps-access-service" },
    @{ File = "notification-service"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "notification-service"; Container = "notification-service"; Tag = "notification-service" },
    @{ File = "frontend-deployment"; ApiVersion = "apps/v1"; Kind = "Deployment"; Resource = "frontend-deployment"; Container = "frontend"; Tag = "frontend" },
    @{ File = "migration-runner"; ApiVersion = "batch/v1"; Kind = "Job"; Resource = "migration-runner"; Container = "migration-runner"; Tag = "migration-runner" }
)

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )
    if ($DryRun) {
        Write-Host "DRY-RUN: $FilePath $($Arguments -join ' ')"
        return
    }

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Assert-Tool {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is required. Install it or make sure it is on PATH."
    }
}

function Get-ArgocdCliPath {
    $localArgocd = Join-Path $LocalBinDir "argocd.exe"
    if (Test-Path $localArgocd) { return $localArgocd }
    return "argocd"
}

function Get-RolloutsCliPath {
    $localRollouts = Join-Path $LocalBinDir "kubectl-argo-rollouts.exe"
    if (Test-Path $localRollouts) { return $localRollouts }
    return "kubectl-argo-rollouts"
}

function Write-ImagePinFile {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Service
    )

    $image = "${ImageRepository}:$($Service.Tag)-$BaselineVersion"
    $path = Join-Path $ImagePinsDir "$($Service.File).yaml"
    $text = @"
# Generated by local/reset-production-demo-baseline.ps1.
# Demo baseline production image pin.
apiVersion: $($Service.ApiVersion)
kind: $($Service.Kind)
metadata:
  name: $($Service.Resource)
spec:
  template:
    spec:
      containers:
        - name: $($Service.Container)
          image: $image
"@

    if ($DryRun) {
        Write-Host "DRY-RUN: would write $path -> $image"
        return
    }

    Set-Content -Path $path -Value $text -Encoding ascii
}

function Set-ProductionVersionLabel {
    $content = Get-Content $KustomizationPath -Raw
    $pattern = 'app\.kubernetes\.io/version:\s*"[^"]*"'
    if ($content -notmatch $pattern) {
        throw "Could not find app.kubernetes.io/version in $KustomizationPath"
    }
    $replacement = "app.kubernetes.io/version: `"$BaselineVersion`""
    $updated = [regex]::Replace($content, $pattern, $replacement, 1)

    if ($DryRun) {
        Write-Host "DRY-RUN: would set production app.kubernetes.io/version to $BaselineVersion"
        return
    }

    $updated = $updated.TrimEnd("`r", "`n") + "`r`n"
    [System.IO.File]::WriteAllText($KustomizationPath, $updated, [System.Text.Encoding]::ASCII)
}

function Assert-GitState {
    $currentBranch = (git -C $RepoRoot branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $currentBranch) {
        throw "Could not determine current git branch."
    }
    if ($currentBranch -ne $GitBranch) {
        throw "Current branch is '$currentBranch', but production reset expects '$GitBranch'. Checkout $GitBranch or pass -GitBranch $currentBranch intentionally."
    }

    $trackedChanges = git -C $RepoRoot status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0) { throw "git status failed."
    }
    if ($trackedChanges -and -not $AllowDirty) {
        throw "Tracked files are already modified. Commit/stash them, or rerun with -AllowDirty."
    }
}

function Validate-ProductionOverlay {
    Write-Step "Validating production overlay"
    $renderPath = Join-Path ([System.IO.Path]::GetTempPath()) "prod-demo-baseline-render.yaml"

    if ($DryRun) {
        Write-Host "DRY-RUN: kubectl kustomize kubernetes/overlays/production > $renderPath"
        if (-not $SkipServerDryRun) {
            Write-Host "DRY-RUN: kubectl apply --dry-run=server -f $renderPath -o name"
        }
        return
    }

    kubectl kustomize (Join-Path $RepoRoot "kubernetes\overlays\production") | Set-Content -Encoding ascii -Path $renderPath
    if ($LASTEXITCODE -ne 0) { throw "kubectl kustomize failed." }

    $renderedImages = Select-String -Path $renderPath -Pattern "$([regex]::Escape($ImageRepository)):[^\s]+" -AllMatches |
        ForEach-Object { $_.Matches.Value } |
        Sort-Object -Unique
    $unexpectedImages = $renderedImages | Where-Object { $_ -notmatch "-$([regex]::Escape($BaselineVersion))$" }
    if ($unexpectedImages) {
        throw "Rendered production overlay contains non-baseline images:`n$($unexpectedImages -join "`n")"
    }

    if (-not $SkipServerDryRun) {
        kubectl apply --dry-run=server -f $renderPath -o name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Server-side dry-run failed." }
    }

    Write-Ok "production overlay renders with $BaselineVersion images"
}

function Commit-And-Push {
    Write-Step "Committing demo baseline reset"
    if ($DryRun) {
        Write-Host "DRY-RUN: git add production image pins and kustomization"
        Write-Host "DRY-RUN: git commit -m '$CommitMessage'"
        if (-not $SkipPush) { Write-Host "DRY-RUN: git push $GitRemote HEAD:$GitBranch" }
        return
    }

    git -C $RepoRoot add `
        kubernetes/overlays/production/kustomization.yaml `
        kubernetes/overlays/production/image-pins
    if ($LASTEXITCODE -ne 0) { throw "git add failed." }

    $cachedChanges = git -C $RepoRoot diff --cached --name-only
    if ($LASTEXITCODE -ne 0) { throw "git diff --cached failed." }
    if (-not $cachedChanges) {
        Write-Ok "production GitOps files already match $BaselineVersion"
        return
    }

    git -C $RepoRoot diff --cached --check
    if ($LASTEXITCODE -ne 0) { throw "git diff --cached --check failed." }

    if ($SkipCommit) {
        Write-Warn "changes are staged but not committed because -SkipCommit was set"
        return
    }

    git -C $RepoRoot commit -m $CommitMessage | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "git commit failed." }

    if (-not $SkipPush) {
        git -C $RepoRoot push $GitRemote "HEAD:$GitBranch"
        if ($LASTEXITCODE -ne 0) { throw "git push failed." }
    }
}

function Start-CanaryTraffic {
    if ($SkipTraffic) { return }
    if (-not (Test-Path $TrafficScript)) {
        Write-Warn "traffic script not found at $TrafficScript; skipping synthetic canary traffic"
        return
    }

    Write-Step "Starting synthetic traffic for canary analysis"
    if ($DryRun) {
        Write-Host "DRY-RUN: $TrafficScript -DurationMinutes $TrafficMinutes -IntervalSeconds $TrafficIntervalSeconds -Namespace $Namespace -ClusterName $ClusterName -AwsRegion $AwsRegion -WaitForPod"
        return
    }

    & $TrafficScript `
        -DurationMinutes $TrafficMinutes `
        -IntervalSeconds $TrafficIntervalSeconds `
        -Namespace $Namespace `
        -ClusterName $ClusterName `
        -AwsRegion $AwsRegion `
        -NoKubeconfigUpdate `
        -WaitForPod
    if ($LASTEXITCODE -ne 0) { throw "traffic script failed." }
}

function Sync-ArgoApplication {
    if ($SkipArgoSync) { return }

    Write-Step "Syncing Argo CD application"
    $argocdPath = Get-ArgocdCliPath
    if ($argocdPath -eq "argocd") { Assert-Tool "argocd" }

    Invoke-Checked kubectl "-n" $ArgocdNamespace "annotate" "application" $ApplicationName "argocd.argoproj.io/refresh=hard" "--overwrite"
    Invoke-Checked kubectl "config" "set-context" "--current" "--namespace" $ArgocdNamespace
    Invoke-Checked $argocdPath "--core" "app" "sync" $ApplicationName "--timeout" ([string]$ArgoTimeoutSeconds)

    if ($SkipRolloutWait) { return }

    Write-Step "Waiting for production rollouts"
    $rolloutsPath = Get-RolloutsCliPath
    if ($rolloutsPath -eq "kubectl-argo-rollouts") { Assert-Tool "kubectl-argo-rollouts" }

    foreach ($service in ($Services | Where-Object { $_.Kind -eq "Deployment" })) {
        Invoke-Checked $rolloutsPath "status" $service.Resource "-n" $Namespace "--timeout" "${RolloutTimeoutSeconds}s"
    }
}

if (-not (Test-Path $ProductionOverlay)) { throw "Production overlay not found: $ProductionOverlay" }
if (-not (Test-Path $ImagePinsDir)) { throw "Production image pins directory not found: $ImagePinsDir" }
if (-not (Test-Path $KustomizationPath)) { throw "Production kustomization not found: $KustomizationPath" }
if (($SkipCommit -or $SkipPush) -and -not $SkipArgoSync) {
    throw "Use -SkipArgoSync when -SkipCommit or -SkipPush is set. Argo CD can only sync committed and pushed GitOps changes."
}

if (-not $CommitMessage) {
    $CommitMessage = "fix: reset production demo baseline to $BaselineVersion"
}

Write-Step "Preparing production demo baseline reset"
Write-Host "  Baseline:  $BaselineVersion"
Write-Host "  Namespace: $Namespace"
Write-Host "  App:       $ApplicationName"
Write-Host "  Branch:    $GitBranch"

Assert-Tool "git"
Assert-Tool "kubectl"
if (-not $NoKubeconfigUpdate -and -not $DryRun) {
    Assert-Tool "aws"
    Invoke-Checked aws "eks" "update-kubeconfig" "--name" $ClusterName "--region" $AwsRegion
}

Assert-GitState

Write-Step "Writing production image pins"
foreach ($service in $Services) {
    Write-ImagePinFile -Service $service
}
Set-ProductionVersionLabel

Validate-ProductionOverlay
Commit-And-Push
Start-CanaryTraffic
Sync-ArgoApplication

Write-Step "Done"
Write-Ok "production reset path is ready for baseline $BaselineVersion"