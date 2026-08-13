[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),
    [string]$ServerListPath = (Join-Path $PSScriptRoot "serverlist.txt"),
    [switch]$SkipReferenceRefresh
)

# =========================
# Author - Rae Rucker
# SQL Server Health Check
# Public / environment-neutral edition
# =========================

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot
$HtmlTemplatePath = Join-Path $ScriptRoot "HtmlReportTemplate.ps1"
$ReferenceJsonPath = Join-Path $ScriptRoot "SQLBuildReference.json"
$ReportDate = Get-Date

function Resolve-LocalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $ScriptRoot $Path
}

if (-not (Test-Path $ConfigPath)) {
    $example = Join-Path $ScriptRoot "config.example.json"
    throw "Configuration not found: $ConfigPath. Copy '$example' to 'config.json' and edit it for your environment."
}
if (-not (Test-Path $ServerListPath)) {
    $example = Join-Path $ScriptRoot "serverlist.example.txt"
    throw "Server list not found: $ServerListPath. Copy '$example' to 'serverlist.txt' and add your SQL instances."
}
if (-not (Test-Path $HtmlTemplatePath)) {
    throw "HTML template not found: $HtmlTemplatePath"
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$Script:SqlHealthThresholds = $Config.Thresholds
. $HtmlTemplatePath

$OutputFolder = Resolve-LocalPath $Config.Report.OutputFolder
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$prefix = if ($Config.Report.FilePrefix) { [string]$Config.Report.FilePrefix } else { "SqlHealthCheck" }
$OutputFilePath = Join-Path $OutputFolder ("{0}_{1:yyyyMMdd_HHmmss}.html" -f $prefix, $ReportDate)
$BackupCsvPath = Join-Path $OutputFolder "FullBackupReport.csv"

$Instances = Get-Content $ServerListPath |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#') } |
    ForEach-Object { $_.Trim() } |
    Sort-Object -Unique

if (-not $Instances -or $Instances.Count -eq 0) {
    throw "No SQL instances were found in $ServerListPath"
}

Write-Host "$($Instances.Count) SQL instance(s) loaded." -ForegroundColor Green

# =========================
# Helper Functions
# =========================

function Get-SqlReleaseCatalog {
    # Extended-support end dates come from Microsoft lifecycle pages.
    # ESU eligibility is intentionally not treated as standard support.
    @(
        @{ MajorVersion="17"; VersionName="SQL Server 2025"; Url="https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions"; SupportEnd="2036-01-06" },
        @{ MajorVersion="16"; VersionName="SQL Server 2022"; Url="https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions"; SupportEnd="2033-01-11" },
        @{ MajorVersion="15"; VersionName="SQL Server 2019"; Url="https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions"; SupportEnd="2030-01-08" },
        @{ MajorVersion="14"; VersionName="SQL Server 2017"; Url="https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/build-versions"; SupportEnd="2027-10-12" },
        @{ MajorVersion="13"; VersionName="SQL Server 2016"; Url="https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2016/build-versions"; SupportEnd="2026-07-14" },
        @{ MajorVersion="12"; VersionName="SQL Server 2014"; Url="https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2014/build-versions"; SupportEnd="2024-07-09" },
        @{ MajorVersion="11"; VersionName="SQL Server 2012"; Url="https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2012/build-versions"; SupportEnd="2022-07-12" },
        @{ MajorVersion="10"; VersionName="SQL Server 2008/2008 R2"; Url="https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2008/build-versions"; SupportEnd="2019-07-09" },
        @{ MajorVersion="9";  VersionName="SQL Server 2005"; Url="https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2005/build-versions"; SupportEnd="2016-04-12" }
    )
}

function Get-LifecycleStatus {
    param([string]$SupportEnd)
    if (-not $SupportEnd) { return "Unknown" }
    if ((Get-Date).Date -gt ([datetime]$SupportEnd).Date) { return "End of Support" }
    return "Supported"
}

function Get-LatestSqlBuildReference {
    [CmdletBinding()]
    param()

    $result = [ordered]@{}

    foreach ($page in (Get-SqlReleaseCatalog)) {
        try {
            Write-Host "Refreshing SQL build reference from $($page.VersionName)..." -ForegroundColor Cyan
            $response = Invoke-WebRequest -Uri $page.Url -UseBasicParsing -ErrorAction Stop
            $content = $response.Content

            $cuPattern  = '(?is)CU\s*\d+\s*(?:\(Latest\))?.*?(\d+\.\d+\.\d+\.\d+).*?(KB\d{7,8})'
            $gdrPattern = '(?is)GDR.*?(\d+\.\d+\.\d+\.\d+).*?(KB\d{7,8})'

            $latestBuild = $null
            $latestKB = $null
            $servicingModel = "CU"

            $cuMatch = [regex]::Match($content, $cuPattern)
            if ($cuMatch.Success) {
                $latestBuild = $cuMatch.Groups[1].Value
                $latestKB = $cuMatch.Groups[2].Value
            }
            else {
                $gdrMatch = [regex]::Match($content, $gdrPattern)
                if ($gdrMatch.Success) {
                    $latestBuild = $gdrMatch.Groups[1].Value
                    $latestKB = $gdrMatch.Groups[2].Value
                    $servicingModel = "GDR"
                }
            }

            if (-not $latestBuild) {
                throw "Could not parse latest build from $($page.Url)"
            }

            $result[$page.MajorVersion] = [ordered]@{
                ProductName = $page.VersionName
                MajorVersion = $page.MajorVersion
                LatestBuild = $latestBuild
                LatestKB = $latestKB
                LifecycleStatus = Get-LifecycleStatus $page.SupportEnd
                SupportEnd = $page.SupportEnd
                ServicingModel = $servicingModel
                SourceUrl = $page.Url
                LastRefreshed = (Get-Date).ToString("s")
            }
        }
        catch {
            Write-Warning "Failed to refresh $($page.VersionName): $($_.Exception.Message)"
        }
    }

    if ($result.Count -eq 0) {
        throw "No SQL build reference data could be downloaded."
    }

    return [PSCustomObject]$result
}

function Get-QueryErrorRow {
    param([string]$Instance, [string]$Section, [string]$ErrorMessage)
    [PSCustomObject]@{ ServerName=$Instance; Section=$Section; Error=$ErrorMessage }
}

function New-SqlConnectionString {
    param([string]$Instance)

    if (-not $Config.Sql.IntegratedSecurity) {
        throw "This public edition currently supports Windows Integrated Security only."
    }

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder["Data Source"] = $Instance
    $builder["Initial Catalog"] = "master"
    $builder["Integrated Security"] = $true
    $builder["TrustServerCertificate"] = [bool]$Config.Sql.TrustServerCertificate
    $builder["Connect Timeout"] = [int]$Config.Sql.ConnectionTimeoutSeconds
    return $builder.ConnectionString
}

function Invoke-HealthQuery {
    param([string]$Instance, [string]$Query)

    $connection = New-Object System.Data.SqlClient.SqlConnection (New-SqlConnectionString $Instance)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = [int]$Config.Sql.CommandTimeoutSeconds

        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
        $table = New-Object System.Data.DataTable
        [void]$adapter.Fill($table)

        foreach ($row in $table.Rows) {
            $obj = [ordered]@{}
            foreach ($col in $table.Columns) {
                $value = $row[$col.ColumnName]
                if ($value -is [System.DBNull]) { $value = $null }
                $obj[$col.ColumnName] = $value
            }
            [PSCustomObject]$obj
        }
    }
    finally {
        if ($connection.State -ne 'Closed') { $connection.Close() }
        $connection.Dispose()
    }
}

