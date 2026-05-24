<#
.SYNOPSIS
    Run manual k6 load tests against the live staging cluster without GitLab CI.

.DESCRIPTION
    Creates a short-lived Kubernetes Job in the staging namespace using the same
    k6 scripts and Prometheus remote-write path as the GitLab release gate.

    Use -Suite real-user for authenticated workflow VU tests, or -Suite public
    for smoke/baseline/stress/spike endpoint exploration. Use -VusSteps to run
    a progressive ladder such as 10,20,30 without redeploying the application.

.EXAMPLE
    .\local\run-staging-k6.ps1 -Suite real-user -Profile medium -Vus 10

.EXAMPLE
    .\local\run-staging-k6.ps1 -Suite real-user -Profile hard -VusSteps 10,20,30 -Duration 3m

.EXAMPLE
    .\local\run-staging-k6.ps1 -Suite public -Profile spike-lite -SpikeRate 25 -Duration 2m
#>

[CmdletBinding()]
param(
    [ValidateSet("real-user", "public")]
    [string]$Suite = "real-user",

    [string]$Profile,

    [ValidateRange(1, 500)]
    [int]$Vus = 10,

    [int[]]$VusSteps,

    [string]$Duration = "3m",
    [string]$WarmupDuration = "30s",
    [string]$CooldownDuration = "30s",
    [string]$JobTimeout = "20m",
    [string]$ScheduleTimeout = "5m",

    [ValidateRange(0, 1000)]
    [int]$PreAllocatedVus = 0,

    [ValidateRange(0, 2000)]
    [int]$MaxVus = 0,

    [ValidateRange(0, 10000)]
    [int]$SweepRate = 1,

    [ValidateRange(0, 10000)]
    [int]$BrowseRate = 2,

    [ValidateRange(0, 10000)]
    [int]$StressRate = 5,

    [ValidateRange(0, 10000)]
    [int]$SpikeRate = 10,

    [string]$StagingUrl,
    [string]$ClusterName = "yr4-project-staging-eks",
    [string]$AwsRegion = "eu-west-1",
    [string]$Namespace = "year4-project-staging",
    [string]$MonitoringNamespace = "monitoring",
    [string]$IstioNamespace = "istio-system",
    [string]$IstioIngressService = "istio-ingressgateway",
    [string]$K6Image = "grafana/k6:0.54.0",
    [string]$ImageVersion = $(if ($env:IMAGE_VERSION) { $env:IMAGE_VERSION } else { "manual" }),
    [string]$ResultsDir = "k6-results/manual",
    [string]$TestIdPrefix = "manual",

    [string]$OwnerEmail = $(if ($env:K6_OWNER_EMAIL) { $env:K6_OWNER_EMAIL } else { "owner@demo.com" }),
    [string]$ManagerEmail = $(if ($env:K6_MANAGER_EMAIL) { $env:K6_MANAGER_EMAIL } else { "manager@demo.com" }),
    [string]$EmployeeEmail = $(if ($env:K6_EMPLOYEE_EMAIL) { $env:K6_EMPLOYEE_EMAIL } else { "employee@demo.com" }),
    [string]$UserPassword = $(if ($env:K6_USER_PASSWORD) { $env:K6_USER_PASSWORD } else { "password123" }),
    [string]$OwnerPassword = $(if ($env:K6_OWNER_PASSWORD) { $env:K6_OWNER_PASSWORD } else { "" }),
    [string]$ManagerPassword = $(if ($env:K6_MANAGER_PASSWORD) { $env:K6_MANAGER_PASSWORD } else { "" }),
    [string]$EmployeePassword = $(if ($env:K6_EMPLOYEE_PASSWORD) { $env:K6_EMPLOYEE_PASSWORD } else { "" }),

    [double]$ThinkTimeSeconds = 0.6,
    [double]$ThinkTimeJitterSeconds = 0.4,
    [int]$LatencyP95Ms = 2500,
    [int]$LatencyP99Ms = 5000,

    [switch]$NoPrometheusRemoteWrite,
    [switch]$KeepJob,
    [switch]$DryRun
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
    if (-not $safe) { return "manual" }
    return $safe
}

function ConvertTo-YamlString {
    param([AllowNull()][object]$Value)
    $text = [string]$Value
    $text = $text.Replace('\\', '\\').Replace('"', '\"')
    return '"' + $text + '"'
}

