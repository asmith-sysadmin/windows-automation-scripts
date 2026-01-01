<#
.SYNOPSIS
Audits Windows patch compliance and pending reboot state. Exports HTML + JSON and structured logs.

.DESCRIPTION
Checks patch recency (based on most recent hotfix install date), pending reboot indicators,
and (optionally) basic Windows Update configuration. Produces a compliance status + score.

.PARAMETER ComputerName
One or more computer names. Defaults to local computer.

.PARAMETER OutputPath
Root output folder. Creates subfolders: reports, logs.

.PARAMETER MaxPatchAgeDays
Maximum allowed age (in days) since last installed update/hotfix before marked non-compliant.

.PARAMETER WarnPatchAgeDays
If patch age exceeds this (but not MaxPatchAgeDays), mark as WARN (grace band).

.PARAMETER SkipHotfix
Skips Get-HotFix checks (some systems restrict it).

.PARAMETER SkipWUConfig
Skips Windows Update configuration checks (best-effort).

.PARAMETER Credential
Optional credential for remote CIM connection.

.PARAMETER AsSingleReport
If specified, builds one combined report for all targets.

.EXAMPLE
.\Invoke-PatchComplianceAudit.ps1 -ComputerName SRV01,SRV02 -MaxPatchAgeDays 30

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
    [ValidateRange(1, 3650)]
    [int] $MaxPatchAgeDays = 30,

    [Parameter()]
    [ValidateRange(0, 3650)]
    [int] $WarnPatchAgeDays = 21,

    [Parameter()]
    [ValidateRange(0, 200)]
    [int] $RecentHotfixCount = 5,

    [Parameter()]
    [System.Management.Automation.PSCredential] $Credential,

    [switch] $SkipHotfix,
    [switch] $SkipWUConfig,
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

$LogFile = Join-Path $LogsPath ("Invoke-PatchComplianceAudit_{0}.log" -f (Get-Date -Format "yyyyMMdd"))

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
    } | ConvertTo-Json -Depth 10 -Compress

    Add-Content -Path $LogFile -Value $entry
}

function New-CimSessionSafe {
    param([Parameter(Mandatory)][string] $Target)

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

function Get-PendingRebootLocal {
    # Strong local checks via registry
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )

    $pending = $false
    $hits = @()

    foreach ($p in $paths) {
        if (Test-Path $p) { $pending = $true; $hits += $p }
    }

    # PendingFileRenameOperations (value)
    try {
        $v = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction Stop
        if ($null -ne $v.PendingFileRenameOperations) { $pending = $true; $hits += "HKLM:\\...\\Session Manager\\PendingFileRenameOperations" }
    } catch { }

    return [ordered]@{
        pendingReboot = $pending
        indicators    = $hits
        method        = "LocalRegistry"
    }
}

function Get-PendingRebootStatus {
    param(
        [Parameter(Mandatory)][string] $Target
    )

    if ($Target -eq $env:COMPUTERNAME) {
        return Get-PendingRebootLocal
    }

    # Resume-safe remote behavior: don't assert pending reboot without a proven remote method.
    # Mark as "Unknown" with a note so the audit is honest.
    return [ordered]@{
        pendingReboot = $null
        indicators    = @()
        method        = "RemoteBestEffort"
        note          = "Remote pending reboot detection is best-effort. Extend via Invoke-Command if permitted."
    }
}

function Get-HotfixData {
    param(
        [Parameter(Mandatory)][string] $Target,
        [int] $RecentCount
    )

    if ($SkipHotfix) {
        return [ordered]@{ lastInstalledOn=$null; lastHotfixId=$null; recent=@(); note="Skipped via -SkipHotfix" }
    }

    try {
        $hotfixes = if ($Target -eq $env:COMPUTERNAME) {
            Get-HotFix | Sort-Object InstalledOn -Descending
        } else {
            Get-HotFix -ComputerName $Target | Sort-Object InstalledOn -Descending
        }

        $last = $hotfixes | Select-Object -First 1
        $recent = $hotfixes | Select-Object -First $RecentCount | ForEach-Object {
            [ordered]@{
                hotfixId    = $_.HotFixID
                installedOn = $_.InstalledOn
                description = $_.Description
            }
        }

        return [ordered]@{
            lastInstalledOn = $last.InstalledOn
            lastHotfixId    = $last.HotFixID
            recent          = $recent
        }
    }
    catch {
        Write-Log -Level "WARN" -Message "Hotfix query failed (best-effort)." -Computer $Target -Data @{ error = $_.Exception.Message }
        return [ordered]@{
            lastInstalledOn = $null
            lastHotfixId    = $null
            recent          = @()
            error           = $_.Exception.Message
        }
    }
}

