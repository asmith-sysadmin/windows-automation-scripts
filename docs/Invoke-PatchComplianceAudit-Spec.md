# Invoke-PatchComplianceAudit.ps1 — Script Specification

## Overview
`Invoke-PatchComplianceAudit.ps1` audits Windows patch compliance and produces a clear compliance status and score.
It is designed to be portable, parameter-driven, and safe for lab or enterprise environments.

---

## Objectives
- Determine patch compliance based on installed update recency
- Detect (or honestly report inability to detect) pending reboot state
- Provide human-readable and machine-readable reporting
- Produce structured logs suitable for later ingestion

---

## Scope

### In Scope
- Local and remote Windows targets (best-effort for remote checks)
- Patch recency check (based on most recent installed hotfix/update)
- Pending reboot check (strong local, best-effort remote)
- Optional Windows Update configuration inspection (best-effort local)

### Out of Scope
- Installing updates / remediating patch state
- Real-time monitoring or alerting
- WSUS / SCCM deep configuration analysis
- Application-specific patch validation

---

## Data Collected (Per Target)

### Updates
- Most recent hotfix/update ID
- Most recent installed date
- Most recent N hotfixes (optional)

### Reboot State
- Pending reboot indicators (local registry checks)
- Remote pending reboot is marked as best-effort/unknown unless extended

### Windows Update Configuration (Best-Effort)
- AUOptions (if available) to indicate update behavior
- Local-only by default

---

## Compliance Logic

### Inputs
- `WarnPatchAgeDays` (default 21)
- `MaxPatchAgeDays` (default 30)

### Health Score (0–100)
- Starts at 100
- Deductions applied for:
  - Patch age exceeding warning/fail thresholds
  - Pending reboot detected
  - Unknown/failed best-effort checks (small penalty)

### Compliance Status
| Status | Meaning |
|--------|--------|
| PASS   | Patch age within limits and no pending reboot |
| WARN   | Patch age is approaching limit or partial data |
| FAIL   | Patch age exceeds maximum OR pending reboot detected |

---

## Outputs
- HTML report (human-friendly)
- JSON report (automation-friendly)
- Structured JSON log file (auditable trail)

Default output paths:
- `output/reports/<ComputerName>_PatchCompliance_<timestamp>.html`
- `output/reports/<ComputerName>_PatchCompliance_<timestamp>.json`
- `output/logs/Invoke-PatchComplianceAudit_<date>.log`

---

## Error Handling & Safety
- Per-target fault tolerance (one system failure does not stop the run)
- No hardcoded domains, credentials, or environment-specific values
- Best-effort areas are explicitly labeled to avoid false claims

---

## Known Limitations
- Remote pending reboot detection is not asserted by default (marked unknown)
- Windows Update configuration collection is local-only by default
- Hotfix queries may be slow/restricted in some environments

---

## Future Enhancements
- Optional remote pending reboot detection via `Invoke-Command` (if permitted)
- Optional WSUS policy inspection
- Export formats for centralized reporting and trend analysis
