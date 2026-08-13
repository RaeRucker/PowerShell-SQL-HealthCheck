# Universal SQL Server Health Check

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

## Quick start

1. Clone the repository, or download and extract the ZIP, onto a Windows system that can reach the target SQL Server instances.

2. Open PowerShell and change into the repository directory:

```powershell
cd .\PowerShell-SQL-HealthCheck
```

3. Create your local configuration files from the included examples:

```powershell
Copy-Item .\config.example.json .\config.json
Copy-Item .\serverlist.example.txt .\serverlist.txt
```

4. Edit `config.json` and `serverlist.txt` with the settings and SQL Server instances for your environment.

5. Run the health check:

> **Note:** PowerShell may ask for permission to run the scripts. If you trust this repository, select **A (Yes to All)** to continue.

```powershell
.\Run-SqlHealthCheck.ps1
```


The first run attempts to create a local `SQLBuildReference.json` cache from Microsoft Learn. Generated reports are written to the configured output directory.

## Optional SQL discovery

The discovery helper can combine SQL SPNs, Active Directory server enumeration, remote Windows service inspection, and SQL Browser discovery:

```powershell
.\Find-SqlInstances.ps1
```

Remote service discovery requires the Active Directory PowerShell module and sufficient rights/network access to query remote servers. It can be noisy in a large domain, so review the script and use the skip switches when appropriate:

```powershell
.\Find-SqlInstances.ps1 -SkipActiveDirectoryServiceScan
```

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
