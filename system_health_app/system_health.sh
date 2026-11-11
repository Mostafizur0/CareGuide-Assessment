#!/usr/bin/env bash
#
# system_health.sh - collect Linux system health metrics and report on them.
#
# The script collects CPU usage, memory usage, disk usage for every mounted
# filesystem, the load average and the top processes by memory. Every run
# appends one JSON line to the health log, optionally writes node_exporter
# textfile metrics and exits with a status that monitoring tools can act on:
#
#   0  healthy    nothing was breached
#   1  warning    a threshold was exceeded
#   2  critical   a hard failure was detected (or the invocation was invalid)
#
# Only bash 4+, coreutils, procps and awk are required.

set -euo pipefail
export LC_ALL=C

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.0.0"

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
DEFAULT_CPU_THRESHOLD=90
DEFAULT_MEM_THRESHOLD=85
DEFAULT_DISK_THRESHOLD=80
DEFAULT_TOP_N=5
DEFAULT_RETENTION_DAYS=3
DEFAULT_LOG_FILE="health_log.txt"
DEFAULT_PROMETHEUS_DIR="/var/lib/node_exporter/textfile_collector"
DEFAULT_PROC_ROOT="/proc"
DEFAULT_CPU_INTERVAL=1
DEFAULT_EXCLUDE_FS="tmpfs,devtmpfs,proc,sysfs,cgroup,cgroup2,devpts,squashfs,overlay"

# --------------------------------------------------------------------------
# Runtime configuration (overridden by the command line)
# --------------------------------------------------------------------------
CPU_THRESHOLD="$DEFAULT_CPU_THRESHOLD"
MEM_THRESHOLD="$DEFAULT_MEM_THRESHOLD"
DISK_THRESHOLD="$DEFAULT_DISK_THRESHOLD"
TOP_N="$DEFAULT_TOP_N"
RETENTION_DAYS="$DEFAULT_RETENTION_DAYS"
LOG_FILE="$DEFAULT_LOG_FILE"
PROMETHEUS_DIR="$DEFAULT_PROMETHEUS_DIR"
PROC_ROOT="$DEFAULT_PROC_ROOT"
CPU_INTERVAL="$DEFAULT_CPU_INTERVAL"
EXCLUDE_FS="$DEFAULT_EXCLUDE_FS"
JSON_OUTPUT=0
PROMETHEUS_OUTPUT=0

CPU_FROM_FLAG=0
MEM_FROM_FLAG=0
DISK_FROM_FLAG=0

# --------------------------------------------------------------------------
# Collected metrics
# --------------------------------------------------------------------------
CPU_USAGE="0.0"
CPU_EXCEEDED="false"
MEM_TOTAL=0
MEM_AVAILABLE=0
MEM_USAGE="0.0"
MEM_EXCEEDED="false"
SWAP_TOTAL=0
SWAP_USED=0
LOAD_1="0.00"
LOAD_5="0.00"
LOAD_15="0.00"
CPU_CORES=1
DISK_COUNT=0
PROC_COUNT=0

STATUS="healthy"
EXIT_CODE=0

declare -a DISK_MOUNT=()
declare -a DISK_FSTYPE=()
declare -a DISK_SIZE_BYTES=()
declare -a DISK_USED_BYTES=()
declare -a DISK_AVAIL_BYTES=()
declare -a DISK_USAGE=()
declare -a DISK_EXCEEDED=()
declare -a PROC_PID=()
declare -a PROC_CMD=()
declare -a PROC_RSS_BYTES=()
declare -a PROC_MEM_PERCENT=()
declare -a WARNINGS=()
declare -a CRITICALS=()
WARNING_COUNT=0
CRITICAL_COUNT=0

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
error() {
	printf '[ERROR] %s\n' "$*" >&2
}