function Convert-DurationToSeconds {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '^(\d+)([smh])$') {
        $amount = [int]$Matches[1]
        switch ($Matches[2]) {
            's' { return $amount }
            'm' { return $amount * 60 }
            'h' { return $amount * 3600 }
        }
    }
    if ($Value -match '^\d+$') { return [int]$Value }
    throw "Invalid duration '$Value'. Use seconds, or suffix with s/m/h, for example 30s, 3m, 1h."
}

function Get-StagingUrl {
    if ($StagingUrl) { return $StagingUrl.TrimEnd('/') }

    Invoke-Checked aws "eks" "update-kubeconfig" "--name" $ClusterName "--region" $AwsRegion | Out-Null
    $serviceJson = kubectl get svc -n $IstioNamespace $IstioIngressService -o json | ConvertFrom-Json
    $ingress = $serviceJson.status.loadBalancer.ingress | Select-Object -First 1
    if ($ingress.hostname) { return "http://$($ingress.hostname)" }
    if ($ingress.ip) { return "http://$($ingress.ip)" }
    throw "No load balancer address found on service $IstioNamespace/$IstioIngressService."
}

function Get-PrometheusRemoteWriteUrl {
    if ($NoPrometheusRemoteWrite) { return "" }
    if ($env:K6_PROMETHEUS_RW_SERVER_URL) { return $env:K6_PROMETHEUS_RW_SERVER_URL }

    $candidates = @("kube-prometheus-stack-prometheus", "prometheus-operated")
    foreach ($service in $candidates) {
        kubectl get service $service -n $MonitoringNamespace *> $null
        if ($LASTEXITCODE -eq 0) {
            return "http://$service.$MonitoringNamespace.svc.cluster.local:9090/api/v1/write"
        }
    }
    throw "Could not find a Prometheus service in namespace $MonitoringNamespace. Use -NoPrometheusRemoteWrite to run without Grafana evidence."
}

function Get-K6ScriptPath {
    param([string]$SelectedSuite)
    if ($SelectedSuite -eq "real-user") { return "tests/k6/real-user-workflows.js" }
    return "tests/k6/baseline-exploration.js"
}

function Assert-Profile {
    param([string]$SelectedSuite, [string]$SelectedProfile)
    if ($SelectedSuite -eq "real-user") {
        if ($SelectedProfile -notin @("medium", "hard")) {
            throw "real-user suite supports -Profile medium or hard. Got '$SelectedProfile'."
        }
        return
    }
    if ($SelectedProfile -notin @("smoke", "baseline", "stress-lite", "spike-lite")) {
        throw "public suite supports -Profile smoke, baseline, stress-lite, or spike-lite. Got '$SelectedProfile'."
    }
}

function New-K6JobYaml {
    param(
        [string]$JobName,
        [string]$ConfigMapName,
        [string]$SecretName,
        [string]$ScriptFile,
        [hashtable]$Environment
    )

    $envLines = foreach ($key in ($Environment.Keys | Sort-Object)) {
        $value = ConvertTo-YamlString $Environment[$key]
      "            - name: $key`n              value: $value`n"
    }
    $envBlock = $envLines -join ''

    @"
apiVersion: batch/v1
kind: Job
metadata:
  name: $JobName
  namespace: $Namespace
  labels:
    app.kubernetes.io/name: k6-staging-manual
    app.kubernetes.io/part-of: year4-project-observability
    environment: staging
    testid: $($Environment['LOAD_TEST_ID'])
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
      labels:
        app.kubernetes.io/name: k6-staging-manual
        app.kubernetes.io/part-of: year4-project-observability
        environment: staging
        testid: $($Environment['LOAD_TEST_ID'])
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 12345
        runAsGroup: 12345
        seccompProfile:
          type: RuntimeDefault
      restartPolicy: Never
      containers:
        - name: k6
          image: $K6Image
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          env:
$envBlock            - name: LOAD_TEST_OWNER_EMAIL
              valueFrom:
                secretKeyRef:
                  name: $SecretName
                  key: owner-email
            - name: LOAD_TEST_MANAGER_EMAIL
              valueFrom:
                secretKeyRef:
                  name: $SecretName
                  key: manager-email
            - name: LOAD_TEST_EMPLOYEE_EMAIL
              valueFrom:
                secretKeyRef:
                  name: $SecretName
                  key: employee-email
            - name: LOAD_TEST_OWNER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: $SecretName
                  key: owner-password
            - name: LOAD_TEST_MANAGER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: $SecretName
                  key: manager-password
            - name: LOAD_TEST_EMPLOYEE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: $SecretName
                  key: employee-password
          command:
            - /bin/sh
            - -c
          args:
            - |
              set +e
              SUMMARY_FILE="/tmp/k6-summary.json"
              if [ -n "`$K6_PROMETHEUS_RW_SERVER_URL" ]; then
                k6 run --out experimental-prometheus-rw --summary-export "`$SUMMARY_FILE" /scripts/$ScriptFile
              else
                k6 run --summary-export "`$SUMMARY_FILE" /scripts/$ScriptFile
              fi
              EXIT_CODE="`$?"
              echo "__K6_SUMMARY_JSON_BEGIN__"
              if [ -f "`$SUMMARY_FILE" ]; then
                cat "`$SUMMARY_FILE"
              else
                echo "{}"
              fi
              echo "__K6_SUMMARY_JSON_END__"
              exit "`$EXIT_CODE"
          volumeMounts:
            - name: k6-script
              mountPath: /scripts
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 1000m
              memory: 512Mi
      volumes:
        - name: k6-script
          configMap:
            name: $ConfigMapName
"@
}

