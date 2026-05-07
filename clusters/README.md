# Automated E2E Migration Pipeline

Once infrastructure is set up (see root [README.md](../README.md) Phases 1-4), you can run the full migration pipeline automatically using the Makefile in this directory.

## Quick Start

```bash
cd clusters

# Full pipeline with a random VM name
make run-e2e

# Full pipeline with a specific VM name and chaos scenario label
make run-e2e VM_NAME_OVERRIDE=my-test-vm CHAOS_SCENARIO=a4-kill-virt-handler

# Pause before migration (for manual chaos injection)
make run-e2e PAUSE_BEFORE_MIGRATION=true
```

## Pipeline Steps

The `run-e2e` target runs these steps in order:

| Step | Target | Description |
|------|--------|-------------|
| 1/6 | `create-vm` | Create a VM on source (blue) cluster from template |
| 2/6 | `setup` | SSH into VM, install workloads (file-writer, sqlite, http, cron) |
| 3/6 | `pre-check` | Capture baseline state as JSON |
| 4/6 | `migrate-vm` | Create MTV Plan + trigger live migration |
| 5/6 | *(built-in)* | Wait for migration to complete, collect metrics |
| 6/6 | `post-check` | Validate data integrity, compare with baseline |

Each step can also be run individually: `make create-vm`, `make setup`, etc.

## Logging Levels

The pipeline supports three verbosity tiers controlled by `LOG_LEVEL`:

| Level | Flag | Output |
|-------|------|--------|
| 1 (default) | — | Clean step summaries with PASS/FAIL |
| 2 (verbose) | `--verbose` | Substep detail, SSH retries, timing |
| 3 (debug) | `--debug` | Raw command traces with timestamps |

```bash
# Via environment variable
make run-e2e LOG_LEVEL=2

# Convenience aliases
make run-e2e-verbose    # LOG_LEVEL=2
make run-e2e-debug      # LOG_LEVEL=3

# Via CLI flags (run-e2e.sh directly)
./scripts/run-e2e.sh --source-kubeconfig ... --verbose
./scripts/run-e2e.sh --source-kubeconfig ... --debug
```

On failure, the last 30 lines of output are auto-expanded regardless of log level, with a pointer to the full log file.

ANSI colors auto-disable when output is piped or redirected (CI-safe).

## Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_LEVEL` | `1` | Logging verbosity (1=summary, 2=verbose, 3=debug) |
| `VM_NAME_OVERRIDE` | *(random)* | Fixed VM name instead of random |
| `NAMESPACE` | `default` | Target namespace |
| `PAUSE_BEFORE_MIGRATION` | `false` | Pause for manual intervention before step 4 |
| `CHAOS_SCENARIO` | *(empty)* | Label for chaos test in metrics JSON |
| `SKIP_PROMETHEUS_METRICS` | `false` | Skip Prometheus/VMIM metrics collection |
| `STABILIZE_WAIT` | `30` | Seconds to wait after workload setup |
| `LARGE_DATA_SIZE_MB` | `500` | Size of persistent test data file |
| `SSH_READY_TIMEOUT` | `600` | Max seconds to wait for guest SSH |

Run `make help` for the full list of targets and variables.

## Chaos Testing

Chaos trigger scripts are included for fault injection during migration:

```bash
# Auto-detect VM and kill virt-handler on destination
bash clusters/scripts/chaos-trigger.sh

# A4: Kill virt-handler on Green when VMIM reaches Running
bash clusters/scripts/chaos-trigger-a4.sh <vm-name>

# A5: Kill virt-controller on Green during early VMIM phase
bash clusters/scripts/chaos-trigger-a5.sh <vm-name>
```

These integrate with the logging system and show structured step/phase output.

## Reports

All runs produce JSON reports in `scripts/reports/`:

- `pre-migration-<vm>-<timestamp>.json` — baseline workload state
- `post-migration-<vm>-<timestamp>.json` — post-migration state + comparison
- `migration-metrics-<vm>-<timestamp>.json` — pipeline timings, pod restarts
- `prometheus-metrics-<vm>-<timestamp>.json` — Thanos/VMIM metrics

```bash
make list-reports       # list all reports
make clean-reports      # remove all reports
```
