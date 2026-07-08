<#
.SYNOPSIS
    Stages upgrade media and performs rolling SQL Server upgrade on a Windows Failover Cluster.
.DESCRIPTION
    Handles the full rolling upgrade workflow:
    - Stages setup media to each node
    - Backs up system databases
    - Performs rolling upgrade (secondary nodes first, then failover primary)
    - Supports -StageOnly mode to stage without upgrading
.PARAMETER ClusterName
    Windows Failover Cluster name.
.PARAMETER InstanceName
    SQL Server instance name (default: MSSQLSERVER).
.PARAMETER SetupMediaPath
    UNC or local path to the SQL Server setup media (containing setup.exe).
.PARAMETER StagingPath
    Local path on each node to stage the media (default: C:\SQLUpgrade).
.PARAMETER BackupPath
    Path for system database backups (default: C:\SQLUpgrade\Backups).
.PARAMETER StageOnly
    Only copy media and create backups; do not run upgrade.
.PARAMETER UpdateSource
    Path to cumulative update files if applying CU during upgrade.
.PARAMETER SkipBackup
    Skip system database backups (not recommended).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
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
    [switch]$SkipBackup
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $StagingPath "upgrade_$timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry -ForegroundColor $(switch ($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "White" } })
    $entry | Out-File -FilePath $logFile -Append -ErrorAction SilentlyContinue
}

function Stop-WithError {
    param([string]$Message)
    Write-Log $Message -Level "ERROR"
    throw $Message
}

# --- Gather Cluster Topology ---
Write-Log "Gathering cluster topology for $ClusterName"
$clusterNodes = Get-ClusterNode -Cluster $ClusterName | Select-Object -ExpandProperty Name

$primaryConn = if ($InstanceName -eq "MSSQLSERVER") { $clusterNodes[0] } else { "$($clusterNodes[0])\$InstanceName" }

# Determine AG primary
try {
    $agInfo = Invoke-Sqlcmd -ServerInstance $primaryConn -Query "
        SELECT
            ar.replica_server_name,
            rs.role_desc
        FROM sys.dm_hadr_availability_replica_states rs
        JOIN sys.availability_replicas ar ON rs.replica_id = ar.replica_id
    " -ErrorAction Stop

    $primaryReplica = ($agInfo | Where-Object { $_.role_desc -eq "PRIMARY" }).replica_server_name
    $secondaryReplicas = ($agInfo | Where-Object { $_.role_desc -eq "SECONDARY" }).replica_server_name

    if (-not $primaryReplica) {
        $primaryReplica = $clusterNodes[0]
        $secondaryReplicas = $clusterNodes[1..($clusterNodes.Count - 1)]
    }
} catch {
    Write-Log "No AG detected or cannot query. Treating as FCI." -Level "WARN"
    $primaryReplica = (Get-ClusterGroup -Cluster $ClusterName |
        Where-Object { $_.GroupType -eq "SqlServer" }).OwnerNode.Name
    if (-not $primaryReplica) { $primaryReplica = $clusterNodes[0] }
    $secondaryReplicas = $clusterNodes | Where-Object { $_ -ne $primaryReplica }
}

Write-Log "Primary: $primaryReplica | Secondaries: $($secondaryReplicas -join ', ')"

# --- Stage Media ---
Write-Host "`n===== STAGING MEDIA =====" -ForegroundColor Cyan

if (-not (Test-Path $SetupMediaPath)) {
    Stop-WithError "Setup media not found at: $SetupMediaPath"
}

foreach ($node in $clusterNodes) {
    Write-Log "Staging media to $node"
    $remoteStagingPath = "\\$node\$($StagingPath -replace ':', '$')"

    try {
        Invoke-Command -ComputerName $node -ScriptBlock {
            param($path)
            if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory -Force | Out-Null }
        } -ArgumentList $StagingPath -ErrorAction Stop

        $remoteSetupPath = Join-Path $remoteStagingPath "Setup"
        if (-not (Test-Path $remoteSetupPath)) {
            New-Item -Path $remoteSetupPath -ItemType Directory -Force | Out-Null
        }

        Write-Log "  Copying setup files to $node..."
        Copy-Item -Path "$SetupMediaPath\*" -Destination $remoteSetupPath -Recurse -Force
        Write-Log "  Staged successfully on $node"
    } catch {
        Stop-WithError "Failed to stage on ${node}: $_"
    }
}

# --- Backup System Databases ---
if (-not $SkipBackup) {
    Write-Host "`n===== BACKING UP SYSTEM DATABASES =====" -ForegroundColor Cyan

    foreach ($node in $clusterNodes) {
        $connString = if ($InstanceName -eq "MSSQLSERVER") { $node } else { "$node\$InstanceName" }

        Invoke-Command -ComputerName $node -ScriptBlock {
            param($path)
            if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory -Force | Out-Null }
        } -ArgumentList $BackupPath -ErrorAction Stop

        $systemDBs = @("master", "model", "msdb")
        foreach ($db in $systemDBs) {
            $backupFile = "\\$node\$($BackupPath -replace ':', '$')\${db}_${node}_${timestamp}.bak"
            try {
                Write-Log "  Backing up $db on $node"
                Invoke-Sqlcmd -ServerInstance $connString -Query "
                    BACKUP DATABASE [$db] TO DISK = N'$BackupPath\${db}_${node}_${timestamp}.bak'
                    WITH INIT, COMPRESSION, CHECKSUM
                " -ErrorAction Stop
            } catch {
                Stop-WithError "Backup of $db failed on ${node}: $_"
            }
        }
        Write-Log "  Backups complete on $node"
    }
} else {
    Write-Log "Skipping backups (SkipBackup specified)" -Level "WARN"
}

