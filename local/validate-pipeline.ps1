#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Locally validate the CD pipeline manifests WITHOUT pushing to GitLab.

.DESCRIPTION
    Runs the same checks as the CI pipeline (kustomize build + kubeconform)
    on your local machine. Catches manifest errors in seconds instead of
    waiting for a remote pipeline run.

    Requires: kustomize, kubeconform (auto-installs via scoop if missing)

.PARAMETER Overlay
    Which overlay to validate: staging, production, dev, or all (default: all)

.PARAMETER ImageVersion
    Simulate image version pinning (e.g. "157ee28f"). If set, replaces
    -latest tags in memory before validation (doesn't modify files).

.PARAMETER DryRun
    If set AND kubectl is configured, runs kubectl apply --dry-run=server
    to validate against the actual cluster API.

.EXAMPLE
    .\validate-pipeline.ps1
    .\validate-pipeline.ps1 -Overlay staging
    .\validate-pipeline.ps1 -Overlay staging -ImageVersion "157ee28f"
    .\validate-pipeline.ps1 -Overlay staging -DryRun
#>
param(
    [ValidateSet("staging", "production", "dev", "all")]
    [string]$Overlay = "all",

    [string]$ImageVersion = "",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# If run from the repo root directly, adjust
if (Test-Path (Join-Path $PSScriptRoot "kubernetes")) {
    $RepoRoot = $PSScriptRoot
} elseif (Test-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "kubernetes")) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$KubernetesDir = Join-Path $RepoRoot "kubernetes"
if (-not (Test-Path $KubernetesDir)) {
    Write-Error "Cannot find kubernetes/ directory. Run from the deployment repo root or local/ subdirectory."
    exit 1
}

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "  CD Pipeline Local Validator" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Repo root: $RepoRoot"
Write-Host ""

# ── Check prerequisites ──
function Test-Tool($Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

$missing = @()
if (-not (Test-Tool "kustomize")) { $missing += "kustomize" }
if (-not (Test-Tool "kubeconform")) { $missing += "kubeconform" }

if ($missing.Count -gt 0) {
    Write-Host "Missing tools: $($missing -join ', ')" -ForegroundColor Yellow
    if (Test-Tool "scoop") {
        Write-Host "Installing via scoop..." -ForegroundColor Yellow
        foreach ($tool in $missing) {
            scoop install $tool
        }
    } elseif (Test-Tool "choco") {
        Write-Host "Installing via chocolatey..." -ForegroundColor Yellow
        foreach ($tool in $missing) {
            choco install $tool -y
        }
    } else {
        Write-Host "`nInstall manually:" -ForegroundColor Red
        Write-Host "  scoop install kustomize kubeconform"
        Write-Host "  # or download from:"
        Write-Host "  # https://github.com/kubernetes-sigs/kustomize/releases"
        Write-Host "  # https://github.com/yannh/kubeconform/releases"
        exit 1
    }
}

# ── Determine overlays to validate ──
$overlays = if ($Overlay -eq "all") {
    @("staging", "production")
} else {
    @($Overlay)
}

$totalErrors = 0

foreach ($env in $overlays) {
    $overlayPath = Join-Path (Join-Path $KubernetesDir "overlays") $env
    if (-not (Test-Path $overlayPath)) {
        Write-Host "`n[$env] Overlay directory not found: $overlayPath" -ForegroundColor Yellow
        continue
    }

    Write-Host ("`n" + ("-" * 41)) -ForegroundColor Cyan
    Write-Host "  Validating overlay: $env" -ForegroundColor Cyan
    Write-Host ("-" * 41) -ForegroundColor Cyan

    # Step 1: kustomize build
    Write-Host "`n  [1/3] Running kustomize build..." -ForegroundColor White
    try {
        $rendered = kustomize build $overlayPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL kustomize build failed:" -ForegroundColor Red
            $rendered | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            $totalErrors++
            continue
        }
        $renderedText = $rendered -join "`n"
        Write-Host "  PASS kustomize build succeeded" -ForegroundColor Green

        # Count resources
        $resourceCount = ($renderedText | Select-String -Pattern "^kind:" -AllMatches).Matches.Count
        Write-Host "       $resourceCount resources rendered" -ForegroundColor DarkGray
    } catch {
        Write-Host "  FAIL kustomize build error: $_" -ForegroundColor Red
        $totalErrors++
        continue
    }

    # Step 1b: Simulate image version pinning if requested
    if ($ImageVersion) {
        Write-Host "`n  [*] Simulating image pin: -latest -> -$ImageVersion" -ForegroundColor Yellow
        $renderedText = $renderedText -replace `
            "bencev04/4th-year-proj-tadgh-bence:([a-z0-9-]+)-latest", `
            "bencev04/4th-year-proj-tadgh-bence:`$1-$ImageVersion"
    }

    # Step 2: kubeconform validation
    Write-Host "`n  [2/3] Running kubeconform..." -ForegroundColor White
    try {
        $conformResult = $renderedText | kubeconform -strict -summary `
            -skip "ClusterIssuer,ClusterSecretStore,ExternalSecret" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL kubeconform validation failed:" -ForegroundColor Red
            $conformResult | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            $totalErrors++
        } else {
            Write-Host "  PASS kubeconform validation passed" -ForegroundColor Green
            $conformResult | Where-Object { $_ -match "Summary" } | ForEach-Object {
                Write-Host "       $_" -ForegroundColor DarkGray
            }
        }
    } catch {
        Write-Host "  FAIL kubeconform error: $_" -ForegroundColor Red
        $totalErrors++
    }

    # Step 3: Check image references
    Write-Host "`n  [3/3] Checking image references..." -ForegroundColor White
    $images = ($renderedText | Select-String -Pattern "image:\s*(\S+)" -AllMatches).Matches |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $customImages = $images | Where-Object { $_ -match "bencev04/" }
    $externalImages = $images | Where-Object { $_ -notmatch "bencev04/" }

    Write-Host "       Custom images ($($customImages.Count)):" -ForegroundColor DarkGray
    foreach ($img in $customImages) {
        $tag = ($img -split ":")[-1]
        if ($tag -match "-latest$" -and -not $ImageVersion) {
            Write-Host "         $img" -ForegroundColor Yellow -NoNewline
            Write-Host " (using -latest)" -ForegroundColor DarkYellow
        } else {
            Write-Host "         $img" -ForegroundColor Green
        }
    }
    if ($externalImages.Count -gt 0) {
        Write-Host "       External images ($($externalImages.Count)):" -ForegroundColor DarkGray
        foreach ($img in $externalImages) {
            Write-Host "         $img" -ForegroundColor DarkGray
        }
    }

    # Step 4: Optional dry-run
    if ($DryRun) {
        Write-Host "`n  [4/4] kubectl dry-run (server)..." -ForegroundColor White
        if (Test-Tool "kubectl") {
            try {
                $dryResult = $renderedText | kubectl apply --dry-run=server -f - 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  FAIL dry-run failed:" -ForegroundColor Red
                    $dryResult | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                    $totalErrors++
                } else {
                    Write-Host "  PASS dry-run succeeded" -ForegroundColor Green
                }
            } catch {
                Write-Host "  WARN dry-run error: $_" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  SKIP kubectl not found" -ForegroundColor Yellow
        }
    }
}

# ── Summary ──
Write-Host "`n=========================================" -ForegroundColor Cyan
if ($totalErrors -eq 0) {
    Write-Host "  ALL CHECKS PASSED" -ForegroundColor Green
} else {
    Write-Host "  $totalErrors CHECK(S) FAILED" -ForegroundColor Red
}
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

exit $totalErrors
