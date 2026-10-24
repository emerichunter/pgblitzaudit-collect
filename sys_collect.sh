#!/usr/bin/env bash
# =============================================================================
#  System Health Collector v1.0
#  Zero-knowledge OS snapshot for server assessment
#
#  Captures: CPU, memory, disk, I/O wait, network, mounts, kernel parameters,
#  open ports, top processes — no user data, no secrets.
#
#  Usage:
#    ./sys_collect.sh [OPTIONS]
#
#  Options:
#    --output-dir DIR         Output directory (default: sys_HOSTNAME_YYYYMMDD_HHMMSS)
#    --docker-container NAME  Collect from inside this Docker container
#    --ssh HOST               Collect from remote host via SSH
#    --ssh-user USER          SSH user (default: root)
#    --ssh-port PORT          SSH port (default: 22)
#    --ssh-key FILE           SSH private key file
#    -h, --help               Show this help
#
#  ── CLIENT QUICK START (no expert required) ──────────────────────────────────
#  1. Copy this script to the target server (or run: bash <(curl -s URL))
#  2. Run:   bash sys_collect.sh
#  3. Zip and send the output directory to your consultant
#
#  Root or sudo is recommended for full sysctl access; the script degrades
#  gracefully and marks unavailable sections rather than failing.
#  ─────────────────────────────────────────────────────────────────────────────
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OUTPUT_DIR=""
DOCKER_CONTAINER=""
SSH_HOST=""
SSH_USER="root"
SSH_PORT=22
SSH_KEY=""

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
_step() { printf "  \033[36m%s\033[0m\n"       "$*"; }
_ok()   { printf "  \033[32mOK  %s\033[0m\n"   "$*"; }
_warn() { printf "  \033[33mWARN  %s\033[0m\n" "$*"; }
_err()  { printf "  \033[31mERR  %s\033[0m\n"  "$*" >&2; exit 1; }
_gray() { printf "  \033[90m%s\033[0m\n"        "$*"; }
_skip() { printf "  \033[90mSKIP %-30s (not available)\033[0m\n" "$*"; }

usage() {
  sed -n '/^#  Usage:/,/^[^#]/p' "$0" | sed 's/^#  \{0,2\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)        OUTPUT_DIR="$2";        shift 2 ;;
    --docker-container)  DOCKER_CONTAINER="$2";  shift 2 ;;
    --ssh)               SSH_HOST="$2";          shift 2 ;;
    --ssh-user)          SSH_USER="$2";          shift 2 ;;
    --ssh-port)          SSH_PORT="$2";          shift 2 ;;
    --ssh-key)           SSH_KEY="$2";           shift 2 ;;
    -h|--help)           usage ;;
    *) _err "Unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Remote runner: execute a shell command on the target
# ---------------------------------------------------------------------------
_run() {
  if [[ -n "$DOCKER_CONTAINER" ]]; then
    docker exec "$DOCKER_CONTAINER" sh -c "$*" 2>/dev/null || true
  elif [[ -n "$SSH_HOST" ]]; then
    local ssh_args=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$SSH_PORT")
    [[ -n "$SSH_KEY" ]] && ssh_args+=(-i "$SSH_KEY")
    ssh "${ssh_args[@]}" "${SSH_USER}@${SSH_HOST}" "$*" 2>/dev/null || true
  else
    eval "$*" 2>/dev/null || true
  fi
}

# Collect one section: _collect LABEL OUTFILE "command string"
_collect() {
  local label="$1" file="$2" cmd="$3"
  local result
  result="$(_run "$cmd")"
  if [[ -n "$result" ]]; then
    printf '%s\n' "$result" > "$file"
    _ok "$label"
  else
    printf '# Not available\n' > "$file"
    _skip "$label"
  fi
}

# ---------------------------------------------------------------------------
# Detect target hostname for directory naming
# ---------------------------------------------------------------------------
TARGET_HOST="$(_run 'hostname -s 2>/dev/null || hostname')"
TARGET_HOST="${TARGET_HOST:-unknown}"
TARGET_HOST="${TARGET_HOST//[^a-zA-Z0-9_-]/}"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="sys_${TARGET_HOST}_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

