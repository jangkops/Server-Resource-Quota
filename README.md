# Server Resource Quota

GPU 연구/학습 서버의 메모리 보호 정책 및 CPU soft lockup 사전 대응 설정.

사용자 1명의 메모리 폭주로 서버 전체가 장애나는 것을 방지하고, SSH·핵심 서비스가 항상 살아있도록 보호합니다.

---

## 정책 구조

### 핵심안 (서버 보호의 본체)

| # | 정책 | 설정 | 효과 |
|---|------|------|------|
| 1 | **사용자 메모리 상한** | `user.slice MemoryLimit=95%` | 전체 메모리의 95%까지 허용, 초과 시 해당 작업만 종료. 서버 전체 장애 방지 |
| 2 | **핵심 서비스 OOM 보호** | `OOMScoreAdjust=-900` (ssh, logind, journald) | 메모리 압박에서도 SSH·로그인·로깅 서비스 생존 보장 |

### 보조안 (동반 적용, 핵심 보호 수단 아님)

| # | 정책 | 설정 | 성격 |
|---|------|------|------|
| 3 | **메모리 경고 구간** | `memory.soft_limit_in_bytes=85%` | hard limit 전 캐시 정리 유도. 보조 힌트 |
| 4 | **CPU 서비스 우선순위** | `system.slice CPUShares=2048` | CPU 경합 시 시스템 서비스 우선. soft lockup 보조 완화 |

---

## OOM 동작 원리

메모리 사용량이 95%를 넘으면:

```
사용자 프로세스가 메모리 할당 시도
  → user.slice hard limit(95%) 초과
    → 커널 cgroup OOM killer 작동
      → user.slice 안에서만 프로세스 kill
        → system.slice(SSH, 로깅 등)는 영향 없음
```

### OOM Score 산정 기준

| 요소 | 설명 |
|------|------|
| 기본 점수 | 프로세스 RSS / 전체 메모리 × 1000 (0~1000) |
| 보정 | `oom_score_adj` (-1000 ~ +1000) |
| 최종 점수 | 기본 점수 + adj. **높을수록 먼저 kill** |

예시 (186GB 서버):

| 프로세스 | RSS | 기본 점수 | adj | 최종 | kill 순서 |
|----------|-----|----------|-----|------|----------|
| 사용자 학습 A | 100GB | 538 | 0 | 538 | 1번 (먼저) |
| 사용자 학습 B | 50GB | 269 | 0 | 269 | 2번 |
| sshd | 5MB | 0 | -1000 | -1000 | 절대 안 죽음 |

→ **메모리를 가장 많이 쓰는 비보호 프로세스가 먼저 kill됨**

---

## CPU Soft Lockup 대응 원리

| 계층 | 방식 | 설명 |
|------|------|------|
| 직접 | `CPUShares=2048` | CPU 포화 시 시스템 서비스가 사용자보다 2배 우선 CPU 확보 |
| 간접 | `MemoryLimit=95%` | 메모리 고갈 자체를 막아 "메모리 고갈 + CPU 폭주" 복합 장애 차단 |

> soft lockup의 주요 원인: 메모리 고갈 시 커널이 reclaim/OOM 처리에 CPU를 빼앗김
> → hard limit이 메모리 고갈을 막으므로 이 복합 상황이 발생하지 않음

---

## 파일 구성

```
├── apply-quota.sh      # 운영 적용 스크립트 (전체)
├── rollback-quota.sh   # 롤백 스크립트 (즉시 원복)
├── verify-quota.sh     # 적용 상태 확인 (조회만, 변경 없음)
└── README.md
```

---

## 사용법

### 적용

```bash
# SSH 세션 2개 이상 확보 후 실행
sudo bash apply-quota.sh
```

### 확인

```bash
bash verify-quota.sh
```

### 롤백

```bash
sudo bash rollback-quota.sh
```

---

## 적용 결과 (검증 완료)

| 서버 | 인스턴스 | 메모리 | hard limit | soft limit | CPUShares | ssh adj | 상태 |
|------|----------|--------|-----------|-----------|-----------|---------|------|
| r7 | i-0c30cae12f60d69d1 | 123GB | 117.6GB (95%) | 105.2GB (85%) | 2048 | -1000 |  |
| g5 | i-0dc3c13df82448939 | 186GB | 177.4GB (95%) | 158.7GB (85%) | 2048 | -1000 |  |
| head | i-074a73c3cf9656989 | 15GB | 14.6GB (95%) | 13.0GB (85%) | 2048 | -1000 |  |

- 서버 전체 장애: **0건**
- soft lockup / panic: **0건**
- 서비스 중단: **0건**
- 사용자 영향: **없음** (g5 13명 접속 중 적용, 문제 없음)
- 재부팅: **없음**

---

## 적용되는 설정 파일 목록

| 경로 | 내용 | 영속 |
|------|------|------|
| `/etc/systemd/system/user.slice.d/memory-limit.conf` | MemoryLimit=95% |  재부팅 유지 |
| `/etc/systemd/system/{ssh,sshd}.service.d/oom-protect.conf` | OOMScoreAdjust=-900 |  재부팅 유지 |
| `/etc/systemd/system/systemd-logind.service.d/oom-protect.conf` | OOMScoreAdjust=-900 |  재부팅 유지 |
| `/etc/systemd/system/systemd-journald.service.d/oom-protect.conf` | OOMScoreAdjust=-900 |  재부팅 유지 |
| `/etc/systemd/system/system.slice.d/cpu-priority.conf` | CPUShares=2048 |  재부팅 유지 |
| `/etc/systemd/system/user-slice-softlimit.service` | soft limit 부팅 시 적용 |  재부팅 유지 |
| `/etc/default/user-slice-softlimit.conf` | soft limit 값 저장 |  |
| `/usr/local/sbin/apply-user-slice-softlimit.sh` | soft limit 적용 헬퍼 |  |
| `/root/quota-backup/` | 적용 전 백업값 | 롤백용 |

---

## 대상 환경

- Ubuntu 20.04
- systemd 245
- cgroup hybrid (v1 memory controller active)
- swap 없음

---

## 주의사항

- `soft limit`는 핵심 보호 수단이 아닙니다. 커널에 대한 캐시 정리 힌트일 뿐이며, hard limit 없이는 의미 없습니다.
- `CPUShares`는 soft lockup 직접 해결책이 아닙니다. CPU 경합 시 시스템 서비스 우선순위를 높이는 보조 수단입니다.
- OOM kill 대상은 "가장 큰 메모리를 쓰는 프로세스"가 되는 **경향**이 있으나, 커널이 100% 보장하지는 않습니다.
- Docker 컨테이너는 `user.slice` 밖에 생성되므로 이 정책의 적용을 받지 않습니다. 별도 `--memory` 옵션이 필요합니다.
- SSH 재시작 시 기존 연결은 유지되지만, 반드시 별도 세션을 확보한 상태에서 실행하세요.