function Test-SqlConnection {
    param([string]$Instance)
    try {
        [void](Invoke-HealthQuery -Instance $Instance -Query "SELECT 1 AS IsOnline;")
        return $true
    }
    catch {
        return $false
    }
}

function Compare-Version {
    param($VersionRow, $Reference)

    $major = [string]$VersionRow.ProductMajorVersion
    $build = [string]$VersionRow.ProductVersion
    $kb = [string]$VersionRow.ProductUpdateReference
    $catalogEntry = Get-SqlReleaseCatalog | Where-Object { $_.MajorVersion -eq $major } | Select-Object -First 1
    $versionName = if ($catalogEntry) { $catalogEntry.VersionName } else { "SQL Server (Major $major)" }
    $lifecycle = if ($catalogEntry) { Get-LifecycleStatus $catalogEntry.SupportEnd } else { "Unknown" }
    $refEntry = $Reference.$major

    if ($lifecycle -eq "End of Support") {
        $recommendation = "Upgrade SQL Server to a supported version"
    }
    else {
        $recommendation = "Manual review required"
    }

    $latestBuild = "Unknown"
    $latestKB = "Unknown"
    $patchStatus = "Unknown"

    if ($refEntry) {
        $latestBuild = [string]$refEntry.LatestBuild
        $latestKB = if ([string]::IsNullOrWhiteSpace([string]$refEntry.LatestKB)) { "Unknown" } else { [string]$refEntry.LatestKB }

        try {
            $installedVersion = [version]$build
            $referenceVersion = [version]$latestBuild
            if ($installedVersion -lt $referenceVersion) {
                $patchStatus = "Update Available"
                if ($lifecycle -ne "End of Support") { $recommendation = "Review and install the current servicing update" }
            }
            elseif ($installedVersion -eq $referenceVersion) {
                $patchStatus = "Up To Date"
                if ($lifecycle -ne "End of Support") { $recommendation = "No action required" }
            }
            else {
                $patchStatus = "Newer Than Reference"
                if ($lifecycle -ne "End of Support") { $recommendation = "No action required; refresh reference data if unexpected" }
            }
        }
        catch {
            $patchStatus = "Unknown"
        }
    }

    [PSCustomObject]@{
        ServerName = $VersionRow.ServerName
        SqlVersion = $versionName
        Edition = $VersionRow.Edition
        InstalledVersion = $build
        InstalledKB = if ([string]::IsNullOrWhiteSpace($kb)) { "Unknown" } else { $kb }
        LatestBuild = $latestBuild
        LatestKB = $latestKB
        LifecycleStatus = $lifecycle
        PatchStatus = $patchStatus
        Recommendation = $recommendation
        Clustered = $VersionRow.IsClustered
        HostNode = $VersionRow.HostNode
    }
}

