<#
.SYNOPSIS
    Pre-validation for clustered SQL Server upgrade.
.DESCRIPTION
    Validates permissions, cluster health, AG synchronization, disk space,
    and service states before proceeding with a rolling upgrade.
.PARAMETER ClusterName
    Windows Failover Cluster name.
.PARAMETER InstanceName
    SQL Server instance name (default: MSSQLSERVER).
.PARAMETER MinDiskSpaceGB
    Minimum free disk space required on each node (default: 20GB).
.PARAMETER TargetVersion
    Expected SQL Server version after upgrade (e.g., "16.0.4175.1").
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter()]
    [string]$InstanceName = "MSSQLSERVER",

    [Parameter()]
    [int]$MinDiskSpaceGB = 20,

    [Parameter()]
    [string]$TargetVersion
)

$ErrorActionPreference = "Stop"
$script:ValidationErrors = @()
$script:ValidationWarnings = @()

function Write-ValidationResult {
    param([string]$Check, [bool]$Passed, [string]$Detail)
    $status = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Passed) { "Green" } else { "Red" }
    Write-Host "$status $Check" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
    if (-not $Passed) { $script:ValidationErrors += "$Check - $Detail" }
}

function Write-ValidationWarning {
    param([string]$Check, [string]$Detail)
    Write-Host "[WARN] $Check" -ForegroundColor Yellow
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
    $script:ValidationWarnings += "$Check - $Detail"
}

# --- Section 1: Permission Checks ---
Write-Host "`n===== PERMISSION VALIDATION =====" -ForegroundColor Cyan

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
Write-ValidationResult -Check "Running as Administrator" -Passed $isAdmin -Detail $(
    if (-not $isAdmin) { "Must run elevated" }
)

# Check cluster admin permissions
try {
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction Stop
    $clusterAccess = $true
} catch {
    $clusterAccess = $false
}
Write-ValidationResult -Check "Cluster admin access ($ClusterName)" -Passed $clusterAccess -Detail $(
    if (-not $clusterAccess) { "Cannot access cluster. Verify permissions and name." }
)

# Check SQL sysadmin on each node
$clusterNodes = Get-ClusterNode -Cluster $ClusterName | Select-Object -ExpandProperty Name
foreach ($node in $clusterNodes) {
    $connString = if ($InstanceName -eq "MSSQLSERVER") { $node } else { "$node\$InstanceName" }
    try {
        $sysadminCheck = Invoke-Sqlcmd -ServerInstance $connString -Query "
            SELECT IS_SRVROLEMEMBER('sysadmin') AS IsSysAdmin
        " -ErrorAction Stop
        $isSysAdmin = $sysadminCheck.IsSysAdmin -eq 1
    } catch {
        $isSysAdmin = $false
    }
    Write-ValidationResult -Check "SQL sysadmin on $node" -Passed $isSysAdmin -Detail $(
        if (-not $isSysAdmin) { "Current user lacks sysadmin role on $connString" }
    )
}

# --- Section 2: Cluster Health ---
Write-Host "`n===== CLUSTER HEALTH =====" -ForegroundColor Cyan

# Check all cluster nodes are Up
$downNodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -ne "Up" }
Write-ValidationResult -Check "All cluster nodes online" -Passed ($downNodes.Count -eq 0) -Detail $(
    if ($downNodes.Count -gt 0) { "Down nodes: $($downNodes.Name -join ', ')" }
)

# Check cluster quorum
try {
    $quorum = Get-ClusterQuorum -Cluster $ClusterName
    $quorumHealthy = $true
} catch {
    $quorumHealthy = $false
}
Write-ValidationResult -Check "Cluster quorum healthy" -Passed $quorumHealthy -Detail $(
    if ($quorumHealthy) { "Type: $($quorum.QuorumType)" } else { "Cannot read quorum state" }
)

