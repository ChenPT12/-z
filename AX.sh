#!/bin/bash
# ============================================================
# AX.txt — Debian 13 "Trixie" Max-Performance Tuner (DUAL-SOCKET / NUMA aware)
#
# Defaults are safe for accops/farm nodes:
#   * NO net.* changes      (they break accops-client connectivity)
#   * sysctl named 98-...   (so 99-accops-memory.conf wins on overlap)
#   * NO auto-reboot
#   * numa_balancing LEFT ON (correct for 2-node un-pinned workloads)
#
# Flags (pass after `-s --` when piping):
#   --proxy       also apply net.* tuning (BBR/buffers) — proxy/aiohttp boxes ONLY
#   --aggressive  add mitigations=off to GRUB (security tradeoff)
#   --no-reboot   do NOT auto-reboot at the end
#
# AUTO-REBOOTS by default (15s grace) so all settings take effect.
#
# Run (CRLF-proof — strips any Windows line endings before running):
#   curl -fsSL <raw-url>/AX.txt | tr -d '\r' | sudo bash
#   curl -fsSL <raw-url>/AX.txt | tr -d '\r' | sudo bash -s -- --proxy
# ============================================================
set -euo pipefail

PROXY=0; AGGRESSIVE=0; DOREBOOT=1
for a in "$@"; do
  case "$a" in
    --proxy)       PROXY=1 ;;
    --aggressive)  AGGRESSIVE=1 ;;
    --no-reboot)   DOREBOOT=0 ;;
    *) echo "unknown flag: $a"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root:  curl ... | sudo bash"
  exit 1
fi

LOG=/var/log/perfmax.log
exec > >(tee -a "$LOG") 2>&1
echo "================ PerfMax (dual-socket) started: $(date) ================"

# ------------------------------------------------------------
# 1) Tooling
# ------------------------------------------------------------
echo "[1/14] Installing tooling..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    linux-cpupower cpufrequtils irqbalance numactl \
    sysfsutils util-linux ethtool systemd-zram-generator || true

# ------------------------------------------------------------
# 2) Detect topology
# ------------------------------------------------------------
echo "[2/14] Detecting NUMA topology..."
NODES=$(find /sys/devices/system/node -maxdepth 1 -name 'node[0-9]*' 2>/dev/null | wc -l)
[[ "$NODES" -lt 1 ]] && NODES=1
echo "    NUMA nodes detected: $NODES"
echo "    Logical CPUs:        $(getconf _NPROCESSORS_CONF)"

# ------------------------------------------------------------
# 3) All cores online (both sockets)
# ------------------------------------------------------------
echo "[3/14] Bringing every core online..."
for c in /sys/devices/system/cpu/cpu[0-9]*/online; do
    echo 1 > "$c" 2>/dev/null || true
done

# ------------------------------------------------------------
# 4) Governor=performance + lock min=max freq + turbo (all cores, both sockets)
# ------------------------------------------------------------
echo "[4/14] governor=performance, freq pinned high, turbo on..."
for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    echo performance > "$g" 2>/dev/null || true
done
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    if [[ -f "$c/cpufreq/cpuinfo_max_freq" ]]; then
        m=$(cat "$c/cpufreq/cpuinfo_max_freq")
        echo "$m" > "$c/cpufreq/scaling_max_freq" 2>/dev/null || true
        echo "$m" > "$c/cpufreq/scaling_min_freq" 2>/dev/null || true
    fi