usage() {
	cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Collect system health metrics, append a JSON entry to the health log and
report the result through the exit code.

Options:
  --cpu <pct>             CPU usage warning threshold      (default: ${DEFAULT_CPU_THRESHOLD})
  --mem <pct>             Memory usage warning threshold    (default: ${DEFAULT_MEM_THRESHOLD})
  --disk <pct>            Disk usage warning threshold     (default: ${DEFAULT_DISK_THRESHOLD})
  --top <n>               Number of top processes to report (default: ${DEFAULT_TOP_N})
  --retention-days <n>    Keep log entries for n days      (default: ${DEFAULT_RETENTION_DAYS})
  --log-file <path>       Health log file                  (default: ${DEFAULT_LOG_FILE})
  --json                  Print the report as one JSON object on stdout
  --prometheus            Write node_exporter textfile metrics
  --prometheus-dir <dir>  Directory for the .prom file     (default: ${DEFAULT_PROMETHEUS_DIR})
  --exclude-fs <list>     Comma separated filesystem types to skip
                          (default: ${DEFAULT_EXCLUDE_FS})
  --proc-root <dir>       Read the /proc data from <dir>   (default: ${DEFAULT_PROC_ROOT})
  --cpu-interval <s>      Seconds between the CPU samples  (default: ${DEFAULT_CPU_INTERVAL})
  -h, --help              Show this help and exit
  --version               Show the version and exit

Exit codes:
  0  healthy     no threshold was exceeded
  1  warning     a threshold was exceeded
  2  critical    a hard failure was detected (or the invocation was invalid)

Thresholds may also be set through the environment variables
SYSTEM_HEALTH_CPU_THRESHOLD, SYSTEM_HEALTH_MEM_THRESHOLD and
SYSTEM_HEALTH_DISK_THRESHOLD. Command line flags always take precedence.
EOF
}

usage_error() {
	error "$1"
	usage >&2
	exit 2
}

# Validate that a value is an integer inside an inclusive range.
is_integer_in_range() {
	local value="$1" low="$2" high="$3"

	case "$value" in
	'' | *[!0-9]*) return 1 ;;
	esac

	if [ "$value" -lt "$low" ] || [ "$value" -gt "$high" ]; then
		return 1
	fi

	return 0
}

# Compare two floating point numbers. Returns 0 when a >= b.
float_ge() {
	awk -v a="$1" -v b="$2" 'BEGIN { exit ((a + 0) >= (b + 0)) ? 0 : 1 }'
}

# Escape a string so it can be embedded in a JSON document.
json_escape() {
	local value="$1"

	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//$'\t'/\\t}"
	value="${value//$'\r'/\\r}"
	value="${value//$'\n'/\\n}"

	printf '%s' "$value"
}

# Escape a value so it can be used inside a Prometheus label.
prom_escape() {
	local value="$1"

	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//$'\n'/\\n}"

	printf '%s' "$value"
}

# Render a byte count in a human readable form.
human_bytes() {
	awk -v bytes="$1" 'BEGIN {
		split("B KiB MiB GiB TiB PiB", unit, " ");
		value = bytes + 0;
		slot = 1;
		while (value >= 1024 && slot < 6) {
			value = value / 1024;
			slot++;
		}
		if (slot == 1) {
			printf "%d %s", value, unit[slot];
		} else {
			printf "%.1f %s", value, unit[slot];
		}
	}'
}

# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------
parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--cpu)
			[ "$#" -ge 2 ] || usage_error "option --cpu requires a value"
			is_integer_in_range "$2" 1 100 || usage_error "--cpu must be an integer between 1 and 100"
			CPU_THRESHOLD="$2"
			CPU_FROM_FLAG=1
			shift 2
			;;
		--mem)
			[ "$#" -ge 2 ] || usage_error "option --mem requires a value"
			is_integer_in_range "$2" 1 100 || usage_error "--mem must be an integer between 1 and 100"
			MEM_THRESHOLD="$2"
			MEM_FROM_FLAG=1
			shift 2
			;;
		--disk)
			[ "$#" -ge 2 ] || usage_error "option --disk requires a value"
			is_integer_in_range "$2" 1 100 || usage_error "--disk must be an integer between 1 and 100"
			DISK_THRESHOLD="$2"
			DISK_FROM_FLAG=1
			shift 2
			;;
		--top)
			[ "$#" -ge 2 ] || usage_error "option --top requires a value"
			is_integer_in_range "$2" 1 100 || usage_error "--top must be an integer between 1 and 100"
			TOP_N="$2"
			shift 2
			;;
		--retention-days)
			[ "$#" -ge 2 ] || usage_error "option --retention-days requires a value"
			is_integer_in_range "$2" 1 3650 || usage_error "--retention-days must be an integer between 1 and 3650"
			RETENTION_DAYS="$2"
			shift 2
			;;
		--log-file)
			[ "$#" -ge 2 ] || usage_error "option --log-file requires a value"
			LOG_FILE="$2"
			shift 2
			;;
		--prometheus-dir)
			[ "$#" -ge 2 ] || usage_error "option --prometheus-dir requires a value"
			PROMETHEUS_DIR="$2"
			shift 2
			;;
		--exclude-fs)
			[ "$#" -ge 2 ] || usage_error "option --exclude-fs requires a value"
			EXCLUDE_FS="$2"
			shift 2
			;;
		--proc-root)
			[ "$#" -ge 2 ] || usage_error "option --proc-root requires a value"
			PROC_ROOT="$2"
			shift 2
			;;
		--cpu-interval)
			[ "$#" -ge 2 ] || usage_error "option --cpu-interval requires a value"
			is_integer_in_range "$2" 0 3600 || usage_error "--cpu-interval must be an integer between 0 and 3600"
			CPU_INTERVAL="$2"
			shift 2
			;;
		--json)
			JSON_OUTPUT=1
			shift
			;;
		--prometheus)
			PROMETHEUS_OUTPUT=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		--version)
			printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
			exit 0
			;;
		*)
			usage_error "unknown option: $1"
			;;
		esac
	done
}

