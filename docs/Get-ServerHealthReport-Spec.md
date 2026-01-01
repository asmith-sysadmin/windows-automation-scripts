# Get-ServerHealthReport.ps1 — Script Specification

## Overview
`Get-ServerHealthReport.ps1` is a PowerShell monitoring script designed to collect
key health indicators from Windows systems and generate a structured health report.

The script is intended for system administrators and infrastructure engineers who
need a repeatable, auditable way to assess server health without relying on
external monitoring tools.

---

## Objectives
- Provide a quick health overview of Windows systems
- Identify common operational risks (disk, CPU, memory, services, events)
- Produce both human-readable and machine-readable outputs
- Operate safely across different environments with minimal assumptions

---

## Scope

### In Scope
- Local and remote Windows systems
- Core system health metrics
- Event log error/critical analysis
- Threshold-based health scoring

### Out of Scope
- Real-time monitoring
- Alerting or notifications
- Cloud-native monitoring integrations
- Deep application-specific checks

---

## Data Collected

### System Information
- Hostname
- Domain or workgroup
- Operating system name, version, build
- System uptime
- CPU model and core count
- Total physical memory

### Performance Snapshot
- CPU load percentage
- Memory used percentage
- Top processes by CPU and memory (local system only)

### Storage
- Local logical disks
- Disk size (GB)
- Free space (GB and %)

### Services
- Status of configurable “critical services”
- Detection of missing or stopped services

### Event Logs
- Error and Critical events from:
  - System log
  - Application log
- Configurable lookback window
- Sample events included for context

### Updates & Reboot State
- Most recently installed hotfix (best-effort)
- Pending reboot indicators (best-effort)

### Network (Best-Effort)
- IPv4 addresses (non-APIPA)
- Default gateway
- DNS servers

---

## Health Assessment Logic

Each system is evaluated using configurable thresholds.

### Health Score
- Starts at **100**
- Points are deducted when thresholds are exceeded
- Final score is clamped between **0–100**

### Health Status
| Status     | Meaning |
|------------|--------|
| OK         | No issues detected based on thresholds |
| WARN       | One or more thresholds exceeded |
| CRITICAL  | Critical service failures or high error volume |

### Threshold Categories
- Disk free percentage
- CPU load percentage
- Memory used percentage
- Error/Critical event volume
- Pending reboot state

---

## Inputs (Parameters)

Key parameters include:
- `ComputerName` — Target systems
- `OutputPath` — Location for reports and logs
- `EventLookbackHours` — Event log time window
- `CriticalServices` — Services to validate
- Threshold parameters for disk, CPU, memory, and events

All parameters are optional and have safe defaults.

---

## Outputs

The script produces the following artifacts:

### Reports
- HTML report for human review
- JSON report for automation or ingestion

### Logs
- Structured JSON log file
- Includes timestamps and run correlation ID

---

## Error Handling & Safety

- Failures are handled per target system
- Errors in one section do not stop the entire run
- Best-effort checks are clearly identified
- No credentials, domains, or environment-specific values are hardcoded

---

## Known Limitations

- Remote process lists are not collected by default
- Remote pending reboot detection is limited without additional remoting
- Event log access depends on permissions and system policy

These limitations are intentional to maintain portability and safety.

---

## Intended Audience
- System Administrators
- Infrastructure Engineers
- IT Operations teams
- Home lab and learning environments

---

## Future Enhancements
- Optional remote process collection
- Threshold customization via configuration file
- Health trend comparison across runs
- Optional alerting or export integrations
