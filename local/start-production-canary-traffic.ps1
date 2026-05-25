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
    [string]$IstioNamespace = "istio-system",
    [string]$MonitoringNamespace = "monitoring",
    [string]$PrometheusService = "kube-prometheus-stack-prometheus",
    [string]$JobPrefix = "prod-canary-traffic",
    [string]$CurlImage = "curlimages/curl:8.11.1",
    [string[]]$Paths = @("/api/v1/health", "/health", "/ready", "/"),
    [ValidateRange(1, 10)]
    [int]$InjectionAttempts = 3,
    [ValidateRange(30, 600)]
    [int]$PodReadyTimeoutSeconds = 180,

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

function Wait-KubernetesServiceEndpoints {
  param(
    [Parameter(Mandatory = $true)][string]$TargetNamespace,
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [int]$TimeoutSeconds = 180
  )

  Write-Host "Waiting for service endpoints: $ServiceName.$TargetNamespace"
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $endpoints = kubectl -n $TargetNamespace get endpoints $ServiceName -o jsonpath='{.subsets[*].addresses[*].ip}' 2>$null
    if ($endpoints) { return }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $deadline)

  kubectl -n $TargetNamespace get svc,endpoints $ServiceName -o wide | Out-Host
  throw "Service $ServiceName in namespace $TargetNamespace has no ready endpoints."
}

function Wait-MeshDependencies {
  Write-Host "Checking release-critical mesh and analysis dependencies"
  $injectionLabel = kubectl get namespace $Namespace -o jsonpath='{.metadata.labels.istio-injection}' 2>$null
  $revisionLabel = kubectl get namespace $Namespace -o jsonpath='{.metadata.labels.istio\.io/rev}' 2>$null
  if ($injectionLabel -ne "enabled" -and -not $revisionLabel) {
    kubectl get namespace $Namespace --show-labels | Out-Host
    throw "Namespace $Namespace is not labelled for Istio sidecar injection."
  }

  Invoke-Checked kubectl "-n" $IstioNamespace "rollout" "status" "deployment/istiod" "--timeout=300s"
  Wait-KubernetesServiceEndpoints -TargetNamespace $IstioNamespace -ServiceName "istiod" -TimeoutSeconds 180
  Invoke-Checked kubectl "get" "mutatingwebhookconfiguration" "istio-sidecar-injector"
  Wait-KubernetesServiceEndpoints -TargetNamespace $MonitoringNamespace -ServiceName $PrometheusService -TimeoutSeconds 300
}

function Get-TrafficPodName {
  $podName = kubectl -n $Namespace get pod -l "job-name=$jobName" -o jsonpath='{.items[0].metadata.name}' 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  return $podName
}

function Wait-TrafficPodName {
  $deadline = (Get-Date).AddSeconds($PodReadyTimeoutSeconds)
  do {
    $podName = Get-TrafficPodName
    if ($podName) { return $podName }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)

  kubectl -n $Namespace describe job $jobName | Out-Host
  throw "Traffic Job $jobName did not create a Pod."
}

function Test-PodHasIstioProxy {
  param([Parameter(Mandatory = $true)][string]$PodName)
  $containers = kubectl -n $Namespace get pod $PodName -o jsonpath='{.spec.containers[*].name}' 2>$null
  if ($LASTEXITCODE -ne 0) { return $false }
  return (($containers -split '\s+') -contains "istio-proxy")
}

function Test-TrafficConnectivity {
  param([Parameter(Mandatory = $true)][string]$PodName)
  $firstService = $services | Select-Object -First 1
  if (-not $firstService) { return $true }

  $url = "http://$firstService.$Namespace.svc.cluster.local/api/v1/health"
  $statusCode = kubectl -n $Namespace exec $PodName -c traffic -- sh -c "curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 $url" 2>$null
  if ($LASTEXITCODE -ne 0) { $statusCode = "000" }
  return ($statusCode -notmatch '^(000|5\d\d)$')
}

function Confirm-TrafficPodReady {
  if (-not $WaitForPod) { return }

  $podName = Wait-TrafficPodName
  Invoke-Checked kubectl "wait" "-n" $Namespace "--for=condition=PodScheduled" "pod/$podName" "--timeout=${PodReadyTimeoutSeconds}s"

  if (-not (Test-PodHasIstioProxy -PodName $podName)) {
    Write-Host "ERROR: traffic Pod $podName was created without the istio-proxy sidecar" -ForegroundColor Red
    Write-Host "This would make STRICT mTLS reset synthetic canary traffic and cause Argo Rollouts to see canary-request-rate=0." -ForegroundColor Red
    kubectl -n $Namespace get pod $podName -o wide | Out-Host
    kubectl -n $Namespace describe pod $podName | Out-Host
    throw "Traffic Pod was not sidecar-injected."
  }

  Invoke-Checked kubectl "wait" "-n" $Namespace "--for=condition=Ready" "pod/$podName" "--timeout=${PodReadyTimeoutSeconds}s"

  if (-not (Test-TrafficConnectivity -PodName $podName)) {
    kubectl -n $Namespace logs $podName --tail=40 | Out-Host
    throw "Traffic Pod $podName cannot reach canary services through the mesh."
  }
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

if (-not $KeepExisting -and -not $DryRun) {
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

  Wait-MeshDependencies

for ($attempt = 1; $attempt -le $InjectionAttempts; $attempt++) {
  if ($attempt -gt 1) {
    Write-Host "Retrying production canary traffic Job after failed sidecar/connectivity verification (attempt $attempt/$InjectionAttempts)" -ForegroundColor Yellow
    kubectl -n $Namespace delete job $jobName --ignore-not-found=true --wait=true *> $null
    Wait-MeshDependencies
  }

  $jobYaml | kubectl apply -f - | Out-Host

  try {
    Confirm-TrafficPodReady
    break
  } catch {
    if ($attempt -ge $InjectionAttempts) {
      kubectl -n $Namespace delete job $jobName --ignore-not-found=true --wait=false *> $null
      throw
    }
  }
}

kubectl -n $Namespace get job $jobName -o wide | Out-Host
kubectl -n $Namespace get pods -l "job-name=$jobName" -o wide | Out-Host

Write-Host ""
Write-Host "Traffic started. Useful follow-up commands:" -ForegroundColor Green
Write-Host "  kubectl -n $Namespace logs job/$jobName -f"
Write-Host "  kubectl -n $Namespace delete job $jobName"