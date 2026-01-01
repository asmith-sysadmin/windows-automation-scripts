## Script Spec: `Get-ServerHealthReport.ps1`

### Goal

Generate a **Windows Server Health Report** for one or more computers and export results to:

* **HTML** (human-friendly)
* **JSON** (automation-friendly)
* **Log file** (auditable execution trail)

### What it collects (per computer)

**System**

* Hostname, domain/workgroup, OS name/version/build
* Boot time, uptime
* CPU model + core count
* Physical memory total

**Performance snapshot**

* CPU load %
* Memory used %
* Top 5 processes by CPU
* Top 5 processes by Working Set (RAM)

**Disk**

* Local logical disks (Drive, Size GB, Free GB, Free %)

**Services**

* Status of “critical services” (configurable list)
* Detects missing services too

**Event Logs**

* Count + samples of recent **Error/Critical** events (last X hours) from:

  * System
  * Application

**Updates / Reboot**

* Last installed hotfix date (best-effort via `Get-HotFix`)
* “Pending reboot” indicators (best-effort registry checks)

**Network**

* IPv4 addresses (non-APIPA), default gateway, DNS servers

### Outputs

* `reports\<ComputerName>_HealthReport_<timestamp>.html`
* `reports\<ComputerName>_HealthReport_<timestamp>.json`
* `logs\Get-ServerHealthReport_<date>.log`

### Execution modes

* Local: default (`$env:COMPUTERNAME`)
* Remote: `-ComputerName server1,server2` using CIM (WinRM)
* Credential optional (`-Credential`) for remote access
* `-SkipEventLogs` and `-SkipHotfix` for restricted environments
* `-WhatIf` support for file writing steps

### Safety / Professional standards

* No secrets, no hardcoded domains/paths
* Errors handled per-computer so one failure doesn’t kill the run
* Logs include correlation ID per run
* JSON output is consistent schema (easy to parse)

---

## PowerShell Script Scaffold 

