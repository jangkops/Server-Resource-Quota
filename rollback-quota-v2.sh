#!/usr/bin/env bash
# ============================================================================
# Server Resource Quota - 롤백 스크립트 (cgroup v2 전용)
# 적용한 모든 설정을 백업값으로 즉시 원복합니다.
# 서버 재부팅 불필요.
# ============================================================================
set -euo pipefail

SSH_UNIT="$(systemctl list-unit-files --type=service --no-legend | awk '$1=="sshd.service" || $1=="ssh.service" {print $1; exit}')"
echo "[ROLLBACK] SSH unit: ${SSH_UNIT:-unknown}"

echo "[STEP 1] systemd drop-in 제거"
sudo rm -rf /etc/systemd/system/user.slice.d
sudo rm -rf /etc/systemd/system/system.slice.d
sudo rm -rf "/etc/systemd/system/${SSH_UNIT}.d" 2>/dev/null || true
sudo rm -rf /etc/systemd/system/sshd.service.d 2>/dev/null || true
sudo rm -rf /etc/systemd/system/ssh.service.d 2>/dev/null || true
sudo rm -rf /etc/systemd/system/systemd-logind.service.d
sudo rm -rf /etc/systemd/system/systemd-journald.service.d

sudo systemctl daemon-reload

echo "[STEP 2] 백업값으로 cgroup 즉시 복원"
if [[ -d /root/quota-backup ]]; then
  sudo bash -c "cat /root/quota-backup/user.slice.memory.max.before > /sys/fs/cgroup/user.slice/memory.max" 2>/dev/null || true
  sudo bash -c "cat /root/quota-backup/user.slice.memory.high.before > /sys/fs/cgroup/user.slice/memory.high" 2>/dev/null || true
  sudo bash -c "cat /root/quota-backup/system.slice.cpu.weight.before > /sys/fs/cgroup/system.slice/cpu.weight" 2>/dev/null || true
else
  echo "[WARN] /root/quota-backup 없음. 기본값으로 복원"
  sudo bash -c 'echo max > /sys/fs/cgroup/user.slice/memory.max' 2>/dev/null || true
  sudo bash -c 'echo max > /sys/fs/cgroup/user.slice/memory.high' 2>/dev/null || true
  sudo bash -c 'echo 100 > /sys/fs/cgroup/system.slice/cpu.weight' 2>/dev/null || true
fi

echo "[STEP 3] OOM score 복원"
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]] && [[ -f "/root/quota-backup/${svc}.oom_score_adj.before" ]]; then
    sudo bash -c "cat /root/quota-backup/${svc}.oom_score_adj.before > /proc/$pid/oom_score_adj" 2>/dev/null || true
  fi
done

echo "[STEP 4] SSH 재시작"
sudo systemctl restart "$SSH_UNIT"

echo ""
echo "================ ROLLBACK VERIFY ================"
echo "memory.max: $(cat /sys/fs/cgroup/user.slice/memory.max)"
echo "memory.high: $(cat /sys/fs/cgroup/user.slice/memory.high)"
echo "cpu.weight: $(cat /sys/fs/cgroup/system.slice/cpu.weight 2>/dev/null || echo N/A)"
systemctl show user.slice -p MemoryMax
systemctl show user.slice -p MemoryHigh
systemctl show system.slice -p CPUWeight
echo "================================================="
echo "[DONE] 롤백 완료 — $(date -u)"