# The environment is only consulted for thresholds that were not given as a
# flag, so a flag always wins over the environment.
resolve_threshold_from_env() {
	local env_name="$1" env_value="$2" default_value="$3" resolved

	if [ -n "$env_value" ]; then
		is_integer_in_range "$env_value" 1 100 || usage_error "${env_name} must be an integer between 1 and 100"
		resolved="$env_value"
	else
		resolved="$default_value"
	fi

	printf '%s' "$resolved"
}

resolve_thresholds() {
	if [ "$CPU_FROM_FLAG" -eq 0 ]; then
		CPU_THRESHOLD=$(resolve_threshold_from_env "SYSTEM_HEALTH_CPU_THRESHOLD" "${SYSTEM_HEALTH_CPU_THRESHOLD:-}" "$DEFAULT_CPU_THRESHOLD")
	fi

	if [ "$MEM_FROM_FLAG" -eq 0 ]; then
		MEM_THRESHOLD=$(resolve_threshold_from_env "SYSTEM_HEALTH_MEM_THRESHOLD" "${SYSTEM_HEALTH_MEM_THRESHOLD:-}" "$DEFAULT_MEM_THRESHOLD")
	fi

	if [ "$DISK_FROM_FLAG" -eq 0 ]; then
		DISK_THRESHOLD=$(resolve_threshold_from_env "SYSTEM_HEALTH_DISK_THRESHOLD" "${SYSTEM_HEALTH_DISK_THRESHOLD:-}" "$DEFAULT_DISK_THRESHOLD")
	fi
}

# --------------------------------------------------------------------------
# Collectors
# --------------------------------------------------------------------------

# Echo "<total> <idle>" for the aggregate CPU counters of a proc stat file.
read_cpu_counters() {
	local stat_file="$1" line total idle

	[ -r "$stat_file" ] || return 1

	if ! line=$(awk '/^cpu[ ]/ { print; exit }' "$stat_file"); then
		return 1
	fi

	[ -n "$line" ] || return 1

	total=$(awk '{ sum = 0; for (i = 2; i <= NF; i++) sum += $i; print sum }' <<<"$line")
	idle=$(awk '{ print $5 + $6 }' <<<"$line")

	[ -n "$total" ] || return 1
	[ -n "$idle" ] || return 1

	printf '%s %s\n' "$total" "$idle"
}

collect_cpu_usage() {
	local stat_file="${PROC_ROOT}/stat"
	local stat_file_next="${PROC_ROOT}/stat_2"
	local first="" second="" usage=""

	first=$(read_cpu_counters "$stat_file" || true)

	if [ "$CPU_INTERVAL" -gt 0 ]; then
		sleep "$CPU_INTERVAL"
	fi

	# A second sample file makes the CPU reading deterministic for fixtures.
	if [ -r "$stat_file_next" ]; then
		second=$(read_cpu_counters "$stat_file_next" || true)
	else
		second=$(read_cpu_counters "$stat_file" || true)
	fi

	if [ -n "$first" ] && [ -n "$second" ]; then
		usage=$(awk -v first="$first" -v second="$second" 'BEGIN {
			split(first, a, " ");
			split(second, b, " ");
			total_delta = b[1] - a[1];
			idle_delta = b[2] - a[2];
			if (total_delta <= 0) {
				print "0.0";
				exit;
			}
			value = 100 * (1 - idle_delta / total_delta);
			if (value < 0) value = 0;
			if (value > 100) value = 100;
			printf "%.1f", value;
		}')
		CPU_USAGE="$usage"
		return 0
	fi

	# Fall back to vmstat when the proc file is not readable.
	local vmstat_output=""
	if vmstat_output=$(vmstat 1 2 2>/dev/null); then
		CPU_USAGE=$(awk 'END {
			if (NF >= 15) {
				printf "%.1f", 100 - $15;
			} else {
				print "0.0";
			}
		}' <<<"$vmstat_output")
	else
		CPU_USAGE="0.0"
	fi
}