```powershell
<#
.SYNOPSIS
Generates a Windows Server Health Report (HTML + JSON) with structured logging.

.DESCRIPTION
Collects key health signals for one or more computers: OS/system info, uptime, CPU/memory snapshot,
disk utilization, critical services status, recent error/critical events, hotfix recency, pending reboot,
and basic network configuration. Exports a readable HTML report plus a machine-readable JSON artifact.

.PARAMETER ComputerName
One or more computer names. Defaults to the local computer.

.PARAMETER OutputPath
Root folder for report output. Creates subfolders: reports, logs.

.PARAMETER EventLookbackHours
How far back to scan event logs for Error/Critical entries.

.PARAMETER CriticalServices
List of service names to validate (e.g., 'W32Time','LanmanServer','WinRM').

.PARAMETER Credential
Optional credential for remote connections.

.PARAMETER SkipEventLogs
Skips event log collection (useful in locked-down environments).

.PARAMETER SkipHotfix
Skips hotfix collection (some systems restrict Get-HotFix).

.PARAMETER AsSingleReport
If specified, builds a single combined HTML/JSON report for all computers.

.EXAMPLE
.\Get-ServerHealthReport.ps1 -ComputerName SRV01,SRV02 -OutputPath .\out -EventLookbackHours 24

.NOTES
Author: Austin Smith
Repository: windows-automation-scripts
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [string[]] $ComputerName = @($env:COMPUTERNAME),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath "output"),

    [Parameter()]
    [ValidateRange(1, 720)]
    [int] $EventLookbackHours = 24,

    [Parameter()]
    [string[]] $CriticalServices = @(
        "W32Time",       # Windows Time
        "LanmanServer",  # Server
        "WinRM",         # Windows Remote Management
        "EventLog"       # Windows Event Log
    ),

    [Parameter()]
    [System.Management.Automation.PSCredential] $Credential,

    [switch] $SkipEventLogs,
    [switch] $SkipHotfix,
    [switch] $AsSingleReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Globals / Paths / Run Metadata
# -----------------------------
$RunId = [guid]::NewGuid().ToString()
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$ReportsPath = Join-Path $OutputPath "reports"
$LogsPath    = Join-Path $OutputPath "logs"

function Initialize-OutputFolders {
    foreach ($p in @($OutputPath, $ReportsPath, $LogsPath)) {
        if (-not (Test-Path $p)) {
            if ($PSCmdlet.ShouldProcess($p, "Create directory")) {
                New-Item -Path $p -ItemType Directory -Force | Out-Null
            }
        }
    }
}

$LogFile = Join-Path $LogsPath ("Get-ServerHealthReport_{0}.log" -f (Get-Date -Format "yyyyMMdd"))

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet("INFO","WARN","ERROR","DEBUG")]
        [string] $Level,
        [Parameter(Mandatory)]
        [string] $Message,
        [string] $Computer = "",
        [hashtable] $Data
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        runId     = $RunId
        level     = $Level
        computer  = $Computer
        message   = $Message
        data      = $Data
    } | ConvertTo-Json -Depth 6 -Compress

    Add-Content -Path $LogFile -Value $entry
}

function New-CimSessionSafe {
    param(
        [Parameter(Mandatory)][string] $Target
    )

    try {
        $opts = New-CimSessionOption -Protocol Wsman
        if ($PSBoundParameters.ContainsKey("Credential")) {
            return New-CimSession -ComputerName $Target -Credential $Credential -SessionOption $opts
        }
        return New-CimSession -ComputerName $Target -SessionOption $opts
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to create CIM session." -Computer $Target -Data @{ error = $_.Exception.Message }
        return $null
    }
}

function Get-PendingRebootStatus {
    param(
        [Parameter(Mandatory)][string] $Target,
        [Microsoft.Management.Infrastructure.CimSession] $CimSession
    )

    # Best-effort checks; return booleans plus details
    $result = [ordered]@{
        pendingReboot = $false
        indicators    = @()
    }

    try {
        # Registry paths commonly used to indicate reboot required
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
            "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
        )

        foreach ($path in $paths) {
            try {
                if ($Target -eq $env:COMPUTERNAME) {
                    if (Test-Path $path) {
                        $result.pendingReboot = $true
                        $result.indicators += $path
                    }
                }
                else {
                    # Remote registry read via CIM is non-trivial without extra dependencies;
                    # We do a best-effort WMI/CIM based check for pending rename operations.
                    # For enterprise, you might extend this via Invoke-Command or Remote Registry service.
                    if ($path -like "*PendingFileRenameOperations") {
                        $os = Get-CimInstance -ClassName Win32_OperatingSystem -CimSession $CimSession
                        # Placeholder indicator: if uptime is very long + patch recency suggests pending reboot, flag in summary.
                        # Keep conservative; do not assert pending reboot without a signal.
                    }
                }
            } catch { }
        }
    }
    catch {
        Write-Log -Level "WARN" -Message "Pending reboot check encountered an issue (best-effort)." -Computer $Target -Data @{ error = $_.Exception.Message }
    }

    return $result
}

function Get-EventLogSummary {
    param(
        [Parameter(Mandatory)][string] $Target,
        [int] $LookbackHours,
        [Microsoft.Management.Infrastructure.CimSession] $CimSession
    )

    $since = (Get-Date).AddHours(-1 * $LookbackHours)

    $logs = @("System","Application")
    $out = @()

    foreach ($logName in $logs) {
        try {
            # Get-WinEvent remote supports -ComputerName, but credentials are tricky;
            # We'll use it for local OR remote without creds requirement. If creds are required, user can run under context or extend with Invoke-Command.
            $filter = @{
                LogName   = $logName
                Level     = 1,2 # Critical=1, Error=2
                StartTime = $since
            }

            $events = if ($Target -eq $env:COMPUTERNAME) {
                Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
            } else {
                Get-WinEvent -ComputerName $Target -FilterHashtable $filter -ErrorAction Stop
            }

            $sample = $events | Select-Object -First 10 | ForEach-Object {
                [ordered]@{
                    timeCreated = $_.TimeCreated
                    id          = $_.Id
                    provider    = $_.ProviderName
                    level       = $_.LevelDisplayName
                    message     = ($_.Message -replace "\r?\n"," " ) -replace "\s{2,}"," "
                }
            }

            $out += [ordered]@{
                logName      = $logName
                since        = $since
                totalCount   = ($events | Measure-Object).Count
                sampleEvents = $sample
            }
        }
        catch {
            Write-Log -Level "WARN" -Message "Failed to query event log $logName." -Computer $Target -Data @{ error = $_.Exception.Message }
            $out += [ordered]@{
                logName      = $logName
                since        = $since
                totalCount   = $null
                sampleEvents = @()
                error        = $_.Exception.Message
            }
        }
    }

    return $out
}

function Get-HealthData {
    param(
        [Parameter(Mandatory)][string] $Target
    )

    Write-Log -Level "INFO" -Message "Collecting health data." -Computer $Target

    $cim = $null
    if ($Target -ne $env:COMPUTERNAME) {
        $cim = New-CimSessionSafe -Target $Target
        if (-not $cim) {
            return [ordered]@{
                computerName = $Target
                status       = "Unreachable"
                error        = "Failed to establish CIM session"
                collectedAt  = (Get-Date).ToString("o")
            }
        }
    }

    try {
        # --- System / OS
        $os = if ($cim) { Get-CimInstance -ClassName Win32_OperatingSystem -CimSession $cim } else { Get-CimInstance -ClassName Win32_OperatingSystem }
        $cs = if ($cim) { Get-CimInstance -ClassName Win32_ComputerSystem -CimSession $cim } else { Get-CimInstance -ClassName Win32_ComputerSystem }
        $cpu = if ($cim) { Get-CimInstance -ClassName Win32_Processor -CimSession $cim } else { Get-CimInstance -ClassName Win32_Processor }

        $boot = [Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)
        $uptime = (Get-Date) - $boot

        # --- Performance snapshot
        $cpuLoad = [math]::Round(($cpu | Measure-Object -Property LoadPercentage -Average).Average, 1)
        $memTotalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        $memFreeGB  = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 2)
        $memUsedPct = if ($memTotalGB -gt 0) { [math]::Round((($memTotalGB - $memFreeGB) / $memTotalGB) * 100, 1) } else { $null }

        # Processes (local only via Get-Process; for remote, skip or extend using Invoke-Command)
        $topProcCpu = @()
        $topProcMem = @()
        try {
            if ($Target -eq $env:COMPUTERNAME) {
                $topProcCpu = Get-Process | Sort-Object -Property CPU -Descending | Select-Object -First 5 Name, Id, CPU
                $topProcMem = Get-Process | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 5 Name, Id, @{n="WorkingSetMB";e={[math]::Round($_.WorkingSet64/1MB,1)}}
            }
        } catch {
            Write-Log -Level "WARN" -Message "Process snapshot failed (non-fatal)." -Computer $Target -Data @{ error = $_.Exception.Message }
        }

        # --- Disks
        $disks = if ($cim) {
            Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -CimSession $cim
        } else {
            Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"
        }

        $diskOut = $disks | ForEach-Object {
            $sizeGB = if ($_.Size) { [math]::Round($_.Size/1GB,2) } else { $null }
            $freeGB = if ($_.FreeSpace) { [math]::Round($_.FreeSpace/1GB,2) } else { $null }
            $freePct = if ($_.Size -and $_.FreeSpace) { [math]::Round(($_.FreeSpace/$_.Size)*100,1) } else { $null }

            [ordered]@{
                drive   = $_.DeviceID
                label   = $_.VolumeName
                sizeGB  = $sizeGB
                freeGB  = $freeGB
                freePct = $freePct
            }
        }

        # --- Services
        $svcData = @()
        foreach ($svc in $CriticalServices) {
            try {
                $s = if ($cim) {
                    Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $svc) -CimSession $cim
                } else {
                    Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $svc)
                }

                if ($null -eq $s) {
                    $svcData += [ordered]@{ name=$svc; status="Missing"; startMode=$null }
                } else {
                    $svcData += [ordered]@{ name=$s.Name; status=$s.State; startMode=$s.StartMode }
                }
            }
            catch {
                $svcData += [ordered]@{ name=$svc; status="Unknown"; startMode=$null; error=$_.Exception.Message }
            }
        }

        # --- Event logs
        $eventSummary = @()
        if (-not $SkipEventLogs) {
            $eventSummary = Get-EventLogSummary -Target $Target -LookbackHours $EventLookbackHours -CimSession $cim
        }

        # --- Hotfix
        $hotfix = $null
        if (-not $SkipHotfix) {
            try {
                $hf = if ($Target -eq $env:COMPUTERNAME) {
                    Get-HotFix | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
                } else {
                    # Get-HotFix supports -ComputerName but can be slow; keep best-effort
                    Get-HotFix -ComputerName $Target | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
                }
                if ($hf) {
                    $hotfix = [ordered]@{
                        hotfixId    = $hf.HotFixID
                        installedOn = $hf.InstalledOn
                        description = $hf.Description
                    }
                }
            } catch {
                Write-Log -Level "WARN" -Message "Hotfix query failed (best-effort)." -Computer $Target -Data @{ error = $_.Exception.Message }
            }
        }

        # --- Pending reboot
        $reboot = Get-PendingRebootStatus -Target $Target -CimSession $cim

        # --- Network (best-effort)
        $net = [ordered]@{
            ipv4        = @()
            gateway     = @()
            dnsServers  = @()
        }

        try {
            if ($Target -eq $env:COMPUTERNAME) {
                $adapters = Get-NetIPConfiguration | Where-Object { $_.IPv4Address -and $_.NetAdapter.Status -eq "Up" }
                $net.ipv4 = $adapters.IPv4Address.IPAddress | Where-Object { $_ -and ($_ -notlike "169.254*") }
                $net.gateway = $adapters.IPv4DefaultGateway.NextHop | Where-Object { $_ }
                $net.dnsServers = $adapters.DnsServer.ServerAddresses | Where-Object { $_ }
            }
        } catch {
            Write-Log -Level "WARN" -Message "Network query failed (non-fatal)." -Computer $Target -Data @{ error = $_.Exception.Message }
        }

        $result = [ordered]@{
            computerName = $Target
            status       = "OK"
            collectedAt  = (Get-Date).ToString("o")

            system = [ordered]@{
                hostname    = $cs.Name
                domain      = $cs.Domain
                osCaption   = $os.Caption
                osVersion   = $os.Version
                osBuild     = $os.BuildNumber
                manufacturer= $cs.Manufacturer
                model       = $cs.Model
                cpuName     = ($cpu | Select-Object -First 1 -ExpandProperty Name)
                cpuCores    = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
                memoryGB    = $memTotalGB
                lastBoot    = $boot
                uptime      = $uptime.ToString()
            }

            snapshot = [ordered]@{
                cpuLoadPct   = $cpuLoad
                memoryUsedPct= $memUsedPct
                topProcCpu   = $topProcCpu
                topProcMem   = $topProcMem
            }

            disks     = $diskOut
            services  = $svcData
            events    = $eventSummary
            hotfix    = $hotfix
            reboot    = $reboot
            network   = $net
        }

        return $result
    }
    catch {
        Write-Log -Level "ERROR" -Message "Health data collection failed." -Computer $Target -Data @{ error = $_.Exception.Message }
        return [ordered]@{
            computerName = $Target
            status       = "Error"
            error        = $_.Exception.Message
            collectedAt  = (Get-Date).ToString("o")
        }
    }
    finally {
        if ($cim) { $cim | Remove-CimSession -ErrorAction SilentlyContinue }
    }
}

function ConvertTo-HtmlReport {
    param(
        [Parameter(Mandatory)] $HealthObjects,
        [Parameter(Mandatory)] [string] $Title
    )

    # Lightweight, resume-safe embedded CSS (no external calls)
    $style = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; }
h1 { margin-bottom: 4px; }
.small { color: #666; margin-top: 0px; }
.card { border: 1px solid #ddd; border-radius: 8px; padding: 14px; margin: 14px 0; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #e5e5e5; padding: 8px; font-size: 12px; vertical-align: top; }
th { background: #f7f7f7; text-align: left; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; border: 1px solid #ddd; }
.ok { background: #eef7ee; }
.warn { background: #fff6e5; }
.err { background: #fdecec; }
</style>
"@

    $generated = (Get-Date).ToString("o")
    $header = "<h1>$Title</h1><p class='small'>Generated: $generated | RunId: $RunId</p>"

    $cards = foreach ($h in $HealthObjects) {
        $statusClass = if ($h.status -eq "OK") { "ok" } elseif ($h.status -eq "Unreachable") { "warn" } else { "err" }

        $diskRows = ($h.disks | ForEach-Object {
            "<tr><td>$($_.drive)</td><td>$($_.label)</td><td>$($_.sizeGB)</td><td>$($_.freeGB)</td><td>$($_.freePct)</td></tr>"
        }) -join ""

        $svcRows = ($h.services | ForEach-Object {
            "<tr><td>$($_.name)</td><td>$($_.status)</td><td>$($_.startMode)</td><td>$($_.error)</td></tr>"
        }) -join ""

        $eventRows = ""
        foreach ($log in ($h.events | ForEach-Object { $_ })) {
            $eventRows += "<h4>$($log.logName) (Errors/Critical since $($log.since))</h4>"
            $eventRows += "<p>Total: $($log.totalCount)</p>"
            if ($log.sampleEvents -and $log.sampleEvents.Count -gt 0) {
                $eventRows += "<table><thead><tr><th>Time</th><th>Provider</th><th>ID</th><th>Level</th><th>Message (sample)</th></tr></thead><tbody>"
                $eventRows += (($log.sampleEvents | ForEach-Object {
                    "<tr><td>$($_.timeCreated)</td><td>$($_.provider)</td><td>$($_.id)</td><td>$($_.level)</td><td>$($_.message)</td></tr>"
                }) -join "")
                $eventRows += "</tbody></table>"
            } else {
                $eventRows += "<p class='small'>No sample events returned (or collection skipped/failed).</p>"
            }
        }

        @"
<div class='card'>
  <div class='grid'>
    <div>
      <h2>$($h.computerName) <span class='badge $statusClass'>$($h.status)</span></h2>
      <p class='small'>Collected: $($h.collectedAt)</p>
      <table>
        <thead><tr><th colspan='2'>System</th></tr></thead>
        <tbody>
          <tr><td>OS</td><td>$($h.system.osCaption) ($($h.system.osVersion) build $($h.system.osBuild))</td></tr>
          <tr><td>Domain</td><td>$($h.system.domain)</td></tr>
          <tr><td>Model</td><td>$($h.system.manufacturer) $($h.system.model)</td></tr>
          <tr><td>CPU</td><td>$($h.system.cpuName) (Cores: $($h.system.cpuCores))</td></tr>
          <tr><td>Memory (GB)</td><td>$($h.system.memoryGB)</td></tr>
          <tr><td>Last Boot</td><td>$($h.system.lastBoot)</td></tr>
          <tr><td>Uptime</td><td>$($h.system.uptime)</td></tr>
        </tbody>
      </table>
    </div>
    <div>
      <table>
        <thead><tr><th colspan='2'>Snapshot</th></tr></thead>
        <tbody>
          <tr><td>CPU Load %</td><td>$($h.snapshot.cpuLoadPct)</td></tr>
          <tr><td>Memory Used %</td><td>$($h.snapshot.memoryUsedPct)</td></tr>
          <tr><td>Pending Reboot</td><td>$($h.reboot.pendingReboot) $($h.reboot.indicators -join ', ')</td></tr>
          <tr><td>Last Hotfix</td><td>$($h.hotfix.hotfixId) $($h.hotfix.installedOn)</td></tr>
          <tr><td>IPv4</td><td>$($h.network.ipv4 -join ', ')</td></tr>
          <tr><td>Gateway</td><td>$($h.network.gateway -join ', ')</td></tr>
          <tr><td>DNS</td><td>$($h.network.dnsServers -join ', ')</td></tr>
        </tbody>
      </table>

      <h3>Disks</h3>
      <table>
        <thead><tr><th>Drive</th><th>Label</th><th>SizeGB</th><th>FreeGB</th><th>Free%</th></tr></thead>
        <tbody>$diskRows</tbody>
      </table>

      <h3>Critical Services</h3>
      <table>
        <thead><tr><th>Name</th><th>Status</th><th>StartMode</th><th>Error</th></tr></thead>
        <tbody>$svcRows</tbody>
      </table>
    </div>
  </div>

  <h3>Recent Events</h3>
  $eventRows
</div>
"@
    }

    $html = @"
<html>
<head>
<meta charset='utf-8' />
$style
</head>
<body>
$header
$($cards -join "`n")
</body>
</html>
"@

    return $html
}

