#!/usr/bin/env bash
#
# ultra-optimize.sh — high-performance tuning for Debian 13 (Trixie, kernel 6.12 LTS)
# Target: dedicated / single-tenant servers doing heavy CPU + many-process/thread work.
#
# Design rules baked in:
#   * NO net.* sysctls anywhere in the persistent config (they can break accops-client
#     Roblox API connectivity). Network tuning lives in a SEPARATE, opt-in step.
#   * sysctl drop-in is prefixed 98- so it loads BEFORE 99-accops-memory.conf and lets
#     AccountOps win on any key it owns.
#   * Everything is idempotent and reversible. Originals are backed up to /root/perf-backup-<ts>.
#
# Usage:
#   sudo bash ultra-optimize.sh                 # apply the safe, default profile
#   sudo bash ultra-optimize.sh --aggressive    # also disables CPU mitigations (REBOOT, security tradeoff)
#   sudo bash ultra-optimize.sh --revert        # restore from the most recent backup
#
set -euo pipefail

AGGRESSIVE=0
REVERT=0
for arg in "$@"; do
  case "$arg" in
    --aggressive) AGGRESSIVE=1 ;;
    --revert)     REVERT=1 ;;
    *) echo "unknown flag: $arg"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/perf-backup-${TS}"
log(){ printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# REVERT
# ---------------------------------------------------------------------------
if [[ $REVERT -eq 1 ]]; then
  last="$(ls -d /root/perf-backup-* 2>/dev/null | sort | tail -n1 || true)"
  [[ -n "$last" ]] || { echo "No backup found."; exit 1; }
  warn "Reverting using $last"
  rm -f /etc/sysctl.d/98-performance.conf
  rm -f /etc/udev/rules.d/60-ioschedulers.rules
  rm -f /etc/systemd/system/perf-tunables.service
  rm -f /etc/systemd/system.conf.d/99-perf-limits.conf
  rm -f /etc/security/limits.d/99-perf.conf
  systemctl daemon-reload
  systemctl disable --now perf-tunables.service 2>/dev/null || true
  [[ -f "$last/sysctl.conf" ]] && cp "$last/sysctl.conf" /etc/sysctl.conf
  sysctl --system >/dev/null
  log "Reverted. A reboot is recommended to fully restore governor/THP/limits."
  exit 0
fi

mkdir -p "$BACKUP"
[[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "$BACKUP/sysctl.conf"
log "Backup dir: $BACKUP"

# ===========================================================================
# 1. sysctl — memory, VM, process/thread scaling, fs handles  (NO net.*)
# ===========================================================================
log "Writing /etc/sysctl.d/98-performance.conf"
cat > /etc/sysctl.d/98-performance.conf <<'EOF'
# High-performance tuning — Debian 13 / kernel 6.12 (EEVDF scheduler).
# Prefix 98- loads BEFORE 99-accops-memory.conf so AccountOps keeps the last word.
# Intentionally contains NO net.* keys — those can break accops-client connectivity.

# --- Virtual memory / writeback ---
vm.swappiness = 10                 # keep working set in RAM; don't swap eagerly
vm.vfs_cache_pressure = 50         # retain dentry/inode cache longer
vm.dirty_ratio = 15                # cap dirty pages before forced writeback
vm.dirty_background_ratio = 5      # start async writeback early to avoid stalls
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 1500
vm.min_free_kbytes = 131072        # 128MB emergency reserve (raise to ~1% of RAM on big boxes)
vm.max_map_count = 1048576         # lots of headroom for many threads/mmaps

# --- Process / thread / file-handle scaling ---
kernel.pid_max = 4194304
kernel.threads-max = 4194304
fs.file-max = 12000000             # huge global FD ceiling
fs.nr_open = 2147483584            # per-process hard FD ceiling (max allowed)
fs.aio-max-nr = 1048576            # async I/O requests
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192

# --- Scheduler behaviour (valid on EEVDF / 6.12) ---
kernel.sched_autogroup_enabled = 0 # better for server batch workloads than desktop autogrouping

# --- Optional, test before keeping ---
# vm.overcommit_memory = 1         # avoids fork/alloc failures, but raises OOM-kill risk
# kernel.numa_balancing = 0        # only meaningful on multi-socket hosts
EOF

# ===========================================================================
# 2. ulimits — PAM logins AND systemd services (services ignore limits.conf!)
# ===========================================================================
log "Raising file-descriptor / process limits"
cat > /etc/security/limits.d/99-perf.conf <<'EOF'
*    soft  nofile  1048576
*    hard  nofile  1048576
*    soft  nproc   1048576
*    hard  nproc   1048576
root soft  nofile  1048576
root hard  nofile  1048576
EOF

# systemd-managed daemons (accops-client, farmsync, etc.) do NOT read limits.conf,
# so set the systemd-wide defaults too:
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-perf-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
systemctl daemon-reexec || true

# ===========================================================================
# 3. I/O scheduler — persistent via udev (none for NVMe, mq-deadline for SSD/HDD)
# ===========================================================================
log "Installing persistent I/O scheduler udev rule"
cat > /etc/udev/rules.d/60-ioschedulers.rules <<'EOF'
# NVMe: bypass the scheduler entirely (lowest latency, highest IOPS)
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
# SATA/virtio SSD & HDD: mq-deadline is the balanced default
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
udevadm control --reload-rules && udevadm trigger || true

# ===========================================================================
# 4. CPU governor + THP — persistent via a oneshot systemd service
#    (governor & THP reset on reboot otherwise; VPS guests may lack cpufreq — handled)
# ===========================================================================
log "Installing perf-tunables.service (governor + THP at boot)"
cat > /usr/local/sbin/perf-tunables.sh <<'EOF'
#!/usr/bin/env bash
# Set CPU governor to performance where cpufreq is exposed
if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$g" ]] && echo performance > "$g" 2>/dev/null || true
  done
fi
# Transparent Huge Pages: 'madvise' = throughput gains without the worst latency spikes.
# Flip to 'always' for pure batch throughput, or 'never' if a DB recommends it.
for f in /sys/kernel/mm/transparent_hugepage/enabled \
         /sys/kernel/mm/transparent_hugepage/defrag; do
  [[ -w "$f" ]] && echo madvise > "$f" 2>/dev/null || true
done
EOF
chmod +x /usr/local/sbin/perf-tunables.sh

cat > /etc/systemd/system/perf-tunables.service <<'EOF'
[Unit]
Description=High-performance CPU governor + THP tunables
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/perf-tunables.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now perf-tunables.service || true

# ===========================================================================
# 5. Apply sysctl now
# ===========================================================================
log "Applying sysctl"
sysctl --system >/dev/null

# ===========================================================================
# 6. (--aggressive) Disable CPU mitigations — biggest single CPU win, security tradeoff
# ===========================================================================
if [[ $AGGRESSIVE -eq 1 ]]; then
  warn "AGGRESSIVE: disabling CPU mitigations in GRUB (Spectre/Meltdown/etc.)."
  warn "Only do this on a TRUSTED, single-tenant box. Requires reboot."
  cp /etc/default/grub "$BACKUP/grub"
  if ! grep -q 'mitigations=off' /etc/default/grub; then
    sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 mitigations=off"/' /etc/default/grub
    update-grub
    warn "GRUB updated. Reboot to take effect."
  fi
fi

echo
log "Done. Summary:"
echo "    governor : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'n/a (no cpufreq — typical on VPS)')"
echo "    THP      : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
echo "    swappiness=$(sysctl -n vm.swappiness)  max_map_count=$(sysctl -n vm.max_map_count)  pid_max=$(sysctl -n kernel.pid_max)"
echo "    file-max : $(sysctl -n fs.file-max)"
echo
warn "fstab not touched. For SSD/NVMe add 'noatime' to your data mounts manually for a free I/O win."
warn "Revert anytime with: sudo bash ultra-optimize.sh --revert"
