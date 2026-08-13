$Script:SqlHealthReportCss = @"
<style>
body {
    font-family: Segoe UI, Arial, sans-serif;
    font-size: 13px;
    margin: 20px;
    background: #f7f7f7;
}
.header {
    background:#1f4e79;
    color:white;
    padding:18px;
    border-radius:6px;
    margin-bottom:20px;
}
.header h1 { margin:0; }
.section {
    background:white;
    border:1px solid #d9d9d9;
    border-radius:6px;
    padding:16px;
    margin-bottom:18px;
}
.section h2 {
    margin-top:0;
    border-bottom:1px solid #e5e5e5;
    padding-bottom:8px;
}
table {
    width:100%;
    border-collapse:collapse;
    margin-top:10px;
}
th {
    background:#1f4e79;
    color:white;
    padding:8px;
    border:1px solid #cfcfcf;
    text-align:left;
}
td {
    padding:8px;
    border:1px solid #d9d9d9;
    vertical-align:top;
}
tr:nth-child(even) { background:#f9f9f9; }
.ok { background:#dff0d8; }
.warn { background:#fcf8e3; }
.error { background:#f2dede; }
.small { font-size:11px; color:#666; }
</style>
"@

function Convert-ToSafeHtml {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-MemoryBar {
    param([decimal]$Percent)

    $width = [math]::Max(0, [math]::Min(100, [math]::Round($Percent)))
    $color = "#27ae60"

    if ($Percent -ge [decimal]$Script:SqlHealthThresholds.MemoryCriticalPercent) { $color = "#c0392b" }
    elseif ($Percent -ge [decimal]$Script:SqlHealthThresholds.MemoryWarningPercent) { $color = "#f1c40f" }

    return "<div style='width:120px;background:#eee;border-radius:4px;overflow:hidden'><div style='width:${width}%;background:$color;height:12px'></div></div>"
}

function Get-StorageBar {
    param([decimal]$PercentFree)

    $percentUsed = 100 - $PercentFree
    $width = [math]::Max(0, [math]::Min(100, [math]::Round($percentUsed)))
    $color = "#27ae60"

    if ($PercentFree -lt [decimal]$Script:SqlHealthThresholds.DiskCriticalFreePercent) { $color = "#c0392b" }
    elseif ($PercentFree -lt [decimal]$Script:SqlHealthThresholds.DiskWarningFreePercent) { $color = "#f1c40f" }

    return "<div style='width:140px;background:#ddd;border-radius:6px'><div style='width:${width}%;background:$color;height:14px;border-radius:6px'></div></div>"
}

function Get-StatusCssClass {
    param(
        [string]$ColumnName,
        [AllowNull()][object]$Value
    )

    $text = [string]$Value

    switch ($ColumnName) {
        "Connectivity" {
            if ($text -eq "Online") { return "ok" }
            if ($text -eq "Offline") { return "error" }
        }
        "JobStatus" {
            if ($text -eq "Disabled") { return "warn" }
            if ($text -eq "Enabled") { return "ok" }
        }
        "LifecycleStatus" {
            if ($text -match "End of Support") { return "error" }
            if ($text -match "Supported") { return "ok" }
        }
        "BackupIssue" {
            if ($text) { return "error" }
        }
        "PatchStatus" {
            if ($text -match "Update Available") { return "warn" }
            if ($text -match "Up To Date|Newer Than Reference") { return "ok" }
        }
        "LastRunStatus" {
            if ($text -eq "Failed") { return "error" }
            if ($text -eq "Succeeded") { return "ok" }
            if ($text -match "Retry|Cancelled|Never Run") { return "warn" }
        }
        "FreeSpacePct" {
            try {
                if ([decimal]$Value -lt [decimal]$Script:SqlHealthThresholds.DiskCriticalFreePercent) { return "error" }
                if ([decimal]$Value -lt [decimal]$Script:SqlHealthThresholds.DiskWarningFreePercent) { return "warn" }
            } catch {}
        }
        "MemoryPercentUsed" {
            try {
                if ([decimal]$Value -ge [decimal]$Script:SqlHealthThresholds.MemoryCriticalPercent) { return "error" }
                if ([decimal]$Value -ge [decimal]$Script:SqlHealthThresholds.MemoryWarningPercent) { return "warn" }
                return "ok"
            } catch {}
        }
    }

    return ""
}

function Convert-DataToHtmlTable {
    param(
        [AllowNull()][object[]]$Data,
        [Parameter(Mandatory)][string]$Title,
        [string]$Note = ""
    )

    $section = "<div class='section'>"
    $section += "<h2>$(Convert-ToSafeHtml $Title)</h2>"

    if ($Note) {
        $section += "<div class='small'>$(Convert-ToSafeHtml $Note)</div>"
    }

    if (-not $Data -or $Data.Count -eq 0) {
        $section += "<p>No results.</p></div>"
        return $section
    }

    $columns = $Data[0].PSObject.Properties.Name
    $table = "<table><thead><tr>"

    foreach ($c in $columns) {
        $table += "<th>$(Convert-ToSafeHtml $c)</th>"
    }

    $table += "</tr></thead><tbody>"

    foreach ($row in $Data) {
        $table += "<tr>"

        foreach ($c in $columns) {
            $rawValue = $row.$c
            $displayValue = Convert-ToSafeHtml $rawValue

            if ($c -eq "MemoryPercentUsed" -and $null -ne $rawValue) {
                $percent = [decimal]$rawValue
                $displayValue = "$(Convert-ToSafeHtml $percent)% $(Get-MemoryBar $percent)"
            }

            if ($c -eq "FreeSpacePct" -and $null -ne $rawValue) {
                $percent = [decimal]$rawValue
                $displayValue = "$(Convert-ToSafeHtml $percent)% $(Get-StorageBar $percent)"
            }

            $css = Get-StatusCssClass $c $rawValue
            $classAttr = if ($css) { " class='$css'" } else { "" }
            $table += "<td$classAttr>$displayValue</td>"
        }

        $table += "</tr>"
    }

    $table += "</tbody></table>"
    $section += $table
    $section += "</div>"
    return $section
}

function New-SqlHealthReportHtml {
    param(
        [datetime]$ReportDate,
        [string]$Collector,
        [string]$OutputFilePath,
        [System.Collections.Generic.List[string]]$HtmlSections
    )

    $safeDate = Convert-ToSafeHtml $ReportDate
    $safeCollector = Convert-ToSafeHtml $Collector
    $safePath = Convert-ToSafeHtml $OutputFilePath

    $header = @"
<html>
<head>
<meta charset='utf-8'>
<title>SQL Health Check</title>
$Script:SqlHealthReportCss
</head>
<body>
<div class='header'>
<h1>SQL Server Health Check</h1>
Generated: $safeDate <br>
Collector: $safeCollector
</div>
"@

    $footer = @"
<div class='small'>
Report saved to: $safePath
</div>
</body>
</html>
"@

    return $header + ($HtmlSections -join "`r`n") + $footer
}