# -----------------------------
# Main
# -----------------------------
Initialize-OutputFolders
Write-Log -Level "INFO" -Message "Run started." -Data @{ computerCount = $ComputerName.Count; outputPath = $OutputPath; eventLookbackHours = $EventLookbackHours }

$all = @()
foreach ($c in $ComputerName) {
    $all += Get-HealthData -Target $c
}

if ($AsSingleReport) {
    $baseName = "HealthReport_All_{0}" -f $Timestamp
    $jsonPath = Join-Path $ReportsPath ($baseName + ".json")
    $htmlPath = Join-Path $ReportsPath ($baseName + ".html")

    $json = $all | ConvertTo-Json -Depth 8
    $html = ConvertTo-HtmlReport -HealthObjects $all -Title "Server Health Report (All Targets)"

    if ($PSCmdlet.ShouldProcess($jsonPath, "Write JSON report")) { $json | Out-File -FilePath $jsonPath -Encoding utf8 }
    if ($PSCmdlet.ShouldProcess($htmlPath, "Write HTML report")) { $html | Out-File -FilePath $htmlPath -Encoding utf8 }

    Write-Log -Level "INFO" -Message "Reports written." -Data @{ html = $htmlPath; json = $jsonPath }
    Write-Output "HTML: $htmlPath"
    Write-Output "JSON: $jsonPath"
}
else {
    foreach ($h in $all) {
        $safeName = ($h.computerName -replace '[^a-zA-Z0-9\-_\.]','_')
        $baseName = "{0}_HealthReport_{1}" -f $safeName, $Timestamp

        $jsonPath = Join-Path $ReportsPath ($baseName + ".json")
        $htmlPath = Join-Path $ReportsPath ($baseName + ".html")

        $json = $h | ConvertTo-Json -Depth 8
        $html = ConvertTo-HtmlReport -HealthObjects @($h) -Title ("Server Health Report: {0}" -f $h.computerName)

        if ($PSCmdlet.ShouldProcess($jsonPath, "Write JSON report")) { $json | Out-File -FilePath $jsonPath -Encoding utf8 }
        if ($PSCmdlet.ShouldProcess($htmlPath, "Write HTML report")) { $html | Out-File -FilePath $htmlPath -Encoding utf8 }

        Write-Log -Level "INFO" -Message "Report written." -Computer $h.computerName -Data @{ html = $htmlPath; json = $jsonPath; status = $h.status }
        Write-Output "[$($h.computerName)] HTML: $htmlPath"
        Write-Output "[$($h.computerName)] JSON: $jsonPath"
    }
}

Write-Log -Level "INFO" -Message "Run completed."
```

---

## Notes 
Structured JSON logs (easy to ship to Splunk/ELK later)
Separate HTML + JSON outputs (ops + automation use-cases)
Per-host fault tolerance (one bad server doesn’t break the run)
No hardcoding (domain/path/credentials)
Extensible (you can add thresholds + “overall health score” next)