# --- Stage-Only Exit ---
if ($StageOnly) {
    Write-Host "`n===== STAGING COMPLETE =====" -ForegroundColor Green
    Write-Log "StageOnly mode - media staged and backups taken. Ready for upgrade."
    Write-Host "Run again without -StageOnly to proceed with upgrade." -ForegroundColor Cyan
    exit 0
}

# --- Perform Rolling Upgrade ---
Write-Host "`n===== PERFORMING ROLLING UPGRADE =====" -ForegroundColor Cyan

$upgradeOrder = @($secondaryReplicas) + @($primaryReplica)
Write-Log "Upgrade order: $($upgradeOrder -join ' -> ')"

function Invoke-NodeUpgrade {
    param([string]$Node, [bool]$IsPrimary)

    $connString = if ($InstanceName -eq "MSSQLSERVER") { $Node } else { "$Node\$InstanceName" }

    # If this is the AG primary, failover first
    if ($IsPrimary) {
        Write-Log "Failing over AG from $Node to a secondary..."
        try {
            $targetSecondary = $secondaryReplicas[0]
            $targetConn = if ($InstanceName -eq "MSSQLSERVER") { $targetSecondary } else { "$targetSecondary\$InstanceName" }

            $agNames = Invoke-Sqlcmd -ServerInstance $connString -Query "
                SELECT ag.name FROM sys.availability_groups ag
                JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id
                WHERE rs.role_desc = 'PRIMARY' AND rs.is_local = 1
            " -ErrorAction Stop

            foreach ($ag in $agNames) {
                Write-Log "  Failing over AG '$($ag.name)' to $targetSecondary"
                Invoke-Sqlcmd -ServerInstance $targetConn -Query "
                    ALTER AVAILABILITY GROUP [$($ag.name)] FAILOVER
                " -ErrorAction Stop
            }

            Start-Sleep -Seconds 15
            Write-Log "  Failover complete"
        } catch {
            Stop-WithError "AG failover failed: $_"
        }
    }

    # Run setup.exe with upgrade action
    Write-Log "Starting upgrade on $Node..."
    $setupExe = "$StagingPath\Setup\setup.exe"
    $instanceParam = if ($InstanceName -eq "MSSQLSERVER") { "MSSQLSERVER" } else { $InstanceName }

    $setupArgs = @(
        "/ACTION=Patch"
        "/INSTANCENAME=$instanceParam"
        "/QUIET"
        "/IACCEPTSQLSERVERLICENSETERMS"
        "/INDICATEPROGRESS"
    )

    if ($UpdateSource) {
        $setupArgs += "/UPDATESOURCE=`"$UpdateSource`""
    }

    try {
        $result = Invoke-Command -ComputerName $Node -ScriptBlock {
            param($exe, $args)
            $process = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -NoNewWindow
            return $process.ExitCode
        } -ArgumentList $setupExe, ($setupArgs -join " ") -ErrorAction Stop

        if ($result -ne 0 -and $result -ne 3010) {
            Stop-WithError "Setup.exe returned exit code $result on $Node. Check SQL Server setup logs."
        }

        if ($result -eq 3010) {
            Write-Log "Node $Node requires a reboot to complete upgrade" -Level "WARN"
            if ($PSCmdlet.ShouldProcess($Node, "Restart computer")) {
                Write-Log "  Restarting $Node..."
                Restart-Computer -ComputerName $Node -Force -Wait
                Start-Sleep -Seconds 60

                # Wait for SQL to come back
                $retries = 0
                do {
                    Start-Sleep -Seconds 10
                    $retries++
                    try {
                        Invoke-Sqlcmd -ServerInstance $connString -Query "SELECT 1" -ErrorAction Stop
                        $sqlUp = $true
                    } catch {
                        $sqlUp = $false
                    }
                } while (-not $sqlUp -and $retries -lt 30)

                if (-not $sqlUp) {
                    Stop-WithError "SQL Server did not come back online on $Node after reboot"
                }
                Write-Log "  $Node back online"
            }
        }

        Write-Log "Upgrade complete on $Node"
    } catch {
        Stop-WithError "Upgrade failed on ${Node}: $_"
    }

    # Wait for AG to resync after this node's upgrade
    Write-Log "Waiting for AG synchronization on $Node..."
    $retries = 0
    do {
        Start-Sleep -Seconds 10
        $retries++
        try {
            $syncState = Invoke-Sqlcmd -ServerInstance $connString -Query "
                SELECT synchronization_health_desc AS Health
                FROM sys.dm_hadr_availability_replica_states
                WHERE is_local = 1
            " -ErrorAction Stop
            $isSynced = ($syncState | Where-Object { $_.Health -ne "HEALTHY" }).Count -eq 0
        } catch {
            $isSynced = $false
        }
    } while (-not $isSynced -and $retries -lt 60)

    if (-not $isSynced) {
        Stop-WithError "AG did not resynchronize on $Node within 10 minutes"
    }
    Write-Log "AG synchronized on $Node"
}

# Upgrade secondaries first, then primary
foreach ($node in $secondaryReplicas) {
    Write-Host "`n--- Upgrading SECONDARY: $node ---" -ForegroundColor Yellow
    Invoke-NodeUpgrade -Node $node -IsPrimary $false
}

Write-Host "`n--- Upgrading PRIMARY: $primaryReplica ---" -ForegroundColor Yellow
Invoke-NodeUpgrade -Node $primaryReplica -IsPrimary $true

# --- Fail back to original primary (optional) ---
Write-Host "`n===== UPGRADE COMPLETE =====" -ForegroundColor Green
Write-Log "All nodes upgraded. Original primary was: $primaryReplica"
Write-Host "Consider failing back to original primary if desired." -ForegroundColor Cyan
Write-Log "Log file: $logFile"
exit 0
