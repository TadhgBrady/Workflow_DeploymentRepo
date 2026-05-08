#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Locally validate the CD pipeline manifests and key CI ordering WITHOUT pushing to GitLab.

.DESCRIPTION
    Runs the same offline checks as the CI pipeline (kustomize build + kubeconform,
    plus kubectl's embedded Kustomize engine) and verifies critical CD pipeline
    ordering on your local machine. Catches manifest and stage-order errors in
    seconds instead of waiting for a remote pipeline run.

    Requires: kustomize, kubeconform, kubectl (auto-installs via scoop if missing)

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
if (-not (Test-Tool "kubectl")) { $missing += "kubectl" }

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
        Write-Host "  scoop install kustomize kubeconform kubectl"
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

# ── Check critical CD pipeline ordering ──
$ciFile = Join-Path $RepoRoot ".gitlab-ci.yml"
if (Test-Path $ciFile) {
    Write-Host "`n-----------------------------------------" -ForegroundColor Cyan
    Write-Host "  Validating CD pipeline stage ordering" -ForegroundColor Cyan
    Write-Host "-----------------------------------------" -ForegroundColor Cyan

    $ciText = Get-Content $ciFile -Raw
    $pipelineErrors = 0

    function Assert-ContainsText($Content, $Needle, $Description) {
        if ($Content.Contains($Needle)) {
            Write-Host "  PASS $Description" -ForegroundColor Green
        } else {
            Write-Host "  FAIL $Description" -ForegroundColor Red
            Write-Host "       Missing: $Needle" -ForegroundColor Red
            $script:pipelineErrors++
        }
    }

    function Assert-TextOrder($Content, $First, $Second, $Description) {
        $firstIndex = $Content.IndexOf($First)
        $secondIndex = $Content.IndexOf($Second)
        if ($firstIndex -ge 0 -and $secondIndex -ge 0 -and $firstIndex -lt $secondIndex) {
            Write-Host "  PASS $Description" -ForegroundColor Green
        } else {
            Write-Host "  FAIL $Description" -ForegroundColor Red
            Write-Host "       Expected '$First' before '$Second'" -ForegroundColor Red
            $script:pipelineErrors++
        }
    }

    Assert-TextOrder $ciText "  - deploy-staging" "  - staging-readiness" "staging readiness runs after staging deploy stage"
    Assert-TextOrder $ciText "  - staging-readiness" "  - staging-tests" "staging readiness runs before staging tests"
    Assert-TextOrder $ciText "  - staging-tests" "  - destroy-staging" "staging tests run before staging destroy stage"
    Assert-TextOrder $ciText "  - destroy-staging" "  - verify-destroy" "staging destroy runs before destroy verification"
    Assert-TextOrder $ciText "  - verify-destroy" "  - promote" "destroy verification stage runs before promotion stage"
    Assert-TextOrder $ciText "confirm-destroy-staging:" "cleanup-staging-loadbalancers:" "manual destroy approval comes before cleanup job"
    Assert-TextOrder $ciText "cleanup-staging-loadbalancers:" "trigger-destroy-staging:" "load balancer cleanup comes before Terraform destroy trigger"
    Assert-TextOrder $ciText "trigger-destroy-staging:" "verify-staging-destroyed:" "destroy verification job is defined after staging destroy trigger"
    Assert-TextOrder $ciText "verify-staging-destroyed:" "promote-to-production:" "promotion job is defined after staging destroy verification"

    Assert-ContainsText $ciText 'PIPELINE_MODE: "auto"' "pipeline mode defaults to auto"
    Assert-ContainsText $ciText "validate-deployment-mode:" "deployment mode validation job exists"
    Assert-ContainsText $ciText "preflight-staging:" "staging preflight job exists"
    Assert-ContainsText $ciText "staging-readiness:" "staging readiness job exists"
    Assert-ContainsText $ciText "confirm-destroy-staging:" "manual staging destroy confirmation job exists"
    Assert-ContainsText $ciText "verify-staging-destroyed:" "staging destroy verification job exists"
    Assert-ContainsText $ciText 'DESTROY_ENV: "staging"' "staging destroy trigger targets only staging"
    Assert-ContainsText $ciText 'scripts/deployment/smoke-tests.sh' "shared smoke-test script is used"
    Assert-ContainsText $ciText "k6-load-staging:" "staging k6 load gate job exists"
    Assert-ContainsText $ciText 'scripts/deployment/run-k6-staging.sh' "shared k6 runner script is used"
    Assert-ContainsText $ciText 'dashboard-k6-staging.yaml' "k6 Grafana dashboard is applied"

    if ($ciText -notmatch "(?s)cleanup-staging-loadbalancers:.*?needs:\s*\r?\n\s*-\s*confirm-destroy-staging") {
        Write-Host "  FAIL cleanup job must depend on confirm-destroy-staging" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS cleanup job depends on manual staging destroy confirmation" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)k6-load-staging:.*?needs:.*?-\s*staging-readiness.*?-\s*job:\s*deploy-staging\s*\r?\n\s*artifacts:\s*true") {
        Write-Host "  FAIL k6 load gate must depend on readiness and deploy-staging artifacts" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS k6 load gate depends on readiness and deploy-staging artifacts" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)confirm-destroy-staging:.*?needs:.*?-\s*smoke-tests-staging.*?-\s*k6-load-staging") {
        Write-Host "  FAIL manual destroy approval must wait for smoke tests and k6" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS manual destroy approval waits for smoke tests and k6" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)verify-staging-destroyed:.*?needs:\s*\r?\n\s*-\s*trigger-destroy-staging") {
        Write-Host "  FAIL destroy verification must depend on trigger-destroy-staging" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS destroy verification depends on staging destroy trigger" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)promote-to-production:.*?needs:\s*\r?\n\s*-\s*verify-staging-destroyed") {
        Write-Host "  FAIL production promotion must depend on verify-staging-destroyed" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS production promotion is gated on staging destroy verification" -ForegroundColor Green
    }

    $promValuesFile = Join-Path $RepoRoot "helm/kube-prometheus-stack/values-staging.yaml"
    if (Test-Path $promValuesFile) {
        $promValuesText = Get-Content $promValuesFile -Raw
        Assert-ContainsText $promValuesText "enableRemoteWriteReceiver: true" "Prometheus remote-write receiver is enabled for k6"
    } else {
        Write-Host "  FAIL staging Prometheus values file is missing" -ForegroundColor Red
        $pipelineErrors++
    }

    $totalErrors += $pipelineErrors
}

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
    Write-Host "`n  [1/4] Running kustomize build..." -ForegroundColor White
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

    # Step 1c: Validate with kubectl's embedded Kustomize implementation.
    # The GitLab deploy jobs use `kubectl apply -k`, not standalone kustomize,
    # so this catches render compatibility issues without requiring cluster access.
    Write-Host "`n  [2/4] Running kubectl embedded Kustomize checks..." -ForegroundColor White
    try {
        $kubectlRendered = kubectl kustomize $overlayPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FAIL kubectl kustomize failed:" -ForegroundColor Red
            $kubectlRendered | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            $totalErrors++
            continue
        }

        Write-Host "  PASS kubectl kustomize succeeded" -ForegroundColor Green
    } catch {
        Write-Host "  FAIL kubectl embedded Kustomize check error: $_" -ForegroundColor Red
        $totalErrors++
        continue
    }

    # Optional: simulate image version pinning if requested
    if ($ImageVersion) {
        Write-Host "`n  [*] Simulating image pin: -latest -> -$ImageVersion" -ForegroundColor Yellow
        $renderedText = $renderedText -replace `
            "bencev04/4th-year-proj-tadgh-bence:([a-z0-9-]+)-latest", `
            "bencev04/4th-year-proj-tadgh-bence:`$1-$ImageVersion"
    }

    # Step 2: kubeconform validation
    Write-Host "`n  [3/4] Running kubeconform..." -ForegroundColor White
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
    Write-Host "`n  [4/4] Checking image references..." -ForegroundColor White
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
        Write-Host "`n  [5/5] kubectl dry-run (server)..." -ForegroundColor White
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
