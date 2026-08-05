# Architecture

## Overview

Two-tier collection, mirroring the host/guest split every hypervisor has —
the same pattern the vSphere navigator in Splunk Observability Cloud relies
on, applied to Hyper-V (which has no native O11y integration).

```
┌─────────────────────────── Hyper-V Host ───────────────────────────┐
│                                                                      │
│  Splunk OTel Collector (otel-collector/hypervisor-host-config.yaml) │
│  Tier 1 — deploy on EVERY host, no per-VM config needed             │
│                                                                      │
│   windowsperfcounters/host        -> host.*        (host.type=hypervisor)
│   windowsperfcounters/hypervisor  -> hyperv.*       (host.type=hypervisor)
│   windowsperfcounters/vm          -> vm.*           (host.type=hypervisor_managed_vm)
│   windowseventlog/*               -> Hyper-V event logs
│   count/migration_failures        -> hyperv.vmms.migration_failures
│                                                                      │
└──────────────────────────────┬───────────────────────────────────┬──┘
                                │ otlphttp                          │
                                ▼                                   │
                  Splunk Observability Cloud                        │
                  (ingest.$SPLUNK_REALM.signalfx.com)                │
                                ▲                                   │
                                │ otlphttp (opt-in, curated only)     │
┌───────────────────────────────┴──────────────┐                    │
│  Guest VM (SELECTED VMs ONLY — see gap #4)    │                    │
│  Splunk OTel Collector                        │                    │
│  (otel-collector/guest-vm-config.yaml)        │                    │
│  Tier 2                                       │                    │
│   hostmetrics/*                -> standard host-metrics namespace │
│   windowsperfcounters/guest_disk -> guest.disk.*                   │
└────────────────────────────────────────────────────────────────────┘
```

## Resource attribute strategy

This is the load-bearing design decision in the repo — get this wrong and
Tier 1/Tier 2 data won't correlate, and dashboards/detectors (which filter on
`host.type`) silently return nothing.

| Attribute | Set by | Value | Purpose |
|---|---|---|---|
| `host.type` | `resource/hypervisor_tag`, `resource/vm_tag`, `resource/guest_tag` | `hypervisor` \| `hypervisor_managed_vm` | Every chart/detector filter in `terraform/dashboards.tf` and `terraform/detectors.tf` is keyed on this. Determines whether a metric is host-side or VM-side. |
| `host.name` | `resourcedetection` (Tier 1 host/hypervisor pipelines) or `transform/vm_hostname` (Tier 1 vm pipeline, copied from `vm.name`) or `resourcedetection` (Tier 2, guest OS hostname) | Hypervisor's own hostname, or the VM's name | The entity key. For Tier 1 VM metrics and Tier 2 guest metrics to land on the **same** Splunk Observability Cloud entity, the Hyper-V VM name must exactly match the guest OS hostname — see "Correlation requirement" below. |
| `vm.name` | `transform/vm_name` (extracted from noisy Perfmon instance strings — see below) | Clean VM name | Intermediate attribute, promoted to `host.name` and used as the `groupbyattrs` key. |
| `hypervisor.host.name` | `resource/vm_tag` (Tier 1, `${env:COMPUTERNAME}`) or `resource/guest_tag` (Tier 2, `${env:HYPERV_HOST_NAME}`) | Parent hypervisor's hostname | Stamped onto every VM's metrics (both tiers) so the infra navigator can link VM -> parent host, independent of whether `host.name` correlation (above) also works. |
| `virtualization.system` | `resource/hypervisor_tag` | `hyperv` | Distinguishes from other virtualization platforms if this repo's output ever lands alongside vSphere/other hypervisor data in the same org. |

## Correlation requirement (Tier 1 <-> Tier 2)

Tier 2 is deployed opt-in, per VM (see `docs/known-gaps-remediation.md`,
gap #4, for why it's not fleet-wide). For a given VM's Tier 1 (host-view) and
Tier 2 (in-guest) metrics to appear on the same entity:

1. The guest OS hostname must exactly match the Hyper-V VM name shown in
   `Get-VM` / Hyper-V Manager. If they differ, override `host.name` in
   `guest-vm-config.yaml`'s `resourcedetection/guest` (or add an explicit
   `resource` processor attribute) to the Hyper-V VM name instead of relying
   on OS-hostname auto-detection.
