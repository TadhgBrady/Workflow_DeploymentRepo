<#
.SYNOPSIS
    Sets up a local Kubernetes development environment simulating AWS infrastructure.

.DESCRIPTION
    1. Starts PostgreSQL + Redis + Mailpit in Docker (simulates RDS + ElastiCache + SES)
    2. Creates a kind (Kubernetes IN Docker) cluster
    3. Loads Docker images into kind
    4. Runs Kustomize to deploy all services with secrets/configmaps
    5. Waits for migration-runner then all pods to be ready

.PARAMETER BuildLocal
    Build images from local source instead of pulling from Docker Hub.

.PARAMETER DevRepo
    Path to the development repo (default: sibling directory yr4-projectdevelopmentrepo).

.EXAMPLE
    .\setup.ps1                    # Use Docker Hub images
    .\setup.ps1 -BuildLocal        # Build from local source
#>

param(
    [switch]$BuildLocal,
    [string]$DevRepo = (Join-Path $PSScriptRoot "..\..\yr4-projectdevelopmentrepo")
)

$ErrorActionPreference = "Stop"
$DeployRepo = Split-Path $PSScriptRoot -Parent
$LocalDir = $PSScriptRoot
$OverlayDir = Join-Path $DeployRepo "kubernetes\overlays\local"

$CLUSTER_NAME = "local-dev"
$NAMESPACE = "year4-project-local"
$IMAGE_REPO = "bencev04/4th-year-proj-tadgh-bence"

# All service image tags
$SERVICES = @(
    "auth-service",
    "user-bl-service",
    "user-db-access-service",
    "job-bl-service",
    "job-db-access-service",
    "customer-bl-service",
    "customer-db-access-service",
    "admin-bl-service",
    "maps-access-service",
    "notification-service",
    "frontend",
    "migration-runner"
)

function Write-Step($msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "    [WARN] $msg" -ForegroundColor Yellow
}

function Invoke-KindLoadImage($Image) {
    $process = Start-Process -FilePath "kind" `
        -ArgumentList @("load", "docker-image", $Image, "--name", $CLUSTER_NAME) `
        -NoNewWindow `
        -PassThru `
        -Wait
    if ($process.ExitCode -ne 0) {
        Write-Error "Failed to load image into kind: $Image"
    }
}

function Invoke-DockerTag($SourceImage, $TargetImage) {
    docker image inspect $TargetImage *>$null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    docker tag $SourceImage $TargetImage
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to tag image ${SourceImage} as ${TargetImage}"
    }
}

function Get-DockerContainerHealth($ContainerName) {
    $inspectOut = New-TemporaryFile
    $inspectErr = New-TemporaryFile
    try {
        $process = Start-Process -FilePath "docker" `
            -ArgumentList @("inspect", "--format={{.State.Health.Status}}", $ContainerName) `
            -NoNewWindow `
            -PassThru `
            -Wait `
            -RedirectStandardOutput $inspectOut.FullName `
            -RedirectStandardError $inspectErr.FullName

        if ($process.ExitCode -ne 0) {
            return ""
        }

        return (Get-Content $inspectOut.FullName -Raw).Trim()
    } finally {
        Remove-Item $inspectOut.FullName, $inspectErr.FullName -Force -ErrorAction SilentlyContinue
    }
}

# ── Pre-flight checks ──────────────────────────────────────────
Write-Step "Pre-flight checks"

foreach ($cmd in @("docker", "kubectl", "kind", "kustomize")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        # kustomize is bundled with kubectl
        if ($cmd -eq "kustomize") { continue }
        Write-Error "$cmd is not installed. Please install it first."
    }
}

# Check Docker is running. Some Docker daemons print benign warnings on stderr.
$dockerInfoOut = New-TemporaryFile
$dockerInfoErr = New-TemporaryFile
try {
    $dockerInfoProcess = Start-Process -FilePath "docker" `
        -ArgumentList @("info") `
        -NoNewWindow `
        -PassThru `
        -Wait `
        -RedirectStandardOutput $dockerInfoOut.FullName `
        -RedirectStandardError $dockerInfoErr.FullName
    $dockerInfoExitCode = $dockerInfoProcess.ExitCode
} finally {
    Remove-Item $dockerInfoOut.FullName, $dockerInfoErr.FullName -Force -ErrorAction SilentlyContinue
}
if ($dockerInfoExitCode -ne 0) {
    Write-Error "Docker is not running. Please start Docker Desktop."
}
Write-Ok "All prerequisites found"

# ── Step 1: Start infrastructure containers ─────────────────────
Write-Step "Starting infrastructure (PostgreSQL, Redis, Mailpit)"
docker compose -f "$LocalDir\docker-compose.infra.yaml" up -d

# Wait for health
Write-Host "    Waiting for PostgreSQL..." -NoNewline
$retries = 0
while ($retries -lt 30) {
    $health = Get-DockerContainerHealth "local-k8s-postgres"
    if ($health -eq "healthy") { break }
    Start-Sleep -Seconds 2
    $retries++
    Write-Host "." -NoNewline
}
if ($health -ne "healthy") { Write-Error "`nPostgreSQL failed to become healthy" }
Write-Ok "PostgreSQL ready on port 5434"

Write-Host "    Waiting for Redis..." -NoNewline
$retries = 0
while ($retries -lt 20) {
    $health = Get-DockerContainerHealth "local-k8s-redis"
    if ($health -eq "healthy") { break }
    Start-Sleep -Seconds 2
    $retries++
    Write-Host "." -NoNewline
}
if ($health -ne "healthy") { Write-Error "`nRedis failed to become healthy" }
Write-Ok "Redis ready on port 6380"

Write-Ok "Mailpit UI at http://localhost:8026"

