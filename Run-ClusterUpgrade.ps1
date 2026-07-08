<#
.SYNOPSIS
    Orchestrator script for end-to-end clustered SQL Server upgrade.
.DESCRIPTION
    Runs the full upgrade pipeline:
      1. Pre-Validation
      2. Stage & Upgrade (or Stage-Only)
      3. Post-Validation
    Stops the pipeline if any step fails.
.EXAMPLE
    # Full upgrade
    .\Run-ClusterUpgrade.ps1 -ClusterName "YOURCLUSTER" -SetupMediaPath "\\fileserver\SQL2022CU"

    # Stage only (prep without upgrading)
    .\Run-ClusterUpgrade.ps1 -ClusterName "YOURCLUSTER" -SetupMediaPath "\\fileserver\SQL2022CU" -StageOnly

    # With expected version validation
    .\Run-ClusterUpgrade.ps1 -ClusterName "YOURCLUSTER" -SetupMediaPath "\\fileserver\SQL2022CU" -ExpectedVersion "16.0.4175.1"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter()]
    [string]$InstanceName = "MSSQLSERVER",

    [Parameter(Mandatory = $true)]
    [string]$SetupMediaPath,

    [Parameter()]
    [string]$StagingPath = "C:\SQLUpgrade",

    [Parameter()]
    [string]$BackupPath = "C:\SQLUpgrade\Backups",

    [Parameter()]
    [switch]$StageOnly,

    [Parameter()]
    [string]$UpdateSource,

    [Parameter()]
    [string]$ExpectedVersion,

    [Parameter()]
    [int]$ExpectedMajorVersion,

    [Parameter()]
    [int]$MinDiskSpaceGB = 20
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

Write-Host "======================================" -ForegroundColor Cyan
Write-Host " SQL Server Cluster Upgrade Pipeline  " -ForegroundColor Cyan
Write-Host " Cluster: $ClusterName                " -ForegroundColor Cyan
Write-Host " $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

# --- Step 1: Pre-Validation ---
Write-Host "`n`n###########################################" -ForegroundColor White
Write-Host "# STEP 1: PRE-VALIDATION                  #" -ForegroundColor White
Write-Host "###########################################`n" -ForegroundColor White

& "$scriptDir\01-Pre-Validation.ps1" `
    -ClusterName $ClusterName `
    -InstanceName $InstanceName `
    -MinDiskSpaceGB $MinDiskSpaceGB

if ($LASTEXITCODE -ne 0) {
    Write-Host "`nPre-validation FAILED. Aborting upgrade pipeline." -ForegroundColor Red
    exit 1
}

Write-Host "`nPre-validation passed. Proceeding..." -ForegroundColor Green
Start-Sleep -Seconds 3

# --- Step 2: Stage & Upgrade ---
Write-Host "`n`n###########################################" -ForegroundColor White
Write-Host "# STEP 2: STAGE & UPGRADE                 #" -ForegroundColor White
Write-Host "###########################################`n" -ForegroundColor White

$upgradeParams = @{
    ClusterName   = $ClusterName
    InstanceName  = $InstanceName
    SetupMediaPath = $SetupMediaPath
    StagingPath   = $StagingPath
    BackupPath    = $BackupPath
}

if ($StageOnly) { $upgradeParams.StageOnly = $true }
if ($UpdateSource) { $upgradeParams.UpdateSource = $UpdateSource }

& "$scriptDir\02-Stage-And-Upgrade.ps1" @upgradeParams

if ($LASTEXITCODE -ne 0) {
    Write-Host "`nStage/Upgrade FAILED. Check logs." -ForegroundColor Red
    exit 2
}

if ($StageOnly) {
    Write-Host "`nStaging complete. Run again without -StageOnly to upgrade." -ForegroundColor Cyan
    exit 0
}

Write-Host "`nUpgrade complete. Running post-validation..." -ForegroundColor Green
Start-Sleep -Seconds 10

# --- Step 3: Post-Validation ---
Write-Host "`n`n###########################################" -ForegroundColor White
Write-Host "# STEP 3: POST-VALIDATION                 #" -ForegroundColor White
Write-Host "###########################################`n" -ForegroundColor White

$postParams = @{
    ClusterName  = $ClusterName
    InstanceName = $InstanceName
}

if ($ExpectedVersion) { $postParams.ExpectedVersion = $ExpectedVersion }
if ($ExpectedMajorVersion) { $postParams.ExpectedMajorVersion = $ExpectedMajorVersion }

& "$scriptDir\03-Post-Validation.ps1" @postParams

if ($LASTEXITCODE -ne 0) {
    Write-Host "`nPost-validation found issues. Review output above." -ForegroundColor Red
    exit 3
}

Write-Host "`n`n======================================" -ForegroundColor Green
Write-Host " UPGRADE PIPELINE COMPLETE            " -ForegroundColor Green
Write-Host " All validations passed.              " -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
exit 0