collect_memory() {
	local meminfo="${PROC_ROOT}/meminfo"
	local total="" available="" swap_total="" swap_free=""
	local fallback=""

	if [ ! -r "$meminfo" ]; then
		return 0
	fi

	total=$(awk '/^MemTotal:/ { print $2; exit }' "$meminfo")
	available=$(awk '/^MemAvailable:/ { print $2; exit }' "$meminfo")
	swap_total=$(awk '/^SwapTotal:/ { print $2; exit }' "$meminfo")
	swap_free=$(awk '/^SwapFree:/ { print $2; exit }' "$meminfo")

	if [ -z "$available" ]; then
		fallback=$(awk '
			/^MemFree:/ { free = $2 }
			/^Buffers:/ { buffers = $2 }
			/^Cached:/ { cached = $2 }
			END { print free + buffers + cached }
		' "$meminfo")
		available="$fallback"
	fi

	# Without any usable value the safest assumption is that memory is
	# available; claiming otherwise would raise a false critical.
	if [ -z "$available" ]; then
		available="$total"
	fi

	if [ -z "$swap_free" ]; then
		swap_free="$swap_total"
	fi

	MEM_TOTAL=$(( ${total:-0} * 1024 ))
	MEM_AVAILABLE=$(( ${available:-0} * 1024 ))
	SWAP_TOTAL=$(( ${swap_total:-0} * 1024 ))
	SWAP_USED=$(( (${swap_total:-0} - ${swap_free:-0}) * 1024 ))

	if [ "$MEM_TOTAL" -gt 0 ]; then
		MEM_USAGE=$(awk -v total="$MEM_TOTAL" -v available="$MEM_AVAILABLE" 'BEGIN {
			value = 100 * (1 - available / total);
			if (value < 0) value = 0;
			if (value > 100) value = 100;
			printf "%.1f", value;
		}')
	else
		MEM_USAGE="0.0"
	fi
}

collect_disks() {
	local raw="" has_type=0
	local line="" fstype="" size="" used="" available="" capacity="" mountpoint=""
	local usage=""

	DISK_COUNT=0

	# A df snapshot inside the proc root makes the disk report deterministic.
	if [ -r "${PROC_ROOT}/df" ]; then
		raw=$(cat "${PROC_ROOT}/df")
		has_type=1
	elif raw=$(df -P -T 2>/dev/null); then
		has_type=1
	else
		raw=$(df -P 2>/dev/null || true)
	fi

	[ -n "$raw" ] || return 0

	while IFS=$'\t' read -r fstype size used available capacity mountpoint; do
		[ -n "$mountpoint" ] || continue
		[ -n "$size" ] || continue
		case "$size" in
		'' | *[!0-9]*) continue ;;
		esac
		case "$used" in
		'' | *[!0-9]*) used=0 ;;
		esac
		case "$available" in
		'' | *[!0-9]*) available=0 ;;
		esac

		if [ -n "$EXCLUDE_FS" ]; then
			case ",${EXCLUDE_FS}," in
			*",${fstype},"*) continue ;;
			esac
		fi

		usage="${capacity%%%}"
		case "$usage" in
		'' | *[!0-9.]*) usage="0.0" ;;
		esac

		DISK_MOUNT[DISK_COUNT]="$mountpoint"
		DISK_FSTYPE[DISK_COUNT]="$fstype"
		DISK_SIZE_BYTES[DISK_COUNT]=$(( size * 1024 ))
		DISK_USED_BYTES[DISK_COUNT]=$(( used * 1024 ))
		DISK_AVAIL_BYTES[DISK_COUNT]=$(( available * 1024 ))
		DISK_USAGE[DISK_COUNT]="$usage"
		DISK_EXCEEDED[DISK_COUNT]="false"
		DISK_COUNT=$(( DISK_COUNT + 1 ))
	done < <(
		printf '%s\n' "$raw" | awk -v has_type="$has_type" 'NR > 1 {
			if (has_type == 1) {
				fstype = $2; size = $3; used = $4; available = $5; capacity = $6; start = 7;
			} else {
				fstype = "unknown"; size = $2; used = $3; available = $4; capacity = $5; start = 6;
			}
			mountpoint = "";
			for (i = start; i <= NF; i++) {
				mountpoint = (i == start ? $i : mountpoint " " $i);
			}
			printf "%s\t%s\t%s\t%s\t%s\t%s\n", fstype, size, used, available, capacity, mountpoint;
		}'
	)
}

