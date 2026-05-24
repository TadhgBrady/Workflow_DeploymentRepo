<#
.SYNOPSIS
    Trigger the deployment repo pipeline for a specific built image version.

.DESCRIPTION
    Starts the GitLab CD pipeline with the same variables normally passed by
    the development repo trigger-deploy bridge job. This is useful for release
    demos where production must stay on an old image while staging runs a newer
    image, then production is promoted manually during the demo.

    Create a pipeline trigger token in yr4-projectdeploymentrepo and set it in
    the current shell as DEPLOYMENT_TRIGGER_TOKEN before running this script.

.EXAMPLE
    $env:DEPLOYMENT_TRIGGER_TOKEN = "..."
    .\local\trigger-demo-release.ps1 -ImageVersion 097716b7 -PipelineMode full-release

.EXAMPLE
    .\local\trigger-demo-release.ps1 -ImageVersion 097716b7 -PipelineMode staging-only -DryRun
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-fA-F]{7,40}$")]
    [string]$ImageVersion,

    [ValidateSet("auto", "validate-only", "staging-only", "staging-teardown-test", "full-release")]
    [string]$PipelineMode = "full-release",

    [string]$ImageTag = $(if ($env:IMAGE_TAG) { $env:IMAGE_TAG } else { "bencev04/4th-year-proj-tadgh-bence" }),

    [string]$SourceCommit = $ImageVersion,

    [string]$SourceBranch = "demo-release",

    [string]$GitLabBaseUrl = "https://gitlab.comp.dkit.ie",

    [string]$ProjectPath = "finalproject/Prototypes/yr4-projectdeploymentrepo",

    [string]$Ref = "main",

    [string]$TriggerToken = $env:DEPLOYMENT_TRIGGER_TOKEN,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if ($SourceCommit -notmatch "^[0-9a-fA-F]{7,40}$") {
    throw "SourceCommit must be a 7-40 character git SHA-like value. Got: $SourceCommit"
}

if (-not $ImageTag -or $ImageTag.Trim().Length -eq 0) {
    throw "ImageTag is required. Pass -ImageTag or set IMAGE_TAG."
}

$encodedProjectPath = [System.Uri]::EscapeDataString($ProjectPath)
$uri = "$GitLabBaseUrl/api/v4/projects/$encodedProjectPath/trigger/pipeline"

$body = @{
    token = $TriggerToken
    ref = $Ref
    "variables[IMAGE_TAG]" = $ImageTag
    "variables[IMAGE_VERSION]" = $ImageVersion.ToLowerInvariant()
    "variables[SOURCE_COMMIT]" = $SourceCommit.ToLowerInvariant()
    "variables[SOURCE_BRANCH]" = $SourceBranch
    "variables[SOURCE_PROJECT_PATH]" = "manual/demo-release"
    "variables[SOURCE_PIPELINE_ID]" = "manual"
    "variables[PIPELINE_MODE]" = $PipelineMode
    "variables[DEMO_RELEASE]" = "true"
}

Write-Host "`nTrigger deployment pipeline" -ForegroundColor Cyan
Write-Host "  Project:       $ProjectPath"
Write-Host "  Ref:           $Ref"
Write-Host "  Image tag:     $ImageTag"
Write-Host "  Image version: $($ImageVersion.ToLowerInvariant())"
Write-Host "  Pipeline mode: $PipelineMode"

if ($DryRun) {
    Write-Host "`nDry run only. No pipeline was triggered." -ForegroundColor Yellow
    Write-Host "POST $uri"
    foreach ($key in ($body.Keys | Sort-Object)) {
        if ($key -eq "token") { continue }
        Write-Host "  $key=$($body[$key])"
    }
    exit 0
}

if (-not $TriggerToken -or $TriggerToken.Trim().Length -eq 0) {
    throw "DEPLOYMENT_TRIGGER_TOKEN is not set. Create a pipeline trigger token in the deployment repo and set `$env:DEPLOYMENT_TRIGGER_TOKEN for this shell."
}

$response = Invoke-RestMethod `
    -Method Post `
    -Uri $uri `
    -ContentType "application/x-www-form-urlencoded" `
    -Body $body

Write-Host "`nPipeline triggered." -ForegroundColor Green
Write-Host "  Pipeline ID:  $($response.id)"
Write-Host "  Status:       $($response.status)"
Write-Host "  URL:          $($response.web_url)"
