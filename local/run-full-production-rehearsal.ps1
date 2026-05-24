<#
.SYNOPSIS
    Fully rehearse a production GitOps promotion locally in kind.

.DESCRIPTION
    This script resets a local kind cluster to an explicit old image version,
    then deploys an explicit new image version through the same production-style
    Argo CD, Argo Rollouts, Istio, and observability path used by AWS production.

    AWS-only dependencies are replaced with local equivalents:
    - RDS -> local PostgreSQL container
    - ElastiCache -> local Redis container
    - AWS Secrets Manager/ESO -> generated local Kubernetes Secrets
    - EKS/NLB -> kind plus local port-forwarding

.EXAMPLE
    .\local\run-full-production-rehearsal.ps1 -OldVersion 097716b7 -NewVersion b0e4e6b

.EXAMPLE
    .\local\run-full-production-rehearsal.ps1 -OldVersion 097716b7 -NewVersion b0e4e6b -DryRun
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-fA-F]{7,40}$")]
    [string]$OldVersion,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-fA-F]{7,40}$")]
    [string]$NewVersion,

    [string]$ImageRepository = $(if ($env:IMAGE_REPOSITORY) { $env:IMAGE_REPOSITORY } else { "bencev04/4th-year-proj-tadgh-bence" }),

    [string]$DevRepo = (Join-Path $PSScriptRoot "..\..\yr4-projectdevelopmentrepo"),

    [string]$RepoUrl = "https://gitlab.comp.dkit.ie/finalproject/Prototypes/yr4-projectdeploymentrepo.git",

    [string]$BaseRevision = "main",

    [string]$BranchPrefix = "local-production-rehearsal",

    [string]$KindClusterName = "local-dev",

    [string]$AppNamespace = "year4-project",

    [string]$ArgocdNamespace = "argocd",

    [int]$ArgoTimeoutSeconds = 900,

    [int]$RolloutTimeoutSeconds = 1800,

    [int]$TrafficSeconds = 900,

    [switch]$SkipImageBuild,

    [switch]$SkipOldImagePull,

    [switch]$SkipInfra,

    [switch]$SkipObservability,

    [switch]$SkipIstio,

    [switch]$SkipArgoInstall,

    [switch]$SkipSmokeTest,

    [switch]$AllowCliFallback,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$RepoRoot = Split-Path -Parent $PSScriptRoot
$LocalDir = $PSScriptRoot
$LocalBinDir = Join-Path $LocalDir "bin"
if (Test-Path $LocalBinDir) {
    $env:PATH = "$LocalBinDir;$env:PATH"
}
$OldVersion = $OldVersion.ToLowerInvariant()
$NewVersion = $NewVersion.ToLowerInvariant()
$OldBranch = "$BranchPrefix/old-$OldVersion"
$NewBranch = "$BranchPrefix/new-$NewVersion"

$Services = @(
    @{ Tag = "nginx"; Local = "nginx-gateway"; Resource = "nginx-gateway"; Container = "nginx"; Kind = "Deployment" },
    @{ Tag = "auth-service"; Local = "auth-service"; Resource = "auth-service"; Container = "auth-service"; Kind = "Deployment" },
    @{ Tag = "user-bl-service"; Local = "user-bl-service"; Resource = "user-bl-service"; Container = "user-bl-service"; Kind = "Deployment" },
    @{ Tag = "user-db-access-service"; Local = "user-db-access-service"; Resource = "user-db-access-service"; Container = "user-db-access-service"; Kind = "Deployment" },
    @{ Tag = "job-bl-service"; Local = "job-bl-service"; Resource = "job-bl-service-deployment"; Container = "job-bl-service"; Kind = "Deployment" },
    @{ Tag = "job-db-access-service"; Local = "job-db-access-service"; Resource = "job-db-access-service-deployment"; Container = "job-db-access-service"; Kind = "Deployment" },
    @{ Tag = "customer-bl-service"; Local = "customer-bl-service"; Resource = "customer-bl-service"; Container = "customer-bl-service"; Kind = "Deployment" },
    @{ Tag = "customer-db-access-service"; Local = "customer-db-access-service"; Resource = "customer-db-access-service"; Container = "customer-db-access-service"; Kind = "Deployment" },
    @{ Tag = "admin-bl-service"; Local = "admin-bl-service"; Resource = "admin-bl-service"; Container = "admin-bl-service"; Kind = "Deployment" },
    @{ Tag = "maps-access-service"; Local = "maps-access-service"; Resource = "maps-access-service"; Container = "maps-access-service"; Kind = "Deployment" },
    @{ Tag = "notification-service"; Local = "notification-service"; Resource = "notification-service"; Container = "notification-service"; Kind = "Deployment" },
    @{ Tag = "frontend"; Local = "frontend"; Resource = "frontend-deployment"; Container = "frontend"; Kind = "Deployment" },
    @{ Tag = "migration-runner"; Local = "migration-runner"; Resource = "migration-runner"; Container = "migration-runner"; Kind = "Job" }
)

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Invoke-Checked([string]$FilePath, [string[]]$Arguments, [string]$FailureMessage) {
    if ($DryRun) {
        Write-Host "DRY-RUN: $FilePath $($Arguments -join ' ')"
        return
    }
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Assert-Tool([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is required for a full local production rehearsal."
    }
}

function Assert-ProductionCli() {
    if ($DryRun -or $AllowCliFallback) { return }
    Assert-Tool "argocd"
    kubectl argo rollouts version > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl argo rollouts plugin is required for the closest production rehearsal. Install kubectl-argo-rollouts or rerun with -AllowCliFallback."
    }
}

