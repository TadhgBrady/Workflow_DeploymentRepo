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
    Assert-TextOrder $ciText "  - staging-tests" "  - e2e-tests" "staging tests run before Playwright E2E stage"
    Assert-TextOrder $ciText "  - e2e-tests" "  - promote" "Playwright E2E runs before promote stage"
    Assert-TextOrder $ciText "  - promote" "  - ensure-production" "production promotion runs before production infra ensure stage"
    Assert-TextOrder $ciText "  - ensure-production" "  - deploy-prod" "production infra ensure runs before production deploy stage"
    Assert-TextOrder $ciText "  - deploy-prod" "  - prod-validation" "production deploy runs before production validation stage"
    Assert-TextOrder $ciText "  - prod-validation" "  - destroy-staging" "optional staging destroy stage is after production flow"
    Assert-TextOrder $ciText "  - destroy-staging" "  - verify-destroy" "staging destroy runs before destroy verification"
    Assert-TextOrder $ciText "promote:" "promote-to-production:" "production approval is defined after promote evidence"
    Assert-TextOrder $ciText "promote:" "confirm-destroy-staging:" "staging destroy option is defined after promote evidence"
    Assert-TextOrder $ciText "confirm-destroy-staging:" "cleanup-staging-loadbalancers:" "manual destroy approval comes before cleanup job"
    Assert-TextOrder $ciText "cleanup-staging-loadbalancers:" "trigger-destroy-staging:" "load balancer cleanup comes before Terraform destroy trigger"
    Assert-TextOrder $ciText "trigger-destroy-staging:" "verify-staging-destroyed:" "destroy verification job is defined after staging destroy trigger"

    Assert-ContainsText $ciText 'PIPELINE_MODE: "auto"' "pipeline mode defaults to auto"
    Assert-ContainsText $ciText "validate-deployment-mode:" "deployment mode validation job exists"
    Assert-ContainsText $ciText "preflight-staging:" "staging preflight job exists"
    Assert-ContainsText $ciText "staging-readiness:" "staging readiness job exists"
    Assert-ContainsText $ciText "playwright-e2e-staging:" "mandatory Playwright E2E job exists"
    Assert-ContainsText $ciText "promote:" "combined promotion evidence job exists"
    Assert-ContainsText $ciText "promote-to-production:" "manual production promotion job exists"
    Assert-ContainsText $ciText "install-argocd-production:" "production Argo CD bootstrap job exists"
    Assert-ContainsText $ciText 'scripts/deployment/write-image-pins.sh "$IMAGE_VERSION" production' "production promotion/deploy writes GitOps image pins"
    Assert-ContainsText $ciText 'scripts/deployment/sync-argocd-production.sh' "production deploy uses Argo CD sync script"
    Assert-ContainsText $ciText "kubectl-argo-rollouts" "production deploy installs Argo Rollouts kubectl plugin"
    Assert-ContainsText $ciText "confirm-destroy-staging:" "manual staging destroy confirmation job exists"
    Assert-ContainsText $ciText "verify-staging-destroyed:" "staging destroy verification job exists"
    Assert-ContainsText $ciText 'DESTROY_ENV: "staging"' "staging destroy trigger targets only staging"
    Assert-ContainsText $ciText 'scripts/deployment/smoke-tests.sh' "shared smoke-test script is used"
    Assert-ContainsText $ciText "k6-load-staging:" "mandatory staging k6 medium load gate job exists"
    Assert-ContainsText $ciText "k6-human-hard-staging:" "manual staging k6 human hard job exists"
    Assert-ContainsText $ciText 'scripts/deployment/run-k6-staging.sh' "shared k6 runner script is used"
    Assert-ContainsText $ciText 'tests/k6/real-user-workflows.js' "k6 real user workflow script is wired in"
    Assert-ContainsText $ciText 'dashboard-k6-staging.yaml' "k6 Grafana dashboard is applied"
    Assert-ContainsText $ciText 'k6-results/' "k6 jobs publish log, metadata, and summary artifacts"

    if ($ciText -notmatch "(?s)cleanup-staging-loadbalancers:.*?needs:\s*\r?\n\s*-\s*confirm-destroy-staging") {
        Write-Host "  FAIL cleanup job must depend on confirm-destroy-staging" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS cleanup job depends on manual staging destroy confirmation" -ForegroundColor Green
    }

    if ($ciText -match "manual-ops|manual-scale-(up|down)-(staging|production):") {
        Write-Host "  FAIL manual ops scale jobs should not exist in this pipeline" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS manual ops scale jobs are removed" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)k6-load-staging:.*?needs:.*?-\s*staging-readiness.*?-\s*job:\s*deploy-staging\s*\r?\n\s*artifacts:\s*true") {
        Write-Host "  FAIL k6 load gate must depend on readiness and deploy-staging artifacts" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS k6 load gate depends on readiness and deploy-staging artifacts" -ForegroundColor Green
    }

    if ($ciText -notmatch '(?s)k6-load-staging:.*?K6_SCRIPT_PATH:\s*"tests/k6/real-user-workflows.js".*?K6_PROFILE:\s*"medium".*?K6_MEDIUM_TARGET_VUS:\s*"10".*?when:\s*on_success.*?allow_failure:\s*false') {
        Write-Host "  FAIL k6 load gate must be mandatory and use the medium real-user workflow" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS k6 load gate is mandatory and uses the medium real-user workflow" -ForegroundColor Green
    }

    if ($ciText -match '(?m)^k6-(baseline|human-medium)-staging:') {
        Write-Host "  FAIL old optional baseline/medium k6 jobs should not remain in CI" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS old optional baseline/medium k6 jobs were removed from CI" -ForegroundColor Green
    }

    if ($ciText -notmatch '(?s)k6-human-hard-staging:.*?K6_SCRIPT_PATH:\s*"tests/k6/real-user-workflows.js".*?K6_PROFILE:\s*"hard".*?when:\s*manual.*?allow_failure:\s*true') {
        Write-Host "  FAIL k6 human hard job must be manual, optional, and use the real workflow script" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS k6 human hard job is manual, optional, and uses the real workflow script" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)playwright-e2e-staging:.*?needs:.*?-\s*smoke-tests-staging.*?-\s*k6-load-staging.*?allow_failure:\s*false") {
        Write-Host "  FAIL Playwright E2E must be a hard gate after smoke and k6" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS Playwright E2E is a hard gate after smoke and k6" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)promote:.*?needs:.*?-\s*smoke-tests-staging.*?-\s*job:\s*k6-load-staging.*?-\s*job:\s*playwright-e2e-staging") {
        Write-Host "  FAIL promote evidence job must wait for smoke, k6, and Playwright evidence" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS promote evidence job waits for smoke, k6, and Playwright evidence" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)confirm-destroy-staging:.*?needs:\s*\r?\n\s*-\s*promote") {
        Write-Host "  FAIL manual destroy approval must wait for promote evidence" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS manual destroy approval waits for promote evidence" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)verify-staging-destroyed:.*?needs:\s*\r?\n\s*-\s*trigger-destroy-staging") {
        Write-Host "  FAIL destroy verification must depend on trigger-destroy-staging" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS destroy verification depends on staging destroy trigger" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)promote-to-production:.*?needs:\s*\r?\n\s*-\s*promote") {
        Write-Host "  FAIL production promotion must depend on promote evidence" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS production promotion is gated on promote evidence" -ForegroundColor Green
    }

    if ($ciText -notmatch "(?s)deploy-production:.*?needs:\s*\r?\n\s*-\s*install-argocd-production") {
        Write-Host "  FAIL production deploy must depend on Argo CD bootstrap" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS production deploy depends on Argo CD bootstrap" -ForegroundColor Green
    }

    if ($ciText -match "kubectl apply -k kubernetes/overlays/production") {
        Write-Host "  FAIL production deploy should not directly apply the full production overlay" -ForegroundColor Red
        $pipelineErrors++
    } else {
        Write-Host "  PASS production deploy does not directly apply the full production overlay" -ForegroundColor Green
    }

    $gitOpsFiles = @(
        "scripts/deployment/write-image-pins.sh",
        "scripts/deployment/bootstrap-argocd-production.sh",
        "scripts/deployment/sync-argocd-production.sh",
        "kubernetes/argocd/project-production.yaml",
        "kubernetes/argocd/application-production.yaml",
        "kubernetes/overlays/staging/image-pins.yaml",
        "kubernetes/overlays/production/image-pins.yaml"
    )
    foreach ($relativePath in $gitOpsFiles) {
        if (Test-Path (Join-Path $RepoRoot $relativePath)) {
            Write-Host "  PASS GitOps file exists: $relativePath" -ForegroundColor Green
        } else {
            Write-Host "  FAIL GitOps file is missing: $relativePath" -ForegroundColor Red
            $pipelineErrors++
        }
    }

    $grafanaConfigFile = Join-Path $RepoRoot "helm/grafana/templates/configmap.yaml"
    $grafanaDeploymentFile = Join-Path $RepoRoot "helm/grafana/templates/deployment.yaml"
    if ((Test-Path $grafanaConfigFile) -and (Test-Path $grafanaDeploymentFile)) {
        $grafanaConfigText = Get-Content $grafanaConfigFile -Raw
        $grafanaDeploymentText = Get-Content $grafanaDeploymentFile -Raw
        Assert-ContainsText $grafanaConfigText "operations-hub.json" "Grafana Operations Hub dashboard is provisioned"
        Assert-ContainsText $grafanaConfigText '"uid": "operations-hub"' "Grafana Operations Hub has a stable UID"
        Assert-ContainsText $grafanaDeploymentText "dashboard-operations" "Grafana deployment mounts Operations Hub dashboard"
    } else {
        Write-Host "  FAIL Grafana chart files are missing" -ForegroundColor Red
        $pipelineErrors++
    }

    $promValuesFile = Join-Path $RepoRoot "helm/kube-prometheus-stack/values-staging.yaml"
    if (Test-Path $promValuesFile) {
        $promValuesText = Get-Content $promValuesFile -Raw
        Assert-ContainsText $promValuesText "enableRemoteWriteReceiver: true" "Prometheus remote-write receiver is enabled for k6"
    } else {
        Write-Host "  FAIL staging Prometheus values file is missing" -ForegroundColor Red
        $pipelineErrors++
    }

    $baselineScript = Join-Path $RepoRoot "tests/k6/baseline-exploration.js"
    if (Test-Path $baselineScript) {
        Write-Host "  PASS k6 baseline exploration script exists" -ForegroundColor Green
    } else {
        Write-Host "  FAIL k6 baseline exploration script is missing" -ForegroundColor Red
        $pipelineErrors++
    }

    $realWorkflowScript = Join-Path $RepoRoot "tests/k6/real-user-workflows.js"
    if (Test-Path $realWorkflowScript) {
        $realWorkflowText = Get-Content $realWorkflowScript -Raw
        Assert-ContainsText $realWorkflowText "ownerDailyWorkflow" "k6 real workflow includes owner daily journey"
        Assert-ContainsText $realWorkflowText "managerSchedulingWorkflow" "k6 real workflow includes manager scheduling journey"
        Assert-ContainsText $realWorkflowText "conflictPressureWorkflow" "k6 real workflow includes conflict pressure journey"
        Assert-ContainsText $realWorkflowText "auth/refresh" "k6 real workflow refreshes access tokens during long runs"
        Assert-ContainsText $realWorkflowText "cleanup_failures" "k6 real workflow emits cleanup failure metric"
    } else {
        Write-Host "  FAIL k6 real user workflow script is missing" -ForegroundColor Red
        $pipelineErrors++
    }

    $k6RunnerScript = Join-Path $RepoRoot "scripts/deployment/run-k6-staging.sh"
    if (Test-Path $k6RunnerScript) {
        $k6RunnerText = Get-Content $k6RunnerScript -Raw
        Assert-ContainsText $k6RunnerText 'SCRIPT_PATH="${K6_SCRIPT_PATH:-tests/k6/real-user-workflows.js}"' "k6 runner defaults to the real-user workflow script"
        Assert-ContainsText $k6RunnerText 'K6_PROFILE="${K6_PROFILE:-medium}"' "k6 runner defaults to the medium profile"
        Assert-ContainsText $k6RunnerText "LOAD_TEST_DURATION" "k6 runner maps duration to non-reserved LOAD_TEST_* env vars"
        Assert-ContainsText $k6RunnerText "LOAD_TEST_MAX_VUS" "k6 runner maps max VUs to non-reserved LOAD_TEST_* env vars"
        Assert-ContainsText $k6RunnerText "K6_DEMO_USER_PASSWORD" "k6 runner defaults to seeded demo credentials for manual human workflows"
        Assert-ContainsText $k6RunnerText "LOAD_TEST_OWNER_PASSWORD" "k6 runner maps owner password through LOAD_TEST_* env vars"
        Assert-ContainsText $k6RunnerText "LOAD_TEST_MEDIUM_TARGET_VUS" "k6 runner maps human medium VU target"
        Assert-ContainsText $k6RunnerText "LOAD_TEST_HARD_TARGET_VUS" "k6 runner maps human hard VU target"
        Assert-ContainsText $k6RunnerText "LOAD_TEST_AUTH_REFRESH_SKEW_SECONDS" "k6 runner maps auth token refresh controls"
        Assert-ContainsText $k6RunnerText "K6_METADATA_FILE" "k6 runner writes per-run metadata artifacts"
        Assert-ContainsText $k6RunnerText "secretKeyRef" "k6 runner uses a Kubernetes Secret for human workflow credentials"
        if ($k6RunnerText -match "(?m)^\s*- name: K6_(?!PROMETHEUS_RW_)[A-Z0-9_]+\s*$") {
            Write-Host "  FAIL k6 runner must not pass custom K6_* env vars into the k6 pod" -ForegroundColor Red
            $pipelineErrors++
        } else {
            Write-Host "  PASS k6 runner keeps custom tuning vars out of reserved K6_* pod env names" -ForegroundColor Green
        }
    } else {
        Write-Host "  FAIL shared k6 runner script is missing" -ForegroundColor Red
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
        $resourceCount = ($renderedText | Select-String -Pattern "(?m)^kind:" -AllMatches).Matches.Count
        Write-Host "       $resourceCount resources rendered" -ForegroundColor DarkGray

        $rolloutCount = ($renderedText | Select-String -Pattern "(?m)^kind:\s*Rollout$" -AllMatches).Matches.Count
        $deploymentCount = ($renderedText | Select-String -Pattern "(?m)^kind:\s*Deployment$" -AllMatches).Matches.Count
        if ($env -eq "production") {
            if ($rolloutCount -gt 0 -and $deploymentCount -eq 0) {
                Write-Host "  PASS production overlay renders Argo Rollouts ($rolloutCount) instead of Deployments" -ForegroundColor Green
            } else {
                Write-Host "  FAIL production overlay must render Rollouts and no Deployments (Rollouts: $rolloutCount, Deployments: $deploymentCount)" -ForegroundColor Red
                $totalErrors++
            }

            $rolloutReplicaTwoCount = ([regex]::Matches($renderedText, "(?ms)^kind:\s*Rollout\s*$.*?^\s+replicas:\s*2\s*$")).Count
            if ($rolloutCount -gt 0 -and $rolloutReplicaTwoCount -eq $rolloutCount) {
                Write-Host "  PASS production Rollouts use 2 replicas" -ForegroundColor Green
            } else {
                Write-Host "  FAIL production Rollouts must all use 2 replicas (Rollouts: $rolloutCount, replicas=2: $rolloutReplicaTwoCount)" -ForegroundColor Red
                $totalErrors++
            }
        } elseif ($rolloutCount -gt 0) {
            Write-Host "  FAIL non-production overlay should not render Argo Rollouts" -ForegroundColor Red
            $totalErrors++
        }
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
            -skip "ClusterIssuer,ClusterSecretStore,ExternalSecret,Rollout" 2>&1
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
