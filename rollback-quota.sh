#!/usr/bin/env bash
# ============================================================================
# Server Resource Quota - 롤백 스크립트
# 적용한 모든 설정을 백업값으로 즉시 원복합니다.
# 서버 재부팅 불필요.
# ============================================================================
set -euo pipefail

SSH_UNIT="$(systemctl list-unit-files --type=service | awk '$1=="sshd.service" || $1=="ssh.service" {print $1; exit}')"
echo "[ROLLBACK] SSH unit: ${SSH_UNIT:-unknown}"

echo "[STEP 1] systemd drop-in 제거"
sudo rm -rf /etc/systemd/system/user.slice.d
sudo rm -rf /etc/systemd/system/system.slice.d
sudo rm -rf "/etc/systemd/system/${SSH_UNIT}.d" 2>/dev/null || true
sudo rm -rf /etc/systemd/system/sshd.service.d 2>/dev/null || true
sudo rm -rf /etc/systemd/system/ssh.service.d 2>/dev/null || true
sudo rm -rf /etc/systemd/system/systemd-logind.service.d
sudo rm -rf /etc/systemd/system/systemd-journald.service.d

echo "[STEP 2] soft limit 영속화 서비스 제거"
sudo systemctl disable --now user-slice-softlimit.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/user-slice-softlimit.service
sudo rm -f /usr/local/sbin/apply-user-slice-softlimit.sh
sudo rm -f /etc/default/user-slice-softlimit.conf

sudo systemctl daemon-reload

echo "[STEP 3] 백업값으로 cgroup 즉시 복원"
if [[ -d /root/quota-backup ]]; then
  sudo bash -c "cat /root/quota-backup/user.slice.memory.limit_in_bytes.before > /sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes" 2>/dev/null || true
  sudo bash -c "cat /root/quota-backup/user.slice.memory.soft_limit_in_bytes.before > /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes" 2>/dev/null || true
  sudo bash -c "cat /root/quota-backup/system.slice.cpu.shares.before > /sys/fs/cgroup/cpu,cpuacct/system.slice/cpu.shares" 2>/dev/null || true
else
  echo "[WARN] /root/quota-backup 없음. 기본값으로 복원"
  sudo bash -c "echo -1 > /sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes" 2>/dev/null || true
  sudo bash -c "echo -1 > /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes" 2>/dev/null || true
  sudo bash -c "echo 1024 > /sys/fs/cgroup/cpu,cpuacct/system.slice/cpu.shares" 2>/dev/null || true
fi

echo "[STEP 4] OOM score 복원"
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]] && [[ -f "/root/quota-backup/${svc}.oom_score_adj.before" ]]; then
    sudo bash -c "cat /root/quota-backup/${svc}.oom_score_adj.before > /proc/$pid/oom_score_adj" 2>/dev/null || true
  fi
done

echo "[STEP 5] SSH 재시작"
sudo systemctl restart "$SSH_UNIT"

echo ""
echo "================ ROLLBACK VERIFY ================"
echo "hard limit: $(cat /sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes)"
echo "soft limit: $(cat /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes)"
echo "cpu.shares: $(cat /sys/fs/cgroup/cpu,cpuacct/system.slice/cpu.shares 2>/dev/null)"
systemctl show user.slice -p MemoryLimit
systemctl show system.slice -p CPUShares
echo "================================================="
echo "[DONE] 롤백 완료 — $(date -u)"
