write a Linux Automation Scripting app in bash with below features:
script name will be system_health.sh
it will collect Collect CPU usage, memory usage, disk usage (all mounted filesystems), load average, and the top 5 processes by memory
Append a timestamped entry to health_log.txt, with an option to output JSON (--json) and retension period of 3 days
Accept configurable thresholds via flags (e.g. --disk 80 --cpu 90 --mem 85) with sensible defaults, and print [WARNING] messages when any threshold is exceeded.
Return meaningful exit codes (0 = healthy, 1 = warning, 2 = critical) so it can be used by monitoring tools like prometheous.
Use set -euo pipefail, pass shellcheck with no warnings, and include a --help option
Provide a cron entry or a systemd service + timer to run it every 5 minutes.
