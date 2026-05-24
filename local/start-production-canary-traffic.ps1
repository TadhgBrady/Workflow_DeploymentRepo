<#
.SYNOPSIS
    Start short-lived production traffic for Argo Rollouts canary analysis.

.DESCRIPTION
    Creates a Kubernetes Job in the production application namespace that sends
    low-rate HTTP requests to each Rollout stable and canary Service. The Job
    runs inside the mesh so Istio records destination_service_name metrics for
    the exact Services used by the production AnalysisTemplate.

    This is intended for demos and quiet environments where real user traffic is
    too low for the canary request-rate metric.

.EXAMPLE
    .\local\start-production-canary-traffic.ps1 -DurationMinutes 45

.EXAMPLE
    .\local\start-production-canary-traffic.ps1 -DurationMinutes 20 -Mode CanaryOnly -IntervalSeconds 3

.EXAMPLE
    .\local\start-production-canary-traffic.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 240)]
    [int]$DurationMinutes = 45,

    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 5,

    [ValidateSet("Both", "CanaryOnly", "StableOnly")]
    [string]$Mode = "Both",

    [string]$Namespace = "year4-project",
    [string]$ClusterName = "yr4-project-production-eks",
    [string]$AwsRegion = "eu-west-1",
    [string]$JobPrefix = "prod-canary-traffic",
    [string]$CurlImage = "curlimages/curl:8.11.1",
    [string[]]$Paths = @("/api/v1/health", "/health", "/ready", "/"),

    [switch]$NoKubeconfigUpdate,
    [switch]$KeepExisting,
    [switch]$DryRun,
    [switch]$WaitForPod
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

function ConvertTo-SafeName {
    param([Parameter(Mandatory = $true)][string]$Value)
    $safe = $Value.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    $safe = $safe -replace '^-+', '' -replace '-+$', '' -replace '-+', '-'
    if ($safe.Length -gt 63) { $safe = $safe.Substring(0, 63) -replace '-+$', '' }
    if (-not $safe) { return "traffic" }
    return $safe
}

function ConvertTo-YamlLiteralList {
    param([Parameter(Mandatory = $true)][string[]]$Values)
    return (($Values | Sort-Object -Unique) -join "`n")
}

if (-not $NoKubeconfigUpdate) {
    Invoke-Checked aws "eks" "update-kubeconfig" "--name" $ClusterName "--region" $AwsRegion | Out-Null
}

$rolloutsJson = kubectl -n $Namespace get rollouts.argoproj.io -o json | ConvertFrom-Json
$targetServices = New-Object System.Collections.Generic.List[string]

foreach ($rollout in $rolloutsJson.items) {
    $canary = $rollout.spec.strategy.canary
    if (-not $canary) { continue }

    if ($Mode -in @("Both", "StableOnly") -and $canary.stableService) {
        $targetServices.Add([string]$canary.stableService)
    }
    if ($Mode -in @("Both", "CanaryOnly") -and $canary.canaryService) {
        $targetServices.Add([string]$canary.canaryService)
    }
}

$services = $targetServices | Sort-Object -Unique
if (-not $services -or $services.Count -eq 0) {
    throw "No Rollout stable/canary Services found in namespace $Namespace."
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$jobName = ConvertTo-SafeName "$JobPrefix-$timestamp"
$durationSeconds = $DurationMinutes * 60
$activeDeadlineSeconds = $durationSeconds + 900
$ttlSeconds = [Math]::Max($durationSeconds + 900, 3600)
$serviceList = ConvertTo-YamlLiteralList $services
$pathList = ConvertTo-YamlLiteralList $Paths
$serviceListYaml = (($serviceList -split "`n") | ForEach-Object { "                $_" }) -join "`n"
$pathListYaml = (($pathList -split "`n") | ForEach-Object { "                $_" }) -join "`n"

if (-not $KeepExisting) {
    kubectl -n $Namespace delete job -l app.kubernetes.io/name=production-canary-traffic --ignore-not-found=true --wait=false *> $null
}

$jobYaml = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: $jobName
  namespace: $Namespace
  labels:
    app.kubernetes.io/name: production-canary-traffic
    app.kubernetes.io/part-of: year4-project-observability
    environment: production
spec:
  backoffLimit: 6
  activeDeadlineSeconds: $activeDeadlineSeconds
  ttlSecondsAfterFinished: $ttlSeconds
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "true"
      labels:
        app.kubernetes.io/name: production-canary-traffic
        app.kubernetes.io/part-of: year4-project-observability
        environment: production
    spec:
      restartPolicy: Never
      priorityClassName: year4-batch
      terminationGracePeriodSeconds: 10
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: traffic
          image: $CurlImage
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          env:
            - name: NAMESPACE
              value: $Namespace
            - name: DURATION_SECONDS
              value: "$durationSeconds"
            - name: INTERVAL_SECONDS
              value: "$IntervalSeconds"
            - name: TARGET_SERVICES
              value: |-
$serviceListYaml
            - name: TARGET_PATHS
              value: |-
$pathListYaml
          command:
            - /bin/sh
            - -c
          args:
            - |
              set -eu
              END_TIME="`$((`$(date +%s) + DURATION_SECONDS))"
              TOTAL=0
              FAILURES=0
              echo "Starting production canary traffic for `$DURATION_SECONDS seconds"
              echo "Namespace: `$NAMESPACE"
              echo "Services:"
              printf '%s\n' "`$TARGET_SERVICES"
              echo "Paths:"
              printf '%s\n' "`$TARGET_PATHS"
              while [ "`$(date +%s)" -lt "`$END_TIME" ]; do
                for SERVICE in `$TARGET_SERVICES; do
                  for PATH_VALUE in `$TARGET_PATHS; do
                    URL="http://`$SERVICE.`$NAMESPACE.svc.cluster.local`$PATH_VALUE"
                    CODE="`$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "`$URL")" || CODE="000"
                    TOTAL="`$((TOTAL + 1))"
                    case "`$CODE" in
                      000|5*) FAILURES="`$((FAILURES + 1))" ;;
                    esac
                    printf '%s service=%s path=%s status=%s total=%s failures=%s\n' "`$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "`$SERVICE" "`$PATH_VALUE" "`$CODE" "`$TOTAL" "`$FAILURES"
                  done
                done
                sleep "`$INTERVAL_SECONDS"
              done
              echo "Finished production canary traffic: total=`$TOTAL failures=`$FAILURES"
              curl -sf -XPOST http://127.0.0.1:15020/quitquitquit || true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
"@

Write-Host "Production canary traffic job" -ForegroundColor Cyan
Write-Host "  Namespace: $Namespace"
Write-Host "  Job:       $jobName"
Write-Host "  Duration:  $DurationMinutes minutes"
Write-Host "  Interval:  $IntervalSeconds seconds"
Write-Host "  Mode:      $Mode"
Write-Host "  Services:  $($services.Count)"

if ($DryRun) {
    Write-Host ""
    Write-Host $jobYaml
    return
}

$jobYaml | kubectl apply -f - | Out-Host

if ($WaitForPod) {
    kubectl wait -n $Namespace --for=condition=PodScheduled pod -l "job-name=$jobName" --timeout=3m | Out-Host
}

kubectl -n $Namespace get job $jobName -o wide | Out-Host
kubectl -n $Namespace get pods -l "job-name=$jobName" -o wide | Out-Host

Write-Host ""
Write-Host "Traffic started. Useful follow-up commands:" -ForegroundColor Green
Write-Host "  kubectl -n $Namespace logs job/$jobName -f"
Write-Host "  kubectl -n $Namespace delete job $jobName"