function Get-DotEnvValue([string]$Path, [string]$Name) {
    if (-not (Test-Path $Path)) { return "" }
    $line = Get-Content $Path | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))=" } | Select-Object -Last 1
    if ($null -eq $line) { return "" }
    return (($line -split "=", 2)[1]).Trim()
}

function Write-ImagePinFile($PinsDir, $ApiVersion, $Kind, $ResourceName, $ContainerName, $ServiceTag, $Version, $FileName) {
    $image = "${ImageRepository}:$ServiceTag-$Version"
    $text = @"
# Generated by local/run-full-production-rehearsal.ps1.
# Rehearsal branch image pin for Argo CD production-local-rehearsal.
apiVersion: $ApiVersion
kind: $Kind
metadata:
  name: $ResourceName
spec:
  template:
    spec:
      containers:
        - name: $ContainerName
          image: $image
"@
    Set-Content -Path (Join-Path $PinsDir "$FileName.yaml") -Value $text -Encoding ascii
}

function Write-RehearsalImagePins([string]$CloneDir, [string]$Version) {
    $overlayDir = Join-Path $CloneDir "kubernetes\overlays\production"
    $pinsDir = Join-Path $overlayDir "image-pins"
    if (-not (Test-Path $overlayDir)) { throw "Production overlay not found in temp clone: $overlayDir" }
    New-Item -ItemType Directory -Path $pinsDir -Force | Out-Null
    Get-ChildItem $pinsDir -Filter "*.yaml" -ErrorAction SilentlyContinue | Remove-Item -Force

    foreach ($svc in $Services) {
        $apiVersion = if ($svc.Kind -eq "Job") { "batch/v1" } else { "apps/v1" }
        $fileName = $svc.Resource
        Write-ImagePinFile $pinsDir $apiVersion $svc.Kind $svc.Resource $svc.Container $svc.Tag $Version $fileName
    }

    $kustomization = Join-Path $overlayDir "kustomization.yaml"
    $content = Get-Content $kustomization -Raw
    $content = $content -replace 'app\.kubernetes\.io/version: "[^"]*"', "app.kubernetes.io/version: `"$Version`""
    Set-Content -Path $kustomization -Value $content -Encoding ascii
}

function New-RehearsalBranch([string]$Version, [string]$BranchName) {
    Write-Step "Creating GitOps rehearsal branch $BranchName for $Version"
    if ($DryRun) {
        Write-Host "DRY-RUN: would clone $RepoUrl, write production image pins for $Version, and push $BranchName"
        return
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yr4-rehearsal-" + [guid]::NewGuid().ToString("N"))
    git clone --quiet --branch $BaseRevision $RepoUrl $tempRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to clone deployment repo from $RepoUrl" }

    try {
        git -C $tempRoot checkout -B $BranchName
        if ($LASTEXITCODE -ne 0) { throw "Failed to create branch $BranchName" }

        Write-RehearsalImagePins $tempRoot $Version

        git -C $tempRoot config user.email "local-rehearsal@gitlab.local"
        git -C $tempRoot config user.name "Local Production Rehearsal"
        git -C $tempRoot add kubernetes/overlays/production/kustomization.yaml kubernetes/overlays/production/image-pins
        git -C $tempRoot commit -m "chore: local production rehearsal $Version" | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "No branch changes to commit for $BranchName; continuing with push."
        }
        git -C $tempRoot push --force-with-lease origin "HEAD:$BranchName"
        if ($LASTEXITCODE -ne 0) { throw "Failed to push rehearsal branch $BranchName" }
    } finally {
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-LocalInfra() {
    if ($SkipInfra) { return }
    Write-Step "Starting local PostgreSQL, Redis, and Mailpit"
    Invoke-Checked "docker" @("compose", "-f", (Join-Path $LocalDir "docker-compose.infra.yaml"), "up", "-d") "Failed to start local infra containers"
}

function Initialize-KindCluster() {
    Write-Step "Ensuring kind cluster $KindClusterName"
    if ($DryRun) {
        Write-Host "DRY-RUN: would create/reuse kind cluster $KindClusterName and switch kubectl to kind-$KindClusterName"
        return
    }

    try {
        $clusterOutput = @(kind get clusters 2>$null)
        if ($LASTEXITCODE -ne 0) { $clusters = @() } else { $clusters = $clusterOutput }
    } catch {
        $clusters = @()
    }
    if ($clusters -notcontains $KindClusterName) {
        Invoke-Checked "kind" @("create", "cluster", "--config", (Join-Path $LocalDir "kind-config.yaml")) "Failed to create kind cluster"
    } else {
        Write-Ok "kind cluster already exists"
    }
    Invoke-Checked "kubectl" @("config", "use-context", "kind-$KindClusterName") "Failed to switch kubectl context"
}

function Import-RegistryImages([string]$Version) {
    if ($SkipOldImagePull) { return }
    Write-Step "Pulling and loading old version images: $Version"
    foreach ($svc in $Services) {
        $image = "${ImageRepository}:$($svc.Tag)-$Version"
        Invoke-Checked "docker" @("pull", $image) "Failed to pull $image"
        Invoke-Checked "kind" @("load", "docker-image", $image, "--name", $KindClusterName) "Failed to load $image into kind"
    }
}

function BuildAndLoadNewImages([string]$Version) {
    Write-Step "Building and loading new version images: $Version"
    if (-not (Test-Path (Join-Path $DevRepo "docker-compose.yml"))) {
        throw "Development repo docker-compose.yml not found at $DevRepo"
    }

    if (-not $SkipImageBuild) {
        Push-Location $DevRepo
        try {
            Invoke-Checked "docker" @("compose", "build") "Failed to build local development images"
        } finally {
            Pop-Location
        }
    } else {
        Write-Warn "Skipping docker compose build; using existing local images."
    }

    foreach ($svc in $Services) {
        $sourceImage = "yr4-projectdevelopmentrepo-$($svc.Local):latest"
        $targetImage = "${ImageRepository}:$($svc.Tag)-$Version"
        Invoke-Checked "docker" @("tag", $sourceImage, $targetImage) "Failed to tag $sourceImage as $targetImage"
        Invoke-Checked "kind" @("load", "docker-image", $targetImage, "--name", $KindClusterName) "Failed to load $targetImage into kind"
    }
}

function Install-Controllers() {
    if ($DryRun) {
        if (-not $SkipObservability) { Write-Host "DRY-RUN: would run local/setup-observability.ps1 -AppNamespace $AppNamespace" }
        if (-not $SkipIstio) { Write-Host "DRY-RUN: would run scripts/deployment/bootstrap-istio-production.sh" }
        if (-not $SkipArgoInstall) { Write-Host "DRY-RUN: would run local/setup-argocd.ps1 -AppNamespace $AppNamespace" }
        return
    }

    if (-not $SkipObservability) {
        Write-Step "Installing local observability for production analysis gates"
        & (Join-Path $LocalDir "setup-observability.ps1") -AppNamespace $AppNamespace
        if ($LASTEXITCODE -ne 0) { throw "Local observability setup failed" }
    }

    if (-not $SkipIstio) {
        Assert-Tool "sh"
        Write-Step "Installing production Istio service mesh locally"
        $env:PROD_NAMESPACE = $AppNamespace
        & sh (Join-Path $RepoRoot "scripts\deployment\bootstrap-istio-production.sh")
        if ($LASTEXITCODE -ne 0) { throw "Local production Istio bootstrap failed" }
    }

    if (-not $SkipArgoInstall) {
        Write-Step "Installing local Argo CD and Argo Rollouts"
        & (Join-Path $LocalDir "setup-argocd.ps1") -AppNamespace $AppNamespace
        if ($LASTEXITCODE -ne 0) { throw "Local Argo CD setup failed" }
    }
}

function Sync-GoogleMapsSecret() {
    $dotEnv = Join-Path $DevRepo ".env"
    $browserKey = Get-DotEnvValue $dotEnv "GOOGLE_MAPS_BROWSER_KEY"
    $serverKey = Get-DotEnvValue $dotEnv "GOOGLE_MAPS_SERVER_KEY"
    $mapId = Get-DotEnvValue $dotEnv "GOOGLE_MAPS_MAP_ID"

    if (-not $browserKey -and -not $serverKey -and -not $mapId) {
        Write-Warn "No Google Maps values found in $dotEnv; using placeholder rehearsal secret."
        return
    }

    Write-Step "Syncing local Google Maps secret values into rehearsal namespace"
    if (-not $serverKey) { $serverKey = $browserKey }
    if (-not $browserKey) { $browserKey = $serverKey }

    if ($DryRun) {
        Write-Host "DRY-RUN: would apply google-maps-secrets in $AppNamespace from local .env (values hidden)"
        return
    }

    kubectl -n $AppNamespace create secret generic google-maps-secrets `
        --from-literal=GOOGLE_MAPS_SERVER_KEY=$serverKey `
        --from-literal=GOOGLE_MAPS_BROWSER_KEY=$browserKey `
        --from-literal=GOOGLE_MAPS_MAP_ID=$mapId `
        --dry-run=client -o yaml | kubectl apply -f - | Out-Host
}

function Set-RehearsalApplications([string]$TargetRevision) {
    Write-Step "Pointing Argo CD rehearsal Applications at $TargetRevision"
    if ($DryRun) {
        Write-Host "DRY-RUN: would apply rehearsal Argo CD Applications at $TargetRevision"
        return
    }
    & (Join-Path $LocalDir "apply-argocd-production-rehearsal.ps1") `
        -RepoUrl $RepoUrl `
        -TargetRevision $TargetRevision `
        -AppNamespace $AppNamespace `
        -ArgocdNamespace $ArgocdNamespace
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply Argo CD rehearsal Applications" }
}

function Sync-ArgoApplication([string]$AppName, [string]$Revision, [switch]$RequireHealth) {
    Write-Step "Syncing Argo CD app $AppName at $Revision"
    if (Get-Command argocd -ErrorAction SilentlyContinue) {
        Invoke-Checked "argocd" @("--core", "app", "sync", $AppName, "--app-namespace", $ArgocdNamespace, "--revision", $Revision, "--prune", "--timeout", "$ArgoTimeoutSeconds") "Argo CD sync failed for $AppName"
        $waitArgs = @("--core", "app", "wait", $AppName, "--app-namespace", $ArgocdNamespace, "--sync", "--timeout", "$ArgoTimeoutSeconds")
        if ($RequireHealth) { $waitArgs = @("--core", "app", "wait", $AppName, "--app-namespace", $ArgocdNamespace, "--sync", "--health", "--timeout", "$ArgoTimeoutSeconds") }
        Invoke-Checked "argocd" $waitArgs "Argo CD wait failed for $AppName"
    } else {
        if (-not $AllowCliFallback -and -not $DryRun) {
            throw "argocd CLI is required for the closest production rehearsal. Install argocd or rerun with -AllowCliFallback."
        }
        Write-Warn "argocd CLI not found; relying on automated sync and polling Application status. Install argocd CLI for the closest production match."
        if (-not $DryRun) {
            kubectl -n $ArgocdNamespace annotate application $AppName "argocd.argoproj.io/refresh=hard" --overwrite | Out-Host
            $deadline = (Get-Date).AddSeconds($ArgoTimeoutSeconds)
            do {
                $sync = kubectl -n $ArgocdNamespace get application $AppName -o jsonpath='{.status.sync.status}' 2>$null
                $health = kubectl -n $ArgocdNamespace get application $AppName -o jsonpath='{.status.health.status}' 2>$null
                if ($sync -eq "Synced" -and (-not $RequireHealth -or $health -eq "Healthy")) { return }
                Start-Sleep -Seconds 10
            } while ((Get-Date) -lt $deadline)
            throw "Timed out waiting for $AppName to sync. Last sync=$sync health=$health"
        }
    }
}

function Wait-Rollouts() {
    Write-Step "Waiting for Argo Rollouts in $AppNamespace"
    if ($DryRun) { return }
    $rollouts = kubectl -n $AppNamespace get rollouts.argoproj.io -o jsonpath='{.items[*].metadata.name}' 2>$null
    foreach ($rollout in ($rollouts -split '\s+' | Where-Object { $_ })) {
        Write-Host "    Waiting for rollout/$rollout"
        kubectl argo rollouts version > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            kubectl argo rollouts status $rollout -n $AppNamespace --timeout "${RolloutTimeoutSeconds}s"
            if ($LASTEXITCODE -ne 0) { throw "Rollout $rollout did not become healthy" }
        } else {
            if (-not $AllowCliFallback) {
                throw "kubectl argo rollouts plugin is required for rollout status. Install kubectl-argo-rollouts or rerun with -AllowCliFallback."
            }
            $deadline = (Get-Date).AddSeconds($RolloutTimeoutSeconds)
            do {
                $phase = kubectl -n $AppNamespace get rollout $rollout -o jsonpath='{.status.phase}' 2>$null
                if ($phase -eq "Healthy") { break }
                Start-Sleep -Seconds 10
            } while ((Get-Date) -lt $deadline)
            if ($phase -ne "Healthy") { throw "Rollout $rollout did not become Healthy; last phase=$phase" }
        }
    }
}

function Start-LocalTraffic() {
    if ($SkipSmokeTest -or $DryRun) { return $null }
    Write-Step "Starting local traffic through Istio ingress for canary metrics"
    $job = Start-Job -ScriptBlock {
        param($Seconds)
        $end = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $end) {
            try { Invoke-WebRequest -Uri "http://localhost:18080/health" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
            Start-Sleep -Seconds 2
        }
    } -ArgumentList $TrafficSeconds
    $pf = Start-Job -ScriptBlock {
        kubectl -n istio-system port-forward svc/istio-ingressgateway 18080:80
    }
    Start-Sleep -Seconds 5
    return @{ Traffic = $job; PortForward = $pf }
}

function Stop-LocalTraffic($Jobs) {
    if ($null -eq $Jobs) { return }
    foreach ($job in @($Jobs.Traffic, $Jobs.PortForward)) {
        if ($null -ne $job) {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SmokeTest() {
    if ($SkipSmokeTest -or $DryRun) { return }
    Write-Step "Running local smoke test through Istio ingress"
    $pf = Start-Job -ScriptBlock { kubectl -n istio-system port-forward svc/istio-ingressgateway 18080:80 }
    try {
        Start-Sleep -Seconds 5
        $response = Invoke-WebRequest -Uri "http://localhost:18080/health" -UseBasicParsing -TimeoutSec 20
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 400) {
            throw "Unexpected health status code $($response.StatusCode)"
        }
        Write-Ok "Istio ingress health endpoint returned $($response.StatusCode)"
    } finally {
        Stop-Job $pf -ErrorAction SilentlyContinue
        Remove-Job $pf -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  Local Full Production Rehearsal" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Old version:      $OldVersion"
Write-Host "  New version:      $NewVersion"
Write-Host "  Image repository: $ImageRepository"
Write-Host "  Old branch:       $OldBranch"
Write-Host "  New branch:       $NewBranch"
Write-Host "  App namespace:    $AppNamespace"

foreach ($tool in @("docker", "kubectl", "kind", "helm", "git")) { Assert-Tool $tool }
Assert-ProductionCli
if (-not (Test-Path $RepoRoot)) { throw "Repo root not found: $RepoRoot" }

if ($DryRun) {
    Write-Warn "Dry run: commands will be printed or skipped; no cluster or Git changes will be made."
}

Start-LocalInfra
Initialize-KindCluster
Import-RegistryImages $OldVersion
BuildAndLoadNewImages $NewVersion
New-RehearsalBranch $OldVersion $OldBranch
New-RehearsalBranch $NewVersion $NewBranch
Install-Controllers

Set-RehearsalApplications $OldBranch
Sync-ArgoApplication "year4-project-service-mesh-production-rehearsal" $OldBranch
Sync-ArgoApplication "year4-project-production-rehearsal" $OldBranch -RequireHealth
Sync-GoogleMapsSecret
Wait-Rollouts
Invoke-SmokeTest

Set-RehearsalApplications $NewBranch
$trafficJobs = Start-LocalTraffic
try {
    Sync-ArgoApplication "year4-project-service-mesh-production-rehearsal" $NewBranch
    Sync-ArgoApplication "year4-project-production-rehearsal" $NewBranch -RequireHealth
    Sync-GoogleMapsSecret
    Wait-Rollouts
    Invoke-SmokeTest
} finally {
    Stop-LocalTraffic $trafficJobs
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  Rehearsal complete" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Cluster was reset to: $OldVersion"
Write-Host "  Then deployed:        $NewVersion"
Write-Host "  Argo CD app:          year4-project-production-rehearsal"
Write-Host "  Useful commands:"
Write-Host "    kubectl get applications -n $ArgocdNamespace"
Write-Host "    kubectl get rollouts -n $AppNamespace"
Write-Host "    kubectl get pods -n $AppNamespace"
Write-Host "    kubectl -n istio-system port-forward svc/istio-ingressgateway 18080:80"
