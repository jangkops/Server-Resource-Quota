#!/usr/bin/env bash
# ============================================================================
# Server Resource Quota - 적용 상태 확인 스크립트 (cgroup v2 전용)
# 변경 없이 조회만 수행합니다.
# ============================================================================
set -euo pipefail

SSH_UNIT="$(systemctl list-unit-files --type=service --no-legend | awk '$1=="sshd.service" || $1=="ssh.service" {print $1; exit}')"

echo "=== Server Resource Quota Status (cgroup v2) ==="
echo "Host: $(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || hostname)"
echo "Time: $(date -u)"
echo ""

echo "[Memory]"
echo "  memory.max (hard limit): $(cat /sys/fs/cgroup/user.slice/memory.max) bytes"
echo "  memory.high (soft throttle): $(cat /sys/fs/cgroup/user.slice/memory.high) bytes"
echo "  memory.current (사용중): $(cat /sys/fs/cgroup/user.slice/memory.current) bytes"
echo "  memory.swap.max: $(cat /sys/fs/cgroup/user.slice/memory.swap.max 2>/dev/null || echo N/A)"
free -h | head -2 | sed 's/^/  /'
echo ""

echo "[CPU]"
echo "  system.slice cpu.weight: $(cat /sys/fs/cgroup/system.slice/cpu.weight 2>/dev/null || echo N/A)"
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

echo "[Docker cgroup]"
docker info 2>/dev/null | grep -i "cgroup" | sed 's/^/  /' || echo "  docker not available"
echo ""

echo "[Swap]"
swapon --show 2>/dev/null || echo "  no swap"
echo "  swappiness: $(cat /proc/sys/vm/swappiness)"
echo ""

echo "[User Sessions]"
loginctl list-sessions 2>/dev/null | tail -3
echo ""

echo "[dmesg Issues]"
dmesg -T 2>/dev/null | tail -5 | grep -iE "oom|panic|lockup" || echo "  no issues"
echo ""

echo "[Uptime]"
uptime