printf "\n"
printf "  \033[97mSystem Health Collector v1.0\033[0m\n"
_gray "Target : ${DOCKER_CONTAINER:-${SSH_HOST:-localhost}}"
_gray "Output : $OUTPUT_DIR"
printf "\n"

# ---------------------------------------------------------------------------
# 00 — Meta (always succeeds)
# ---------------------------------------------------------------------------
_step "System identity..."
{
  printf "hostname: %s\n"     "$(_run 'hostname -f 2>/dev/null || hostname')"
  printf "uname: %s\n"        "$(_run 'uname -a')"
  printf "os_release:\n"
  _run 'cat /etc/os-release 2>/dev/null || cat /etc/redhat-release 2>/dev/null || echo unknown' \
    | sed 's/^/  /'
  printf "uptime: %s\n"       "$(_run 'uptime')"
  printf "date_utc: %s\n"     "$(_run 'date -u +"%Y-%m-%dT%H:%M:%SZ"')"
  printf "timezone: %s\n"     "$(_run 'cat /etc/timezone 2>/dev/null || timedatectl show --value -p Timezone 2>/dev/null || date +%Z')"
  printf "virtualization: %s\n" "$(_run 'systemd-detect-virt 2>/dev/null || cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown')"
} > "$OUTPUT_DIR/00_meta.txt"
_ok "System identity"

# ---------------------------------------------------------------------------
# 01 — CPU info
# ---------------------------------------------------------------------------
_step "CPU info..."
_collect "CPU info (lscpu)" "$OUTPUT_DIR/01_cpu_lscpu.txt" \
  "lscpu 2>/dev/null || cat /proc/cpuinfo"

_collect "CPU topology" "$OUTPUT_DIR/01_cpu_topology.txt" \
  "lscpu --extended 2>/dev/null || nproc --all 2>/dev/null | xargs -I{} echo 'CPUs: {}'"

# ---------------------------------------------------------------------------
# 02 — CPU usage (vmstat sample)
# ---------------------------------------------------------------------------
_step "CPU usage (vmstat 1 5)..."
_collect "CPU usage vmstat" "$OUTPUT_DIR/02_cpu_vmstat.txt" \
  "vmstat 1 5 2>/dev/null"

_collect "CPU usage mpstat" "$OUTPUT_DIR/02_cpu_mpstat.txt" \
  "mpstat -P ALL 1 3 2>/dev/null"

# /proc/stat snapshot as universal fallback
_run 'cat /proc/stat' > "$OUTPUT_DIR/02_cpu_procstat.txt" 2>/dev/null || \
  printf '# Not available\n' > "$OUTPUT_DIR/02_cpu_procstat.txt"

# ---------------------------------------------------------------------------
# 03 — Load average
# ---------------------------------------------------------------------------
_step "Load average..."
_collect "Load average" "$OUTPUT_DIR/03_loadavg.txt" \
  "cat /proc/loadavg; nproc --all 2>/dev/null | xargs printf 'cpus: %s\n'"

# ---------------------------------------------------------------------------
# 04 — Memory
# ---------------------------------------------------------------------------
_step "Memory..."
_collect "meminfo"    "$OUTPUT_DIR/04_meminfo.txt"  "cat /proc/meminfo"
_collect "free -m"    "$OUTPUT_DIR/04_mem_free.txt" "free -m 2>/dev/null || free 2>/dev/null"
_collect "vmstat -s"  "$OUTPUT_DIR/04_vmstat_s.txt" "vmstat -s 2>/dev/null"

# ---------------------------------------------------------------------------
# 05 — Huge pages
# ---------------------------------------------------------------------------
_step "Huge pages..."
{
  _run 'grep -i huge /proc/meminfo 2>/dev/null'
  printf "\n--- sysctl ---\n"
  _run 'sysctl -a 2>/dev/null | grep -i hugepage' || true
  printf "\n--- transparent hugepages ---\n"
  _run 'cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null' || printf '# Not available\n'
  _run 'cat /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null'  || true
} > "$OUTPUT_DIR/05_hugepages.txt"
_ok "Huge pages"