2. `HYPERV_HOST_NAME` must be set in the Tier 2 collector's environment to
   the parent hypervisor's hostname, matching what Tier 1 stamps via
   `${env:COMPUTERNAME}`.

If VM names contain duplicates on the same host (see
`docs/known-gaps-remediation.md`, gap #6), correlation degrades further:
multiple VMs' metrics will merge onto one entity. That's a Hyper-V-estate
naming-hygiene problem, not something the collector config can resolve.

## Why `vm.name` extraction is non-trivial

Windows Perfmon does not expose a clean "VM name" field — VM identity is
embedded inside instance strings whose format differs per counter object:

| Object | Example instance string | Extraction rule |
|---|---|---|
| `Hyper-V Hypervisor Virtual Processor` | `VMName:Hv VP 0` | split on `:`, take first segment |
| `Hyper-V Dynamic Memory VM` | `VMName` | already clean |
| `Hyper-V Virtual Network Adapter` | `VMName_Network Adapter_{GUID}` | split on `_Network Adapter` |
| `Hyper-V Virtual Storage Device` | `...\Virtual Hard Disks\VMName.vhdx` | split on `Virtual Hard Disks-`, then strip `.vhdx` |
| any of the above, when duplicated | `VMName#1` | strip trailing `#[0-9]+` (must run last — see gap #6) |

This entire chain lives in `transform/vm_name` in
`hypervisor-host-config.yaml`, ordered so later, more-specific statements
override the generic first-pass copy. `filter/vm_noise` runs first to drop
non-VM instances (`Default Switch`, `.vmgs`, `.iso`) before extraction, and
`groupbyattrs/vm` runs after to promote the final `vm.name` from a datapoint
attribute to a resource attribute (making each VM its own entity).

## Event-to-metric conversion (VMMS migration failures)

Detectors in Splunk Observability Cloud alert on metric time series, not raw
log events. `hypervisor-host-config.yaml` uses the `count` connector
(`count/migration_failures`) to convert Event ID 21026 occurrences
(live-migration failures) on the `Microsoft-Windows-Hyper-V-VMMS-Admin`
channel into a `hyperv.vmms.migration_failures` metric, fed to its own
`metrics/migration_failures` pipeline and the `vmms_migration_failures`
detector in `terraform/detectors.tf`. This is the general pattern to follow
if other event-log channels need to become alertable — see
`docs/known-gaps-remediation.md`, gap #9.

## Dashboards and detectors (Terraform)

- `terraform/main.tf` — `signalfx` provider + `signalfx_dashboard_group.hyperv`
- `terraform/dashboards.tf` — two dashboards: "Hypervisor Overview" (Tier 1
  only, one row per host) and "VM Detail" (Tier 1 VM metrics + optional Tier
  2 guest disk chart, explicitly labeled as requiring opt-in deployment)
- `terraform/detectors.tf` — VM health critical, hypervisor CPU high, VM
  memory pressure high, VM storage latency high (shipped disabled pending
  unit validation — gap #5), VMMS migration failures

All chart/detector `program_text` filters on `host.type`, per the table
above — this is why getting the resource attribute strategy right matters
more than any individual metric mapping.

## What this repo deliberately does not do

- Reimplement Hyper-V inventory/power-state polling — that's SCVMM's job
  (see `docs/known-gaps-remediation.md`, gap #1); this repo's job is to make
  that data (once emitted as OTLP with matching resource attributes) land on
  the same entities as everything else here.
- Force fleet-wide in-guest deployment — see gap #4 and the billing math in
  `guest-vm-config.yaml`'s header comment.
- Attempt full content/navigator parity with the vSphere integration in one
  pass — this is a field accelerator (dashboards + detectors as code), not a
  claim of native-integration-equivalent coverage. See `docs/limitations.md`.