# Check for any failed/offline cluster resources
$failedResources = Get-ClusterResource -Cluster $ClusterName | Where-Object { $_.State -notin @("Online", "Offline") }
Write-ValidationResult -Check "No failed cluster resources" -Passed ($failedResources.Count -eq 0) -Detail $(
    if ($failedResources.Count -gt 0) { "Failed: $($failedResources.Name -join ', ')" }
)

# --- Section 3: Availability Group Health ---
Write-Host "`n===== AVAILABILITY GROUP HEALTH =====" -ForegroundColor Cyan

$primaryNode = $clusterNodes[0]
$primaryConn = if ($InstanceName -eq "MSSQLSERVER") { $primaryNode } else { "$primaryNode\$InstanceName" }

try {
    $agReplicas = Invoke-Sqlcmd -ServerInstance $primaryConn -Query "
        SELECT
            ag.name AS AGName,
            rs.role_desc AS Role,
            rs.connected_state_desc AS ConnState,
            rs.synchronization_health_desc AS SyncHealth,
            ar.replica_server_name AS ReplicaNode
        FROM sys.dm_hadr_availability_replica_states rs
        JOIN sys.availability_replicas ar ON rs.replica_id = ar.replica_id
        JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
    " -ErrorAction Stop

    $unhealthyReplicas = $agReplicas | Where-Object { $_.SyncHealth -ne "HEALTHY" }
    Write-ValidationResult -Check "All AG replicas synchronized" -Passed ($unhealthyReplicas.Count -eq 0) -Detail $(
        if ($unhealthyReplicas.Count -gt 0) {
            ($unhealthyReplicas | ForEach-Object { "$($_.ReplicaNode) ($($_.AGName)): $($_.SyncHealth)" }) -join "; "
        } else {
            "All replicas HEALTHY across $($agReplicas.Count) replica(s)"
        }
    )

    $disconnected = $agReplicas | Where-Object { $_.ConnState -ne "CONNECTED" }
    Write-ValidationResult -Check "All AG replicas connected" -Passed ($disconnected.Count -eq 0) -Detail $(
        if ($disconnected.Count -gt 0) {
            ($disconnected | ForEach-Object { "$($_.ReplicaNode): $($_.ConnState)" }) -join "; "
        }
    )
} catch {
    Write-ValidationWarning -Check "AG health check" -Detail "Could not query AG state from $primaryConn - $_"
}

# Check AG databases are synchronized
try {
    $agDatabases = Invoke-Sqlcmd -ServerInstance $primaryConn -Query "
        SELECT
            d.name AS DatabaseName,
            drs.synchronization_state_desc AS SyncState,
            drs.is_suspended AS IsSuspended
        FROM sys.dm_hadr_database_replica_states drs
        JOIN sys.databases d ON drs.database_id = d.database_id
        WHERE drs.is_local = 0
    " -ErrorAction Stop

    $unsyncedDBs = $agDatabases | Where-Object { $_.SyncState -ne "SYNCHRONIZED" -and $_.SyncState -ne "SYNCHRONIZING" }
    $suspendedDBs = $agDatabases | Where-Object { $_.IsSuspended -eq $true }

    Write-ValidationResult -Check "All AG databases synchronized" -Passed ($unsyncedDBs.Count -eq 0) -Detail $(
        if ($unsyncedDBs.Count -gt 0) { ($unsyncedDBs | ForEach-Object { "$($_.DatabaseName): $($_.SyncState)" }) -join "; " }
    )
    Write-ValidationResult -Check "No suspended AG databases" -Passed ($suspendedDBs.Count -eq 0) -Detail $(
        if ($suspendedDBs.Count -gt 0) { ($suspendedDBs.DatabaseName -join ", ") + " are suspended" }
    )
} catch {
    Write-ValidationWarning -Check "AG database sync check" -Detail "Could not query - $_"
}

# --- Section 4: Disk Space ---
Write-Host "`n===== DISK SPACE =====" -ForegroundColor Cyan