# =========================
# Load / Refresh Build Reference
# =========================

$BuildReference = $null
if (Test-Path $ReferenceJsonPath) {
    try {
        $BuildReference = Get-Content $ReferenceJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
        Write-Host "Loaded cached SQL build reference." -ForegroundColor DarkGreen
    }
    catch {
        Write-Warning "Cached SQL build reference is invalid and will be rebuilt."
    }
}

if (-not $SkipReferenceRefresh) {
    try {
        $NewBuildReference = Get-LatestSqlBuildReference
        $JsonText = $NewBuildReference | ConvertTo-Json -Depth 10
        $null = $JsonText | ConvertFrom-Json -ErrorAction Stop
        $JsonText | Out-File $ReferenceJsonPath -Encoding utf8
        $BuildReference = $JsonText | ConvertFrom-Json -ErrorAction Stop
        Write-Host "SQL build reference refreshed successfully." -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not refresh SQL build reference automatically: $($_.Exception.Message)"
    }
}

if (-not $BuildReference) {
    throw "No SQL build reference is available. Run once with internet access so SQLBuildReference.json can be created."
}

# =========================
# Queries
# =========================

$QueryVersionInfo = @"
SELECT
    @@SERVERNAME AS ServerName,
    SERVERPROPERTY('Edition') AS Edition,
    SERVERPROPERTY('ProductVersion') AS ProductVersion,
    SERVERPROPERTY('ProductMajorVersion') AS ProductMajorVersion,
    SERVERPROPERTY('ProductUpdateReference') AS ProductUpdateReference,
    SERVERPROPERTY('IsClustered') AS IsClustered,
    SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS HostNode;
"@

$QueryMemoryUsage = @"
SELECT
    @@SERVERNAME AS ServerName,
    (committed_kb/1024) AS SQLMemoryMB,
    (physical_memory_kb/1024) AS TotalMemoryMB,
    CAST((committed_kb * 100.0) / NULLIF(physical_memory_kb,0) AS decimal(5,2)) AS MemoryPercentUsed