done
[[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
[[ -f /sys/devices/system/cpu/cpufreq/boost ]] && echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
[[ -f /sys/devices/system/cpu/amd_pstate/status ]] && echo active > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true
for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
    [[ -w "$f" ]] && echo performance > "$f" 2>/dev/null || true
done

# ------------------------------------------------------------
# 5) Transparent Huge Pages
# ------------------------------------------------------------
echo "[5/14] THP=madvise..."
for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
    [[ -w "$f" ]] && echo madvise > "$f" 2>/dev/null || true
done

# ------------------------------------------------------------
# 6) Persistence unit (re-apply CPU + THP each boot)
# ------------------------------------------------------------
echo "[6/14] Installing perfmax.service..."
cat > /usr/local/sbin/perfmax-apply.sh <<'EOF'
#!/bin/bash
for c in /sys/devices/system/cpu/cpu[0-9]*/online; do echo 1 > "$c" 2>/dev/null || true; done
for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null || true; done
for c in /sys/devices/system/cpu/cpu[0-9]*; do
  if [[ -f "$c/cpufreq/cpuinfo_max_freq" ]]; then
    m=$(cat "$c/cpufreq/cpuinfo_max_freq")
    echo "$m" > "$c/cpufreq/scaling_max_freq" 2>/dev/null || true
    echo "$m" > "$c/cpufreq/scaling_min_freq" 2>/dev/null || true
  fi
done
[[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
[[ -f /sys/devices/system/cpu/cpufreq/boost ]] && echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do [[ -w "$f" ]] && echo performance > "$f" 2>/dev/null || true; done
for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do [[ -w "$f" ]] && echo madvise > "$f" 2>/dev/null || true; done
exit 0
EOF
chmod +x /usr/local/sbin/perfmax-apply.sh
cat > /etc/systemd/system/perfmax.service <<'EOF'
[Unit]
Description=PerfMax - re-apply CPU/THP performance settings at boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/perfmax-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable perfmax.service

# ------------------------------------------------------------
# 7) sysctl — VM / fs / scheduler. NO net.* here. Named 98- so accops (99-) wins.
# ------------------------------------------------------------
echo "[7/14] sysctl (98-perfmax.conf, no net.*)..."
cat > /etc/sysctl.d/98-perfmax.conf <<'EOF'
# Dual-socket high-performance tuning. NO net.* (would break accops-client).
# 98- prefix => loads before 99-accops-memory.conf, which keeps the last word.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 262144
vm.max_map_count = 1048576
# NUMA: keep auto-balancing ON for un-pinned 2-node workloads. Do NOT disable.
kernel.numa_balancing = 1
# zone_reclaim_mode left at default 0 (do not force local reclaim on NUMA).
kernel.pid_max = 4194304
kernel.threads-max = 4194304
fs.file-max = 12000000
fs.nr_open = 2147483584
fs.aio-max-nr = 1048576
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
kernel.sched_autogroup_enabled = 0
EOF

# ------------------------------------------------------------
# 7b) Optional net.* — proxy/aiohttp boxes ONLY, never accops/farm
# ------------------------------------------------------------
if [[ $PROXY -eq 1 ]]; then
  echo "[7b] --proxy: applying net.* tuning (98-perfmax-net.conf)..."
  cat > /etc/sysctl.d/98-perfmax-net.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
EOF
else
  rm -f /etc/sysctl.d/98-perfmax-net.conf 2>/dev/null || true
  echo "    net.* skipped (safe default). Use --proxy on non-accops boxes only."
fi
sysctl --system >/dev/null

# ------------------------------------------------------------
# 8) I/O schedulers per device type
# ------------------------------------------------------------
echo "[8/14] I/O scheduler udev rule..."
cat > /etc/udev/rules.d/60-ioschedulers.rules <<'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
udevadm control --reload-rules && udevadm trigger || true

# ------------------------------------------------------------
# 9) irqbalance — spread IRQs across BOTH sockets
# ------------------------------------------------------------
echo "[9/14] irqbalance..."
systemctl enable --now irqbalance || true

# ------------------------------------------------------------
# 10) Resource limits (PAM + systemd services)
# ------------------------------------------------------------
echo "[10/14] limits..."
cat > /etc/security/limits.d/99-perfmax.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  1048576
* hard nproc  1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-perfmax.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
EOF
systemctl daemon-reexec || true

# ------------------------------------------------------------
# 11) NUMA launch helper:  numa-run <node> <command...>
# ------------------------------------------------------------
echo "[11/14] Installing /usr/local/bin/numa-run..."
cat > /usr/local/bin/numa-run <<'EOF'
#!/bin/bash
# Pin a process AND its memory to one NUMA node (avoids cross-socket latency).
# Usage: numa-run <node> <command> [args...]
#   numa-run 0 python3 solver.py    # socket 0
#   numa-run 1 python3 solver.py    # socket 1
n="$1"; shift || true
if [[ -z "${n:-}" || -z "${1:-}" ]]; then echo "usage: numa-run <node> <command...>"; exit 1; fi
exec numactl --cpunodebind="$n" --membind="$n" "$@"
EOF
chmod +x /usr/local/bin/numa-run

# ------------------------------------------------------------
# 12) ZRAM compressed swap
# ------------------------------------------------------------
echo "[12/14] ZRAM (zstd, ram/2)..."
cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
systemctl daemon-reload || true
systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true

# ------------------------------------------------------------
# 13) Weekly TRIM + optional mitigations=off
# ------------------------------------------------------------
echo "[13/14] fstrim.timer..."
systemctl enable --now fstrim.timer || true
if [[ $AGGRESSIVE -eq 1 ]]; then
  echo "    --aggressive: mitigations=off (trusted single-tenant only, reboot req)"
  if [[ -f /etc/default/grub ]] && ! grep -q 'mitigations=off' /etc/default/grub; then
    cp /etc/default/grub "/etc/default/grub.bak.$(date +%s)"
    sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 mitigations=off"/' /etc/default/grub
    update-grub || true
  fi
fi

# ------------------------------------------------------------
# 14) Verification
# ------------------------------------------------------------
echo "[14/14] Verification:"
echo "  NUMA nodes     : $NODES"
command -v numactl >/dev/null && numactl --hardware 2>/dev/null | grep -E 'available|node [0-9]+ cpus' | sed 's/^/    /'
echo "  Cores online   : $(nproc) / $(getconf _NPROCESSORS_CONF)"
echo "  Governors      : $(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ' ' || echo 'n/a')"
[[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && echo "  intel no_turbo : $(cat /sys/devices/system/cpu/intel_pstate/no_turbo) (0=turbo on)"
echo "  numa_balancing : $(sysctl -n kernel.numa_balancing)"
echo "  swappiness     : $(sysctl -n vm.swappiness)"
echo "  max_map_count  : $(sysctl -n vm.max_map_count)"
echo "  net tuning     : $([[ $PROXY -eq 1 ]] && echo 'APPLIED (--proxy)' || echo 'skipped (accops-safe)')"
echo "  THP            : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
echo "================ Done. Log: $LOG ================"
echo "Pin heavy jobs per socket with:  numa-run 0 <cmd>   |   numa-run 1 <cmd>"

if [[ $DOREBOOT -eq 1 ]]; then
  echo "All settings live now + persist on boot. Auto-rebooting in 15s (Ctrl+C to cancel)..."
  sleep 15
  systemctl reboot
else
  echo "--no-reboot set: skipping reboot. Settings are live now and persist on boot."
fi
