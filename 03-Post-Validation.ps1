<#
.SYNOPSIS
    Post-upgrade validation for clustered SQL Server.
.DESCRIPTION
    Validates the upgrade was successful by checking:
    - SQL Server version matches expected target on all nodes
    - AG health and synchronization restored
    - All services running
    - Cluster health intact
    - Database accessibility
.PARAMETER ClusterName
    Windows Failover Cluster name.
.PARAMETER InstanceName
    SQL Server instance name (default: MSSQLSERVER).
.PARAMETER ExpectedVersion
    Expected SQL Server version string after upgrade (e.g., "16.0.4175.1").
.PARAMETER ExpectedMajorVersion
    Expected major version (e.g., 16 for SQL 2022). Used if ExpectedVersion not provided.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter()]
    [string]$InstanceName = "MSSQLSERVER",

    [Parameter()]
    [string]$ExpectedVersion,

    [Parameter()]
    [int]$ExpectedMajorVersion
)

$ErrorActionPreference = "Stop"
$script:PostErrors = @()
$script:PostWarnings = @()

function Write-PostResult {
    param([string]$Check, [bool]$Passed, [string]$Detail)
    $status = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Passed) { "Green" } else { "Red" }
    Write-Host "$status $Check" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
    if (-not $Passed) { $script:PostErrors += "$Check - $Detail" }
}

function Write-PostWarning {
    param([string]$Check, [string]$Detail)
    Write-Host "[WARN] $Check" -ForegroundColor Yellow
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
    $script:PostWarnings += "$Check - $Detail"
}

$clusterNodes = Get-ClusterNode -Cluster $ClusterName | Select-Object -ExpandProperty Name

# --- Section 1: Version Verification ---
Write-Host "`n===== VERSION VERIFICATION =====" -ForegroundColor Cyan

foreach ($node in $clusterNodes) {
    $connString = if ($InstanceName -eq "MSSQLSERVER") { $node } else { "$node\$InstanceName" }
    try {
        $versionInfo = Invoke-Sqlcmd -ServerInstance $connString -Query "
            SELECT
                SERVERPROPERTY('ProductVersion') AS Version,
                SERVERPROPERTY('ProductLevel') AS Level,
                SERVERPROPERTY('Edition') AS Edition,
                SERVERPROPERTY('ProductMajorVersion') AS MajorVersion
        " -ErrorAction Stop

        $currentVersion = $versionInfo.Version
        $currentMajor = [int]$versionInfo.MajorVersion

        if ($ExpectedVersion) {
            $versionMatch = $currentVersion -eq $ExpectedVersion
            Write-PostResult -Check "Version on $node" -Passed $versionMatch -Detail (
                "Current: $currentVersion | Expected: $ExpectedVersion ($($versionInfo.Edition))"
            )
        } elseif ($ExpectedMajorVersion) {
            $majorMatch = $currentMajor -ge $ExpectedMajorVersion
            Write-PostResult -Check "Major version on $node" -Passed $majorMatch -Detail (
                "Current: $currentVersion (Major: $currentMajor) | Expected Major: >= $ExpectedMajorVersion"
            )
        } else {
            Write-Host "  $node : v$currentVersion ($($versionInfo.Level)) - $($versionInfo.Edition)" -ForegroundColor White
        }
    } catch {
        Write-PostResult -Check "Version check on $node" -Passed $false -Detail "Cannot connect: $_"
    }
}

