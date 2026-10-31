# Backlog

Candidate tools, each mapped to the guide. Status: seeded (sample exists), planned, idea.

| ID | Tool | Workstream | Status |
|---|---|---|---|
| T-01 | Export the standard switch layout of every host in a cluster (switches, uplinks, port groups, VLANs, vmk adapters) and propose the VDS plan with the majority rule | RW-01, RW-08 | Seeded |
| T-02 | Create the VDS and port groups from the plan CSV | RW-08 | Seeded |
| T-03 | Move the uplinks and vmk0 of one host in stages, with a check after each stage | RW-08 | Seeded |
| T-04 | Move the VM adapters of one port group, with a rollback CSV | RW-08 | Seeded |
| T-05 | Add the vMotion VMkernel adapter from an IP plan CSV | RW-07 | Seeded |
| T-06 | Record the multipathing state (PowerPath/VE or NMP) of every host and LUN | RW-05 | Seeded |
| T-07 | Set the NMP Round Robin SATP rules for the Dell arrays (option B of RW-05) | RW-05 | Planned |
| T-08 | Find VMFS-5 datastores and the datastores below 10% free space | RW-04 | Planned |
| T-09 | Export and re-create vSphere tags and categories, and the tag assignments | RW-13 | Planned |
| T-10 | Find the DHCP VMkernel adapters (iDRAC USB NIC, VxRail BMC) | RW-09 | Planned |
| T-11 | Check the import and converge requirements for each cluster (VDS, vMotion, DRS, static vmk, vLCM image) | RW-16, RW-17 | Planned |
| T-12 | Check DNS forward and reverse records and NTP on every host | RW-02 | Planned |
| T-13 | Roll a cluster back from VDS to standard switch (pilot safety net) | RW-08, RB-03 | Partly built: `Remove-VdsPlanSwitch.ps1` removes an unused VDS. Moving uplinks and VMkernel adapters back is manual. |
| T-14 | VDS Planner: local page with draft tabs, port group options and rule checks. Commit makes a hashed plan file and a launcher for `Invoke-VdsPlan.ps1` | RW-08 | Version 1.0 |

## T-14 VDS Planner phases

| Phase | Content | Status |
|---|---|---|
| 1 | Plan file format, `Invoke-VdsPlan.ps1`, planner with draft tabs, port group options, commit and generate again | Built |
| 2 | Environment overview, security zones, copy settings, duplicate draft, run report in the package, operator guide | Built |
| 3 | Shared VDS for more than one cluster (V-08 check with uplinks, NIC speed, port groups and zone), new VMkernel adapters with a static IP plan (`-Part VMkernel`, one host at a time) | Built |
| 4 | Inventory refresh with a difference view, stale-draft checks, Sync from inventory | Built |
| - | Preflight (`-Part Check`), rollback script, datacenter port group name check, ESXi version check, planner self-test, offline tests | Built |
| - | Start from an inventory workbook: converter, project file with two drafts, name repair, simulation against the inventory, readiness report, preload for all vCenters | Built |
| - | Planner: Add all switches, trunk check for a full VDS, Fix names, existing VDS names | Built |
| - | Live test on a lab vCenter (`docs/vds-planner-live-test.html`). Review with the customer. | Open |
| - | Design decision for datacenters with many clusters: new port group names (draft "names fixed") or shared VDS (V-08) | Open (customer decision) |
| 5 | .exe wrapper | Not planned. The HTML path was chosen. |

Decision: new vMotion and Provisioning VMkernel adapters default to MTU 9000, and the VDS MTU follows. The designer can change it. The guide rule V-09 (VDS MTU 1500) needs an update for this.

Not run against a vCenter yet. Internal tests of version 1.0: planner self-test 83 of 83, offline tests 148 of 148 and Pester 55 of 55 on PowerShell 5.1 and 7.6, PowerCLI Core parameter check 0 wrong. See `docs/vds-planner-test-report.html`.
