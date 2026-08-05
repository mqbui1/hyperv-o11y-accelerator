# =============================================================================
# Charts + dashboards mirroring the vSphere navigator's host/VM split.
# Metric names here match otel-collector/hypervisor-host-config.yaml and
# guest-vm-config.yaml. Adjust filters/dimensions if you rename anything.
# =============================================================================

# ---------------------------------------------------------------------------
# Dashboard 1: Hypervisor Overview (Tier 1 — one row per Hyper-V host)
# ---------------------------------------------------------------------------

resource "signalfx_time_chart" "hypervisor_cpu" {
  name = "Hypervisor Host CPU (% Total Run Time)"

  program_text = <<-EOF
    A = data('hyperv.host_cpu.total_run_time', filter=filter('host.type', 'hypervisor')).mean(by=['host.name'])
    A.publish(label='Host CPU %')
  EOF

  time_range = 3600

  plot_type = "LineChart"
}

resource "signalfx_time_chart" "vm_health_critical" {
  name = "VMs in Critical Health (per Hyper-V host)"

  program_text = <<-EOF
    A = data('hyperv.health.critical', filter=filter('host.type', 'hypervisor')).sum(by=['host.name'])
    A.publish(label='VMs Critical')
  EOF

  time_range = 3600

  plot_type = "ColumnChart"
}

resource "signalfx_time_chart" "hypervisor_memory_pressure" {
  name = "Hypervisor Memory Pressure (%)"

  program_text = <<-EOF
    A = data('hyperv.memory.current_pressure', filter=filter('host.type', 'hypervisor')).mean(by=['host.name'])
    A.publish(label='Memory Pressure %')
  EOF

  time_range = 3600

  plot_type = "LineChart"
}

resource "signalfx_time_chart" "vswitch_throughput" {
  name = "Virtual Switch Throughput (bytes/sec)"

  program_text = <<-EOF
    A = data('hyperv.vswitch.bytes_total', filter=filter('host.type', 'hypervisor')).sum(by=['host.name'])
    A.publish(label='vSwitch Bytes/sec')
  EOF

  time_range = 3600

  plot_type = "AreaChart"
}

resource "signalfx_dashboard" "hypervisor_overview" {
  name            = "Hyper-V: Hypervisor Overview"
  dashboard_group = signalfx_dashboard_group.hyperv.id

  chart {
    chart_id = signalfx_time_chart.hypervisor_cpu.id
    row      = 0
    column   = 0
    width    = 6
    height   = 3
  }
  chart {
    chart_id = signalfx_time_chart.vm_health_critical.id
    row      = 0
    column   = 6
    width    = 6
    height   = 3
  }
  chart {
    chart_id = signalfx_time_chart.hypervisor_memory_pressure.id
    row      = 3
    column   = 0
    width    = 6
    height   = 3
  }
  chart {
    chart_id = signalfx_time_chart.vswitch_throughput.id
    row      = 3
    column   = 6
    width    = 6
    height   = 3
  }
}

# ---------------------------------------------------------------------------
# Dashboard 2: VM Detail (Tier 1 host-view metrics + Tier 2 in-guest metrics,
# both landing on the same host.name resource — see docs/architecture.md)
# ---------------------------------------------------------------------------

resource "signalfx_time_chart" "vm_cpu" {
  name = "VM CPU (% Total Run Time) — Tier 1: host-view"

  program_text = <<-EOF
    A = data('vm.cpu.total_run_time', filter=filter('host.type', 'hypervisor_managed_vm')).mean(by=['host.name'])
    A.publish(label='VM CPU %')
  EOF

  time_range = 3600

  plot_type = "LineChart"
}

resource "signalfx_time_chart" "vm_memory_pressure" {
  name = "VM Memory Pressure (%) — Tier 1: host-view"

  program_text = <<-EOF
    A = data('vm.memory.current_pressure', filter=filter('host.type', 'hypervisor_managed_vm')).mean(by=['host.name'])
    A.publish(label='VM Memory Pressure %')
  EOF

  time_range = 3600

  plot_type = "LineChart"
}

resource "signalfx_time_chart" "vm_storage_latency" {
  name = "VM Virtual Disk Latency (s) — Tier 1: host-view"

  program_text = <<-EOF
    A = data('vm.storage.latency', filter=filter('host.type', 'hypervisor_managed_vm')).mean(by=['host.name'])
    A.publish(label='Disk Latency (s)')
  EOF

  time_range = 3600

  plot_type = "LineChart"
}

resource "signalfx_time_chart" "vm_network_throughput" {
  name = "VM Network Throughput (bytes/sec) — Tier 1: host-view"

  program_text = <<-EOF
    A = data('vm.net.bytes_total', filter=filter('host.type', 'hypervisor_managed_vm')).sum(by=['host.name'])
    A.publish(label='vNIC Bytes/sec')
  EOF

  time_range = 3600

  plot_type = "AreaChart"
}

resource "signalfx_time_chart" "guest_disk_free" {
  name = "Guest Disk Free Space (%) — Tier 2 opt-in only: curated VM subset, requires guest-vm-config.yaml (see docs/known-gaps-remediation.md gap #4)"

  program_text = <<-EOF
    A = data('guest.disk.free_space', filter=filter('host.type', 'hypervisor_managed_vm')).mean(by=['host.name'])
    A.publish(label='Guest Disk Free %')
  EOF

  time_range = 3600

  plot_type = "LineChart"
}

resource "signalfx_dashboard" "vm_detail" {
  name            = "Hyper-V: VM Detail"
  dashboard_group = signalfx_dashboard_group.hyperv.id

  chart {
    chart_id = signalfx_time_chart.vm_cpu.id
    row      = 0
    column   = 0
    width    = 4
    height   = 3
  }
  chart {
    chart_id = signalfx_time_chart.vm_memory_pressure.id
    row      = 0
    column   = 4
    width    = 4
    height   = 3
  }
  chart {
    chart_id = signalfx_time_chart.vm_storage_latency.id
    row      = 0
    column   = 8
    width    = 4
    height   = 3
  }
  chart {
    chart_id = signalfx_time_chart.vm_network_throughput.id
    row      = 3
    column   = 0
    width    = 6
    height   = 3
  }
  chart {
    chart_id = signalfx_time_chart.guest_disk_free.id
    row      = 3
    column   = 6
    width    = 6
    height   = 3
  }
}