# ---------------------------------------------------------------------------
# 06 — Disk usage
# ---------------------------------------------------------------------------
_step "Disk usage..."
_collect "df -h"  "$OUTPUT_DIR/06_df.txt"  "df -h 2>/dev/null || df"
_collect "lsblk"  "$OUTPUT_DIR/06_lsblk.txt" \
  "lsblk -o NAME,SIZE,TYPE,ROTA,SCHED,PHY-SeC,LOG-SeC,MOUNTPOINT 2>/dev/null || lsblk 2>/dev/null"

# ---------------------------------------------------------------------------
# 07 — I/O statistics
# ---------------------------------------------------------------------------
_step "I/O statistics (iostat 1 5)..."
{
  printf "=== iostat -x 1 5 ===\n"
  _run "iostat -x 1 5 2>/dev/null" || printf "# iostat not available\n"
} > "$OUTPUT_DIR/07_iostat.txt"
_ok "I/O iostat"

# /proc/diskstats snapshot pair (universal fallback — ~1s apart)
{
  printf "=== /proc/diskstats snapshot 1 ===\n"
  _run "cat /proc/diskstats 2>/dev/null" || printf "# Not available\n"
  printf "\n=== sleep 2 ===\n"
  _run "sleep 2; cat /proc/diskstats 2>/dev/null" || true
  printf "\n=== /proc/diskstats snapshot 2 ===\n"
  _run "cat /proc/diskstats 2>/dev/null" || true
} > "$OUTPUT_DIR/07_diskstats.txt"
_ok "I/O diskstats"

# ---------------------------------------------------------------------------
# 08 — Mount options
# ---------------------------------------------------------------------------
_step "Mount options..."
{
  printf "=== findmnt ===\n"
  _run "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS -A 2>/dev/null" || \
  _run "mount 2>/dev/null" || \
  _run "cat /proc/mounts 2>/dev/null" || printf "# Not available\n"
  printf "\n=== /etc/fstab ===\n"
  _run "cat /etc/fstab 2>/dev/null" || printf "# Not available\n"
} > "$OUTPUT_DIR/08_mounts.txt"
_ok "Mount options"

# ---------------------------------------------------------------------------
# 09 — Kernel parameters (sysctl)
# ---------------------------------------------------------------------------
_step "Kernel parameters..."
{
  printf "=== Memory / VM ===\n"
  _run "sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio \
    vm.dirty_writeback_centisecs vm.dirty_expire_centisecs \
    vm.overcommit_memory vm.overcommit_ratio \
    vm.nr_hugepages vm.nr_overcommit_hugepages \
    vm.zone_reclaim_mode 2>/dev/null" || \
  _run "cat /proc/sys/vm/swappiness /proc/sys/vm/dirty_ratio \
       /proc/sys/vm/dirty_background_ratio 2>/dev/null | paste - - -" || \
  printf "# Not available\n"

  printf "\n=== Kernel IPC (shared memory / semaphores) ===\n"
  _run "sysctl kernel.shmmax kernel.shmall kernel.shmmni kernel.sem 2>/dev/null" || \
  printf "# Not available\n"

  printf "\n=== NUMA ===\n"
  _run "sysctl kernel.numa_balancing 2>/dev/null" || printf "# Not available\n"
  _run "numactl --hardware 2>/dev/null" || printf "# numactl not installed\n"

  printf "\n=== Network core ===\n"
  _run "sysctl net.core.somaxconn net.core.netdev_max_backlog \
    net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range \
    net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time \
    net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
    net.core.rmem_max net.core.wmem_max \
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem 2>/dev/null" || \
  printf "# Not available\n"

  printf "\n=== File handles ===\n"
  _run "sysctl fs.file-max fs.file-nr fs.aio-max-nr 2>/dev/null" || \
  _run "cat /proc/sys/fs/file-max 2>/dev/null | xargs printf 'fs.file-max = %s\n'" || \
  printf "# Not available\n"

  printf "\n=== Scheduler ===\n"
  _run "sysctl kernel.sched_migration_cost_ns kernel.sched_autogroup_enabled 2>/dev/null" || \
  printf "# Not available\n"

  printf "\n=== Full sysctl dump (vm.* + net.core.* + net.ipv4.*) ===\n"
  _run "sysctl -a 2>/dev/null | grep -E '^(vm|kernel\.shmmax|kernel\.shmall|kernel\.sem|net\.core|net\.ipv4\.tcp|fs\.file)'" || \
  printf "# Not available\n"
} > "$OUTPUT_DIR/09_sysctl.txt"
_ok "Kernel parameters"