collect_load() {
	local loadavg="${PROC_ROOT}/loadavg"
	local cores=""

	if [ -r "$loadavg" ]; then
		local one="" five="" fifteen="" rest=""
		read -r one five fifteen rest < "$loadavg" || true
		LOAD_1=$(printf '%.2f' "${one:-0}")
		LOAD_5=$(printf '%.2f' "${five:-0}")
		LOAD_15=$(printf '%.2f' "${fifteen:-0}")
	fi

	if cores=$(nproc 2>/dev/null); then
		CPU_CORES="$cores"
	elif cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null); then
		CPU_CORES="$cores"
	else
		CPU_CORES=1
	fi
}

collect_top_processes() {
	local output=""

	PROC_COUNT=0

	if output=$(ps -eo pid=,rss=,%mem=,comm= --sort=-rss 2>/dev/null); then
		:
	elif output=$(ps -eo pid=,rss=,%mem=,comm= 2>/dev/null); then
		output=$(printf '%s\n' "$output" | sort -k2 -nr)
	else
		return 0
	fi

	local line="" pid="" rss="" mem="" command=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		pid=$(awk '{ print $1 }' <<<"$line")
		rss=$(awk '{ print $2 }' <<<"$line")
		mem=$(awk '{ print $3 }' <<<"$line")
		command=$(awk '{ $1 = ""; $2 = ""; $3 = ""; sub(/^[ \t]+/, ""); print }' <<<"$line")
		[ -n "$pid" ] || continue
		case "$rss" in
		'' | *[!0-9]*) rss=0 ;;
		esac
		case "$mem" in
		'' | *[!0-9.]*) mem="0.0" ;;
		esac
		[ -n "$command" ] || command="unknown"

		PROC_PID[PROC_COUNT]="$pid"
		PROC_CMD[PROC_COUNT]="$command"
		PROC_RSS_BYTES[PROC_COUNT]=$(( rss * 1024 ))
		PROC_MEM_PERCENT[PROC_COUNT]="$mem"
		PROC_COUNT=$(( PROC_COUNT + 1 ))
	done < <(head -n "$TOP_N" <<<"$output")
}

collect_metrics() {
	collect_cpu_usage
	collect_memory
	collect_disks
	collect_load
	collect_top_processes
}

# --------------------------------------------------------------------------
# Evaluation
# --------------------------------------------------------------------------
add_warning() {
	WARNINGS[WARNING_COUNT]="$1"
	WARNING_COUNT=$(( WARNING_COUNT + 1 ))
}

add_critical() {
	CRITICALS[CRITICAL_COUNT]="$1"
	CRITICAL_COUNT=$(( CRITICAL_COUNT + 1 ))
}

evaluate_metrics() {
	local index=0

	# Hard failures are checked first: they take precedence over warnings.
	if [ "$MEM_TOTAL" -gt 0 ] && [ "$MEM_AVAILABLE" -eq 0 ]; then
		add_critical "[CRITICAL] No available memory (0 bytes available)"
	fi

	for (( index = 0; index < DISK_COUNT; index++ )); do
		if float_ge "${DISK_USAGE[index]}" 100 && [ "${DISK_AVAIL_BYTES[index]}" -eq 0 ]; then
			add_critical "[CRITICAL] Filesystem ${DISK_MOUNT[index]} is full (100% used, 0 bytes available)"
		fi
	done

	if float_ge "$CPU_USAGE" "$CPU_THRESHOLD"; then
		CPU_EXCEEDED="true"
		add_warning "[WARNING] CPU usage ${CPU_USAGE}% exceeds threshold ${CPU_THRESHOLD}%"
	fi

	if float_ge "$MEM_USAGE" "$MEM_THRESHOLD"; then
		MEM_EXCEEDED="true"
		add_warning "[WARNING] Memory usage ${MEM_USAGE}% exceeds threshold ${MEM_THRESHOLD}%"
	fi

	for (( index = 0; index < DISK_COUNT; index++ )); do
		if float_ge "${DISK_USAGE[index]}" "$DISK_THRESHOLD"; then
			DISK_EXCEEDED[index]="true"
			add_warning "[WARNING] Disk usage ${DISK_USAGE[index]}% on ${DISK_MOUNT[index]} exceeds threshold ${DISK_THRESHOLD}%"
		fi
	done

	if [ "$CRITICAL_COUNT" -gt 0 ]; then
		STATUS="critical"
		EXIT_CODE=2
	elif [ "$WARNING_COUNT" -gt 0 ]; then
		STATUS="warning"
		EXIT_CODE=1
	else
		STATUS="healthy"
		EXIT_CODE=0
	fi
}