function Get-WindowsUpdateConfigLocal {
    if ($SkipWUConfig) {
        return [ordered]@{ auOptions=$null; note="Skipped via -SkipWUConfig" }
    }

    # AUOptions may exist in different places; keep best-effort and honest
    try {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update"
        $au = $null
        if (Test-Path $key) {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($null -ne $p.AUOptions) { $au = [int]$p.AUOptions }
        }

        $meaning = switch ($au) {
            2 { "Notify for download and install" }
            3 { "Auto download and notify for install" }
            4 { "Auto download and schedule install" }
            5 { "Allow local admin to choose setting" }
            default { $null }
        }

        return [ordered]@{
            auOptions = $au
            meaning   = $meaning
            method    = "LocalRegistry"
        }
    }
    catch {
        Write-Log -Level "WARN" -Message "Windows Update config read failed (best-effort)." -Data @{ error = $_.Exception.Message }
        return [ordered]@{ auOptions=$null; error=$_.Exception.Message }
    }
}

function Get-ComplianceAssessment {
    param(
        [Parameter(Mandatory)] $AuditObject,
        [Parameter(Mandatory)][int] $MaxPatchAgeDays,
        [Parameter(Mandatory)][int] $WarnPatchAgeDays
    )

    $score = 100
    $findings = New-Object System.Collections.Generic.List[string]
    $status = "PASS"

    function Set-Status([string]$NewStatus) {
        $rank = @{ "PASS" = 0; "WARN" = 1; "FAIL" = 2 }
        if ($rank[$NewStatus] -gt $rank[$status]) { $status = $NewStatus }
    }

    # Patch age
    $patchAgeDays = $null
    if ($AuditObject.updates.lastInstalledOn) {
        $patchAgeDays = [int]((Get-Date) - ([datetime]$AuditObject.updates.lastInstalledOn)).TotalDays

        if ($patchAgeDays -gt $MaxPatchAgeDays) {
            $score -= 50
            $findings.Add(("Patch age is {0} days (> {1})" -f $patchAgeDays, $MaxPatchAgeDays))
            Set-Status "FAIL"
        }
        elseif ($patchAgeDays -gt $WarnPatchAgeDays) {
            $score -= 20
            $findings.Add(("Patch age is {0} days (> {1})" -f $patchAgeDays, $WarnPatchAgeDays))
            Set-Status "WARN"
        }
    } else {
        $score -= 15
        $findings.Add("Unable to determine last installed update date (best-effort).")
        Set-Status "WARN"
    }

    # Pending reboot
    if ($AuditObject.reboot.pendingReboot -eq $true) {
        $score -= 40
        $findings.Add("Pending reboot detected")
        Set-Status "FAIL"
    }
    elseif ($AuditObject.reboot.pendingReboot -eq $null) {
        $score -= 10
        $findings.Add("Pending reboot state unknown for remote target (best-effort).")
        Set-Status "WARN"
    }

    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }

    return [ordered]@{
        status      = $status
        score       = $score
        patchAgeDays= $patchAgeDays
        findings    = $findings
        thresholds  = [ordered]@{
            maxPatchAgeDays  = $MaxPatchAgeDays
            warnPatchAgeDays = $WarnPatchAgeDays
        }
    }
}

function ConvertTo-HtmlReport {
    param(
        [Parameter(Mandatory)] $AuditObjects,
        [Parameter(Mandatory)][string] $Title
    )

    $style = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; }
