<#
.SYNOPSIS
    Installs local Argo CD and Argo Rollouts CLIs for production rehearsals.

.DESCRIPTION
    Downloads the same CLI versions used by the production GitLab pipeline into
    local/bin. run-full-production-rehearsal.ps1 automatically prepends that
    directory to PATH when it exists.
#>

param(
    [string]$ArgoCdVersion = "v2.12.6",
    [string]$ArgoRolloutsVersion = "v1.7.2",
    [string]$InstallDir = (Join-Path $PSScriptRoot "bin"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Save-Download([string]$Uri, [string]$OutFile) {
    if ((Test-Path $OutFile) -and -not $Force) {
        Write-Host "Already exists: $OutFile"
        return
    }
    Write-Host "Downloading $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    Unblock-File -Path $OutFile -ErrorAction SilentlyContinue
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "Only 64-bit Windows is supported by this helper."
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$argocdPath = Join-Path $InstallDir "argocd.exe"
$rolloutsPath = Join-Path $InstallDir "kubectl-argo-rollouts.exe"

Write-Step "Installing Argo CD CLI $ArgoCdVersion"
Save-Download `
    -Uri "https://github.com/argoproj/argo-cd/releases/download/$ArgoCdVersion/argocd-windows-amd64.exe" `
    -OutFile $argocdPath

Write-Step "Installing Argo Rollouts kubectl plugin $ArgoRolloutsVersion"
Save-Download `
    -Uri "https://github.com/argoproj/argo-rollouts/releases/download/$ArgoRolloutsVersion/kubectl-argo-rollouts-windows-amd64" `
    -OutFile $rolloutsPath

Write-Step "Installed local Argo CLIs"
Write-Host "Install dir: $InstallDir"
Write-Host "This terminal can use them with: `$env:PATH = '$InstallDir;' + `$env:PATH"
Write-Host "The rehearsal script adds this directory to PATH automatically."
