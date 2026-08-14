# PowerShell-SQL-HealthCheck

A PowerShell-based SQL Server health-check framework that inventories one or more SQL Server instances and produces a self-contained HTML report plus an optional CSV backup inventory.

This repository is intentionally environment-neutral: no production server names, internal domains, service accounts, email addresses, or credentials are stored in source control.

## What it checks

- SQL connectivity
- SQL Server version, edition, lifecycle status, and servicing baseline
- SQL Server memory consumption as a percentage of host physical memory
- User-database full-backup age and missing log backups for FULL recovery databases
- Free space on volumes that contain SQL database files
- SQL Agent enabled/disabled state and latest run result
- Clustered-instance status and current physical host node
- Collection/query errors
## Workflow

```text
serverlist.txt + config.json
           │
           ▼
Run-SqlHealthCheck.ps1
           │
           ▼
Invoke-SqlHealthCheck.ps1
           │
    ┌──────┼────────┐
    ▼      ▼        ▼
 SQL DMV  MSDB   Windows
 Checks   Checks   Checks
    └──────┼────────┘
           ▼
      HTML Report
           │
           ▼
      Daily Email
```
## Repository layout

```text
SqlHealthCheck-Universal/
├── Invoke-SqlHealthCheck.ps1   # Main collection/report engine
├── Run-SqlHealthCheck.ps1      # Wrapper + optional SMTP delivery
├── Find-SqlInstances.ps1       # Optional discovery helper
├── HtmlReportTemplate.ps1      # HTML/CSS rendering
├── Install-ScheduledTask.ps1   # Optional daily Task Scheduler installer
├── config.example.json         # Safe configuration template
├── serverlist.example.txt      # Safe inventory example
└── .gitignore                  # Keeps local data/reports out of Git
```

`SQLBuildReference.json` is generated locally as a cache and is intentionally ignored by Git.

## Quick Start

### Requirements

Before running the health check, make sure:

- PowerShell is available on the Windows system running the script.
- The system running the script can reach each target SQL Server instance.
- The account running the script can authenticate to each SQL Server instance.
- The account has permission to read the SQL Server health information used by the report.
- PowerShell script execution is allowed by your organization's execution policy.

The health check can also be run directly from one of the SQL Servers being monitored, as long as that server is included in `serverlist.txt`.

### SQL Server Permissions

The account running the health check does not need full SQL Server administrative access, but it must be able to read server-level health information, backup history, and SQL Agent job data.

Depending on the SQL Server version, the required server-level permission is:

- SQL Server 2019 and earlier: `VIEW SERVER STATE`
- SQL Server 2022 and later: `VIEW SERVER PERFORMANCE STATE`

For SQL Agent reporting, the account should also have access to SQL Agent job information in `msdb`, such as membership in `SQLAgentReaderRole`.

Use a least-privilege monitoring or service account where possible.

## Run the Health Check

1. Download and extract the repository onto a Windows system that can reach the target SQL Server instances.

2. Open `config.json` and update the settings for your environment.

3. Open `serverlist.txt` and enter each SQL Server instance you want to monitor, one per line.

Example:

```text
<SQLSERVERNAME>
<SQLSERVERNAME>\<INSTANCENAME>
<SQLSERVERNAME>,<PORT>
```

For example:

```text
SQLSERVER01
SQLSERVER02\SQLEXPRESS
SQLSERVER03,1433
```

If the script is being run directly from one of the target SQL Servers, include that server in `serverlist.txt` so it is included in the health check.

4. Open PowerShell in the extracted repository folder.

> **Note:** PowerShell may ask for permission to run the scripts. If you trust this repository, select **A (Yes to All)** to continue.

5. Run the health check:

```powershell
.\Run-SqlHealthCheck.ps1
```

The generated HTML report will be written to the configured output directory.

## Optional SQL discovery

Administrators who do not already have a complete list of SQL Server instances can use the included discovery helper to identify SQL instances across the environment.

The recommended discovery method uses SQL SPNs and SQL Browser discovery while avoiding a broad remote service scan:

```powershell
.\Find-SqlInstances.ps1 -SkipActiveDirectoryServiceScan
```

For a more comprehensive search, administrators can also include Active Directory server enumeration and remote Windows service inspection:

```powershell
.\Find-SqlInstances.ps1
```

Remote service discovery requires the Active Directory PowerShell module along with sufficient permissions and network access to query remote servers. In large domains, this scan may generate significant network activity, so use it only when appropriate.

## Scheduling

To register a daily Windows Scheduled Task at 05:00:

```powershell
.\Install-ScheduledTask.ps1 -RunAt "05:00"
```

For unattended execution under a dedicated account, pass a credential at registration time instead of hard-coding a username/password in the repository:

```powershell
$cred = Get-Credential
.\Install-ScheduledTask.ps1 -RunAt "05:00" -Credential $cred
```

## Email delivery

Email is disabled by default. Configure the non-secret SMTP fields in `config.json` and set `Email.Enabled` to `true`.

If your SMTP server requires a username/password, provide them at runtime as environment variables rather than committing them:

```powershell
$env:SQLHEALTH_SMTP_USERNAME = "smtp-user"
$env:SQLHEALTH_SMTP_PASSWORD = "use-a-secret-store-in-production"
.\Run-SqlHealthCheck.ps1
```

For long-term automation, use your organization's approved secret-management method instead of persisting plaintext secrets in a profile or script.

## Permissions

The account running the check needs:

- Network access to each SQL Server instance.
- SQL permissions sufficient to read the server properties/DMVs used by the script.
- Access to `msdb` backup history and SQL Agent metadata for those report sections.
- If discovery is used: permissions/modules required for the selected AD/CIM discovery methods.

Use a least-privilege monitoring account where possible.

## Servicing and lifecycle notes

The script refreshes its local build reference from Microsoft SQL Server build-history pages and compares the installed build to that reference. Treat the result as a **servicing baseline**, not as a declaration that an environment is secure or compliant. Organizations may follow CU, GDR, ESU, or other approved servicing policies.

Lifecycle status is based on Microsoft's standard extended-support end dates. Extended Security Update eligibility is not treated as normal product support by this script.

## Security / privacy notes

Do not commit:

- `serverlist.txt`
- `config.json`
- generated HTML/CSV reports
- SMTP passwords or SQL credentials
- exported Scheduled Task XML from a production environment

Generated reports can contain server names, database names, SQL Agent job names, patch levels, and host information. Treat them as environment data.

## Portfolio note

The project demonstrates practical Windows/SQL infrastructure automation: discovery, multi-instance health collection, SQL querying, version/lifecycle evaluation, backup monitoring, storage/memory checks, report generation, configuration management, error handling, and scheduled execution.

## Example Report

The health check generates a self-contained HTML report with a centralized view of SQL Server health across the environment.

<img width="2528" height="1048" alt="SQLHTML-Output_1" src="https://github.com/user-attachments/assets/7ef0cf8d-1a7c-46ba-a08b-03cb3ffdc578" />

<img width="2496" height="1102" alt="SQLHTML-Output_2" src="https://github.com/user-attachments/assets/e2c7c23e-35b4-4c18-90b2-eb70db88e959" />
