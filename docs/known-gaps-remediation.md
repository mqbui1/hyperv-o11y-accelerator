# Known Gaps and Remediation

Source: a real customer POC test summary (`HV-CLUSTER-01` cluster, hosts
`HV-HOST-01/02/03`), "Known gaps and open items" section. This maps each
finding to a concrete fix in this repo, or to an explicit non-goal with a
recommended workaround.

## 1. Availability / power-state monitoring deferred
No VM/host "down" detection exists in Tier 1 (`hypervisor-host-config.yaml`) —
Perfmon counters only report state for VMs that are running; a powered-off VM
simply stops emitting data, which is indistinguishable from "collector
briefly missed a scrape."

**Fix:** don't solve this with Perfmon. The customer's own
`collect-scvmm-metrics.ps1` already has PowerState from SCVMM — that's the
correct source of truth for on/off/paused/critical state, not the hypervisor
performance counters. Recommended integration: have that script (or a
scheduled task wrapping it) emit an OTLP metric `vm.power_state` (0/1 gauge,
or a string-enum dimension) tagged with the same `vm.name`/`host.name`
resource attributes this repo already standardizes on, and export it via the
same `otlphttp/splunk` exporter pattern used in
`hypervisor-host-config.yaml`. This repo does not reimplement SCVMM polling —
it just needs the metric to land with matching resource attributes so it
shows up on the same dashboard/entity. Not yet built here; flagged as the
next integration point once the script's output format is confirmed.

## 2. Static-memory VMs invisible to memory-pressure alerting
By design: "Current Pressure" (`Hyper-V Dynamic Memory VM` object) only
exists for VMs with Dynamic Memory enabled. Static-memory VMs never populate
this counter, so `vm_memory_pressure_high` in `detectors.tf` silently never
fires for them — not a bug, a coverage gap.

**Fix:** this is exactly the "curated subset" use case called out in the
Tier 2 header comment in `guest-vm-config.yaml`. For static-memory VMs where
memory exhaustion risk matters, opt them into Tier 2's `hostmetrics/memory`
scraper instead of relying on Tier 1. Do not attempt to fleet-wide deploy
Tier 2 to work around this — see gap #4 and the billing note in
`guest-vm-config.yaml`.

