#!/usr/bin/env bash
set -Eeuo pipefail

DISK=80
CPU=90
MEM=85
JSON=false
LOG_FILE="${HEALTH_LOG_FILE:-"$(dirname -- "$0")/health_log.txt"}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --disk PCT   Disk usage threshold (default: 80)
  --cpu PCT    CPU usage threshold (default: 90)
  --mem PCT    Memory usage threshold (default: 85)
  --json       Output JSON
  --log PATH   Log file path
  --help       Show this help
EOF
}

error() {
    echo "Error: $*" >&2
    exit 2
}

while (($#)); do
    case "$1" in
        --disk|--cpu|--mem|--log)
            (($# >= 2)) || error "Missing value for $1"

            case "$1" in
                --disk) DISK=$2 ;;
                --cpu) CPU=$2 ;;
                --mem) MEM=$2 ;;
                --log) LOG_FILE=$2 ;;
            esac
            shift 2
            ;;
        --json)
            JSON=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done

for threshold in "$DISK" "$CPU" "$MEM"; do
  if [[ ! $threshold =~ ^[0-9]+$ ]] || ((threshold > 100)); then
    echo "Thresholds must be integers from 0 to 100" >&2
    exit 2
  fi
done

for cmd in awk df ps date tee wc mv mkdir; do
    command -v "$cmd" >/dev/null 2>&1 ||
        error "Required command not found: $cmd"
done

[[ -r /proc/meminfo && -r /proc/stat && -r /proc/loadavg ]] ||
    error "This script requires Linux /proc information"

mkdir -p "$(dirname -- "$LOG_FILE")" ||
    error "Cannot create log directory"

# Rotate log file when larger than 1 MB.
if [[ -f "$LOG_FILE" ]] &&
   (( $(wc -c < "$LOG_FILE") > 1048576 )); then
    mv -f -- "$LOG_FILE" "$LOG_FILE.1"
fi

stamp=$(date -Is)

load=$(awk '{print $1, $2, $3}' /proc/loadavg)

# Memory usage
read -r mem_total mem_avail < <(
    awk '
        /^MemTotal:/ { total=$2 }
        /^MemAvailable:/ { available=$2 }
        END { print total, available }
    ' /proc/meminfo
)

((mem_total > 0)) || error "Unable to read total memory"

mem_pct=$(( (100 * (mem_total - mem_avail)) / mem_total ))

# CPU usage using /proc/stat deltas
read -r cpu_total_1 cpu_idle_1 < <(
    awk '/^cpu / {
        total=0
        for (i=2; i<=NF; i++) total += $i
        print total, $5
        exit
    }' /proc/stat
)

sleep 1

read -r cpu_total_2 cpu_idle_2 < <(
    awk '/^cpu / {
        total=0
        for (i=2; i<=NF; i++) total += $i
        print total, $5
        exit
    }' /proc/stat
)

total_diff=$((cpu_total_2 - cpu_total_1))
idle_diff=$((cpu_idle_2 - cpu_idle_1))

if ((total_diff > 0)); then
    cpu_pct=$((100 * (total_diff - idle_diff) / total_diff))
else
    cpu_pct=0
fi

# Disk usage
disk_rows=$(
    df -P -x tmpfs -x devtmpfs |
    awk 'NR > 1 {
        gsub(/%/, "", $5)
        print $6, $5
    }'
)

# Top 5 memory-consuming processes
procs=$(
    ps -eo pid,comm,%mem --sort=-%mem |
    awk 'NR > 1 && NR <= 6 {
        printf "%s(pid=%s,mem=%s%%) ", $2, $1, $3
    }'
)

warnings=()
code=0

while read -r mount pct; do
    [[ -n "${mount:-}" ]] || continue

    if ((pct > 10#$DISK)); then
        warnings+=("disk $mount ${pct}% > ${DISK}%")
        code=1
    fi
done <<< "$disk_rows"

if ((cpu_pct > 10#$CPU)); then
    warnings+=("cpu ${cpu_pct}% > ${CPU}%")
    code=1
fi

if ((mem_pct > 10#$MEM)); then
    warnings+=("memory ${mem_pct}% > ${MEM}%")
    code=1
fi

status=healthy
((${#warnings[@]} == 0)) || status=warning

# JSON escaping helper
json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

if $JSON; then
    disk_json=""
    while read -r mount pct; do
        [[ -n "${mount:-}" ]] || continue

        disk_json+="${disk_json:+,}"
        disk_json+="{\"mount\":\"$(json_escape "$mount")\",\"usage_pct\":$pct}"
    done <<< "$disk_rows"

    warnings_json=""
    for warning in "${warnings[@]}"; do
        warnings_json+="${warnings_json:+,}"
        warnings_json+="\"$(json_escape "$warning")\""
    done

    record=$(printf \
        '{"timestamp":"%s","status":"%s","cpu_pct":%s,"memory_pct":%s,"load":"%s","disks":[%s],"top_processes":"%s","warnings":[%s]}' \
        "$(json_escape "$stamp")" \
        "$status" \
        "$cpu_pct" \
        "$mem_pct" \
        "$(json_escape "$load")" \
        "$disk_json" \
        "$(json_escape "$procs")" \
        "$warnings_json"
    )
else
    record="$stamp status=$status cpu=${cpu_pct}% memory=${mem_pct}% load=$load disks=[$(echo "$disk_rows" | tr '\n' ';')] top5=[$procs]"

    for warning in "${warnings[@]}"; do
        echo "[WARNING] $warning" >&2
    done
fi

echo "$record" | tee -a "$LOG_FILE"

exit "$code"
