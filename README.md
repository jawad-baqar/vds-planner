# VDS Planner and vSphere preparation toolkit

Version 1.0.0. See `CHANGELOG.md`.

The VDS Planner and PowerCLI scripts that prepare vSphere 8 environments for VCF 9.1.1. Each script maps to a workstream (RW-nn) of the VCF 9.1.1 readiness and remediation guide. The planner and the scripts are generic: they hold no data and no name of a customer.

| Folder | Script | Workstream | Changes the environment |
|---|---|---|---|
| `scripts/inventory` | `Export-VssLayout.ps1` | RW-01, RW-08 | No |
| `scripts/inventory` | `Export-PlannerInventory.ps1` (planner input from an inventory workbook) | RW-01, RW-08 | No |
| `scripts/inventory` | `Export-PlannerPreload.ps1` (input, project files and simulation for all vCenters) | RW-01, RW-08 | No |
| `scripts/network` | `New-ClusterVds.ps1` | RW-08 | Yes |
| `scripts/network` | `Move-HostToVds.ps1` | RW-08 | Yes |
| `scripts/network` | `Move-VmNetworkToVds.ps1` | RW-08 | Yes |
| `scripts/network` | `Invoke-VdsPlan.ps1` | RW-08 | Yes |
| `scripts/network` | `Get-VdsPlanPreflight.ps1` | RW-08 | No |
| `scripts/network` | `Remove-VdsPlanSwitch.ps1` | RW-08, RB-03 | Yes |
| `scripts/lib` | `VdsPlan.psm1` (plan file checks) | RW-08 | No |
| `planner` | `vds-planner.html` (VDS Planner) | RW-08 | No |
| `scripts/network` | `Add-VMotionVmk.ps1` | RW-07 | Yes |
| `scripts/storage` | `Get-MultipathState.ps1` | RW-05 | No |
| `scripts/tags` | (planned) | - | - |

See `BACKLOG.md` for the planned tools.

## VDS Planner

`planner/vds-planner.html` is a local page for the VDS plan of one vCenter. Open it in Microsoft Edge from a local folder or a file share. It needs no install and no server, and it makes no network connection. The documentation starts at `docs/index.html`: getting started, user guide, design rules and checks, troubleshooting, live test checklist and feedback.

To try it, open the planner and select **Open project** with `samples/site-a.sample.vdsplan.json`.

With an inventory workbook of each vCenter, no connection to vCenter is necessary to start. In the planner, select **Import inventory** and select the workbook: the full workbook, only its network sheets, or CSV exports of the sheets. The planner makes the project (JSON) with two drafts. `tests/Test-PlannerWorkbook.ps1` makes sure that the planner and `Export-PlannerInventory.ps1` give the same inventory. Or run `Export-PlannerPreload.ps1`, which makes the planner input, a project file with two drafts ("Standard layout (V-01)" and "Standard layout (V-01), names fixed") and a readiness report for each vCenter from a simulation of the change against the inventory (`tests/Invoke-InventorySimulation.ps1`). Keep that output outside this repository. The package of that sample is in `samples/demo-package`.

1. Run `Export-VssLayout.ps1` for each cluster. In the planner, select **Import inventory** and select the `_vdsplan.csv` and `_hosts.csv` files. Set the security zone of each cluster. The inventory is read only in the planner.
2. The **Environment** tab shows each standard switch of each cluster and its status (not planned, in draft, committed).
3. Make one draft tab or more. Add a VDS for each standard switch, then set the port groups (VLAN, binding, ports, allocation, teaming, security). To put more clusters on one VDS, drag the switch of a cluster onto the VDS, or use **+ Cluster** (same datacenter and zone, other differences you accept, rule V-08). Use **+ VMkernel** for new VMkernel adapters with a static IP plan. The checks panel shows the guide rules. A blocking check stops the commit.
4. Select **Save project**. The project file (`*.vdsplan.json`) holds the inventory, the drafts and all committed versions. Keep it in your environment. Do not put it in git.
5. Enter your name and select **Commit and generate package**. The planner writes four files: `plan-<draft>-v<n>.json`, `plan-<draft>-v<n>.json.sha256`, `Invoke-<draft>-v<n>.ps1` and `plan-<draft>-v<n>-report.html`. Select **Generate again** to write the same plan files again later.
6. On the jump host, run `.\Invoke-<draft>-v<n>.ps1 -WhatIf`, then run it again with no `-WhatIf` under change control. It asks for the vCenter credential (default `administrator@vsphere.local`) and runs `Invoke-VdsPlan.ps1` for each VDS. After `Move-HostToVds.ps1` stage 2 on a host, run `.\Invoke-<draft>-v<n>.ps1 -Part VMkernel -VMHost <host>` for the new VMkernel adapters.
7. To refresh the inventory, import the new export. The planner shows the differences. Use **Sync from inventory** on each VDS.

Before the change window, run `.\Invoke-<draft>-v<n>.ps1 -Part Check`. It runs `Get-VdsPlanPreflight.ps1`, which is read-only. For a pilot rollback, `Remove-VdsPlanSwitch.ps1` removes a VDS of the plan when nothing uses it.

The planner and the generated package hold no credentials. `Invoke-VdsPlan.ps1` stops if the plan file changed after the commit, and it does all read-only checks before it changes anything.

## Tests

| Test | Command | Needs |
|---|---|---|
| Planner self-test | Open the planner, select **Tools**, **Run the self-test** | Edge or Chrome |
| Scripts against a fake vCenter | `.\tests\Invoke-OfflineTests.ps1` | PowerShell 5.1 or 7 only |
| Simulation of one project | `.\tests\Invoke-InventorySimulation.ps1 -ProjectFile <file> -OutputFolder <folder>` | PowerShell 5.1 or 7 only |
| PowerCLI parameter names | `.\tests\Test-PowerCliParameters.ps1` | PowerCLI (Core and VDS) |
| Pester | `Invoke-Pester .\tests` | Pester 5 |

The live test checklist for the lab and the pilot is `docs/vds-planner-live-test.html`. The internal test report is `docs/vds-planner-test-report.html`.

## Feedback

The release has an offline package, `VDS-Planner-<version>.zip`, with a SHA-256 file. Check the hash, unpack the folder on the jump host or a file share, and open `planner/vds-planner.html` in Microsoft Edge. The package needs no install and no network connection. The scripts need PowerShell 5.1 or 7 and VMware PowerCLI 13 or later.

## Use

1. Install PowerCLI 13 or later: `Install-Module VMware.PowerCLI -Scope CurrentUser`.
2. Connect: `Connect-VIServer -Server <vcenter-fqdn> -Credential (Get-Credential)`.
3. Run a read-only script first. Then run each changing script with `-WhatIf`, then for real on the pilot cluster, under the change control of your organization.

Output (transcripts and CSV logs) goes to `.\output\`. That folder is not kept in git.
