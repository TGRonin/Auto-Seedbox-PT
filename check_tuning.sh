#!/usr/bin/env bash
set -euo pipefail

section() {
  echo ""
  echo "==================== $1 ===================="
}

print_kv() {
  local key="$1"
  local val
  val=$(sysctl -n "$key" 2>/dev/null || true)
  if [[ -n "$val" ]]; then
    printf "%-45s %s\n" "$key" "$val"
  else
    printf "%-45s %s\n" "$key" "(not available)"
  fi
}

section "System Info"
uname -a

echo ""
echo "Detected virtualization:"
systemd-detect-virt 2>/dev/null || echo "(not available)"

echo ""
echo "Default route & NIC:"
ip -o -4 route show to default || true

section "Sysctl Files"
if [[ -f /etc/sysctl.conf ]]; then
  echo "/etc/sysctl.conf (first 200 lines):"
  sed -n '1,200p' /etc/sysctl.conf
else
  echo "/etc/sysctl.conf not found"
fi

echo ""
if [[ -d /etc/sysctl.d ]]; then
  echo "List /etc/sysctl.d/*.conf:"
  ls -1 /etc/sysctl.d/*.conf 2>/dev/null || echo "(none)"
  if [[ -f /etc/sysctl.d/99-ptbox.conf ]]; then
    echo ""
    echo "/etc/sysctl.d/99-ptbox.conf:" 
    cat /etc/sysctl.d/99-ptbox.conf
  fi
else
  echo "/etc/sysctl.d not found"
fi

section "Kernel/Net Core (Install.sh + auto_seedbox_pt.sh)"
print_kv kernel.pid_max
print_kv kernel.msgmnb
print_kv kernel.msgmax
print_kv kernel.sched_migration_cost_ns
print_kv kernel.sched_autogroup_enabled
print_kv kernel.sched_min_granularity_ns
print_kv kernel.sched_wakeup_granularity_ns

print_kv fs.file-max
print_kv fs.nr_open

print_kv vm.dirty_background_ratio
print_kv vm.dirty_ratio
print_kv vm.dirty_expire_centisecs
print_kv vm.dirty_writeback_centisecs
print_kv vm.swappiness

print_kv net.core.netdev_budget
print_kv net.core.netdev_budget_usecs
print_kv net.core.netdev_max_backlog
print_kv net.core.rmem_default
print_kv net.core.rmem_max
print_kv net.core.wmem_default
print_kv net.core.wmem_max
print_kv net.core.optmem_max
print_kv net.core.somaxconn
print_kv net.core.default_qdisc

section "IPv4 TCP / Routing"
print_kv net.ipv4.route.mtu_expires
print_kv net.ipv4.route.min_adv_mss
print_kv net.ipv4.ip_local_port_range
print_kv net.ipv4.ip_no_pmtu_disc
print_kv net.ipv4.neigh.default.unres_qlen_bytes

print_kv net.ipv4.tcp_max_syn_backlog
print_kv net.ipv4.tcp_abort_on_overflow
print_kv net.ipv4.tcp_max_orphans
print_kv net.ipv4.tcp_max_tw_buckets
print_kv net.ipv4.tcp_mtu_probing
print_kv net.ipv4.tcp_base_mss
print_kv net.ipv4.tcp_min_snd_mss
print_kv net.ipv4.tcp_sack
print_kv net.ipv4.tcp_comp_sack_delay_ns
print_kv net.ipv4.tcp_dsack
print_kv net.ipv4.tcp_early_retrans
print_kv net.ipv4.tcp_ecn
print_kv net.ipv4.tcp_mem
print_kv net.ipv4.tcp_rmem
print_kv net.ipv4.tcp_wmem
print_kv net.ipv4.tcp_moderate_rcvbuf
print_kv net.ipv4.tcp_adv_win_scale
print_kv net.ipv4.tcp_reordering
print_kv net.ipv4.tcp_max_reordering
print_kv net.ipv4.tcp_synack_retries
print_kv net.ipv4.tcp_syn_retries
print_kv net.ipv4.tcp_keepalive_time
print_kv net.ipv4.tcp_keepalive_probes
print_kv net.ipv4.tcp_keepalive_intvl
print_kv net.ipv4.tcp_retries1
print_kv net.ipv4.tcp_retries2
print_kv net.ipv4.tcp_orphan_retries
print_kv net.ipv4.tcp_autocorking
print_kv net.ipv4.tcp_frto
print_kv net.ipv4.tcp_rfc1337
print_kv net.ipv4.tcp_slow_start_after_idle
print_kv net.ipv4.tcp_fastopen
print_kv net.ipv4.tcp_timestamps
print_kv net.ipv4.tcp_fin_timeout
print_kv net.ipv4.tcp_no_metrics_save
print_kv net.ipv4.tcp_tw_reuse
print_kv net.ipv4.tcp_window_scaling
print_kv net.ipv4.tcp_workaround_signed_windows
print_kv net.ipv4.tcp_notsent_lowat
print_kv net.ipv4.tcp_limit_output_bytes
print_kv net.ipv4.tcp_congestion_control

section "Network Device Queue/Offload"
ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1 || true)
if [[ -n "$ETH" ]]; then
  echo "NIC: $ETH"
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig "$ETH" | sed -n '1,5p'
  fi
  if command -v ethtool >/dev/null 2>&1; then
    echo "ethtool -k $ETH (offload flags):"
    ethtool -k "$ETH" 2>/dev/null | sed -n '1,30p'
    echo "ethtool -g $ETH (ring buffer):"
    ethtool -g "$ETH" 2>/dev/null || true
  else
    echo "ethtool not available"
  fi
else
  echo "No default NIC detected"
fi

section "Disk Scheduler"
if command -v lsblk >/dev/null 2>&1; then
  lsblk -nd --output NAME,ROTA,SIZE
  for disk in $(lsblk -nd --output NAME | grep -v '^md' | grep -v '^loop'); do
    if [[ -f "/sys/block/$disk/queue/scheduler" ]]; then
      echo "$disk scheduler: $(cat /sys/block/$disk/queue/scheduler)"
    fi
    if [[ -f "/sys/block/$disk/queue/read_ahead_kb" ]]; then
      echo "$disk read_ahead_kb: $(cat /sys/block/$disk/queue/read_ahead_kb)"
    fi
  done
else
  echo "lsblk not available"
fi

section "Tuning Services"
if systemctl list-unit-files | grep -q "asp-tune.service"; then
  systemctl status asp-tune.service --no-pager || true
fi
if systemctl list-unit-files | grep -q "boot-script.service"; then
  systemctl status boot-script.service --no-pager || true
fi
if systemctl list-unit-files | grep -q "bbrinstall.service"; then
  systemctl status bbrinstall.service --no-pager || true
fi

echo ""
echo "Done."