# ── Step 2: Create kind cluster ─────────────────────────────────
Write-Step "Creating kind cluster '$CLUSTER_NAME'"

$existingClusters = kind get clusters 2>$null
if ($existingClusters -contains $CLUSTER_NAME) {
    Write-Warn "Cluster '$CLUSTER_NAME' already exists, reusing it"
} else {
    kind create cluster --config "$LocalDir\kind-config.yaml"
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create kind cluster" }
}
Write-Ok "Cluster ready"

# Set context
kubectl cluster-info --context "kind-$CLUSTER_NAME" *>$null
Write-Ok "kubectl context set to kind-$CLUSTER_NAME"

# ── Step 3: Get images into kind ────────────────────────────────
Write-Step "Loading images into kind cluster"

if ($BuildLocal) {
    Write-Host "    Building images from local source ($DevRepo)..."
    if (-not (Test-Path "$DevRepo\docker-compose.yml")) {
        Write-Error "Dev repo not found at $DevRepo"
    }
    Push-Location $DevRepo
    docker compose build
    Pop-Location
    Write-Ok "Build complete"

    # The local build uses different image names (from docker-compose), so tag them
    $composeImages = docker compose -f "$DevRepo\docker-compose.yml" config --images 2>$null
    foreach ($img in $composeImages) {
        if ($img) {
            $imagesToLoad = @($img)
            if ($img -like "yr4-projectdevelopmentrepo-*" -and $img -notmatch "[:@]") {
                $latestImage = "${img}:latest"
                Invoke-DockerTag $img $latestImage
                $imagesToLoad += $latestImage
            }

            foreach ($imageToLoad in $imagesToLoad) {
                Write-Host "    Loading $imageToLoad..."
                Invoke-KindLoadImage $imageToLoad
            }
        }
    }
} else {
    Write-Host "    Pulling and loading images from Docker Hub..."
    foreach ($svc in $SERVICES) {
        $img = "${IMAGE_REPO}:${svc}-latest"
        Write-Host "    $img" -NoNewline
        docker pull $img 2>$null
        if ($LASTEXITCODE -eq 0) {
            Invoke-KindLoadImage $img
            Write-Host " [loaded]" -ForegroundColor Green
        } else {
            Write-Host " [not found - will use imagePull]" -ForegroundColor Yellow
        }
    }
    # Also load nginx base image
    $nginxImg = "nginx:1.25-alpine"
    Write-Host "    $nginxImg" -NoNewline
    docker pull $nginxImg 2>$null
    Invoke-KindLoadImage $nginxImg
    Write-Host " [loaded]" -ForegroundColor Green
}
Write-Ok "Images loaded"

# ── Step 4: Deploy with Kustomize ───────────────────────────────
Write-Step "Deploying services to cluster (namespace: $NAMESPACE)"

# Validate first
Write-Host "    Validating kustomize output..."
kubectl kustomize $OverlayDir > $null
if ($LASTEXITCODE -ne 0) { Write-Error "Kustomize validation failed" }

# Apply
kubectl delete job migration-runner -n $NAMESPACE --ignore-not-found | Out-Host
kubectl apply -k $OverlayDir
if ($LASTEXITCODE -ne 0) { Write-Error "kubectl apply failed" }
Write-Ok "Manifests applied"

# ── Step 5: Wait for migration-runner ───────────────────────────
Write-Step "Waiting for migration-runner job to complete"

$migrationTimeout = 120
kubectl wait --for=condition=complete job/migration-runner `
    -n $NAMESPACE --timeout="${migrationTimeout}s" 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Warn "Migration runner did not complete in ${migrationTimeout}s"
    Write-Host "    Checking logs..."
    kubectl logs job/migration-runner -n $NAMESPACE --tail=20 2>$null
} else {
    Write-Ok "Migrations complete"
}

# ── Step 6: Wait for pods ──────────────────────────────────────
Write-Step "Waiting for all pods to be ready"

$deployments = kubectl get deployments -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>$null
$deploymentList = $deployments -split '\s+'

foreach ($dep in $deploymentList) {
    if (-not $dep) { continue }
    Write-Host "    Waiting for $dep..." -NoNewline
    kubectl rollout status deployment/$dep -n $NAMESPACE --timeout=120s 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host " [ready]" -ForegroundColor Green
    } else {
        Write-Host " [timeout]" -ForegroundColor Red
    }
}

# ── Summary ────────────────────────────────────────────────────
Write-Step "Deployment complete!"
Write-Host ""
Write-Host "    Application:  http://localhost:30080" -ForegroundColor White
Write-Host "    Mailpit UI:   http://localhost:8026" -ForegroundColor White
    Write-Host "    PostgreSQL:   localhost:5434 (crm_user/crm_password)" -ForegroundColor White
Write-Host "    Redis:        localhost:6380 (password: redis-dev-password)" -ForegroundColor White
Write-Host ""
Write-Host "    Useful commands:" -ForegroundColor Gray
Write-Host "      kubectl get pods -n $NAMESPACE" -ForegroundColor Gray
Write-Host "      kubectl logs -f deployment/auth-service -n $NAMESPACE" -ForegroundColor Gray
Write-Host "      kubectl port-forward svc/nginx-gateway 8080:80 -n $NAMESPACE" -ForegroundColor Gray
Write-Host "      .\local\setup-observability.ps1      # install local Prometheus/Loki/Grafana/Fluent Bit" -ForegroundColor Gray
Write-Host "      .\local\validate-observability.ps1   # validate local metrics and logs" -ForegroundColor Gray
Write-Host "      .\local\teardown.ps1   # to clean up" -ForegroundColor Gray
Write-Host ""

# Show pod status
kubectl get pods -n $NAMESPACE -o wide