print_findings() {
	local index=0

	for (( index = 0; index < CRITICAL_COUNT; index++ )); do
		printf '%s\n' "${CRITICALS[index]}" >&2
	done

	for (( index = 0; index < WARNING_COUNT; index++ )); do
		printf '%s\n' "${WARNINGS[index]}" >&2
	done
}

# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------
build_json() {
	local timestamp="$1" epoch="$2" hostname="$3"
	local out="" index=0 body=""

	out="{\"timestamp\":\"$(json_escape "$timestamp")\""
	out="${out},\"epoch\":${epoch}"
	out="${out},\"hostname\":\"$(json_escape "$hostname")\""
	out="${out},\"status\":\"$(json_escape "$STATUS")\""
	out="${out},\"exit_code\":${EXIT_CODE}"

	out="${out},\"cpu\":{\"usage_percent\":${CPU_USAGE},\"threshold_percent\":${CPU_THRESHOLD},\"exceeded\":${CPU_EXCEEDED}}"
	out="${out},\"memory\":{\"total_bytes\":${MEM_TOTAL},\"available_bytes\":${MEM_AVAILABLE},\"usage_percent\":${MEM_USAGE},\"threshold_percent\":${MEM_THRESHOLD},\"exceeded\":${MEM_EXCEEDED},\"swap_total_bytes\":${SWAP_TOTAL},\"swap_used_bytes\":${SWAP_USED}}"
	out="${out},\"load_average\":{\"1m\":${LOAD_1},\"5m\":${LOAD_5},\"15m\":${LOAD_15},\"cores\":${CPU_CORES}}"

	body=""
	for (( index = 0; index < DISK_COUNT; index++ )); do
		if [ -n "$body" ]; then
			body="${body},"
		fi
		body="${body}{\"mountpoint\":\"$(json_escape "${DISK_MOUNT[index]}")\""
		body="${body},\"fstype\":\"$(json_escape "${DISK_FSTYPE[index]}")\""
		body="${body},\"size_bytes\":${DISK_SIZE_BYTES[index]}"
		body="${body},\"used_bytes\":${DISK_USED_BYTES[index]}"
		body="${body},\"available_bytes\":${DISK_AVAIL_BYTES[index]}"
		body="${body},\"usage_percent\":${DISK_USAGE[index]}"
		body="${body},\"threshold_percent\":${DISK_THRESHOLD}"
		body="${body},\"exceeded\":${DISK_EXCEEDED[index]}}"
	done
	out="${out},\"disks\":[${body}]"

	body=""
	for (( index = 0; index < PROC_COUNT; index++ )); do
		if [ -n "$body" ]; then
			body="${body},"
		fi
		body="${body}{\"pid\":${PROC_PID[index]}"
		body="${body},\"command\":\"$(json_escape "${PROC_CMD[index]}")\""
		body="${body},\"rss_bytes\":${PROC_RSS_BYTES[index]}"
		body="${body},\"mem_percent\":${PROC_MEM_PERCENT[index]}}"
	done
	out="${out},\"top_processes_by_memory\":[${body}]"

	body=""
	for (( index = 0; index < WARNING_COUNT; index++ )); do
		if [ -n "$body" ]; then
			body="${body},"
		fi
		body="${body}\"$(json_escape "${WARNINGS[index]}")\""
	done
	out="${out},\"warnings\":[${body}]"

	body=""
	for (( index = 0; index < CRITICAL_COUNT; index++ )); do
		if [ -n "$body" ]; then
			body="${body},"
		fi
		body="${body}\"$(json_escape "${CRITICALS[index]}")\""
	done
	out="${out},\"criticals\":[${body}]}"

	printf '%s' "$out"
}

