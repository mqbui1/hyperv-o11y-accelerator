# =============================================================================
# Detectors mirroring the common Hyper-V failure modes referenced in the
# archived Splunk Add-on for Microsoft Hyper-V (VM health, hypervisor CPU,
# memory pressure, storage latency). Tune thresholds/durations per environment
# before rolling out to production.
# =============================================================================

resource "signalfx_detector" "vm_health_critical" {
  name = "Hyper-V: VM(s) in Critical Health"

  program_text = <<-EOF
    A = data('hyperv.health.critical', filter=filter('host.type', 'hypervisor')).sum(by=['host.name'])
    detect(when(A > 0)).publish('VM Health Critical')
  EOF

  rule {
    detect_label     = "VM Health Critical"
    severity          = "Critical"
    description       = "One or more VMs on this Hyper-V host reported Health Critical"
    notifications     = []
  }
}

resource "signalfx_detector" "hypervisor_cpu_high" {
  name = "Hyper-V: Hypervisor Host CPU Sustained High"

  program_text = <<-EOF
    A = data('hyperv.host_cpu.total_run_time', filter=filter('host.type', 'hypervisor')).mean(by=['host.name'])
    detect(when(A > 90, lasting='10m')).publish('Hypervisor CPU High')
  EOF

  rule {
    detect_label     = "Hypervisor CPU High"
    severity          = "Warning"
    description       = "Hyper-V host CPU run time above 90% for 10+ minutes"
    notifications     = []
  }
}

resource "signalfx_detector" "vm_memory_pressure_high" {
  name = "Hyper-V: VM Memory Pressure High"

  program_text = <<-EOF
    A = data('vm.memory.current_pressure', filter=filter('host.type', 'hypervisor_managed_vm')).mean(by=['host.name'])
    detect(when(A > 80, lasting='10m')).publish('VM Memory Pressure High')
  EOF

  rule {
    detect_label     = "VM Memory Pressure High"
    severity          = "Warning"
    description       = "Dynamic Memory pressure above 80% for 10+ minutes — VM may be memory-starved"
    notifications     = []
  }
}

resource "signalfx_detector" "vm_storage_latency_high" {
  # DO NOT ENABLE until the vm.storage.latency unit is confirmed against a raw
  # counter value in the target environment (documented by Microsoft as 100ns
  # ticks, but not independently verified). A wrong unit assumption here means
  # this threshold is either always-firing noise or silently useless. See
  # otel-collector/hypervisor-host-config.yaml and
  # docs/known-gaps-remediation.md, gap #5. Comment out this resource (or set
  # rule.disabled = true) until validated.
  name = "Hyper-V: VM Virtual Disk Latency High"

  program_text = <<-EOF
    A = data('vm.storage.latency', filter=filter('host.type', 'hypervisor_managed_vm')).mean(by=['host.name'])
    detect(when(A > 0.02, lasting='5m')).publish('VM Storage Latency High')
  EOF

  rule {
    detect_label     = "VM Storage Latency High"
    severity          = "Warning"
    description       = "Virtual disk IO latency above 20ms for 5+ minutes — VERIFY UNIT before relying on this (see gap #5)"
    disabled          = true
    notifications     = []
  }
}

resource "signalfx_detector" "vmms_migration_failures" {
  name = "Hyper-V: Live Migration Failures (VMMS Event 21026)"

  program_text = <<-EOF
    A = data('hyperv.vmms.migration_failures', filter=filter('host.type', 'hypervisor')).sum(by=['host.name']).sum(over='10m')
    detect(when(A > 0)).publish('VMMS Migration Failures')
  EOF

  rule {
    detect_label     = "VMMS Migration Failures"
    severity          = "Warning"
    description       = "One or more live-migration failures (Event ID 21026) on this host in the last 10m — root cause of elevated VMMS load in a real customer POC (docs/known-gaps-remediation.md, gap #9)"
    notifications     = []
  }
}
