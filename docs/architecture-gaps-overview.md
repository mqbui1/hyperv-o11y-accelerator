# Architecture Overview + Gap Mapping

A single-page synthesis of [architecture.md](architecture.md) and
[known-gaps-remediation.md](known-gaps-remediation.md) — the overall system
design, and how each piece of that design maps to the 10 specific gaps found
during a real customer POC.

## Overall architecture

```
┌─────────────────────────────── Hyper-V Host (Tier 1) ────────────────────────────────┐
│  Splunk OTel Collector — otel-collector/hypervisor-host-config.yaml                   │
│  Deployed on EVERY host, no per-VM config needed                                      │
│                                                                                          │
│  windowsperfcounters/host        → host.*         (host.type=hypervisor)              │
│  windowsperfcounters/hypervisor  → hyperv.*        (host.type=hypervisor)              │
│  windowsperfcounters/vm          → vm.*            (host.type=hypervisor_managed_vm)   │
│  windowseventlog/*               → Hyper-V event logs                                  │
│  count/migration_failures        → hyperv.vmms.migration_failures                      │
│         │                                                                               │
│         ├─ filter/vm_noise      (drops Default Switch / .vmgs / .iso noise)            │
│         ├─ transform/vm_name    (extracts clean VM name from Perfmon instance strings) │
│         ├─ groupbyattrs/vm      (promotes vm.name → resource, one entity per VM)       │
│         ├─ resource/vm_tag      (tags host.type, hypervisor.host.name)                 │
│         └─ transform/vm_hostname (vm.name → host.name for entity correlation)          │
└──────────────────────────────────────┬──────────────────────────────────────────────────┘
                                        │ otlphttp/splunk
                                        ▼
                        Splunk Observability Cloud
                 (dashboards + detectors provisioned via terraform/*.tf)
                                        ▲
                                        │ otlphttp/splunk (opt-in only)
┌───────────────────────────────────────┴──────────────────────┐
│  Guest VM (Tier 2 — CURATED SUBSET, not fleet-wide)           │
│  otel-collector/guest-vm-config.yaml                          │
│  hostmetrics/* + windowsperfcounters/guest_disk                │
└─────────────────────────────────────────────────────────────┘
```

**Why two tiers, and why Tier 2 is opt-in:** Tier 1 is cheap (no extra
billable hosts) but can only see hypervisor-visible resource allocation —
not real guest-OS internals. Tier 2 sees inside the guest but makes every VM
a separately-billed host. One customer POC measured ~1,478 physical hosts
vs. ~17,000 VMs, so Tier 2 defaulting to fleet-wide would multiply billable
hosts ~12x. This split *is itself* the fix for gap #4.

**The load-bearing design decision** is the resource-attribute strategy:
every dashboard/detector filters on `host.type` (`hypervisor` vs.
`hypervisor_managed_vm`), and `vm.name` → `host.name` promotion is what lets
a VM become its own entity. Get this wrong and nothing correlates — which is
exactly why gaps #3, #6, and #7 all live in this layer.

## How the architecture maps to each of the 10 gaps

| # | Gap | Architectural component that addresses it |
|---|---|---|
| 1 | No power-state/availability monitoring | **Deliberately out-of-band** — Perfmon can't distinguish "VM off" from "scrape missed." Design leaves a contract (matching `vm.name`/`host.name` resource attrs) for the customer's existing SCVMM script to plug into via OTLP, rather than building it into the collector. |
| 2 | Static-memory VMs invisible to memory pressure | Tier 1's `Hyper-V Dynamic Memory VM` counter simply doesn't exist for these VMs — this is exactly the use case the **Tier 2 opt-in curated subset** exists for (`hostmetrics/memory` on just those VMs). |
| 3 | ~20% of VHD instances unattributed | `transform/vm_name`'s storage-path extraction rule handles the common case; pass-through/ISO disks have no reliable signal in the raw instance string, so this is an accepted, scoped gap (storage-metric-specific, not fleet-wide) rather than a false fix. |
| 4 | No guest filesystem used % | **The Tier 1/Tier 2 split itself** — Tier 2 (`guest-vm-config.yaml`) is the fix, reframed as opt-in per the billing constraint above. |
| 5 | Disk latency unit unconfirmed | Not an architecture fix — a **safety gate**: the metric description flags it, and `vm_storage_latency_high` in `detectors.tf` ships `disabled = true` until validated (see `nested-hyperv-azure-test-plan.md`, step 4). |
| 6 | Malformed `vm.name` from Perfmon `#N` duplicate suffixing | Final statement in `transform/vm_name` strips `#[0-9]+$`, run **last** so it applies regardless of which object type's instance string it came from. Validated both synthetically (`otel-collector/test/`) and via the nested-Hyper-V test plan against real Windows behavior. |
| 7 | ~20% of VMs missing network series | Flagged directly on the `windowsperfcounters/vm` network receiver block — architecture deliberately does **not** build a detector on `vm.net.bytes_total` until this is spot-checked, to avoid false positives on VMs with no vNIC. |
| 8 | `guest_os` accuracy issues | **Out of scope by design** — lives entirely in the customer's `enrich-vm-guest-os.ps1`; this repo doesn't ingest or re-derive `guest_os` at all, same non-goal pattern as gap #1. |
| 9 | VMMS load from failed live migrations (Event 21026) | New architectural piece: the **`count` connector** (`count/migration_failures`) converts raw log events into a metric (`hyperv.vmms.migration_failures`), because detectors alert on metrics, not logs. Feeds a dedicated pipeline + `vmms_migration_failures` detector. |
| 10 | poc → production cutover | Solved by design, not by a fix — every filter (`host.type == "hypervisor"` / `"hypervisor_managed_vm"`) is environment-agnostic, so cutover is just repointing `SPLUNK_REALM`/`SPLUNK_ACCESS_TOKEN`. |

## Further detail

- [architecture.md](architecture.md) — full resource-attribute strategy,
  the Perfmon instance-string extraction table, and the event-to-metric
  conversion pattern
- [known-gaps-remediation.md](known-gaps-remediation.md) — the original,
  detailed per-gap writeup this table summarizes
- [limitations.md](limitations.md) — what this accelerator cannot do,
  independent of the 10 gaps
- [deployment-guide.md](deployment-guide.md) — delivery/install/test-verify
  runbook
- [nested-hyperv-azure-test-plan.md](nested-hyperv-azure-test-plan.md) —
  validating gaps #5 and #6 against a real (nested) Hyper-V host