## 3. ~19–23% of VHD instances unattributed (fleet match rate 77–81%)
`Get-VMHardDiskDrive` (used by the customer's `build-hyperv-vm-disk-map.ps1`)
doesn't return DVD/ISO-mounted drives or pass-through disks, so a fifth of
the `Hyper-V Virtual Storage Device` Perfmon instances can't be mapped back
to a VM name by path alone.

**Fix:** `transform/vm_name` in `hypervisor-host-config.yaml` already handles
the common `...\Virtual Hard Disks\VMName.vhdx` path pattern and now also
strips the Perfmon `#N` duplicate suffix (gap #6). It intentionally does NOT
try to guess VM names for pass-through/ISO instances — there's no reliable
signal in the raw Perfmon instance string for those. Two options, not
mutually exclusive: (a) accept the ~20% gap for storage *file I/O* metrics
specifically (CPU/memory/network attribution is unaffected — this gap is
storage-object-specific), or (b) feed the existing
`build-hyperv-vm-disk-map.ps1` output in as a side-channel lookup
(e.g. a `transform` processor statement keyed on a resource attribute set
from that script's export) if per-VM storage completeness for pass-through
disks becomes a hard requirement. Not implemented here — (a) is the
pragmatic default.

## 4. No guest filesystem used % visible
Confirmed architectural limitation: `host.disk.free_space` / Hyper-V's
`Hyper-V Virtual Storage Device` counters describe host-visible virtual disk
*files*, not what's actually used inside the guest's filesystem.

**Fix:** requires Tier 2 (`guest-vm-config.yaml`, `hostmetrics/filesystem` or
`windowsperfcounters/guest_disk`). Given the billing constraint (see gap
below), this repo now frames Tier 2 explicitly as an **opt-in curated
subset**, not a fleet default — see the header comment added to
`guest-vm-config.yaml` and the chart name in `dashboards.tf`
(`guest_disk_free`).

**Billing constraint (why Tier 2 can't be the default):** one customer POC
measured ~1,478 physical/hypervisor hosts vs. ~17,000 VMs. Deploying an OTel
Collector inside every VM would make each VM a separately-billed host —
roughly a 12x increase in billable host count for metrics that, for most
VMs, Tier 1 already approximates well enough. Reserve Tier 2 for VMs that
specifically need it (business-critical workloads, static-memory VMs per
gap #2, or VMs where in-guest process/app metrics are required).

## 5. Disk latency unit unconfirmed
`vm.storage.latency` (from the `Hyper-V Virtual Storage Device` object's
"Latency" counter) is documented by Microsoft as 100ns ticks, but this has
not been independently verified against a raw counter value in a live
environment.

**Fix:** `hypervisor-host-config.yaml` now flags this in the metric
description and a code comment. `detectors.tf`'s `vm_storage_latency_high`
detector is now shipped with `disabled = true` and a comment explaining why —
do not enable it until someone validates the unit by comparing the raw
Perfmon counter value against a VM with a known slow/fast disk. Flipping the
unit wrong here means the 20ms threshold is either meaningless (if the real
unit is much smaller) or never useful (if much larger).

## 6. Malformed vm.name values from Perfmon duplicate-instance suffixing
3 instances observed with a trailing `#1` (the cluster has 62 duplicate-named
VMs across its hosts, and Perfmon disambiguates same-named instances by
appending `#N`). The prior `transform/vm_name` logic didn't strip this, so
those VMs' metrics landed under a malformed `vm.name` like `WebServer#1`
instead of `WebServer`.

**Fix:** added a final OTTL statement to `transform/vm_name` in
`hypervisor-host-config.yaml`:
```
set(attributes["vm.name"], Split(attributes["vm.name"], "#")[0]) where attributes["vm.name"] != nil and IsMatch(attributes["vm.name"], ".*#[0-9]+$")
```
This runs last (after all object-specific extraction), since the `#N` suffix
can appear regardless of which Perfmon object the instance string came from.
Note this does not solve name *collisions* — if a customer has 62 VMs with
duplicate names, this correctly strips the disambiguator but the VMs will
still land on the same `host.name` entity in Splunk Observability Cloud
(their metrics will merge). That's a genuine naming-hygiene problem on the
customer's Hyper-V estate, not something an OTel processor can fix — flagged
as an out-of-band recommendation (rename duplicate VMs) rather than a config
workaround.

## 7. ~20% of VMs emit no network series (244 series vs. ~308 VMs)
Root cause not yet confirmed in the POC — candidates: VMs with no vNIC
attached, VMs powered off during the collection window, or a naming edge
case in the `Hyper-V Virtual Network Adapter` instance string not covered by
`transform/vm_name`.

**Fix:** flagged with a comment directly on the `Hyper-V Virtual Network
Adapter` receiver block in `hypervisor-host-config.yaml`. Explicitly do NOT
build a "no network data" detector on `vm.net.bytes_total` until this is
spot-checked — a naive "series stopped/never existed" detector would
false-positive on every VM that legitimately has no vNIC. Recommended next
step: cross-reference the ~64 missing VMs against `Get-VMNetworkAdapter`
output to confirm whether they truly lack a vNIC, before deciding whether a
detector is even meaningful here.

## 8. guest_os accuracy issues (99 unknown + 28 untagged; heuristic Linux tagging; secure-boot fallback needs remote rights)
This is entirely inside the customer's `enrich-vm-guest-os.ps1` script, not
in this repo's OTel/Terraform layer — this accelerator doesn't currently
ingest or re-derive `guest_os` at all.

**Fix (recommendation, not implemented here):** if `guest_os` needs to be a
resource attribute for filtering/dashboards, export it from
`enrich-vm-guest-os.ps1` as a metric label or resource attribute using the
same OTLP/`otlphttp/splunk` pattern as gap #1's power-state suggestion,
keyed by `vm.name` so it joins onto the same entity. The underlying accuracy
problems (heuristic-only 101/102 Linux tags, secure-boot fallback needing
elevated remote rights) are data-quality issues in that script's SCVMM/WMI
queries, outside this repo's scope to fix.

## 9. VMMS load issues driven by failed live migrations (Event ID 21026)
Confirmed root cause on `HV-HOST-01`; `HV-HOST-03` needed a
`disk_map_build_timeout_sec: 900` override to work around the resulting
slowness.

**Fix:** added a `count` connector (`count/migration_failures`) in
`hypervisor-host-config.yaml` that converts Event ID 21026 occurrences on the
`Microsoft-Windows-Hyper-V-VMMS-Admin` channel into a metric
(`hyperv.vmms.migration_failures`), plus a new `metrics/migration_failures`
pipeline and `vmms_migration_failures` detector in `detectors.tf`. This makes
the root cause directly alertable instead of only visible after the fact via
`disk_map_build_timeout_sec` workarounds. **Caveat:** the connector's
condition (`attributes["winlog.event_id"] == 21026`) assumes the
`windowseventlogreceiver`'s attribute key — verify this against a raw
ingested event for the collector version actually deployed, since this
attribute naming has changed across contrib releases.

## 10. environment=poc → production cutover
Already validated as low-risk in the POC via the `host.type == "hypervisor"`
/ `"hypervisor_managed_vm"` filter design used throughout
`hypervisor-host-config.yaml`, `dashboards.tf`, and `detectors.tf` — those
filters are environment-agnostic. No repo change needed; just point
`SPLUNK_REALM`/`SPLUNK_ACCESS_TOKEN` at the production org token and roll the
same config out to the remaining hosts.
