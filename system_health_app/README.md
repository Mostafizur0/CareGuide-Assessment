# CareGuide System Health Monitor

A Linux automation script that collects system health metrics, appends a
timestamped JSON entry to a health log and reports the result through its exit
code so that monitoring tools such as Prometheus can act on it.

Built for the DevOps assessment task defined in [`Prompt.md`](Prompt.md).

## What it collects

| Metric | Source |
|---|---|
| CPU usage | `/proc/stat` aggregate counters, sampled twice |
| Memory usage | `/proc/meminfo` (`MemTotal`, `MemAvailable`, swap) |
| Disk usage | `df -P -T` for every mounted filesystem |
| Load average | `/proc/loadavg`, normalised against `nproc` |
| Top processes | `ps` sorted by resident set size |

## Requirements

- `bash` 4 or newer
- coreutils (`df`, `date`, `mktemp`, `mv`, `awk`)
- `procps` (`ps`, `nproc`)

No `jq` dependency: the JSON is produced by the script itself.

## Usage

```bash
./system_health.sh [OPTIONS]
```

| Option | Default | Purpose |
|---|---|---|
| `--cpu <pct>` | `90` | CPU usage warning threshold |
| `--mem <pct>` | `85` | Memory usage warning threshold |
| `--disk <pct>` | `80` | Disk usage warning threshold, per filesystem |
| `--top <n>` | `5` | Number of top processes to report |
| `--retention-days <n>` | `3` | Keep log entries for this many days |
| `--log-file <path>` | `health_log.txt` | Health log file |
| `--json` | off | Print the report as one JSON object on stdout |
| `--prometheus` | off | Write node_exporter textfile metrics |
| `--prometheus-dir <dir>` | `/var/lib/node_exporter/textfile_collector` | Directory for the `.prom` file |
| `--exclude-fs <list>` | `tmpfs,devtmpfs,proc,sysfs,cgroup,cgroup2,devpts,squashfs,overlay` | Filesystem types to skip |
| `--proc-root <dir>` | `/proc` | Read the `/proc` data from another directory |
| `--cpu-interval <s>` | `1` | Seconds between the two CPU samples |
| `-h`, `--help` | — | Show the help text |
| `--version` | — | Show the version |

Thresholds can also come from the environment, which is handy when the script is
called from cron or systemd:

| Variable | Default |
|---|---|
| `SYSTEM_HEALTH_CPU_THRESHOLD` | `90` |
| `SYSTEM_HEALTH_MEM_THRESHOLD` | `85` |
| `SYSTEM_HEALTH_DISK_THRESHOLD` | `80` |

A flag always wins over the environment variable.

### Examples

```bash
# Default run: human readable report on stdout, JSON line appended to health_log.txt
./system_health.sh

# Custom thresholds
./system_health.sh --disk 80 --cpu 90 --mem 85

# Machine readable report on stdout
./system_health.sh --json

# Prometheus textfile metrics for node_exporter
./system_health.sh --prometheus --prometheus-dir /var/lib/node_exporter/textfile_collector
```

## Exit codes

| Code | Meaning | Condition |
|---|---|---|
| `0` | healthy | Nothing was breached |
| `1` | warning | CPU, memory or a filesystem reached its threshold |
| `2` | critical | A hard failure: a filesystem is 100 % full, or no memory is available |
| `2` | invalid | The command line was not understood |

A critical result takes precedence over a warning: when both happen, the script
exits with `2`.

Warnings and critical findings are printed on **stderr**, one per line:

```
[WARNING] Memory usage 93.8% exceeds threshold 85%
[CRITICAL] No available memory (0 bytes available)
```

## Output

**stdout** carries the report: the human readable table by default, or a single
JSON object with `--json`. **stderr** carries only the findings.

The text report looks like this:

```
System Health Report - 2026-11-11T14:32:43Z
Hostname: node-01
Status: warning (exit 1)

CPU
  Usage        : 95.2% (threshold 90%)

Memory
  Total        : 15.3 GiB
  Available    : 1.0 GiB
  Usage        : 93.8% (threshold 85%)
  Swap used    : 0 B of 2.0 GiB

Load Average
  1m 0.52  5m 0.41  15m 0.33  (4 cores)

Disk Usage
  MOUNTPOINT               FSTYPE               SIZE         USED    AVAILABLE    USAGE
  /                        ext4            100.0 GiB     85.0 GiB     15.0 GiB      85%

Top 5 processes by memory
  PID               RSS     MEM%  COMMAND
  1234         120.5 MiB     7.7%  postgres
```

## Health log

Every run appends exactly **one JSON line** to the log file. The format is
JSON-lines, which is what Loki, Alloy and `jq` all read natively:

