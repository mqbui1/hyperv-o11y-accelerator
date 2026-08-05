#!/usr/bin/env python3
"""
Sends synthetic OTLP/HTTP data to the local test collector defined in
test-config.yaml, to validate the vm.name extraction logic (transform/vm_name)
and the VMMS-migration-failure count connector from
../hypervisor-host-config.yaml, without needing a real Windows Hyper-V host.

Only dependency: `requests` (pip install requests).

Usage:
    docker run --rm -p 4318:4318 \
      -v "$(pwd)/test-config.yaml:/etc/otelcol-contrib/config.yaml" \
      otel/opentelemetry-collector-contrib:latest
    python3 send_test_data.py

Then read the collector container's stdout — each metrics/vm datapoint
printed by the `debug` exporter should show a resource with host.name set to
the EXPECTED value noted in the comments below. A `hyperv.vmms.migration_failures`
metric with value 1 should also appear from the log test.
"""

import time
import requests

ENDPOINT = "http://localhost:4318"


def now_ns():
    return str(time.time_ns())


def metric_payload(metric_name, unit, instance_values):
    """One metric, one datapoint per instance string."""
    return {
        "resourceMetrics": [
            {
                "resource": {"attributes": []},
                "scopeMetrics": [
                    {
                        "scope": {},
                        "metrics": [
                            {
                                "name": metric_name,
                                "unit": unit,
                                "gauge": {
                                    "dataPoints": [
                                        {
                                            "asDouble": 42.0,
                                            "timeUnixNano": now_ns(),
                                            "attributes": [
                                                {
                                                    "key": "instance",
                                                    "value": {"stringValue": instance},
                                                }
                                            ],
                                        }
                                        for instance in instance_values
                                    ]
                                },
                            }
                        ],
                    }
                ],
            }
        ]
    }


def log_payload(event_id):
    return {
        "resourceLogs": [
            {
                "resource": {"attributes": []},
                "scopeLogs": [
                    {
                        "scope": {},
                        "logRecords": [
                            {
                                "timeUnixNano": now_ns(),
                                "attributes": [
                                    {
                                        "key": "winlog.event_id",
                                        "value": {"intValue": str(event_id)},
                                    }
                                ],
                                "body": {
                                    "stringValue": "Live migration failed (synthetic test event)"
                                },
                            }
                        ],
                    }
                ],
            }
        ]
    }


# --- Test cases for transform/vm_name (see known-gaps-remediation.md gap #6) ---

CPU_INSTANCES = [
    "WebServer:Hv VP 0",        # expect host.name = WebServer
    "WebServer#1:Hv VP 0",      # duplicate-suffix case -> expect host.name = WebServer
]

NETWORK_INSTANCES = [
    "SQLNode_Network Adapter_{AAAA-BBBB}",   # expect host.name = SQLNode
    "Default Switch_{CCCC-DDDD}",            # noise -> should be DROPPED (filter/vm_noise)
]

STORAGE_INSTANCES = [
    r"C:\VMs\Virtual Hard Disks-ProdDB.vhdx",     # expect host.name = ProdDB
    r"C:\VMs\Virtual Hard Disks-ProdDB#1.vhdx",   # duplicate-suffix on storage -> expect host.name = ProdDB
    r"C:\VMs\{GUID}.vmgs",                        # noise -> should be DROPPED
    r"D:\ISOs\install.iso",                        # noise -> should be DROPPED
]


def main():
    print("Sending CPU instances (expect WebServer x2, deduped by groupbyattrs)...")
    requests.post(
        f"{ENDPOINT}/v1/metrics",
        json=metric_payload("vm.cpu.total_run_time", "%", CPU_INSTANCES),
        timeout=5,
    )

    print("Sending network instances (expect SQLNode; Default Switch dropped)...")
    requests.post(
        f"{ENDPOINT}/v1/metrics",
        json=metric_payload("vm.net.bytes_total", "By/s", NETWORK_INSTANCES),
        timeout=5,
    )

    print("Sending storage instances (expect ProdDB x2; .vmgs/.iso dropped)...")
    requests.post(
        f"{ENDPOINT}/v1/metrics",
        json=metric_payload("vm.storage.read_bytes", "By/s", STORAGE_INSTANCES),
        timeout=5,
    )

    print("Sending a synthetic VMMS Event ID 21026 (expect hyperv.vmms.migration_failures=1)...")
    requests.post(f"{ENDPOINT}/v1/logs", json=log_payload(21026), timeout=5)

    print("\nDone. Check the collector container's stdout for the debug exporter output.")
    print("Verify each datapoint's resource host.name matches the 'expect' comment above,")
    print("and that a hyperv.vmms.migration_failures metric appears with value 1.")


if __name__ == "__main__":
    main()
