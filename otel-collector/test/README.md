# Local test harness (no Windows host required)

Validates the two trickiest pieces of `../hypervisor-host-config.yaml` —
`transform/vm_name` extraction (including the Perfmon `#N` duplicate-suffix
fix, gap #6) and the `count/migration_failures` connector (gap #9) — using
plain Docker, with no Windows machine and no Splunk account/token needed.

## Why this exists

`windowsperfcounters` and `windowseventlogreceiver` only work on Windows —
neither can run in a Linux Docker container. `test-config.yaml` swaps those
two receivers for a plain `otlp` receiver but keeps every processor/connector
from the real config **verbatim**, so this is a true test of the transform
logic, not a reimplementation of it.

## Run it

```
docker run --rm -p 4318:4318 --name hyperv-test-otelcol \
  -v "$(pwd)/test-config.yaml:/etc/otelcol-contrib/config.yaml" \
  otel/opentelemetry-collector-contrib:latest
```

If port 4318 is already in use on your machine (e.g. another OTel collector
running), map to a different host port instead, e.g. `-p 4419:4318`, and edit
`ENDPOINT` at the top of `send_test_data.py` to match (`http://localhost:4419`).

In another terminal:

```
pip install requests
python3 send_test_data.py
```

Then read the collector's stdout (`docker logs -f hyperv-test-otelcol`) via the
`debug` exporter. Confirmed results from the last run:

| Synthetic instance string(s) | Resulting `host.name` |
|---|---|
| `WebServer:Hv VP 0`, `WebServer#1:Hv VP 0` | `WebServer` (deduped) |
| `SQLNode_Network Adapter_{GUID}`, `Default Switch_{GUID}` | `SQLNode` (`Default Switch` dropped) |
| `...Virtual Hard Disks-ProdDB.vhdx`, `...ProdDB#1.vhdx` | `ProdDB` (deduped) |
| `{GUID}.vmgs`, `install.iso` | dropped by `filter/vm_noise` |
| Synthetic Event ID 21026 | `hyperv.vmms.migration_failures` = 1 |

Stop the container with `docker stop hyperv-test-otelcol` when done.

## What this does NOT test

- Real Windows Perfmon counter availability/values on an actual Hyper-V host
- The `resourcedetection` processors (hostname auto-detection) — this harness
  hardcodes `hypervisor.host.name`
- Delivery to Splunk Observability Cloud — swap the `debug` exporter for
  `otlphttp/splunk` (see `../hypervisor-host-config.yaml`) with a real access
  token if you want to confirm end-to-end delivery into an org.