FROM sys.dm_os_sys_info;
"@

$QueryBackupStatus = @"
WITH LastFullBackup AS
(
    SELECT database_name, MAX(backup_finish_date) AS LastFullBackupDate
    FROM msdb.dbo.backupset
    WHERE type = 'D'
    GROUP BY database_name
),
LastLogBackup AS
(
    SELECT database_name, MAX(backup_finish_date) AS LastLogBackupDate
    FROM msdb.dbo.backupset
    WHERE type = 'L'
    GROUP BY database_name
)
SELECT
    @@SERVERNAME AS ServerName,
    d.name AS DatabaseName,
    d.state_desc AS DatabaseState,
    d.recovery_model_desc AS RecoveryModel,
    f.LastFullBackupDate,
    l.LastLogBackupDate,
    DATEDIFF(hour, f.LastFullBackupDate, GETDATE()) AS FullBackupAgeHours
FROM sys.databases d
LEFT JOIN LastFullBackup f ON d.name = f.database_name
LEFT JOIN LastLogBackup l ON d.name = l.database_name
WHERE d.database_id > 4
ORDER BY FullBackupAgeHours DESC;
"@

$diskWarning = [decimal]$Config.Thresholds.DiskWarningFreePercent
$QueryDriveSpace = @"
SELECT
    @@SERVERNAME AS ServerName,
    dovs.volume_mount_point AS Drive,
    CONVERT(decimal(18,2), MIN((dovs.available_bytes * 100.0) / NULLIF(dovs.total_bytes,0))) AS FreeSpacePct
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id,mf.file_id) dovs
GROUP BY dovs.volume_mount_point
HAVING MIN((dovs.available_bytes * 100.0) / NULLIF(dovs.total_bytes,0)) < $diskWarning
ORDER BY FreeSpacePct ASC;
"@

$QueryJobStatus = @"
SELECT
    @@SERVERNAME AS ServerName,
    j.name AS JobName,
    CASE WHEN j.enabled = 1 THEN 'Enabled' ELSE 'Disabled' END AS JobStatus,
    CASE
        WHEN h.run_status IS NULL THEN 'Never Run'
        WHEN h.run_status = 0 THEN 'Failed'
        WHEN h.run_status = 1 THEN 'Succeeded'
        WHEN h.run_status = 2 THEN 'Retry'
        WHEN h.run_status = 3 THEN 'Cancelled'
        WHEN h.run_status = 4 THEN 'Running'
        ELSE 'Unknown'
    END AS LastRunStatus,
    CASE WHEN h.run_date IS NULL OR h.run_date = 0 THEN NULL
         ELSE msdb.dbo.agent_datetime(h.run_date, h.run_time)
    END AS LastRunTime
FROM msdb.dbo.sysjobs j
OUTER APPLY
(
    SELECT TOP (1) h2.run_status, h2.run_date, h2.run_time
    FROM msdb.dbo.sysjobhistory h2
    WHERE h2.job_id = j.job_id AND h2.step_id = 0
    ORDER BY h2.instance_id DESC
) h
ORDER BY j.name;
"@

# =========================
# Data Collection
# =========================

$Connectivity = @()
$VersionReview = @()
$MemoryUsage = @()
$BackupStatus = @()
$DriveSpace = @()
$JobStatus = @()
$QueryErrors = @()