```json
{"timestamp":"2026-11-11T14:32:43Z","epoch":1794417163,"hostname":"node-01","status":"warning","exit_code":1,"cpu":{"usage_percent":95.2,"threshold_percent":90,"exceeded":true},"memory":{"total_bytes":16384000000,"available_bytes":1024000000,"usage_percent":93.8,"threshold_percent":85,"exceeded":true,"swap_total_bytes":2147483648,"swap_used_bytes":0},"load_average":{"1m":0.52,"5m":0.41,"15m":0.33,"cores":4},"disks":[{"mountpoint":"/","fstype":"ext4","size_bytes":107374182400,"used_bytes":91136000000,"available_bytes":16238182400,"usage_percent":85,"threshold_percent":80,"exceeded":true}],"top_processes_by_memory":[{"pid":1234,"command":"postgres","rss_bytes":126353408,"mem_percent":7.7}],"warnings":["[WARNING] Memory usage 93.8% exceeds threshold 85%"],"criticals":[]}
```

### Retention

Entries older than `--retention-days` (3 by default) are removed after every
run. The rewrite happens through a temporary file in the same directory that is
moved into place, so a reader never sees a truncated log. Entries without an
`epoch` field are kept.

## Prometheus metrics

With `--prometheus` the script writes `<prometheus-dir>/system_health.prom` in
the node_exporter textfile collector format. Point node_exporter at the
directory and the metrics appear in Prometheus:

```yaml
# /etc/node_exporter/node_exporter.service
ExecStart=/usr/local/bin/node_exporter \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

| Metric | Type | Labels |
|---|---|---|
| `system_health_cpu_usage_percent` | gauge | — |
| `system_health_memory_usage_percent` | gauge | — |
| `system_health_load_average` | gauge | `interval` (`1m`, `5m`, `15m`) |
| `system_health_disk_usage_percent` | gauge | `mountpoint`, `fstype` |
| `system_health_disk_size_bytes` | gauge | `mountpoint` |
| `system_health_disk_free_bytes` | gauge | `mountpoint` |
| `system_health_process_resident_memory_bytes` | gauge | `process` |
| `system_health_status` | gauge | — |

`system_health_status` is the direct counterpart of the exit code: `0` healthy,
`1` warning, `2` critical. It is the metric to alert on:

```yaml
groups:
  - name: system-health
    rules:
      - alert: SystemHealthWarning
        expr: system_health_status == 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "System health warning on {{ $labels.instance }}"
      - alert: SystemHealthCritical
        expr: system_health_status == 2
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "System health critical on {{ $labels.instance }}"
```

## Scheduling

### systemd (recommended)

```bash
sudo install -m 0755 system_health_app/system_health.sh /opt/system_health/system_health.sh
sudo install -d -m 0755 /var/log/system_health
sudo install -m 0644 system_health_app/systemd/system-health.service /etc/systemd/system/system-health.service
sudo install -m 0644 system_health_app/systemd/system-health.timer /etc/systemd/system/system-health.timer

sudo systemctl daemon-reload
sudo systemctl enable --now system-health.timer
sudo systemctl list-timers system-health.timer
```

The timer runs the service every 5 minutes (`OnUnitActiveSec=5min`). The
service is `Type=oneshot` and declares `SuccessExitStatus=1`, so a warning exit
does not mark the unit as failed — only a critical exit does.

### cron

```bash
sudo install -m 0755 system_health_app/system_health.sh /opt/system_health/system_health.sh
sudo install -d -m 0755 /var/log/system_health
sudo install -m 0644 system_health_app/cron/system-health.cron /etc/cron.d/system-health
```

The snippet runs every 5 minutes. A file in `/etc/cron.d` must include a user
field, which the snippet already does.

## Testing

The `fixtures/proc` directory holds fake `/proc` trees that make the script
deterministic, so the exit codes can be asserted without touching the real
system:

```bash
# healthy -> exit 0
./system_health.sh --proc-root system_health_app/fixtures/proc/healthy --cpu-interval 0

# warning -> exit 1
./system_health.sh --proc-root system_health_app/fixtures/proc/warning --cpu-interval 0

# critical -> exit 2
./system_health.sh --proc-root system_health_app/fixtures/proc/critical --cpu-interval 0
```

`--cpu-interval 0` skips the sleep, and the `stat_2` file in each fixture
supplies the second CPU sample, so the readings are identical on every run.

## Continuous integration

[`.github/workflows/system-health.yml`](.github/workflows/system-health.yml)
runs on every push that touches `system_health_app/`. It checks the syntax,
runs shellcheck at `--severity=style` and executes the functional suite above:
the three exit codes, the JSON output, the log growth, the retention pruning
and the Prometheus file.

```bash
shellcheck --severity=style system_health_app/system_health.sh
```

## Layout

```
system_health_app/
├── Prompt.md
├── README.md
├── system_health.sh              # the monitor
├── cron/system-health.cron       # /etc/cron.d snippet, every 5 minutes
├── systemd/
│   ├── system-health.service     # Type=oneshot
│   └── system-health.timer       # OnUnitActiveSec=5min
└── fixtures/proc/{healthy,warning,critical}/
    ├── stat                      # CPU counters, first sample
    ├── stat_2                    # CPU counters, second sample
    ├── meminfo
    ├── loadavg
    └── df                        # disk snapshot
```
