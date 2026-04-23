#!/usr/bin/env bash
# ============================================================================
# Server Resource Quota - 운영 적용 스크립트
# ============================================================================
#
# 대상 전제:
#   - Ubuntu 20.04
#   - systemd 245
#   - cgroup hybrid
#   - v1 memory controller active
#
# 정책 구조:
#   1) 핵심안
#     - user.slice MemoryLimit=95%
#     - ssh/logind/(권장)journald OOM 보호
#   2) 보조안
#     - user.slice memory.soft_limit_in_bytes=85%
#     - system.slice CPUShares=2048
#
# 주의:
#   - soft limit는 핵심 enforcement가 아니라 보조 힌트
#   - CPUShares는 soft lockup 직접 해결책이 아니라 보조 완화 힌트
#   - 반드시 SSH 세션 2개 이상 확보 후 적용
#   - 먼저 1대 canary 서버에만 적용 후 검증
#
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# 0. 기본 변수/사전 확인
# ----------------------------------------------------------------------------
INSTANCE_ID="$(curl -s http://169.254.169.254/latest/meta-data/instance-id || hostname)"
echo "[INFO] Instance ID: ${INSTANCE_ID}"

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

# ----------------------------------------------------------------------------
# 1. 사전 백업
# ----------------------------------------------------------------------------
echo -e "\n[STEP 1] 백업"
sudo mkdir -p /root/quota-backup

# 현재 cgroup 값 백업
sudo bash -c 'cat /sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes > /root/quota-backup/user.slice.memory.limit_in_bytes.before'
sudo bash -c 'cat /sys/fs/cgroup/memory/user.slice/memory.soft_limit_in_bytes > /root/quota-backup/user.slice.memory.soft_limit_in_bytes.before'
sudo bash -c 'cat /sys/fs/cgroup/cpu,cpuacct/system.slice/cpu.shares > /root/quota-backup/system.slice.cpu.shares.before 2>/dev/null || echo 1024 > /root/quota-backup/system.slice.cpu.shares.before'

# systemd 속성 백업
sudo bash -c 'systemctl show user.slice -p MemoryLimit > /root/quota-backup/user.slice.MemoryLimit.before'
sudo bash -c 'systemctl show system.slice -p CPUShares > /root/quota-backup/system.slice.CPUShares.before'

# 서비스별 현재 oom_score_adj 백업
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "${pid:-}" && "$pid" != "0" ]]; then
    sudo bash -c "cat /proc/$pid/oom_score_adj > /root/quota-backup/${svc}.oom_score_adj.before"
  fi
done
echo "[BACKUP] Done → /root/quota-backup/"

# ----------------------------------------------------------------------------
# 2. 핵심안 1 - user.slice hard limit 95%
# ----------------------------------------------------------------------------
# 설명:
#   - systemd drop-in으로 영속 설정
#   - set-property --runtime 으로 현재 떠 있는 user.slice 에 즉시 반영
#   - MemoryLimit은 systemd resource control의 정식 속성
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

# ----------------------------------------------------------------------------
# 3. 핵심안 2 - 중요 서비스 OOM 보호
# ----------------------------------------------------------------------------
# 설명:
#   - ssh/logind/journald 는 죽으면 접근/로그인/로그 수집에 문제
#   - drop-in으로 영속화
#   - ssh는 재시작으로 즉시 반영
#   - logind/journald는 현재 PID의 /proc/.../oom_score_adj 에 직접 적용
#   - oom_score_adj 는 OOM 희생 우선순위를 조정하는 프로세스별 값
echo -e "\n[STEP 3] OOM 보호"
for svc in "$SSH_UNIT" systemd-logind.service systemd-journald.service; do
  sudo mkdir -p "/etc/systemd/system/${svc}.d"
  sudo tee "/etc/systemd/system/${svc}.d/oom-protect.conf" > /dev/null <<'EOF'
[Service]
OOMScoreAdjust=-900
EOF
done
sudo systemctl daemon-reload

# 주의: SSH 재시작 전 반드시 별도 SSH 세션 1개 이상 유지
sudo systemctl restart "$SSH_UNIT"

# logind/journald는 현재 PID에 직접 반영
# (재시작하면 세션 끊김/로그 유실 위험이 있으므로)
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

# ----------------------------------------------------------------------------
# 4. 보조안 - memory soft limit 85%
# ----------------------------------------------------------------------------
# 설명:
#   - hard limit 전에 완충 구간/보조 reclaim 힌트
#   - 핵심 보호 수단 아님
#   - v1 soft limit는 deprecated / best-effort 이므로, hard limit를 대체하지 못함
#   - 영속화를 위해 oneshot unit도 같이 생성
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

# ----------------------------------------------------------------------------
# 5. 보조안 - CPU soft lockup 사전 대응용 CPUShares
# ----------------------------------------------------------------------------
# 설명:
#   - system.slice에 상대 CPU 가중치 부여
#   - 핵심 해결책 아님, 보조 완화용 힌트
#   - CPUShares는 legacy/v1 계층의 상대 가중치
echo -e "\n[STEP 5] system.slice CPUShares=2048"
sudo mkdir -p /etc/systemd/system/system.slice.d
sudo tee /etc/systemd/system/system.slice.d/cpu-priority.conf > /dev/null <<'EOF'
[Slice]
CPUShares=2048
EOF
sudo systemctl daemon-reload
sudo systemctl set-property --runtime system.slice CPUShares=2048
echo "  CPUShares: $(cat /sys/fs/cgroup/cpu,cpuacct/system.slice/cpu.shares 2>/dev/null || echo N/A)"

# ----------------------------------------------------------------------------
# 6. 최종 확인
# ----------------------------------------------------------------------------
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
