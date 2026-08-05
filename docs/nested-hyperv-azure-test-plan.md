# Nested Hyper-V Test Plan (Azure)

Runbook for validating the real `windowsperfcounters` / `windowseventlogreceiver`
receivers in `otel-collector/hypervisor-host-config.yaml` against a genuine
Hyper-V host — closing the gap the Docker harness in `otel-collector/test/`
can't cover (those receivers only run on Windows).

This uses **nested virtualization**: one Azure VM acts as the "physical"
Hyper-V host, with 1–2 lightweight VMs created inside it to populate
per-VM Perfmon counters. Azure is one of the few clouds where this reliably
works on regular (non-bare-metal) VM sizes.

## 1. Provision the Azure VM

Nested virtualization requires a VM size from the Dv3/Ev3 family or newer,
and a Generation 2 image.

```
az group create --name hyperv-test-rg --location eastus

az vm create \
  --resource-group hyperv-test-rg \
  --name hyperv-test-host \
  --image Win2022Datacenter:latest \
  --size Standard_D4s_v3 \
  --admin-username azureuser \
  --admin-password '<set-a-strong-password>' \
  --generation V2 \
  --public-ip-sku Standard

az vm open-port --resource-group hyperv-test-rg --name hyperv-test-host --port 3389
```

RDP in once it's up (`az vm show ... --show-details --query publicIps`).

## 2. Enable the Hyper-V role and reboot

Inside the VM (PowerShell, run as Administrator):

```powershell
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
```

After reboot, confirm the real Hyper-V Perfmon counter sets now exist:

```powershell
Get-Counter -ListSet "Hyper-V*" | Select-Object CounterSetName
```

This is the first real validation point — confirms Microsoft hasn't renamed
any of the counter objects `hypervisor-host-config.yaml` depends on
(`Hyper-V Hypervisor`, `Hyper-V Dynamic Memory VM`, `Hyper-V Virtual Network
Adapter`, `Hyper-V Virtual Storage Device`, `Hyper-V Virtual Machine Health
Summary`) on this Windows Server build.

## 3. Create 1–2 nested guest VMs

VMs don't need a bootable OS to populate CPU/memory/network/storage-existence
counters — Hyper-V allocates resources as soon as a VM is powered on, boot
device or not. A default virtual switch is created automatically when the
Hyper-V role installs.

```powershell
New-VM -Name "vm-alpha" -MemoryStartupBytes 512MB -Generation 1 -NewVHDPath "C:\VMs\Virtual Hard Disks-vm-alpha.vhdx" -NewVHDSizeBytes 5GB -SwitchName "Default Switch"
Start-VM -Name "vm-alpha"

# Create a SECOND VM with the SAME name to observe the real Perfmon
# duplicate-suffix behavior (validates gap #6 against ground truth, not
# just our assumption):
New-VM -Name "vm-alpha" -MemoryStartupBytes 512MB -Generation 1 -NewVHDPath "C:\VMs\Virtual Hard Disks-vm-alpha-2.vhdx" -NewVHDSizeBytes 5GB -SwitchName "Default Switch"
Start-VM -Name "vm-alpha"
```

Check the raw instance strings Windows actually produces:

```powershell
(Get-Counter -ListSet "Hyper-V Hypervisor Virtual Processor").PathsWithInstances
(Get-Counter -ListSet "Hyper-V Virtual Storage Device").PathsWithInstances
```

Confirm whether the second `vm-alpha` shows up as `vm-alpha#1` in the raw
instance strings — if so, the `transform/vm_name` suffix-strip
(`known-gaps-remediation.md` gap #6) is validated against real Windows
behavior, not just the synthetic test in `otel-collector/test/`.

## 4. For a real disk-latency reading (gap #5), use an OS-having VM

The CPU/memory/network/storage-*existence* counters work with an OS-less VM,
but a meaningful, non-zero `Latency` value needs actual I/O. Attach a small
bootable ISO (e.g. a minimal Linux distro) to one VM, boot it, and run a
simple disk-write loop (`dd if=/dev/zero of=testfile bs=1M count=100`) to
generate I/O while capturing the raw counter value:

```powershell
Get-Counter '\Hyper-V Virtual Storage Device(*)\Latency'
```

Compare the raw number against the write duration you observed manually to
confirm whether the unit is really 100ns ticks as documented, or something
else — this is the validation gate for enabling
`vm_storage_latency_high` in `terraform/detectors.tf`.

## 5. Install the real Splunk OTel Collector for Windows

Use Splunk's official Windows installer (PowerShell install script or MSI —
see the Splunk Distribution of the OpenTelemetry Collector documentation for
the current download link/script for your Splunk Observability Cloud realm).

Once installed, replace its config with
`otel-collector/hypervisor-host-config.yaml` from this repo. For a first
pass without needing real Splunk credentials, swap the `otlphttp/splunk`
exporter for a `debug` exporter (same technique as
`otel-collector/test/test-config.yaml`) so you can read real instance
strings and counter values directly from the Windows Event Viewer /
collector logs before wiring up real ingestion.

## 6. Validation checklist

- [ ] `Get-Counter -ListSet "Hyper-V*"` confirms all counter objects this
      repo depends on still exist on this Windows Server build
- [ ] Real per-VM instance strings match the formats assumed in
      `transform/vm_name` (CPU: `VMName:Hv VP N`; network:
      `VMName_Network Adapter_{GUID}`; storage: path containing
      `Virtual Hard Disks-VMName.vhdx`)
- [ ] Duplicate-named VM (`vm-alpha` x2) produces a `#1`-suffixed instance
      string, and the collector correctly strips it back to `vm-alpha`
- [ ] Raw `Latency` counter value cross-checked against manually-timed disk
      I/O to confirm/refute the 100ns-tick unit assumption (gap #5)
- [ ] `windowseventlogreceiver` successfully tails
      `Microsoft-Windows-Hyper-V-Hypervisor-Admin`,
      `-VMMS-Admin`, and `-Worker-Admin` channels without error
- [ ] (Stretch — requires a 2-node cluster, likely not worth the cost for
      this test) A genuine live-migration failure produces a real Event ID
      21026, confirmed against the `count/migration_failures` connector

## 7. Teardown

Nested Hyper-V test hosts are billed hourly — delete when done:

```
az group delete --name hyperv-test-rg --yes --no-wait
```