foreach ($Instance in $Instances) {
    Write-Host "Collecting health data from $Instance" -ForegroundColor Cyan

    $isOnline = Test-SqlConnection -Instance $Instance
    $Connectivity += [PSCustomObject]@{
        ServerName = $Instance
        Connectivity = if ($isOnline) { "Online" } else { "Offline" }
    }

    if (-not $isOnline) {
        $QueryErrors += Get-QueryErrorRow -Instance $Instance -Section "Connectivity" -ErrorMessage "Could not establish a SQL connection."
        continue
    }

    try {
        $v = Invoke-HealthQuery -Instance $Instance -Query $QueryVersionInfo
        foreach ($row in ($v | Sort-Object ServerName, ProductVersion -Unique)) {
            $VersionReview += Compare-Version -VersionRow $row -Reference $BuildReference
        }
    } catch { $QueryErrors += Get-QueryErrorRow -Instance $Instance -Section "Version Check" -ErrorMessage $_.Exception.Message }

    try { $MemoryUsage += Invoke-HealthQuery -Instance $Instance -Query $QueryMemoryUsage }
    catch { $QueryErrors += Get-QueryErrorRow -Instance $Instance -Section "Memory Usage" -ErrorMessage $_.Exception.Message }

    try { $BackupStatus += Invoke-HealthQuery -Instance $Instance -Query $QueryBackupStatus }
    catch { $QueryErrors += Get-QueryErrorRow -Instance $Instance -Section "Backup Status" -ErrorMessage $_.Exception.Message }

    try { $DriveSpace += Invoke-HealthQuery -Instance $Instance -Query $QueryDriveSpace }
    catch { $QueryErrors += Get-QueryErrorRow -Instance $Instance -Section "Drive Space" -ErrorMessage $_.Exception.Message }

    try { $JobStatus += Invoke-HealthQuery -Instance $Instance -Query $QueryJobStatus }
    catch { $QueryErrors += Get-QueryErrorRow -Instance $Instance -Section "SQL Agent Jobs" -ErrorMessage $_.Exception.Message }
}

$Connectivity = $Connectivity | Sort-Object ServerName -Unique
$VersionReview = $VersionReview | Sort-Object ServerName, InstalledVersion -Unique
$MemoryUsage = $MemoryUsage | Sort-Object { [decimal]$_.MemoryPercentUsed } -Descending
$DriveSpace = $DriveSpace | Sort-Object ServerName, Drive -Unique
$JobStatus = $JobStatus | Sort-Object ServerName, JobName
$BackupStatus = $BackupStatus | Sort-Object FullBackupAgeHours -Descending

$backupWarn = [int]$Config.Thresholds.FullBackupWarningHours
$backupCritical = [int]$Config.Thresholds.FullBackupCriticalHours

$BackupIssues = $BackupStatus | ForEach-Object {
    $issues = New-Object System.Collections.Generic.List[string]

    if ($_.DatabaseState -ne "ONLINE") {
        $issues.Add("Database state is $($_.DatabaseState)")
    }
    if ($null -eq $_.LastFullBackupDate) {
        $issues.Add("No full backup found")
    }
    elseif ([int]$_.FullBackupAgeHours -gt $backupCritical) {
        $issues.Add("Full backup older than $backupCritical hours")
    }
    elseif ([int]$_.FullBackupAgeHours -gt $backupWarn) {
        $issues.Add("Full backup older than $backupWarn hours")
    }
    if ($_.RecoveryModel -eq "FULL" -and $null -eq $_.LastLogBackupDate) {
        $issues.Add("No transaction log backup found")
    }

    if ($issues.Count -gt 0) {
        [PSCustomObject]@{
            ServerName = $_.ServerName
            DatabaseName = $_.DatabaseName
            DatabaseState = $_.DatabaseState
            RecoveryModel = $_.RecoveryModel
            LastFullBackupDate = $_.LastFullBackupDate
            LastLogBackupDate = $_.LastLogBackupDate
            FullBackupAgeHours = $_.FullBackupAgeHours
            BackupIssue = ($issues -join "; ")
        }
    }
}

$BackupIssues = $BackupIssues | Sort-Object FullBackupAgeHours -Descending

if ([bool]$Config.Report.ExportFullBackupCsv) {
    $BackupStatus | Export-Csv $BackupCsvPath -NoTypeInformation
}

# =========================
# Summary + HTML
# =========================

