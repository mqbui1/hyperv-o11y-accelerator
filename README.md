# Hyper-V Observability Accelerator

A field-delivered accelerator for monitoring Microsoft Hyper-V environments
in **Splunk Observability Cloud**, which has no native Hyper-V integration.
Built on the generic OpenTelemetry `windowsperfcounters` /
`windowseventlogreceiver` receivers, Terraform-defined dashboards/detectors,
and hardened against gaps found during a real customer POC.

## What this is (and isn't)

- A two-tier OTel Collector config + Terraform dashboard/detector pack you
  deploy yourselves — not a Splunkbase app, not a native integration.
- Tier 1 (host-side) covers hypervisor/VM resource-allocation metrics from
  every Hyper-V host. Tier 2 (in-guest) is **opt-in only**, for a curated
  subset of VMs — see [docs/limitations.md](docs/limitations.md) for why
  fleet-wide in-guest deployment isn't the default.
- Not a claim of parity with the native VMware vSphere integration. See
  [docs/limitations.md](docs/limitations.md) for the honest gap list.

## Repo layout

```
otel-collector/
  hypervisor-host-config.yaml   Tier 1 — deploy on every Hyper-V host
  guest-vm-config.yaml          Tier 2 — opt-in, curated VM subset only
terraform/
  main.tf                       signalfx provider + dashboard group
  variables.tf                  splunk_access_token / splunk_realm
  dashboards.tf                 Hypervisor Overview + VM Detail dashboards
  detectors.tf                  VM health, CPU, memory, storage latency,
                                 VMMS migration-failure detectors
docs/
  architecture.md               Resource-attribute strategy, vm.name
                                 extraction, event-to-metric conversion
  limitations.md                What this accelerator cannot do, and why
  known-gaps-remediation.md     10 specific gaps from a real customer POC,
                                 mapped to fixes/workarounds in this repo
  deployment-guide.md           Delivery, install, configure, test/verify
```

## Quick start

1. **Provision dashboards + detectors**
   ```
   cd terraform
   cp terraform.tfvars.example terraform.tfvars   # fill in splunk_access_token + splunk_realm
   terraform init && terraform apply
   ```
2. **Install the Splunk OTel Collector for Windows** on each Hyper-V host,
   using `otel-collector/hypervisor-host-config.yaml`.
3. **(Optional)** deploy `otel-collector/guest-vm-config.yaml` to a curated
   subset of VMs that need in-guest visibility.

Full step-by-step instructions, environment variables, and a test/verify
checklist: [docs/deployment-guide.md](docs/deployment-guide.md).

## Known gaps

This repo was hardened against 10 specific findings from a real customer
POC (malformed VM names, unconfirmed disk-latency units, missing network
series, VMMS migration failures, etc.) — see
[docs/known-gaps-remediation.md](docs/known-gaps-remediation.md) for the
full list and what's already fixed vs. still open.