# ---------------------------------------------------------------------------
# 10 — Network interfaces
# ---------------------------------------------------------------------------
_step "Network interfaces..."
{
  printf "=== ip -s link ===\n"
  _run "ip -s link 2>/dev/null" || \
  _run "ifconfig -a 2>/dev/null" || printf "# Not available\n"
  printf "\n=== ip addr ===\n"
  _run "ip addr 2>/dev/null" || _run "ifconfig 2>/dev/null" || printf "# Not available\n"
  printf "\n=== /proc/net/dev ===\n"
  _run "cat /proc/net/dev 2>/dev/null" || printf "# Not available\n"
} > "$OUTPUT_DIR/10_net_ifaces.txt"
_ok "Network interfaces"

# ---------------------------------------------------------------------------
# 11 — Network throughput (sar / /proc snapshot)
# ---------------------------------------------------------------------------
_step "Network throughput..."
{
  printf "=== sar -n DEV 1 5 ===\n"
  _run "sar -n DEV 1 5 2>/dev/null" || printf "# sar not available (install sysstat)\n"
  printf "\n=== /proc/net/dev snapshot 1 ===\n"
  _run "cat /proc/net/dev 2>/dev/null"
  printf "\n=== /proc/net/dev snapshot 2 (after 2s) ===\n"
  _run "sleep 2; cat /proc/net/dev 2>/dev/null"
} > "$OUTPUT_DIR/11_net_throughput.txt"
_ok "Network throughput"

# ---------------------------------------------------------------------------
# 12 — Socket / TCP stats
# ---------------------------------------------------------------------------
_step "Socket statistics..."
{
  printf "=== ss -s (summary) ===\n"
  _run "ss -s 2>/dev/null" || _run "netstat -s 2>/dev/null | head -20" || printf "# Not available\n"
  printf "\n=== ss -tuln (listening ports) ===\n"
  _run "ss -tuln 2>/dev/null" || _run "netstat -tuln 2>/dev/null" || printf "# Not available\n"
  printf "\n=== ss -tanp (established + process names) ===\n"
  _run "ss -tanp 2>/dev/null | head -50" || printf "# Not available\n"
  printf "\n=== /proc/net/sockstat ===\n"
  _run "cat /proc/net/sockstat 2>/dev/null" || printf "# Not available\n"
} > "$OUTPUT_DIR/12_sockets.txt"
_ok "Socket statistics"

# ---------------------------------------------------------------------------
# 13 — Top processes (CPU + memory)
# ---------------------------------------------------------------------------
_step "Top processes..."
{
  printf "=== Top 20 by CPU ===\n"
  _run "ps aux --sort=-%cpu 2>/dev/null | head -22" || \
  _run "ps aux 2>/dev/null | sort -k3 -rn | head -22" || printf "# Not available\n"
  printf "\n=== Top 20 by RSS Memory ===\n"
  _run "ps aux --sort=-%mem 2>/dev/null | head -22" || \
  _run "ps aux 2>/dev/null | sort -k4 -rn | head -22" || printf "# Not available\n"
  printf "\n=== Process count by state ===\n"
  _run "ps aux 2>/dev/null | awk 'NR>1{state[\$8]++} END{for(s in state) print s, state[s]}'" || \
  printf "# Not available\n"
} > "$OUTPUT_DIR/13_processes.txt"
_ok "Top processes"

# ---------------------------------------------------------------------------
# 14 — Running services
# ---------------------------------------------------------------------------
_step "Running services..."
{
  printf "=== systemctl (running services) ===\n"
  _run "systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null" || \
  _run "service --status-all 2>/dev/null | grep '+'" || \
  _run "ps aux 2>/dev/null | awk 'NR>1{print \$11}' | sort -u | grep -vE '\\[|ps |awk'" || \
  printf "# Not available\n"
} > "$OUTPUT_DIR/14_services.txt"
_ok "Running services"