# Verify all nodes on same version
$nodeVersions = @{}
foreach ($node in $clusterNodes) {
    $connString = if ($InstanceName -eq "MSSQLSERVER") { $node } else { "$node\$InstanceName" }
    try {
        $v = Invoke-Sqlcmd -ServerInstance $connString -Query "SELECT SERVERPROPERTY('ProductVersion') AS V" -ErrorAction Stop
        $nodeVersions[$node] = $v.V
    } catch {
        $nodeVersions[$node] = "UNREACHABLE"
    }
}
$uniqueVersions = $nodeVersions.Values | Select-Object -Unique
Write-PostResult -Check "All nodes on same version" -Passed ($uniqueVersions.Count -eq 1) -Detail (
    ($nodeVersions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " | "
)

# --- Section 2: Cluster Health ---
Write-Host "`n===== CLUSTER HEALTH =====" -ForegroundColor Cyan

$downNodes = Get-ClusterNode -Cluster $ClusterName | Where-Object { $_.State -ne "Up" }
Write-PostResult -Check "All cluster nodes online" -Passed ($downNodes.Count -eq 0) -Detail $(
    if ($downNodes.Count -gt 0) { "Down: $($downNodes.Name -join ', ')" } else { "All $($clusterNodes.Count) nodes UP" }
)

$failedResources = Get-ClusterResource -Cluster $ClusterName | Where-Object { $_.State -notin @("Online", "Offline") }
Write-PostResult -Check "No failed cluster resources" -Passed ($failedResources.Count -eq 0) -Detail $(
    if ($failedResources.Count -gt 0) { "Failed: $($failedResources.Name -join ', ')" }
)

# --- Section 3: AG Health ---
Write-Host "`n===== AVAILABILITY GROUP HEALTH =====" -ForegroundColor Cyan

$primaryConn = $null
foreach ($node in $clusterNodes) {
    $connString = if ($InstanceName -eq "MSSQLSERVER") { $node } else { "$node\$InstanceName" }
    try {
        $role = Invoke-Sqlcmd -ServerInstance $connString -Query "
            SELECT role_desc FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1
        " -ErrorAction Stop
        if ($role.role_desc -eq "PRIMARY") {
            $primaryConn = $connString
            break
        }
    } catch { }
}

if (-not $primaryConn) {
    $primaryConn = if ($InstanceName -eq "MSSQLSERVER") { $clusterNodes[0] } else { "$($clusterNodes[0])\$InstanceName" }
}

try {
    $agReplicas = Invoke-Sqlcmd -ServerInstance $primaryConn -Query "
        SELECT
            ag.name AS AGName,
            ar.replica_server_name AS ReplicaNode,
            rs.role_desc AS Role,
            rs.connected_state_desc AS ConnState,
            rs.synchronization_health_desc AS SyncHealth,
            rs.operational_state_desc AS OpState
        FROM sys.dm_hadr_availability_replica_states rs
        JOIN sys.availability_replicas ar ON rs.replica_id = ar.replica_id
        JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
    " -ErrorAction Stop

    $unhealthy = $agReplicas | Where-Object { $_.SyncHealth -ne "HEALTHY" }
    Write-PostResult -Check "All AG replicas healthy" -Passed ($unhealthy.Count -eq 0) -Detail $(
        if ($unhealthy.Count -gt 0) {
            ($unhealthy | ForEach-Object { "$($_.ReplicaNode)($($_.AGName)): $($_.SyncHealth)" }) -join "; "
        } else {
            "$($agReplicas.Count) replica(s) HEALTHY"
        }
    )

    $disconnected = $agReplicas | Where-Object { $_.ConnState -ne "CONNECTED" }
    Write-PostResult -Check "All AG replicas connected" -Passed ($disconnected.Count -eq 0) -Detail $(
        if ($disconnected.Count -gt 0) {
            ($disconnected | ForEach-Object { "$($_.ReplicaNode): $($_.ConnState)" }) -join "; "
        }
    )

    # Show current AG topology
    Write-Host "`n  Current AG Topology:" -ForegroundColor Gray
    foreach ($r in $agReplicas) {
        $roleColor = if ($r.Role -eq "PRIMARY") { "Cyan" } else { "Gray" }
        Write-Host "    $($r.ReplicaNode) - $($r.Role) - $($r.SyncHealth) [$($r.AGName)]" -ForegroundColor $roleColor
    }
} catch {
    Write-PostWarning -Check "AG health check" -Detail "Cannot query AG state: $_"
}

# AG database synchronization
try {
    $agDatabases = Invoke-Sqlcmd -ServerInstance $primaryConn -Query "
        SELECT
            d.name AS DatabaseName,
            ar.replica_server_name AS ReplicaNode,
            drs.synchronization_state_desc AS SyncState,
            drs.is_suspended AS IsSuspended,
            drs.suspend_reason_desc AS SuspendReason
        FROM sys.dm_hadr_database_replica_states drs
        JOIN sys.databases d ON drs.database_id = d.database_id
        JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
        WHERE drs.is_local = 0
    " -ErrorAction Stop

    $unsyncedDBs = $agDatabases | Where-Object { $_.SyncState -notin @("SYNCHRONIZED", "SYNCHRONIZING") }
    $suspendedDBs = $agDatabases | Where-Object { $_.IsSuspended -eq $true }

    Write-PostResult -Check "All AG databases synchronized" -Passed ($unsyncedDBs.Count -eq 0) -Detail $(
        if ($unsyncedDBs.Count -gt 0) {
            ($unsyncedDBs | ForEach-Object { "$($_.DatabaseName)@$($_.ReplicaNode): $($_.SyncState)" }) -join "; "
        } else {
            "$($agDatabases.Count) database replica(s) in sync"
        }
    )
    Write-PostResult -Check "No suspended AG databases" -Passed ($suspendedDBs.Count -eq 0) -Detail $(
        if ($suspendedDBs.Count -gt 0) {
            ($suspendedDBs | ForEach-Object { "$($_.DatabaseName): $($_.SuspendReason)" }) -join "; "
        }
    )
} catch {
    Write-PostWarning -Check "AG database sync check" -Detail "Cannot query: $_"
}

# --- Section 4: Services ---
Write-Host "`n===== SQL SERVER SERVICES =====" -ForegroundColor Cyan

foreach ($node in $clusterNodes) {
    try {
        $services = Invoke-Command -ComputerName $node -ScriptBlock {
            param($inst)
            $svcName = if ($inst -eq "MSSQLSERVER") { "MSSQLSERVER" } else { "MSSQL`$$inst" }
            $agentName = if ($inst -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { "SQLAgent`$$inst" }
            Get-Service -Name $svcName, $agentName -ErrorAction SilentlyContinue |
                Select-Object Name, Status
        } -ArgumentList $InstanceName -ErrorAction Stop

        foreach ($svc in $services) {
            Write-PostResult -Check "$($svc.Name) on $node" -Passed ($svc.Status -eq "Running") -Detail "Status: $($svc.Status)"
        }
    } catch {
        Write-PostWarning -Check "Service check on $node" -Detail "Cannot query: $_"
    }
}

# --- Section 5: Database Accessibility ---
Write-Host "`n===== DATABASE ACCESSIBILITY =====" -ForegroundColor Cyan

foreach ($node in $clusterNodes) {
    $connString = if ($InstanceName -eq "MSSQLSERVER") { $node } else { "$node\$InstanceName" }
    try {
        $databases = Invoke-Sqlcmd -ServerInstance $connString -Query "
            SELECT
                name,
                state_desc,
                is_read_only
            FROM sys.databases
            WHERE database_id > 4
            AND state_desc != 'ONLINE'
        " -ErrorAction Stop

        $offlineDBs = $databases | Where-Object { $_.state_desc -ne "ONLINE" }
        if ($offlineDBs.Count -eq 0) {
            Write-PostResult -Check "All user databases online on $node" -Passed $true -Detail ""
        } else {
            Write-PostResult -Check "All user databases online on $node" -Passed $false -Detail (
                ($offlineDBs | ForEach-Object { "$($_.name): $($_.state_desc)" }) -join "; "
            )
        }
    } catch {
        # Secondary replicas may not expose non-AG databases — that's fine
        Write-PostWarning -Check "Database accessibility on $node" -Detail "Cannot query (may be secondary): $_"
    }
}

# --- Section 6: Error Log Check ---
Write-Host "`n===== RECENT ERROR LOG ENTRIES =====" -ForegroundColor Cyan

foreach ($node in $clusterNodes) {
    $connString = if ($InstanceName -eq "MSSQLSERVER") { $node } else { "$node\$InstanceName" }
    try {
        $errors = Invoke-Sqlcmd -ServerInstance $connString -Query "
            EXEC sp_readerrorlog 0, 1, N'Error', NULL, DATEADD(HOUR, -2, GETDATE()), NULL
        " -ErrorAction Stop

        if ($errors.Count -gt 0) {
            Write-PostWarning -Check "Recent errors in SQL log on $node" -Detail "$($errors.Count) error entries in last 2 hours"
            $errors | Select-Object -First 5 | ForEach-Object {
                Write-Host "    $($_.LogDate): $($_.Text)" -ForegroundColor Gray
            }
        } else {
            Write-PostResult -Check "No recent errors in SQL log on $node" -Passed $true -Detail ""
        }
    } catch {
        Write-PostWarning -Check "Error log on $node" -Detail "Cannot read: $_"
    }
}

# --- Summary ---
Write-Host "`n===== POST-UPGRADE VALIDATION SUMMARY =====" -ForegroundColor Cyan

if ($script:PostErrors.Count -eq 0 -and $script:PostWarnings.Count -eq 0) {
    Write-Host "`nAll post-upgrade checks PASSED. Upgrade successful." -ForegroundColor Green
    exit 0
} elseif ($script:PostErrors.Count -eq 0) {
    Write-Host "`nUpgrade appears successful with $($script:PostWarnings.Count) warning(s):" -ForegroundColor Yellow
    $script:PostWarnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    exit 0
} else {
    Write-Host "`n$($script:PostErrors.Count) FAILED post-upgrade check(s):" -ForegroundColor Red
    $script:PostErrors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    if ($script:PostWarnings.Count -gt 0) {
        Write-Host "`n$($script:PostWarnings.Count) warning(s):" -ForegroundColor Yellow
        $script:PostWarnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    Write-Host "`nInvestigate failures before declaring upgrade complete." -ForegroundColor Red
    exit 1
}