$EndOfSupport = ($VersionReview | Where-Object { $_.LifecycleStatus -eq "End of Support" }).Count
$Updates = ($VersionReview | Where-Object { $_.PatchStatus -eq "Update Available" }).Count
$HighMemory = ($MemoryUsage | Where-Object { [decimal]$_.MemoryPercentUsed -ge [decimal]$Config.Thresholds.MemoryCriticalPercent }).Count
$CriticalDisk = ($DriveSpace | Where-Object { [decimal]$_.FreeSpacePct -lt [decimal]$Config.Thresholds.DiskCriticalFreePercent }).Count
$FailedJobs = ($JobStatus | Where-Object { $_.LastRunStatus -eq "Failed" }).Count
$ClusteredInstances = ($VersionReview | Where-Object { [int]$_.Clustered -eq 1 }).Count
$OfflineInstances = ($Connectivity | Where-Object { $_.Connectivity -eq "Offline" }).Count

$Summary = @(
    [PSCustomObject]@{ Metric="SQL Instances Checked"; Value=$Instances.Count }
    [PSCustomObject]@{ Metric="Offline SQL Instances"; Value=$OfflineInstances }
    [PSCustomObject]@{ Metric="End-of-Support SQL Instances"; Value=$EndOfSupport }
    [PSCustomObject]@{ Metric="Instances Missing Reference Update"; Value=$Updates }
    [PSCustomObject]@{ Metric="Instances Above Critical SQL Memory Threshold"; Value=$HighMemory }
    [PSCustomObject]@{ Metric="SQL Volumes Below Critical Free-Space Threshold"; Value=$CriticalDisk }
    [PSCustomObject]@{ Metric="Backup Issues Detected"; Value=$BackupIssues.Count }
    [PSCustomObject]@{ Metric="Failed SQL Agent Jobs"; Value=$FailedJobs }
    [PSCustomObject]@{ Metric="Clustered SQL Instances"; Value=$ClusteredInstances }
    [PSCustomObject]@{ Metric="Query Errors"; Value=$QueryErrors.Count }
)

$HtmlSections = New-Object System.Collections.Generic.List[string]
$HtmlSections.Add((Convert-DataToHtmlTable $Summary "Environment Summary"))
$HtmlSections.Add((Convert-DataToHtmlTable $Connectivity "SQL Connectivity"))
$HtmlSections.Add((Convert-DataToHtmlTable $VersionReview "SQL Version, Lifecycle & Servicing Baseline" "Patch comparison uses the latest build reference collected from Microsoft and should be treated as a servicing baseline, not a substitute for your organization's patch policy."))
$HtmlSections.Add((Convert-DataToHtmlTable $MemoryUsage "SQL Memory Usage"))
$HtmlSections.Add((Convert-DataToHtmlTable $BackupIssues "Backup Issues" "Only databases with detected backup/state issues are shown here. See the CSV output for the full backup inventory."))
$HtmlSections.Add((Convert-DataToHtmlTable $DriveSpace "Low Free Space on SQL Database Volumes"))

foreach ($group in ($JobStatus | Group-Object ServerName)) {
    $HtmlSections.Add((Convert-DataToHtmlTable ($group.Group | Sort-Object JobName) "SQL Agent Jobs - $($group.Name)"))
}

if ($QueryErrors.Count -gt 0) {
    $HtmlSections.Add((Convert-DataToHtmlTable $QueryErrors "Collection Errors"))
}

$FullHtml = New-SqlHealthReportHtml -ReportDate $ReportDate -Collector $env:COMPUTERNAME -OutputFilePath $OutputFilePath -HtmlSections $HtmlSections
$FullHtml | Out-File $OutputFilePath -Encoding utf8

Write-Host ""
Write-Host "SQL Health Report created:" -ForegroundColor Green
Write-Host $OutputFilePath -ForegroundColor Yellow

# Keep newest N reports.
$retention = [int]$Config.Report.RetentionCount
if ($retention -gt 0) {
    $files = Get-ChildItem -Path $OutputFolder -Filter "${prefix}_*.html" | Sort-Object LastWriteTime -Descending
    if ($files.Count -gt $retention) {
        $files | Select-Object -Skip $retention | Remove-Item -Force
    }
}

[PSCustomObject]@{
    HtmlReportPath = $OutputFilePath
    BackupCsvPath = if ([bool]$Config.Report.ExportFullBackupCsv) { $BackupCsvPath } else { $null }
    InstancesChecked = $Instances.Count
    QueryErrorCount = $QueryErrors.Count
}