# ---------------------------------------------------------------------------
# 15 — Security: SELinux / AppArmor / firewall
# ---------------------------------------------------------------------------
_step "Security posture..."
{
  printf "=== SELinux ===\n"
  _run "getenforce 2>/dev/null || sestatus 2>/dev/null" || printf "# Not available\n"
  printf "\n=== AppArmor ===\n"
  _run "aa-status 2>/dev/null || apparmor_status 2>/dev/null" || printf "# Not available\n"
  printf "\n=== iptables (summary) ===\n"
  _run "iptables -L -n --line-numbers 2>/dev/null | head -40" || printf "# Not available\n"
  printf "\n=== nftables ===\n"
  _run "nft list ruleset 2>/dev/null | head -30" || printf "# Not available\n"
  printf "\n=== Kernel version (CVE surface) ===\n"
  _run "uname -r"
  printf "\n=== ASLR ===\n"
  _run "cat /proc/sys/kernel/randomize_va_space 2>/dev/null | xargs printf 'randomize_va_space = %s\n'" || \
  printf "# Not available\n"
  printf "\n=== /etc/passwd shell users ===\n"
  _run "grep -v '/nologin\|/false' /etc/passwd 2>/dev/null" || printf "# Not available\n"
} > "$OUTPUT_DIR/15_security.txt"
_ok "Security posture"

# ---------------------------------------------------------------------------
# 16 — Docker stats (if Docker is available on host)
# ---------------------------------------------------------------------------
_step "Docker stats..."
{
  printf "=== docker ps ===\n"
  _run "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null" || \
  printf "# Docker not available\n"
  printf "\n=== docker stats (snapshot) ===\n"
  _run "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null" || \
  printf "# Docker not available\n"
} > "$OUTPUT_DIR/16_docker.txt"
_ok "Docker stats"

# ---------------------------------------------------------------------------
# 17 — OOM / dmesg critical events
# ---------------------------------------------------------------------------
_step "Kernel events (OOM, errors)..."
{
  printf "=== dmesg errors / warnings (last 100) ===\n"
  _run "dmesg -T --level=err,warn 2>/dev/null | tail -100" || \
  _run "dmesg 2>/dev/null | grep -iE 'oom|error|warn|fail|panic|kill' | tail -100" || \
  printf "# Not available (may require root)\n"
  printf "\n=== OOM killer events ===\n"
  _run "dmesg 2>/dev/null | grep -i 'out of memory\|oom.kill' | tail -30" || \
  printf "# Not available\n"
} > "$OUTPUT_DIR/17_dmesg.txt"
_ok "Kernel events"

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
_step "Writing manifest..."
COLLECTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
KERNEL="$(_run 'uname -r' | tr -d '\n')"
OS_PRETTY="$(_run 'grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d "\"" || uname -o' | tr -d '\n')"

FILES_JSON="["
FIRST=1
for f in "$OUTPUT_DIR"/*.txt; do
  [[ -f "$f" ]] || continue
  NAME="$(basename "$f")"
  SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
  [[ "$FIRST" -eq 0 ]] && FILES_JSON+=","
  FILES_JSON+="{\"name\":\"${NAME}\",\"size_bytes\":${SZ}}"
  FIRST=0
done
FILES_JSON+="]"

cat > "${OUTPUT_DIR}/manifest.json" <<EOF
{
  "sys_collector_version": "1.0",
  "collected_at": "${COLLECTED_AT}",
  "target": "${DOCKER_CONTAINER:-${SSH_HOST:-localhost}}",
  "hostname": "${TARGET_HOST}",
  "kernel": "${KERNEL}",
  "os": "${OS_PRETTY}",
  "files": ${FILES_JSON}
}
EOF
_ok "manifest.json"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n"
printf "  \033[97mBundle ready: %s\033[0m\n" "$OUTPUT_DIR"
printf "\n"
TOTAL=0
for f in "$OUTPUT_DIR"/*; do
  [[ -f "$f" ]] || continue
  NAME="$(basename "$f")"
  SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
  printf "  \033[90m    %-40s %6d KB\033[0m\n" "$NAME" "$(( (SZ + 512) / 1024 ))"
  TOTAL=$(( TOTAL + SZ ))
done
printf "\n"
printf "  \033[90m    %-40s %6d KB\033[0m\n" "TOTAL" "$(( (TOTAL + 512) / 1024 ))"
printf "\n"
