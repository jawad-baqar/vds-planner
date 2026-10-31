# Change log

## 1.0.0

First release.

### VDS Planner (`planner/vds-planner.html`)

- One HTML file for Microsoft Edge or Google Chrome. No install, no server, no network connection (Content Security Policy).
- Inventory input: the inventory workbook (.xlsx) of a vCenter, full or only the network sheets, CSV exports of the sheets, or the CSV files of `Export-VssLayout.ps1`. Inventory refresh with a difference view.
- Draft tabs. One VDS for each standard switch (V-01), or more clusters on one VDS (V-08) by drag and drop, **+ Cluster** or the Move list. Hard limits block (datacenter, zone, uplinks). Other differences are accepted and recorded.
- VDS topology view like the vSphere Client: port groups, bus and uplinks, with the physical adapter of each host. Fold, filter, active and standby uplinks of the selected port group.
- Port group settings: VLAN, VLAN trunking, binding, ports, allocation, teaming, failover order, security. New VMkernel adapters with a static IP plan (MTU 9000 for vMotion and Provisioning).
- Design checks for rules V-01 to V-10, unique port group names in a datacenter, ESXi version against the VDS version, VLAN trunk check (V-05).
- Commit: a plan file with a SHA-256 hash, a PowerShell launcher and a report. A committed version never changes.
- Application frame: menu bar, start screen, open, open recent, save, save as, close, undo and redo, recovery copy, project settings, preferences, themes, status bar, keyboard shortcuts, guided tour, help bubbles, demo project, About.

### Scripts

- `Invoke-VdsPlan.ps1` applies one VDS of a committed plan, after all read-only checks. `Get-VdsPlanPreflight.ps1` checks a plan before the change window. `Remove-VdsPlanSwitch.ps1` removes an unused VDS of a plan.
- `Export-VssLayout.ps1`, `Export-PlannerInventory.ps1` and `Export-PlannerPreload.ps1` make the planner input from vCenter or from an inventory workbook.
- `Move-HostToVds.ps1`, `Move-VmNetworkToVds.ps1`, `New-ClusterVds.ps1`, `Add-VMotionVmk.ps1`, `Get-MultipathState.ps1`.
- All changing scripts support `-WhatIf` and `-Confirm`, and write a transcript and a CSV log.

### File formats

- Project: `vdsplan-project/1`. Committed plan: `vdsplan-run/1`.

### Tests

- Planner self-test (83 checks), offline tests against a fake vCenter (148 checks), Pester (55 tests), PowerCLI parameter check, workbook parity test.
