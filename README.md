# Windows-Automation-Scripts

PowerShell automation toolkit for Windows system administration and infrastructure engineering. This repository is designed to demonstrate real-world, production-oriented scripting practices used by system administrators and infrastructure engineers.

---

## 🚀 Purpose

This repository focuses on **practical automation** that reduces manual effort, increases reliability, and enforces consistency across Windows environments. Scripts are written to be:

* Safe and parameter-driven
* Readable and maintainable
* Suitable for both standalone systems and enterprise environments

---

## 🧰 Script Categories

* **System Administration** – Baselines, configuration, patching
* **Monitoring & Reporting** – Health checks, audits, compliance reports
* **User Management** – Provisioning, deprovisioning, lifecycle tasks
* **Backup & Recovery** – Config, log, and state capture
* **Infrastructure Utilities** – Supporting tools for Windows environments

---

## 📂 Script Inventory (Planned & In Progress)

### 1. `New-InfraBaseline.ps1`

**Category:** System Administration
**Description:**
Applies a standardized Windows server baseline configuration, including security settings, firewall profiles, remoting configuration, time synchronization checks, and core service validation. Outputs a compliance summary.

**Status:** Planned

---

### 2. `Get-ServerHealthReport.ps1`

**Category:** Monitoring & Reporting
**Description:**
Generates a comprehensive server health report including CPU, memory, disk usage, critical services, recent event log errors, patch status, uptime, and network configuration. Exports results to HTML and JSON.

**Status:** Planned

---

### 3. `Invoke-PatchComplianceAudit.ps1`

**Category:** System Administration / Monitoring
**Description:**
Audits Windows patch compliance by checking installed updates, pending reboot state, and update configuration (Windows Update / WSUS). Produces a pass/fail compliance report per system.

**Status:** Planned

---

### 4. `Backup-ConfigsAndLogs.ps1`

**Category:** Backup
**Description:**
Collects and archives critical system configuration and log data, including event logs, installed software lists, scheduled tasks, services, and selected registry keys. Outputs a timestamped archive for recovery or auditing.

**Status:** Planned

---

### 5. `New-JoinerOffboardToolkit.ps1`

**Category:** User Management
**Description:**
Provides a controlled, auditable toolkit for onboarding and offboarding users. Supports account creation templates, account disablement, group membership capture, and safe execution modes.

**Status:** Planned

---

## 🛡️ Design Principles

* **No hardcoded environment values** (domains, paths, credentials)
* **Dry-run / WhatIf support** where applicable
* **Clear logging and error handling**
* **Minimal external dependencies**
* **Idempotent operations** whenever possible

---

## ▶️ Usage

Each script is designed to be executed independently:

```powershell
.\ScriptName.ps1 -Parameter Value
```

Detailed usage instructions and examples will be included at the top of each script.

---

## 🧪 Testing

Scripts are tested in:

* Local Windows Server lab environments
* Standalone Windows systems

Additional validation and edge-case testing is documented per script.

---

## 🛣️ Roadmap

* Expand reporting output formats
* Add centralized logging support
* Introduce optional configuration via JSON/YAML
* Extend scripts for hybrid / cloud-connected environments

---

## 📜 License

MIT License

---

## 👤 Author

Austin Smith
Infrastructure / Systems Engineering Focus

---

*This repository is actively developed and expanded as part of ongoing professional infrastructure engineering work.*
