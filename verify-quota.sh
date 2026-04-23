#!/usr/bin/env bash
# ============================================================================
# Server Resource Quota - 적용 상태 확인 스크립트
# 변경 없이 조회만 수행합니다.
# ============================================================================
set -euo pipefail

SSH_UNIT="$(systemctl list-unit-files --type=service | awk '$1=="sshd.service" || $1=="ssh.service" {print $1; exit}')"

echo "=== Server Resource Quota Status ==="
echo "Instance: $(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || hostname)"
echo "Time: $(date -u)"
echo ""

echo "[Memory]"
echo "  hard limit: $(cat /sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes) bytes"
echo "  soft limit: $(cat /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes) bytes"
free -h | head -2 | sed 's/^/  /'
echo ""

echo "[CPU]"
echo "  system.slice cpu.shares: $(cat /sys/fs/cgroup/cpu,cpuacct/system.slice/cpu.shares 2>/dev/null || echo N/A)"
echo ""

echo "[OOM Protection]"
for svc in "${SSH_UNIT:-ssh.service}" systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]]; then
    echo "  $svc pid=$pid oom_score_adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null || echo N/A)"
  fi
done
echo ""

echo "[Services]"
for svc in "${SSH_UNIT:-ssh.service}" systemd-logind.service systemd-journald.service docker.service containerd.service; do
  if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q .; then
    echo "  $svc: $(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
  fi
done
echo ""

echo "[Softlimit Service]"
systemctl is-active user-slice-softlimit.service 2>/dev/null || echo "  not installed"
echo ""

echo "[dmesg Issues]"
dmesg -T 2>/dev/null | tail -5 | grep -iE "oom|panic|lockup" || echo "  no issues"
echo ""

echo "[Uptime]"
uptime
