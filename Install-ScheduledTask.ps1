[CmdletBinding()]
param(
    [string]$TaskName = "SQL Server Daily Health Check",
    [string]$RunAt = "05:00",
    [System.Management.Automation.PSCredential]$Credential
)

$runner = Join-Path $PSScriptRoot "Run-SqlHealthCheck.ps1"
if (-not (Test-Path $runner)) { throw "Runner script not found: $runner" }

try {
    $time = [datetime]::ParseExact($RunAt, "HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
}
catch {
    throw "RunAt must use 24-hour HH:mm format, for example 05:00 or 23:30."
}

$powerShellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$arguments = "-NoProfile -File `"$runner`""
$action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $arguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Daily -At $time
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)

if ($Credential) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -User $Credential.UserName -Password $Credential.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null
}
else {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null
    Write-Warning "No credential was supplied. Verify the task's Security Options in Task Scheduler if it must run while the user is logged off."
}

Write-Host "Scheduled task '$TaskName' registered for $RunAt daily." -ForegroundColor Green
