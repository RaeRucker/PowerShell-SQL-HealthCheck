[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),
    [string]$ServerListPath = (Join-Path $PSScriptRoot "serverlist.txt"),
    [switch]$SkipReferenceRefresh
)

$healthCheckScript = Join-Path $PSScriptRoot "Invoke-SqlHealthCheck.ps1"
$Result = & $healthCheckScript -ConfigPath $ConfigPath -ServerListPath $ServerListPath -SkipReferenceRefresh:$SkipReferenceRefresh

if (-not $Result -or -not (Test-Path $Result.HtmlReportPath)) {
    throw "Health check did not return a valid report path."
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not [bool]$Config.Email.Enabled) {
    Write-Host "Email delivery is disabled in config.json." -ForegroundColor DarkYellow
    return $Result
}

# Optional SMTP credentials are read from environment variables, never from config.json:
# SQLHEALTH_SMTP_USERNAME
# SQLHEALTH_SMTP_PASSWORD
$mail = New-Object System.Net.Mail.MailMessage
$smtp = New-Object System.Net.Mail.SmtpClient([string]$Config.Email.SmtpServer, [int]$Config.Email.SmtpPort)

try {
    $mail.From = [string]$Config.Email.From
    foreach ($recipient in @($Config.Email.To)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$recipient)) {
            [void]$mail.To.Add([string]$recipient)
        }
    }

    if ($mail.To.Count -eq 0) { throw "Email.Enabled is true but no recipients are configured." }

    $mail.Subject = [string]$Config.Email.Subject
    $mail.IsBodyHtml = $true
    $mail.Body = Get-Content $Result.HtmlReportPath -Raw
    [void]$mail.Attachments.Add((New-Object System.Net.Mail.Attachment($Result.HtmlReportPath)))

    if ($Result.BackupCsvPath -and (Test-Path $Result.BackupCsvPath)) {
        [void]$mail.Attachments.Add((New-Object System.Net.Mail.Attachment($Result.BackupCsvPath)))
    }

    $smtp.EnableSsl = [bool]$Config.Email.UseSsl

    if ($env:SQLHEALTH_SMTP_USERNAME) {
        if (-not $env:SQLHEALTH_SMTP_PASSWORD) {
            throw "SQLHEALTH_SMTP_USERNAME is set but SQLHEALTH_SMTP_PASSWORD is missing."
        }
        $smtp.Credentials = New-Object System.Net.NetworkCredential($env:SQLHEALTH_SMTP_USERNAME, $env:SQLHEALTH_SMTP_PASSWORD)
    }
    else {
        $smtp.UseDefaultCredentials = $true
    }

    $smtp.Send($mail)
    Write-Host "Health-check email sent." -ForegroundColor Green
}
finally {
    $mail.Dispose()
    $smtp.Dispose()
}

$Result
