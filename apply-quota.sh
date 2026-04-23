#!/usr/bin/env bash
# ============================================================================
# Server Resource Quota - 운영 적용 스크립트
# ============================================================================
#
# 대상 환경:
#   - Ubuntu 20.04, systemd 245, cgroup hybrid (v1 memory controller)
#
# 정책:
#   [핵심] 1. user.slice MemoryLimit=95%
#   [핵심] 2. ssh/logind/journald OOM 보호 (OOMScoreAdjust=-900)
#   [보조] 3. user.slice soft limit=85% (캐시 정리 유도 힌트)
#   [보조] 4. system.slice CPUShares=2048 (CPU 경합 시 시스템 서비스 우선)
#
# ============================================================================
set -euo pipefail

INSTANCE_ID="$(curl -s http://169.254.169.254/latest/meta-data/instance-id || hostname)"
echo "[INFO] Instance: ${INSTANCE_ID}"

SSH_UNIT="$(systemctl list-unit-files --type=service | awk '$1=="sshd.service" || $1=="ssh.service" {print $1; exit}')"
if [[ -z "${SSH_UNIT:-}" ]]; then echo "[ERROR] SSH unit not found"; exit 1; fi
echo "[INFO] SSH unit: $SSH_UNIT"

echo "[INFO] 현재 상태"
free -h | head -2 || true
cat /sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes || true
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service docker.service containerd.service; do
  if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q .; then
    echo -n "  $svc: "; systemctl is-active "$svc" || true
  fi
done

# --- 1. 백업 ---
echo -e "\n[STEP 1] 백업"
sudo mkdir -p /root/quota-backup
sudo bash -c 'cat /sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes > /root/quota-backup/user.slice.memory.limit_in_bytes.before'
sudo bash -c 'cat /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes > /root/quota-backup/user.slice.memory.soft_limit_in_bytes.before'
sudo bash -c 'cat /sys/fs/cgroup/cpu,cpuacct/system.slice/cpu.shares > /root/quota-backup/system.slice.cpu.shares.before 2>/dev/null || echo 1024 > /root/quota-backup/system.slice.cpu.shares.before'
sudo bash -c 'systemctl show user.slice -p MemoryLimit > /root/quota-backup/user.slice.MemoryLimit.before'
sudo bash -c 'systemctl show system.slice -p CPUShares > /root/quota-backup/system.slice.CPUShares.before'
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]]; then
    sudo bash -c "cat /proc/$pid/oom_score_adj > /root/quota-backup/${svc}.oom_score_adj.before"
  fi
done
echo "[BACKUP] Done → /root/quota-backup/"

# --- 2. [핵심] user.slice MemoryLimit=95% ---
echo -e "\n[STEP 2] user.slice MemoryLimit=95%"
sudo mkdir -p /etc/systemd/system/user.slice.d
sudo tee /etc/systemd/system/user.slice.d/memory-limit.conf > /dev/null <<'EOF'
[Slice]
MemoryLimit=95%
EOF
sudo systemctl daemon-reload
sudo systemctl set-property --runtime user.slice MemoryLimit=95%
echo "  show: $(systemctl show user.slice -p MemoryLimit --value)"
echo "  cgroup: $(cat /sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes)"

# --- 3. [핵심] OOM 보호 ---
echo -e "\n[STEP 3] OOM 보호"
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  sudo mkdir -p "/etc/systemd/system/${svc}.d"
  sudo tee "/etc/systemd/system/${svc}.d/oom-protect.conf" > /dev/null <<'EOF'
[Service]
OOMScoreAdjust=-900
EOF
done
sudo systemctl daemon-reload
sudo systemctl restart "$SSH_UNIT"
for svc in systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]]; then
    sudo bash -c "echo -900 > /proc/$pid/oom_score_adj"
  fi
done
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]]; then
    echo "  $svc pid=$pid adj=$(cat /proc/$pid/oom_score_adj)"
  fi
done

# --- 4. [보조] soft limit 85% ---
echo -e "\n[STEP 4] soft limit 85%"
TOTAL_BYTES=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) * 1024 ))
SOFT_85=$(( TOTAL_BYTES * 85 / 100 ))
sudo bash -c "echo $SOFT_85 > /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes"
echo "$SOFT_85" | sudo tee /etc/default/user-slice-softlimit.conf > /dev/null
sudo tee /usr/local/sbin/apply-user-slice-softlimit.sh > /dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -f /etc/default/user-slice-softlimit.conf ]]; then
  cat /etc/default/user-slice-softlimit.conf > /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes
fi
EOF
sudo chmod 0755 /usr/local/sbin/apply-user-slice-softlimit.sh
sudo tee /etc/systemd/system/user-slice-softlimit.service > /dev/null <<'EOF'
[Unit]
Description=Apply user.slice memory.soft_limit_in_bytes
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apply-user-slice-softlimit.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now user-slice-softlimit.service
echo "  soft limit: $(cat /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes)"

# --- 5. [보조] CPUShares=2048 ---
echo -e "\n[STEP 5] system.slice CPUShares=2048"
sudo mkdir -p /etc/systemd/system/system.slice.d
sudo tee /etc/systemd/system/system.slice.d/cpu-priority.conf > /dev/null <<'EOF'
[Slice]
CPUShares=2048
EOF
sudo systemctl daemon-reload
sudo systemctl set-property --runtime system.slice CPUShares=2048
echo "  CPUShares: $(cat /sys/fs/cgroup/cpu,cpuacct/system.slice/cpu.shares 2>/dev/null || echo N/A)"

# --- 6. 최종 확인 ---
echo -e "\n================ FINAL VERIFY ================"
echo "hard limit: $(cat /sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes)"
echo "soft limit: $(cat /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes)"
echo "cpu.shares: $(cat /sys/fs/cgroup/cpu,cpuacct/system.slice/cpu.shares 2>/dev/null)"
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
