#!/usr/bin/env bash
# ============================================================================
# Server Resource Quota - 운영 적용 스크립트 (cgroup v2 전용)
# ============================================================================
#
# 대상 전제:
#   - Ubuntu 22.04+
#   - systemd 249+
#   - cgroup v2 only (unified hierarchy)
#
# 정책 구조:
#   1) 핵심안
#     - user.slice MemoryMax=95% (hard limit)
#     - user.slice MemoryHigh=85% (soft throttle — v2에서 실제 작동)
#     - ssh/logind/journald OOM 보호
#   2) 보조안
#     - system.slice CPUWeight=200
#
# v1과의 차이:
#   - MemoryLimit → MemoryMax (hard limit)
#   - soft_limit_in_bytes (hint) → MemoryHigh (실제 throttle)
#   - CPUShares → CPUWeight (기본값 100)
#   - soft limit용 oneshot service 불필요 (systemd가 직접 관리)
#
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# 0. 사전 확인
# ----------------------------------------------------------------------------
# cgroup v2 확인
if ! mount | grep -q "cgroup2 on /sys/fs/cgroup"; then
  echo "[ERROR] cgroup v2가 아닙니다. apply-quota.sh (v1용)를 사용하세요."
  exit 1
fi

INSTANCE_ID="$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || hostname)"
echo "[INFO] Host: ${INSTANCE_ID}"

SSH_UNIT="$(systemctl list-unit-files --type=service --no-legend | awk '$1=="sshd.service" || $1=="ssh.service" {print $1; exit}')"
if [[ -z "${SSH_UNIT:-}" ]]; then echo "[ERROR] SSH unit not found"; exit 1; fi
echo "[INFO] SSH unit: $SSH_UNIT"

echo "[INFO] 현재 상태"
free -h | head -2 || true
echo "  memory.max: $(cat /sys/fs/cgroup/user.slice/memory.max 2>/dev/null || echo N/A)"
echo "  memory.high: $(cat /sys/fs/cgroup/user.slice/memory.high 2>/dev/null || echo N/A)"
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service docker.service containerd.service; do
  if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q .; then
    echo -n "  $svc: "; systemctl is-active "$svc" || true
  fi
done

# ----------------------------------------------------------------------------
# 1. 사전 백업
# ----------------------------------------------------------------------------
echo -e "\n[STEP 1] 백업"
sudo mkdir -p /root/quota-backup
sudo bash -c 'cat /sys/fs/cgroup/user.slice/memory.max > /root/quota-backup/user.slice.memory.max.before 2>/dev/null || echo "max" > /root/quota-backup/user.slice.memory.max.before'
sudo bash -c 'cat /sys/fs/cgroup/user.slice/memory.high > /root/quota-backup/user.slice.memory.high.before 2>/dev/null || echo "max" > /root/quota-backup/user.slice.memory.high.before'
sudo bash -c 'cat /sys/fs/cgroup/system.slice/cpu.weight > /root/quota-backup/system.slice.cpu.weight.before 2>/dev/null || echo "100" > /root/quota-backup/system.slice.cpu.weight.before'
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]]; then
    sudo bash -c "cat /proc/$pid/oom_score_adj > /root/quota-backup/${svc}.oom_score_adj.before 2>/dev/null || true"
  fi
done
echo "[BACKUP] Done → /root/quota-backup/"

# ----------------------------------------------------------------------------
# 2. 핵심안 1 - user.slice MemoryMax=95% + MemoryHigh=85%
# ----------------------------------------------------------------------------
echo -e "\n[STEP 2] user.slice MemoryMax=95%, MemoryHigh=85%"
sudo mkdir -p /etc/systemd/system/user.slice.d
sudo tee /etc/systemd/system/user.slice.d/memory-limit.conf > /dev/null <<'EOF'
[Slice]
MemoryMax=95%
MemoryHigh=85%
EOF
sudo systemctl daemon-reload
echo "  MemoryMax: $(systemctl show user.slice -p MemoryMax --value)"
echo "  MemoryHigh: $(systemctl show user.slice -p MemoryHigh --value)"
echo "  cgroup memory.max: $(cat /sys/fs/cgroup/user.slice/memory.max)"
echo "  cgroup memory.high: $(cat /sys/fs/cgroup/user.slice/memory.high)"

# ----------------------------------------------------------------------------
# 3. 핵심안 2 - 중요 서비스 OOM 보호
# ----------------------------------------------------------------------------
echo -e "\n[STEP 3] OOM 보호"
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  sudo mkdir -p "/etc/systemd/system/${svc}.d"
  sudo tee "/etc/systemd/system/${svc}.d/oom-protect.conf" > /dev/null <<'EOF'
[Service]
OOMScoreAdjust=-900
EOF
done
sudo systemctl daemon-reload

# SSH 재시작 (별도 세션 확보 상태에서!)
sudo systemctl restart "$SSH_UNIT"

# logind/journald는 현재 PID에 직접 반영
for svc in systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]]; then
    sudo bash -c "echo -900 > /proc/$pid/oom_score_adj" 2>/dev/null || true
  fi
done
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]]; then
    echo "  $svc pid=$pid adj=$(cat /proc/$pid/oom_score_adj)"
  fi
done

# ----------------------------------------------------------------------------
# 4. 보조안 - CPU 서비스 우선순위
# ----------------------------------------------------------------------------
echo -e "\n[STEP 4] system.slice CPUWeight=200"
sudo mkdir -p /etc/systemd/system/system.slice.d
sudo tee /etc/systemd/system/system.slice.d/cpu-priority.conf > /dev/null <<'EOF'
[Slice]
CPUWeight=200
EOF
sudo systemctl daemon-reload
echo "  CPUWeight: $(systemctl show system.slice -p CPUWeight --value)"
echo "  cgroup cpu.weight: $(cat /sys/fs/cgroup/system.slice/cpu.weight 2>/dev/null || echo N/A)"

# ----------------------------------------------------------------------------
# 5. 최종 확인
# ----------------------------------------------------------------------------
echo -e "\n================ FINAL VERIFY ================"
echo "memory.max: $(cat /sys/fs/cgroup/user.slice/memory.max)"
echo "memory.high: $(cat /sys/fs/cgroup/user.slice/memory.high)"
echo "memory.swap.max: $(cat /sys/fs/cgroup/user.slice/memory.swap.max 2>/dev/null || echo N/A)"
echo "cpu.weight: $(cat /sys/fs/cgroup/system.slice/cpu.weight 2>/dev/null || echo N/A)"
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service docker.service containerd.service; do
  if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q .; then
    echo -n "$svc: "; systemctl is-active "$svc" || true
  fi
done
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]]; then
    echo "$svc pid=$pid adj=$(cat /proc/$pid/oom_score_adj)"
  fi
done
echo "============================================="
echo "[DONE] $(date -u)"