.small { color: #666; }
.card { border: 1px solid #ddd; border-radius: 10px; padding: 14px; margin: 14px 0; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #e5e5e5; padding: 8px; font-size: 12px; vertical-align: top; }
th { background: #f7f7f7; text-align: left; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; border: 1px solid #ddd; }
.pass { background: #eef7ee; }
.warn { background: #fff6e5; }
.fail { background: #fdecec; }
</style>
"@

    $generated = (Get-Date).ToString("o")
    $header = "<h1>$Title</h1><p class='small'>Generated: $generated | RunId: $RunId</p>"

    $cards = foreach ($a in $AuditObjects) {
        $cls = switch ($a.assessment.status) { "PASS" { "pass" } "WARN" { "warn" } default { "fail" } }
        $findings = if ($a.assessment.findings.Count -gt 0) { ($a.assessment.findings -join "<br/>") } else { "No issues detected." }

@"
<div class='card'>
  <h2>$($a.computerName) <span class='badge $cls'>$($a.assessment.status)</span></h2>
  <p class='small'>Collected: $($a.collectedAt)</p>

  <table>
    <thead><tr><th colspan='2'>Compliance</th></tr></thead>
    <tbody>
      <tr><td>Score</td><td><b>$($a.assessment.score)</b> / 100</td></tr>
      <tr><td>Patch Age (Days)</td><td>$($a.assessment.patchAgeDays)</td></tr>
      <tr><td>Pending Reboot</td><td>$($a.reboot.pendingReboot)</td></tr>
      <tr><td>Last Hotfix</td><td>$($a.updates.lastHotfixId) $($a.updates.lastInstalledOn)</td></tr>
      <tr><td>Thresholds</td><td>Warn &gt; $($a.assessment.thresholds.warnPatchAgeDays) days | Fail &gt; $($a.assessment.thresholds.maxPatchAgeDays) days</td></tr>
      <tr><td>Findings</td><td>$findings</td></tr>
    </tbody>
  </table>
</div>
"@
    }

    return @"
<html>
<head><meta charset='utf-8' />$style</head>
<body>
$header
$($cards -join "`n")
</body>
</html>
"@
}

# -----------------------------
# Main
# -----------------------------
Initialize-OutputFolders
Write-Log -Level "INFO" -Message "Run started." -Data @{
    computerCount = $ComputerName.Count
    outputPath = $OutputPath
    maxPatchAgeDays = $MaxPatchAgeDays
    warnPatchAgeDays = $WarnPatchAgeDays
    recentHotfixCount = $RecentHotfixCount
    skipHotfix = [bool]$SkipHotfix
    skipWUConfig = [bool]$SkipWUConfig
}

$all = @()
foreach ($c in $ComputerName) {
    Write-Log -Level "INFO" -Message "Collecting compliance data." -Computer $c

    $audit = [ordered]@{
        computerName = $c
        collectedAt  = (Get-Date).ToString("o")
        updates      = Get-HotfixData -Target $c -RecentCount $RecentHotfixCount
        reboot       = Get-PendingRebootStatus -Target $c
        wuConfig     = if ($c -eq $env:COMPUTERNAME) { Get-WindowsUpdateConfigLocal } else { [ordered]@{ note="WU config collection is local-only by default." } }
    }

    $audit.assessment = Get-ComplianceAssessment -AuditObject $audit -MaxPatchAgeDays $MaxPatchAgeDays -WarnPatchAgeDays $WarnPatchAgeDays
    $audit.status = $audit.assessment.status

    $all += $audit
}

if ($AsSingleReport) {
    $baseName = "PatchCompliance_All_{0}" -f $Timestamp
    $jsonPath = Join-Path $ReportsPath ($baseName + ".json")
    $htmlPath = Join-Path $ReportsPath ($baseName + ".html")

    $json = $all | ConvertTo-Json -Depth 10
    $html = ConvertTo-HtmlReport -AuditObjects $all -Title "Patch Compliance Audit (All Targets)"

    if ($PSCmdlet.ShouldProcess($jsonPath, "Write JSON report")) { $json | Out-File -FilePath $jsonPath -Encoding utf8 }
    if ($PSCmdlet.ShouldProcess($htmlPath, "Write HTML report")) { $html | Out-File -FilePath $htmlPath -Encoding utf8 }

    Write-Log -Level "INFO" -Message "Reports written." -Data @{ html=$htmlPath; json=$jsonPath }
    Write-Output "HTML: $htmlPath"
    Write-Output "JSON: $jsonPath"
}
else {
    foreach ($a in $all) {
        $safeName = ($a.computerName -replace '[^a-zA-Z0-9\-_\.]','_')
        $baseName = "{0}_PatchCompliance_{1}" -f $safeName, $Timestamp

        $jsonPath = Join-Path $ReportsPath ($baseName + ".json")
        $htmlPath = Join-Path $ReportsPath ($baseName + ".html")

        $json = $a | ConvertTo-Json -Depth 10
        $html = ConvertTo-HtmlReport -AuditObjects @($a) -Title ("Patch Compliance Audit: {0}" -f $a.computerName)

        if ($PSCmdlet.ShouldProcess($jsonPath, "Write JSON report")) { $json | Out-File -FilePath $jsonPath -Encoding utf8 }
        if ($PSCmdlet.ShouldProcess($htmlPath, "Write HTML report")) { $html | Out-File -FilePath $htmlPath -Encoding utf8 }

        Write-Log -Level "INFO" -Message "Report written." -Computer $a.computerName -Data @{ html=$htmlPath; json=$jsonPath; status=$a.status; score=$a.assessment.score }

        Write-Output "[$($a.computerName)] Status: $($a.status) | Score: $($a.assessment.score) | PatchAgeDays: $($a.assessment.patchAgeDays)"
        Write-Output "[$($a.computerName)] HTML: $htmlPath"
        Write-Output "[$($a.computerName)] JSON: $jsonPath"
    }
}

Write-Log -Level "INFO" -Message "Run completed."

