[CmdletBinding()]
param(
    [string]$OutputFile = (Join-Path $PSScriptRoot "serverlist.txt"),
    [switch]$SkipSpnDiscovery,
    [switch]$SkipActiveDirectoryServiceScan,
    [switch]$SkipSqlBrowserDiscovery
)

Write-Host "Discovering SQL instances..." -ForegroundColor Cyan
$instances = New-Object System.Collections.Generic.List[string]

function Add-SqlInstance {
    param([string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $instances.Add($Value.Trim().TrimEnd('\'))
    }
}

# 1. SQL SPN discovery (domain environments)
if (-not $SkipSpnDiscovery) {
    Write-Progress -Activity "SQL Discovery" -Status "Scanning Active Directory SQL SPNs" -PercentComplete 10
    if (Get-Command setspn.exe -ErrorAction SilentlyContinue) {
        try {
            setspn.exe -Q MSSQLSvc/* 2>$null |
                Select-String "MSSQLSvc/" |
                ForEach-Object {
                    $entry = ($_ -split "/")[1]
                    if ($entry -match ":") {
                        $server = $entry.Split(":")[0].Split(".")[0]
                        $instanceOrPort = $entry.Split(":")[1]
                        if ($instanceOrPort -eq "1433") { Add-SqlInstance $server }
                        elseif ($instanceOrPort -match '^\d+$') { Add-SqlInstance "$server,$instanceOrPort" }
                        else { Add-SqlInstance "$server\$instanceOrPort" }
                    }
                }
        } catch {
            Write-Warning "SPN discovery failed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "setspn.exe is unavailable; skipping SPN discovery."
    }
}

# 2. Remote service discovery (optional and potentially noisy)
if (-not $SkipActiveDirectoryServiceScan) {
    Write-Progress -Activity "SQL Discovery" -Status "Enumerating Windows servers" -PercentComplete 25

    if (Get-Module -ListAvailable -Name ActiveDirectory) {
        Import-Module ActiveDirectory -ErrorAction Stop
        $servers = @(Get-ADComputer -Filter 'OperatingSystem -like "*Server*"' | Select-Object -ExpandProperty Name)
        $total = [math]::Max($servers.Count, 1)
        $count = 0

        foreach ($server in $servers) {
            $count++
            $percent = [int](($count / $total) * 55) + 25
            Write-Progress -Activity "Scanning Servers for SQL Services" -Status "Checking $server ($count of $($servers.Count))" -PercentComplete $percent

            $session = $null
            try {
                $session = New-CimSession -ComputerName $server -ErrorAction Stop
                Get-CimInstance -ClassName Win32_Service -CimSession $session -ErrorAction Stop |
                    Where-Object { $_.Name -eq "MSSQLSERVER" -or $_.Name -like 'MSSQL$*' } |
                    ForEach-Object {
                        if ($_.Name -eq "MSSQLSERVER") { Add-SqlInstance $server }
                        else {
                            $inst = $_.Name -replace '^MSSQL\$', ''
                            Add-SqlInstance "$server\$inst"
                        }
                    }
            }
            catch {
                Write-Verbose "Could not query services on $server: $($_.Exception.Message)"
            }
            finally {
                if ($session) { Remove-CimSession $session }
            }
        }
    }
    else {
        Write-Warning "ActiveDirectory module is unavailable; skipping AD server/service discovery."
    }
}

# 3. SQL Browser enumeration (best effort)
if (-not $SkipSqlBrowserDiscovery) {
    Write-Progress -Activity "SQL Discovery" -Status "Scanning SQL Browser broadcasts" -PercentComplete 90
    try {
        $browser = [System.Data.Sql.SqlDataSourceEnumerator]::Instance.GetDataSources()
        foreach ($row in $browser) {
            if ($row.InstanceName) { Add-SqlInstance "$($row.ServerName)\$($row.InstanceName)" }
            else { Add-SqlInstance $row.ServerName }
        }
    }
    catch {
        Write-Warning "SQL Browser discovery failed: $($_.Exception.Message)"
    }
}

$clean = $instances |
    Where-Object { $_ -notmatch "FDLauncher|Launchpad|OLAP|MICROSOFT##|SSEE" } |
    Sort-Object -Unique

$clean | Out-File $OutputFile -Encoding utf8
Write-Progress -Activity "SQL Discovery" -Completed
Write-Host ""
Write-Host "Discovery complete." -ForegroundColor Green
Write-Host "$($clean.Count) SQL instance(s) found."
Write-Host "Server list saved to $OutputFile"