render_text_report() {
	local timestamp="$1" hostname="$2"
	local index=0

	printf 'System Health Report - %s\n' "$timestamp"
	printf 'Hostname: %s\n' "$hostname"
	printf 'Status: %s (exit %s)\n' "$STATUS" "$EXIT_CODE"
	printf '\n'
	printf 'CPU\n'
	printf '  Usage        : %s%% (threshold %s%%)\n' "$CPU_USAGE" "$CPU_THRESHOLD"
	printf '\n'
	printf 'Memory\n'
	printf '  Total        : %s\n' "$(human_bytes "$MEM_TOTAL")"
	printf '  Available    : %s\n' "$(human_bytes "$MEM_AVAILABLE")"
	printf '  Usage        : %s%% (threshold %s%%)\n' "$MEM_USAGE" "$MEM_THRESHOLD"
	printf '  Swap used    : %s of %s\n' "$(human_bytes "$SWAP_USED")" "$(human_bytes "$SWAP_TOTAL")"
	printf '\n'
	printf 'Load Average\n'
	printf '  1m %s  5m %s  15m %s  (%s cores)\n' "$LOAD_1" "$LOAD_5" "$LOAD_15" "$CPU_CORES"
	printf '\n'
	printf 'Disk Usage\n'
	printf '  %-24s %-12s %12s %12s %12s %8s\n' "MOUNTPOINT" "FSTYPE" "SIZE" "USED" "AVAILABLE" "USAGE"

	if [ "$DISK_COUNT" -eq 0 ]; then
		printf '  %s\n' "(no mounted filesystems matched)"
	else
		for (( index = 0; index < DISK_COUNT; index++ )); do
			printf '  %-24s %-12s %12s %12s %12s %7s%%\n' \
				"${DISK_MOUNT[index]}" \
				"${DISK_FSTYPE[index]}" \
				"$(human_bytes "${DISK_SIZE_BYTES[index]}")" \
				"$(human_bytes "${DISK_USED_BYTES[index]}")" \
				"$(human_bytes "${DISK_AVAIL_BYTES[index]}")" \
				"${DISK_USAGE[index]}"
		done
	fi

	printf '\n'
	printf 'Top %s processes by memory\n' "$TOP_N"

	if [ "$PROC_COUNT" -eq 0 ]; then
		printf '  %s\n' "(no process information available)"
	else
		printf '  %-8s %12s %8s  %s\n' "PID" "RSS" "MEM%" "COMMAND"
		for (( index = 0; index < PROC_COUNT; index++ )); do
			printf '  %-8s %12s %7s%%  %s\n' \
				"${PROC_PID[index]}" \
				"$(human_bytes "${PROC_RSS_BYTES[index]}")" \
				"${PROC_MEM_PERCENT[index]}" \
				"${PROC_CMD[index]}"
		done
	fi
}

# --------------------------------------------------------------------------
# Logging and retention
# --------------------------------------------------------------------------
append_to_log() {
	local entry="$1"
	local directory=""

	directory=$(dirname "$LOG_FILE")
	if ! mkdir -p "$directory" 2>/dev/null; then
		error "cannot create the log directory: ${directory}"
		return 1
	fi

	printf '%s\n' "$entry" >>"$LOG_FILE"
}

prune_log() {
	local cutoff="$1"
	local temporary=""

	[ -f "$LOG_FILE" ] || return 0

	temporary=$(mktemp "${LOG_FILE}.XXXXXX") || {
		error "cannot create a temporary file next to ${LOG_FILE}"
		return 1
	}

	awk -v cutoff="$cutoff" '
		{
			if (match($0, /"epoch":[0-9]+/) > 0) {
				epoch = substr($0, RSTART + 8, RLENGTH - 8) + 0;
				if (epoch >= cutoff) {
					print;
				}
			} else {
				print;
			}
		}
	' "$LOG_FILE" >"$temporary"

	chmod 0644 "$temporary" || true
	mv -f "$temporary" "$LOG_FILE"
}