foreach ($node in $clusterNodes) {
    try {
        $drives = Invoke-Command -ComputerName $node -ScriptBlock {
            Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" |
                Select-Object DeviceID, @{N='FreeGB';E={[math]::Round($_.FreeSpace/1GB,2)}},
                    @{N='SizeGB';E={[math]::Round($_.Size/1GB,2)}}
        } -ErrorAction Stop

        foreach ($drive in $drives) {
            $hasSpace = $drive.FreeGB -ge $MinDiskSpaceGB
            Write-ValidationResult -Check "Disk space $node $($drive.DeviceID)" -Passed $hasSpace -Detail (
                "$($drive.FreeGB)GB free of $($drive.SizeGB)GB (min: ${MinDiskSpaceGB}GB)"
            )
        }
    } catch {
        Write-ValidationWarning -Check "Disk space on $node" -Detail "Cannot query remotely - $_"
    }
}

# --- Section 5: SQL Server Services ---
Write-Host "`n===== SQL SERVER SERVICES =====" -ForegroundColor Cyan

foreach ($node in $clusterNodes) {
    try {
        $services = Invoke-Command -ComputerName $node -ScriptBlock {
            param($inst)
            $svcName = if ($inst -eq "MSSQLSERVER") { "MSSQLSERVER" } else { "MSSQL`$$inst" }
            $agentName = if ($inst -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { "SQLAgent`$$inst" }
            Get-Service -Name $svcName, $agentName -ErrorAction SilentlyContinue |
                Select-Object Name, Status, StartType
        } -ArgumentList $InstanceName -ErrorAction Stop

        foreach ($svc in $services) {
            $running = $svc.Status -eq "Running"
            Write-ValidationResult -Check "Service $($svc.Name) on $node" -Passed $running -Detail "Status: $($svc.Status)"
        }
    } catch {
        Write-ValidationWarning -Check "Service check on $node" -Detail "Cannot query - $_"
    }
}

# --- Section 6: Current Version Info ---
Write-Host "`n===== CURRENT SQL SERVER VERSION =====" -ForegroundColor Cyan

foreach ($node in $clusterNodes) {
    $connString = if ($InstanceName -eq "MSSQLSERVER") { $node } else { "$node\$InstanceName" }
    try {
        $versionInfo = Invoke-Sqlcmd -ServerInstance $connString -Query "
            SELECT
                SERVERPROPERTY('ProductVersion') AS Version,
                SERVERPROPERTY('ProductLevel') AS Level,
                SERVERPROPERTY('Edition') AS Edition
        " -ErrorAction Stop
        Write-Host "  $node : v$($versionInfo.Version) ($($versionInfo.Level)) - $($versionInfo.Edition)" -ForegroundColor Gray
    } catch {
        Write-ValidationWarning -Check "Version check on $node" -Detail "Cannot connect - $_"
    }
}

# --- Summary ---
Write-Host "`n===== VALIDATION SUMMARY =====" -ForegroundColor Cyan

if ($script:ValidationErrors.Count -eq 0 -and $script:ValidationWarnings.Count -eq 0) {
    Write-Host "`nAll checks PASSED. Server is ready for upgrade." -ForegroundColor Green
    exit 0
} elseif ($script:ValidationErrors.Count -eq 0) {
    Write-Host "`nAll critical checks passed with $($script:ValidationWarnings.Count) warning(s):" -ForegroundColor Yellow
    $script:ValidationWarnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "`nProceed with caution." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "`n$($script:ValidationErrors.Count) FAILED check(s):" -ForegroundColor Red
    $script:ValidationErrors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    if ($script:ValidationWarnings.Count -gt 0) {
        Write-Host "`n$($script:ValidationWarnings.Count) warning(s):" -ForegroundColor Yellow
        $script:ValidationWarnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    Write-Host "`nDO NOT proceed with upgrade until failures are resolved." -ForegroundColor Red
    exit 1
}
