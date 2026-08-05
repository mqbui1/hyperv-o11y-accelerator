# Limitations

This is a field-built accelerator, not a native Splunk Observability Cloud
integration. Read this before promising a customer parity with vSphere/
native-integration coverage.

## 1. No native Hyper-V integration exists in Splunk Observability Cloud

Everything in this repo is built on the generic `windowsperfcounters` and
`windowseventlogreceiver` OTel receivers — there is no Hyper-V-specific
receiver upstream, and Hyper-V is not on the Observability Cloud
infrastructure-monitoring roadmap as of this writing (not prioritized;
see internal solutioning notes). This repo is a stopgap, not a
forward-compatible guarantee — Microsoft can change counter names/objects
across Windows Server versions without notice, and this config has only
been validated against the counter set documented by Microsoft plus one
real customer POC cluster.

## 2. Virtualization isolation boundary: guest-OS-internal metrics are not visible from the hypervisor

This is not a Splunk or OTel limitation — it's fundamental to how
virtualization works, and would apply equally to vSphere without VMware
Tools reporting from inside the guest. From the host side (Tier 1,
`hypervisor-host-config.yaml`), you get **resource allocation as seen by the
hypervisor**:
- vCPU % time, not what's running inside the guest
- Assigned/pressure memory, not actual guest memory utilization
- Virtual disk **file** I/O (bytes/sec, latency), not guest filesystem used %
- vNIC throughput, not guest-level connection/socket state

You do NOT get, from Tier 1 alone:
- Guest filesystem free space (see `docs/known-gaps-remediation.md`, gap #4)
- Guest process/service state
- Guest application-level metrics
- Guest OS patch level, installed software, etc.

Getting any of the above requires Tier 2 (`guest-vm-config.yaml`), deployed
inside the guest — which is a fleet-deployment problem (push via existing
config management), not a virtualization-specific one.

## 3. Tier 2 cannot be deployed fleet-wide due to host-license billing economics

Every VM running an OTel Collector becomes a separately-billed host. In one
real customer POC, ~1,478 physical/hypervisor hosts hosted ~17,000 VMs —
fleet-wide Tier 2 would multiply billable host count roughly 12x. This repo
frames Tier 2 as opt-in/curated only (see `guest-vm-config.yaml` header).
Practically, this means most customers evaluating this accelerator will
have a **permanent, load-bearing gap** in guest-OS-internal visibility for
any VM not explicitly opted in — this is a real, not cosmetic, coverage gap
and should be represented as such, not glossed over as "solved by Tier 2."

## 4. Static-memory VMs have no memory-pressure signal from Tier 1

The `Hyper-V Dynamic Memory VM` object's "Current Pressure" counter only
exists for VMs with Dynamic Memory enabled. Static-memory VMs never populate
`vm.memory.current_pressure` — the `vm_memory_pressure_high` detector
silently never fires for them. See `docs/known-gaps-remediation.md`, gap #2.

## 5. VM name extraction from Perfmon instance strings is best-effort, not guaranteed

`transform/vm_name` in `hypervisor-host-config.yaml` handles the instance
string formats observed in Microsoft's documentation and one real customer
POC. Known incomplete cases:
- Pass-through disks and DVD/ISO-mounted drives are not attributable to a VM
  name by path alone (`Get-VMHardDiskDrive` doesn't return them either) —
  ~19–23% of VHD instances went unmatched in the reference POC. See gap #3.
- Duplicate VM names on the same host produce identical `vm.name` values
  after suffix-stripping (gap #6) — their metrics will merge onto one
  Splunk Observability Cloud entity. This is a customer naming-hygiene
  problem, not fixable purely in collector config.
- Any future Perfmon instance-string format not covered by the existing
  `Split`/`IsMatch` chain will fall through to the generic first-pass copy
  (raw instance string as `vm.name`), producing a messy but non-fatal entity
  name rather than a silent drop.

## 6. `vm.storage.latency` unit is unconfirmed

Documented by Microsoft as 100ns ticks, but not independently verified
against a raw counter value in a live environment. The
`vm_storage_latency_high` detector ships `disabled = true` for this reason —
do not enable it until validated. See `docs/known-gaps-remediation.md`,
gap #5.

## 7. Network series completeness is unverified (~20% of VMs missing in one POC)

Root cause not confirmed — could be VMs with no vNIC, powered-off VMs during
the collection window, or an uncovered instance-string edge case. No
detector should be built on "missing network series" until this is
spot-checked. See gap #7.

## 8. No availability/power-state monitoring

Perfmon counters only report data for running VMs — a powered-off VM simply
stops emitting, which looks identical to "the collector missed a scrape."
This repo does not attempt VM/host up-down detection; that requires a
different source of truth (SCVMM). See gap #1.

## 9. This is a metrics/logs pipeline + dashboards/detectors — not full navigator parity

The vSphere integration in Splunk Observability Cloud includes curated
navigators, entity relationships, and content built by the Infrastructure
Monitoring content team over time. This repo provides the OTel Collector
configs and Terraform-defined dashboards/detectors to approximate that for
Hyper-V, but does not claim equivalent polish, coverage, or long-term
maintenance commitment. Treat it as a starting point for a field engagement,
not a packaged product.