function Invoke-K6Run {
    param([int]$TargetVus)

    $selectedProfile = $Profile
    if (-not $selectedProfile) {
        if ($Suite -eq "real-user") { $selectedProfile = "medium" } else { $selectedProfile = "baseline" }
    }
    $selectedProfile = $selectedProfile.ToLowerInvariant()
    Assert-Profile $Suite $selectedProfile

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $scriptPath = Join-Path $repoRoot (Get-K6ScriptPath $Suite)
    if (-not (Test-Path $scriptPath)) { throw "k6 script not found: $scriptPath" }
    $scriptFile = Split-Path $scriptPath -Leaf

    $targetUrl = Get-StagingUrl
    $prometheusUrl = Get-PrometheusRemoteWriteUrl

    $effectivePreAllocatedVus = $PreAllocatedVus
    if ($effectivePreAllocatedVus -le 0) { $effectivePreAllocatedVus = [Math]::Max(4, [Math]::Ceiling($TargetVus * 1.2)) }
    $effectiveMaxVus = $MaxVus
    if ($effectiveMaxVus -le 0) { $effectiveMaxVus = [Math]::Max($effectivePreAllocatedVus, $TargetVus * 2) }
    if ($Suite -eq "public") {
        $publicRateCeiling = [Math]::Max($BrowseRate, [Math]::Max($StressRate, $SpikeRate))
        $effectiveMaxVus = [Math]::Max($effectiveMaxVus, $publicRateCeiling * 2)
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $testId = ConvertTo-SafeName "$TestIdPrefix-$Suite-$selectedProfile-${TargetVus}vu-$timestamp"
    $jobName = ConvertTo-SafeName "k6-$testId"
    $configMapName = ConvertTo-SafeName "$jobName-script"
    $secretName = ConvertTo-SafeName "$jobName-credentials"

    $ownerPasswordValue = if ($OwnerPassword) { $OwnerPassword } else { $UserPassword }
    $managerPasswordValue = if ($ManagerPassword) { $ManagerPassword } else { $UserPassword }
    $employeePasswordValue = if ($EmployeePassword) { $EmployeePassword } else { $UserPassword }

    $environment = @{
        STAGING_URL = $targetUrl
        BASE_URL = $targetUrl
        LOAD_TEST_ENVIRONMENT = "staging"
        LOAD_TEST_PROFILE = $selectedProfile
        LOAD_TEST_ID = $testId
        CI_PIPELINE_ID = "manual"
        CI_JOB_ID = "local"
        IMAGE_VERSION = $ImageVersion
        LOAD_TEST_ITERATION_RATE = $SweepRate
        LOAD_TEST_SWEEP_RATE = $SweepRate
        LOAD_TEST_BROWSE_RATE = $BrowseRate
        LOAD_TEST_STRESS_RATE = $StressRate
        LOAD_TEST_SPIKE_RATE = $SpikeRate
        LOAD_TEST_WARMUP_DURATION = $WarmupDuration
        LOAD_TEST_DURATION = $Duration
        LOAD_TEST_COOLDOWN_DURATION = $CooldownDuration
        LOAD_TEST_PRE_ALLOCATED_VUS = $effectivePreAllocatedVus
        LOAD_TEST_MAX_VUS = $effectiveMaxVus
        LOAD_TEST_MEDIUM_TARGET_VUS = $TargetVus
        LOAD_TEST_HARD_TARGET_VUS = $TargetVus
        LOAD_TEST_THINK_TIME_SECONDS = $ThinkTimeSeconds
        LOAD_TEST_THINK_TIME_JITTER_SECONDS = $ThinkTimeJitterSeconds
        LOAD_TEST_REQUEST_TIMEOUT = "15s"
        LOAD_TEST_FAILURE_RATE = "0.02"
        LOAD_TEST_CRITICAL_FAILURE_RATE = "0.01"
        LOAD_TEST_UNEXPECTED_STATUS_RATE = "0.02"
        LOAD_TEST_SERVER_ERROR_RATE = "0.01"
        LOAD_TEST_CHECK_RATE = "0.95"
        LOAD_TEST_LATENCY_P95_MS = $LatencyP95Ms
        LOAD_TEST_LATENCY_P99_MS = $LatencyP99Ms
        LOAD_TEST_WORKFLOW_SUCCESS_RATE = "0.95"
        LOAD_TEST_AUTH_FAILURE_RATE = "0.01"
        LOAD_TEST_CLEANUP_FAILURE_RATE = "0.02"
        LOAD_TEST_SCHEDULING_P95_MS = $LatencyP95Ms
        LOAD_TEST_SCHEDULING_P99_MS = $LatencyP99Ms
        LOAD_TEST_CONFLICT_P95_MS = $LatencyP95Ms
        LOAD_TEST_CONFLICT_P99_MS = $LatencyP99Ms
        LOAD_TEST_CLEANUP_ENABLED = "true"
        LOAD_TEST_AUTH_RECOVERY_ENABLED = "true"
        LOAD_TEST_AUTH_REFRESH_SKEW_SECONDS = "60"
        LOAD_TEST_AUTH_RETRY_DELAY_SECONDS = "0.4"
        K6_PROMETHEUS_RW_SERVER_URL = $prometheusUrl
        K6_PROMETHEUS_RW_PUSH_INTERVAL = "5s"
        K6_PROMETHEUS_RW_TREND_STATS = "min,avg,med,p(90),p(95),p(99),max"
        K6_PROMETHEUS_RW_STALE_MARKERS = "true"
    }

    $jobYaml = New-K6JobYaml -JobName $jobName -ConfigMapName $configMapName -SecretName $secretName -ScriptFile $scriptFile -Environment $environment

    $metadataPath = Join-Path $ResultsDir "$jobName-metadata.json"
    $logPath = Join-Path $ResultsDir "$jobName.log"
    $summaryPath = Join-Path $ResultsDir "$jobName-summary.json"

    Write-Host ""
    Write-Host "k6 staging manual run" -ForegroundColor Cyan
    Write-Host "  Suite:       $Suite"
    Write-Host "  Profile:     $selectedProfile"
    Write-Host "  VUs:         $TargetVus"
    Write-Host "  Target:      $targetUrl"
    Write-Host "  Test ID:     $testId"
    Write-Host "  Job:         $Namespace/$jobName"
    Write-Host "  Results:     $ResultsDir"

    if ($DryRun) {
        Write-Host ""
        Write-Host "Dry run only. Kubernetes Job manifest:" -ForegroundColor Yellow
        Write-Host $jobYaml
        return
    }

      New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
      $metadata = [ordered]@{
        test_id = $testId
        job_name = $jobName
        suite = $Suite
        profile = $selectedProfile
        vus = $TargetVus
        staging_url = $targetUrl
        script = (Resolve-Path $scriptPath).Path
        duration = $Duration
        warmup_duration = $WarmupDuration
        cooldown_duration = $CooldownDuration
        preallocated_vus = $effectivePreAllocatedVus
        max_vus = $effectiveMaxVus
        prometheus_remote_write_url = $prometheusUrl
        image_version = $ImageVersion
        created_utc = (Get-Date).ToUniversalTime().ToString("o")
      }
      $metadata | ConvertTo-Json -Depth 5 | Set-Content -Encoding ascii -Path $metadataPath

    Invoke-Checked kubectl "create" "configmap" $configMapName "--namespace" $Namespace "--from-file=$scriptFile=$scriptPath" "--dry-run=client" "-o" "yaml" | kubectl apply -f - | Out-Null
    Invoke-Checked kubectl `
      "create" "secret" "generic" $secretName `
      "--namespace" $Namespace `
      "--from-literal=owner-email=$OwnerEmail" `
      "--from-literal=manager-email=$ManagerEmail" `
      "--from-literal=employee-email=$EmployeeEmail" `
      "--from-literal=owner-password=$ownerPasswordValue" `
      "--from-literal=manager-password=$managerPasswordValue" `
      "--from-literal=employee-password=$employeePasswordValue" `
      "--dry-run=client" "-o" "yaml" | kubectl apply -f - | Out-Null

    $jobYaml | kubectl apply -f - | Out-Host

    Write-Host "Waiting for k6 pod scheduling..."
    kubectl wait -n $Namespace --for=condition=PodScheduled pod -l "job-name=$jobName" --timeout=$ScheduleTimeout | Out-Host
    if ($LASTEXITCODE -ne 0) {
        kubectl describe job $jobName -n $Namespace | Out-Host
        throw "k6 pod did not schedule within $ScheduleTimeout"
    }

    $deadline = (Get-Date).AddSeconds((Convert-DurationToSeconds $JobTimeout))
    $result = 124
    while ((Get-Date) -lt $deadline) {
        $job = kubectl get job $jobName -n $Namespace -o json 2>$null | ConvertFrom-Json
        $succeeded = [int]($job.status.succeeded | ForEach-Object { $_ })
        $failed = [int]($job.status.failed | ForEach-Object { $_ })
        if ($succeeded -ge 1) { $result = 0; break }
        if ($failed -ge 1) { $result = 1; break }
        Start-Sleep -Seconds 5
    }

    kubectl get job $jobName -n $Namespace -o wide | Out-Host
    kubectl get pods -n $Namespace -l "job-name=$jobName" -o wide | Out-Host

    $logs = kubectl logs -n $Namespace "job/$jobName" --all-containers=true 2>&1
    $logs | Tee-Object -FilePath $logPath | Out-Host

    $capturing = $false
    $summaryLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $logs) {
        if ($line -eq "__K6_SUMMARY_JSON_BEGIN__") { $capturing = $true; continue }
        if ($line -eq "__K6_SUMMARY_JSON_END__") { $capturing = $false; continue }
        if ($capturing) { $summaryLines.Add($line) }
    }
    if ($summaryLines.Count -gt 0) {
        $summaryLines | Set-Content -Encoding ascii -Path $summaryPath
    } else {
        "{}" | Set-Content -Encoding ascii -Path $summaryPath
    }

    if (-not $KeepJob) {
        kubectl delete configmap $configMapName -n $Namespace --ignore-not-found=true *> $null
        kubectl delete secret $secretName -n $Namespace --ignore-not-found=true *> $null
    }

    if ($result -ne 0) {
        kubectl describe job $jobName -n $Namespace | Out-Host
        kubectl describe pods -n $Namespace -l "job-name=$jobName" | Out-Host
        if (-not $KeepJob) {
            kubectl delete job $jobName -n $Namespace --ignore-not-found=true --wait=false *> $null
        }
        throw "k6 run failed or timed out. See $logPath"
    }

    if (-not $KeepJob) {
        kubectl delete job $jobName -n $Namespace --ignore-not-found=true --wait=false *> $null
    }

    Write-Host "k6 run passed. Summary: $summaryPath" -ForegroundColor Green
    Write-Host "Grafana testid filter: $testId" -ForegroundColor Green
}

if (-not $Profile) {
    if ($Suite -eq "real-user") { $Profile = "medium" } else { $Profile = "baseline" }
}

Invoke-Checked aws "eks" "update-kubeconfig" "--name" $ClusterName "--region" $AwsRegion | Out-Null

$steps = @()
if ($VusSteps -and $VusSteps.Count -gt 0) {
    $steps = $VusSteps
} else {
    $steps = @($Vus)
}

foreach ($step in $steps) {
    if ($step -lt 1) { throw "All VusSteps values must be positive. Got $step." }
    Invoke-K6Run -TargetVus $step
}