# --------------------------------------------------------------------------
# Prometheus textfile metrics
# --------------------------------------------------------------------------
write_prometheus_metrics() {
	local temporary=""
	local index=0
	local seen_names=""

	if ! mkdir -p "$PROMETHEUS_DIR" 2>/dev/null; then
		error "cannot create the prometheus output directory: ${PROMETHEUS_DIR}"
		exit 2
	fi

	temporary=$(mktemp "${PROMETHEUS_DIR}/.system_health.prom.XXXXXX") || {
		error "cannot create a temporary file in ${PROMETHEUS_DIR}"
		exit 2
	}

	{
		printf '# HELP system_health_cpu_usage_percent Current CPU usage percentage.\n'
		printf '# TYPE system_health_cpu_usage_percent gauge\n'
		printf 'system_health_cpu_usage_percent %s\n' "$CPU_USAGE"

		printf '# HELP system_health_memory_usage_percent Current memory usage percentage.\n'
		printf '# TYPE system_health_memory_usage_percent gauge\n'
		printf 'system_health_memory_usage_percent %s\n' "$MEM_USAGE"

		printf '# HELP system_health_load_average Load average over the given interval.\n'
		printf '# TYPE system_health_load_average gauge\n'
		printf 'system_health_load_average{interval="1m"} %s\n' "$LOAD_1"
		printf 'system_health_load_average{interval="5m"} %s\n' "$LOAD_5"
		printf 'system_health_load_average{interval="15m"} %s\n' "$LOAD_15"

		printf '# HELP system_health_disk_usage_percent Disk usage percentage per mountpoint.\n'
		printf '# TYPE system_health_disk_usage_percent gauge\n'
		for (( index = 0; index < DISK_COUNT; index++ )); do
			printf 'system_health_disk_usage_percent{mountpoint="%s",fstype="%s"} %s\n' \
				"$(prom_escape "${DISK_MOUNT[index]}")" \
				"$(prom_escape "${DISK_FSTYPE[index]}")" \
				"${DISK_USAGE[index]}"
		done

		printf '# HELP system_health_disk_size_bytes Total size of the filesystem in bytes.\n'
		printf '# TYPE system_health_disk_size_bytes gauge\n'
		for (( index = 0; index < DISK_COUNT; index++ )); do
			printf 'system_health_disk_size_bytes{mountpoint="%s"} %d\n' \
				"$(prom_escape "${DISK_MOUNT[index]}")" \
				"${DISK_SIZE_BYTES[index]}"
		done

		printf '# HELP system_health_disk_free_bytes Available space of the filesystem in bytes.\n'
		printf '# TYPE system_health_disk_free_bytes gauge\n'
		for (( index = 0; index < DISK_COUNT; index++ )); do
			printf 'system_health_disk_free_bytes{mountpoint="%s"} %d\n' \
				"$(prom_escape "${DISK_MOUNT[index]}")" \
				"${DISK_AVAIL_BYTES[index]}"
		done

		printf '# HELP system_health_process_resident_memory_bytes Resident memory of the heaviest process per command.\n'
		printf '# TYPE system_health_process_resident_memory_bytes gauge\n'
		for (( index = 0; index < PROC_COUNT; index++ )); do
			case ",${seen_names}," in
			*",${PROC_CMD[index]},"*) continue ;;
			esac
			seen_names="${seen_names},${PROC_CMD[index]}"
			printf 'system_health_process_resident_memory_bytes{process="%s"} %d\n' \
				"$(prom_escape "${PROC_CMD[index]}")" \
				"${PROC_RSS_BYTES[index]}"
		done

		printf '# HELP system_health_status Health status: 0 healthy, 1 warning, 2 critical.\n'
		printf '# TYPE system_health_status gauge\n'
		printf 'system_health_status %s\n' "$EXIT_CODE"
	} >"$temporary"

	mv -f "$temporary" "${PROMETHEUS_DIR}/system_health.prom"
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
main() {
	parse_args "$@"
	resolve_thresholds
	collect_metrics
	evaluate_metrics

	local timestamp="" epoch="" hostname=""
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	epoch=$(date +%s)
	hostname=$(uname -n 2>/dev/null || printf 'unknown')

	local entry=""
	entry=$(build_json "$timestamp" "$epoch" "$hostname")

	if [ "$JSON_OUTPUT" -eq 1 ]; then
		printf '%s\n' "$entry"
	else
		render_text_report "$timestamp" "$hostname"
	fi

	print_findings

	append_to_log "$entry"
	prune_log "$(( epoch - RETENTION_DAYS * 86400 ))"

	if [ "$PROMETHEUS_OUTPUT" -eq 1 ]; then
		write_prometheus_metrics
	fi

	exit "$EXIT_CODE"
}

main "$@"
