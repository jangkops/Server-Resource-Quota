#!/usr/bin/env python3
"""
oom-guard v3: hybrid 작업 식별 + cgroup scope 기반 선제 kill 데몬.

v2 대비 수정:
  - 작업 식별: pgid → hybrid (cgroup scope > process tree > pgid > single PID)
  - session-*.scope 통째 kill 금지
  - user-<uid>.slice 통째 kill 금지
  - fail-safe: 식별 불충분 시 dry-run skip
  - 상세 로그 강화

작업 식별 우선순위:
  1순위: per-job cgroup scope (run-*.scope, docker, slurm, jupyter kernel)
  2순위: process tree (train.py parent의 descendant)
  3순위: process group (같은 pgid 내 단일 user, 단일 scope, 보호 대상 없음)
  4순위: single PID (RSS 충분, parent/cmdline 명확, 보호 대상 아님)

절대 금지:
  - user-<uid>.slice 전체 kill
  - session-*.scope 전체 kill
  - 보호 대상이 포함된 group kill
"""

import os
import sys
import time
import signal
import logging
import logging.handlers
import subprocess
import pwd
import re

# ============================================================================
# 설정
# ============================================================================
POLL_INTERVAL = 5
WARN_THRESHOLD = 0.90
KILL_THRESHOLD = 0.93
SIGTERM_WAIT = 5
MAX_KILLS_PER_CYCLE = 3
MIN_RSS_BYTES = 100 * 1024 * 1024  # 100MB
# 기본값은 dry-run. active kill은 --active-kill 플래그로만 활성화
DRY_RUN = '--active-kill' not in sys.argv

# 보호 대상 comm (15자 제한)
PROTECTED_COMMS = frozenset({
    'systemd', 'systemd-logind', 'systemd-journal', 'systemd-udevd',
    'systemd-resolve', 'systemd-timesyn', 'systemd-network',
    'sshd', 'ssh',
    'dockerd', 'containerd', 'containerd-shim', 'docker-proxy',
    'nvidia-persiste', 'nvidia-smi', 'nv-hostengine', 'dcgm',
    'nvidia-fabricma',
    'nginx', 'amazon-cloudwat', 'oom-guard', 'oom-guard-v3',
    'agetty', 'login', 'dbus-daemon', 'cron', 'atd',
    'polkitd', 'accounts-daemon', 'udisksd',
    'jupyterhub', 'jupyter-lab', 'jupyter-noteboo', 'node',
})

# session kill 금지 패턴
SESSION_SCOPE_RE = re.compile(r'session-\d+\.scope')
USER_SLICE_RE = re.compile(r'user-\d+\.slice$')
# per-job scope 패턴 (systemd-run이 생성하는 모든 run-*.scope)
JOB_SCOPE_RE = re.compile(r'run-.*\.scope')

# shell 프로세스 (kill 후보에서 제외, child를 찾아야 함)
SHELL_COMMS = frozenset({'bash', 'sh', 'zsh', 'fish', 'dash', 'csh', 'tcsh',
                         'tmux', 'tmux: server', 'screen'})

# ============================================================================
# 로깅
# ============================================================================
LOG_PATH = '/var/log/oom-guard.log'

def setup_logging():
    logger = logging.getLogger('oom-guard')
    logger.setLevel(logging.INFO)
    try:
        fh = logging.handlers.RotatingFileHandler(
            LOG_PATH, maxBytes=10*1024*1024, backupCount=3)
    except PermissionError:
        fh = logging.StreamHandler(sys.stderr)
    fh.setFormatter(logging.Formatter(
        '%(asctime)s [%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S'))
    logger.addHandler(fh)
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(logging.Formatter('[oom-guard] %(message)s'))
    logger.addHandler(sh)
    return logger

log = setup_logging()
if DRY_RUN:
    log.info("*** DRY-RUN MODE ***")

# ============================================================================
# cgroup 감지
# ============================================================================
def detect_cgroup_version():
    if os.path.isdir('/sys/fs/cgroup/memory/user.slice'):
        return 'v1'
    try:
        with open('/proc/mounts', 'r') as f:
            for line in f:
                if 'cgroup2' in line and '/sys/fs/cgroup' in line:
                    return 'v2'
    except Exception:
        pass
    return 'v1'

CGROUP_VERSION = detect_cgroup_version()
log.info(f"cgroup version: {CGROUP_VERSION}")

# ============================================================================
# 메모리 읽기
# ============================================================================
def read_int(path):
    try:
        with open(path, 'r') as f:
            val = f.read().strip()
            if val == 'max': return None
            return int(val)
    except (FileNotFoundError, ValueError, PermissionError):
        return None

def get_total_memory():
    try:
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    return int(line.split()[1]) * 1024
    except Exception:
        pass
    return None

def get_user_slice_usage():
    if CGROUP_VERSION == 'v2':
        return read_int('/sys/fs/cgroup/user.slice/memory.current')
    return read_int('/sys/fs/cgroup/memory/user.slice/memory.usage_in_bytes')

def get_user_slice_limit():
    if CGROUP_VERSION == 'v2':
        return read_int('/sys/fs/cgroup/user.slice/memory.max')
    val = read_int('/sys/fs/cgroup/memory/user.slice/memory.limit_in_bytes')
    if val and val > 2**62: return None
    return val

# ============================================================================
# 프로세스 정보 수집
# ============================================================================
def get_proc_info(pid):
    """단일 프로세스 상세 정보. 실패 시 None."""
    try:
        with open(f'/proc/{pid}/cgroup', 'r') as f:
            cgroup_raw = f.read().strip()
        if 'user.slice' not in cgroup_raw:
            return None

        with open(f'/proc/{pid}/comm', 'r') as f:
            comm = f.read().strip()

        if comm in PROTECTED_COMMS:
            return None

        with open(f'/proc/{pid}/stat', 'r') as f:
            stat_line = f.read()
        rp = stat_line.rfind(')')
        fields = stat_line[rp+2:].split()
        ppid = int(fields[1])
        pgid = int(fields[2])
        sid = int(fields[4])
        start_time = int(fields[19])
        rss_bytes = int(fields[21]) * 4096

        uid = None
        with open(f'/proc/{pid}/status', 'r') as f:
            for line in f:
                if line.startswith('Uid:'):
                    uid = int(line.split()[1])
                    break
        if uid is not None and uid < 1000:
            return None

        try:
            username = pwd.getpwuid(uid).pw_name if uid else 'unknown'
        except (KeyError, TypeError):
            username = str(uid)

        try:
            with open(f'/proc/{pid}/cmdline', 'r') as f:
                cmdline = f.read().replace('\x00', ' ').strip()[:300]
        except Exception:
            cmdline = comm

        # cgroup scope 추출
        cgroup_scope = extract_scope(cgroup_raw)

        # elapsed
        elapsed_sec = None
        try:
            clk = os.sysconf('SC_CLK_TCK')
            with open('/proc/uptime', 'r') as f:
                up = float(f.read().split()[0])
            elapsed_sec = up - start_time / clk
        except Exception:
            pass

        return {
            'pid': pid, 'comm': comm, 'rss_bytes': rss_bytes,
            'start_time': start_time, 'uid': uid, 'username': username,
            'ppid': ppid, 'pgid': pgid, 'sid': sid,
            'cmdline': cmdline, 'cgroup_raw': cgroup_raw,
            'cgroup_scope': cgroup_scope, 'elapsed_sec': elapsed_sec,
        }
    except (FileNotFoundError, PermissionError, ValueError, IndexError):
        return None

def extract_scope(cgroup_raw):
    """cgroup 경로에서 가장 구체적인 scope/slice를 추출.
    예: '0::/user.slice/user-2001.slice/run-r1234.scope' → 'run-r1234.scope'
        '12:memory:/user.slice/user-1022.slice/session-1.scope' → 'session-1.scope'
    """
    for line in cgroup_raw.split('\n'):
        parts = line.split(':')
        if len(parts) >= 3:
            path = parts[-1]
            # 가장 마지막 segment
            segments = [s for s in path.split('/') if s]
            if segments:
                return segments[-1]
    return None

def get_descendants(pid):
    """pid의 모든 자손 PID 목록"""
    children = []
    try:
        with open(f'/proc/{pid}/task/{pid}/children', 'r') as f:
            direct = [int(c) for c in f.read().split() if c.isdigit()]
    except (FileNotFoundError, PermissionError):
        direct = []
    for c in direct:
        children.append(c)
        children.extend(get_descendants(c))
    return children

def get_all_user_procs():
    """user.slice 내 모든 사용자 프로세스 (RSS 필터 없이)"""
    procs = []
    try:
        pids = [int(p) for p in os.listdir('/proc') if p.isdigit()]
    except Exception:
        return procs
    for pid in pids:
        if pid <= 2:
            continue
        info = get_proc_info(pid)
        if info:
            procs.append(info)
    return procs

# ============================================================================
# Hybrid 작업 식별
# ============================================================================
def identify_jobs(all_procs):
    """
    프로세스 목록에서 kill 가능한 "작업 단위"를 식별.
    반환: list of job dict, 각 job에 policy, members, kill_pids 포함.
    """
    jobs = []
    assigned_pids = set()

    # --- 1순위: per-job cgroup scope (run-*.scope) ---
    scope_groups = {}
    for p in all_procs:
        scope = p['cgroup_scope']
        if scope and JOB_SCOPE_RE.match(scope):
            if scope not in scope_groups:
                scope_groups[scope] = []
            scope_groups[scope].append(p)

    for scope, members in scope_groups.items():
        if not members:
            continue
        pids = {m['pid'] for m in members}
        if pids & assigned_pids:
            continue
        # 보호 대상 체크
        if any(m['comm'] in PROTECTED_COMMS for m in members):
            continue
        # 단일 UID 체크
        uids = {m['uid'] for m in members}
        if len(uids) > 1:
            continue

        total_rss = sum(m['rss_bytes'] for m in members)
        oldest = min(members, key=lambda m: m['start_time'])
        jobs.append({
            'policy': 'cgroup_scope',
            'scope': scope,
            'members': members,
            'kill_pids': [m['pid'] for m in members],
            'total_rss': total_rss,
            'oldest_start_time': oldest['start_time'],
            'uid': oldest['uid'],
            'username': oldest['username'],
            'leader': oldest,
        })
        assigned_pids |= pids

    # --- 2순위: process tree (큰 RSS parent의 descendant) ---
    remaining = [p for p in all_procs if p['pid'] not in assigned_pids
                 and p['rss_bytes'] >= MIN_RSS_BYTES
                 and p['comm'] not in SHELL_COMMS]

    for p in sorted(remaining, key=lambda x: x['rss_bytes'], reverse=True):
        if p['pid'] in assigned_pids:
            continue
        desc_pids = get_descendants(p['pid'])
        tree_members = [p]
        for dp in desc_pids:
            dm = next((x for x in all_procs if x['pid'] == dp), None)
            if dm and dm['pid'] not in assigned_pids:
                tree_members.append(dm)

        # 보호 대상 체크
        if any(m['comm'] in PROTECTED_COMMS for m in tree_members):
            continue
        # 단일 UID
        uids = {m['uid'] for m in tree_members}
        if len(uids) > 1:
            continue
        # 단일 cgroup scope (session scope는 허용하되 kill 단위는 tree)
        scopes = {m['cgroup_scope'] for m in tree_members if m['cgroup_scope']}
        # session scope만 있으면 OK (tree 단위로 kill)

        total_rss = sum(m['rss_bytes'] for m in tree_members)
        if total_rss < MIN_RSS_BYTES:
            continue

        pids = {m['pid'] for m in tree_members}
        jobs.append({
            'policy': 'process_tree',
            'scope': p.get('cgroup_scope', 'unknown'),
            'members': tree_members,
            'kill_pids': list(pids),
            'total_rss': total_rss,
            'oldest_start_time': min(m['start_time'] for m in tree_members),
            'uid': p['uid'],
            'username': p['username'],
            'leader': p,
        })
        assigned_pids |= pids

    # --- 3순위: process group (엄격 조건) ---
    remaining2 = [p for p in all_procs if p['pid'] not in assigned_pids
                  and p['rss_bytes'] >= MIN_RSS_BYTES
                  and p['comm'] not in SHELL_COMMS]

    pgid_groups = {}
    for p in remaining2:
        pg = p['pgid']
        if pg not in pgid_groups:
            pgid_groups[pg] = []
        pgid_groups[pg].append(p)

    for pgid, members in pgid_groups.items():
        if not members:
            continue
        pids = {m['pid'] for m in members}
        if pids & assigned_pids:
            continue
        # 엄격 조건: 단일 UID, 단일 cgroup scope, 보호 대상 없음
        uids = {m['uid'] for m in members}
        if len(uids) > 1:
            continue
        scopes = {m['cgroup_scope'] for m in members if m['cgroup_scope']}
        if len(scopes) > 1:
            continue
        if any(m['comm'] in PROTECTED_COMMS for m in members):
            continue

        total_rss = sum(m['rss_bytes'] for m in members)
        if total_rss < MIN_RSS_BYTES:
            continue

        oldest = min(members, key=lambda m: m['start_time'])
        jobs.append({
            'policy': 'pgid',
            'scope': oldest.get('cgroup_scope', 'unknown'),
            'members': members,
            'kill_pids': [m['pid'] for m in members],
            'total_rss': total_rss,
            'oldest_start_time': oldest['start_time'],
            'uid': oldest['uid'],
            'username': oldest['username'],
            'leader': oldest,
        })
        assigned_pids |= pids

    # --- 4순위: single PID (최후 fallback) ---
    remaining3 = [p for p in all_procs if p['pid'] not in assigned_pids
                  and p['rss_bytes'] >= MIN_RSS_BYTES
                  and p['comm'] not in SHELL_COMMS]

    for p in remaining3:
        if p['comm'] in PROTECTED_COMMS:
            continue
        jobs.append({
            'policy': 'single_pid',
            'scope': p.get('cgroup_scope', 'unknown'),
            'members': [p],
            'kill_pids': [p['pid']],
            'total_rss': p['rss_bytes'],
            'oldest_start_time': p['start_time'],
            'uid': p['uid'],
            'username': p['username'],
            'leader': p,
        })

    return jobs

# ============================================================================
# fail-safe 검증
# ============================================================================
def validate_kill_target(job):
    """kill 전 최종 안전 검증. (safe, reason) 반환."""
    # 1. session scope 통째 kill 금지
    scope = job.get('scope', '')
    if scope and SESSION_SCOPE_RE.match(scope) and job['policy'] == 'cgroup_scope':
        return False, f"session scope '{scope}' 통째 kill 금지 — process_tree/single_pid로 재식별 필요"

    # 2. user slice 통째 kill 금지
    if scope and USER_SLICE_RE.match(scope):
        return False, f"user slice '{scope}' 통째 kill 금지"

    # 3. 보호 대상 포함 체크
    for m in job['members']:
        if m['comm'] in PROTECTED_COMMS:
            return False, f"보호 대상 포함: pid={m['pid']} comm={m['comm']}"

    # 4. 여러 UID 혼재
    uids = {m['uid'] for m in job['members']}
    if len(uids) > 1:
        return False, f"여러 UID 혼재: {uids}"

    # 5. 여러 cgroup scope 혼재 (pgid policy에서)
    if job['policy'] == 'pgid':
        scopes = {m['cgroup_scope'] for m in job['members'] if m['cgroup_scope']}
        if len(scopes) > 1:
            return False, f"여러 cgroup scope 혼재: {scopes}"

    # 6. RSS 너무 작음
    if job['total_rss'] < MIN_RSS_BYTES:
        return False, f"total_rss={job['total_rss']/(1024**2):.0f}MB < {MIN_RSS_BYTES/(1024**2):.0f}MB"

    # 7. shell만 있고 workload child 없음
    if all(m['comm'] in SHELL_COMMS for m in job['members']):
        return False, f"shell만 포함, workload child 없음"

    # 8. cmdline 식별 불가
    if not job['leader'].get('cmdline', '').strip():
        return False, "cmdline 비어있음 — 작업 식별 불가"

    return True, "ok"

# ============================================================================
# Kill 로직
# ============================================================================
def log_job_detail(job, prefix=""):
    """작업 상세 로그"""
    leader = job['leader']
    rss_gb = job['total_rss'] / (1024**3)
    elapsed = f"{leader.get('elapsed_sec', 0):.0f}s" if leader.get('elapsed_sec') else 'N/A'
    log.warning(f"{prefix}policy={job['policy']} scope={job.get('scope','?')} "
                f"uid={job['uid']}({job['username']}) rss={rss_gb:.1f}GB "
                f"members={len(job['members'])} oldest_start={job['oldest_start_time']} "
                f"elapsed={elapsed}")
    log.warning(f"{prefix}leader: pid={leader['pid']} ppid={leader['ppid']} "
                f"pgid={leader['pgid']} sid={leader['sid']} comm={leader['comm']}")
    log.warning(f"{prefix}cmdline: {leader['cmdline'][:200]}")
    log.warning(f"{prefix}cgroup: {leader['cgroup_raw'][:150]}")
    log.warning(f"{prefix}kill_pids: {job['kill_pids'][:10]}")
    for m in job['members'][:5]:
        log.warning(f"{prefix}  member pid={m['pid']} ppid={m['ppid']} pgid={m['pgid']} "
                    f"sid={m['sid']} comm={m['comm']} rss={m['rss_bytes']/(1024**3):.2f}GB "
                    f"scope={m['cgroup_scope']} start={m['start_time']}")
    if len(job['members']) > 5:
        log.warning(f"{prefix}  ... +{len(job['members'])-5} more")

def kill_job(job):
    """작업 kill. kill 직전 재검증 후 kill_pids 목록의 모든 PID에 signal 전송."""
    kill_pids = job['kill_pids']
    rss_gb = job['total_rss'] / (1024**3)

    if DRY_RUN:
        log.warning(f"[DRY-RUN] WOULD KILL {len(kill_pids)} pids, {rss_gb:.1f}GB")
        log_job_detail(job, "[DRY-RUN] ")
        return True

    # === kill 직전 재검증 ===
    recheck_ok, recheck_reason = revalidate_before_kill(job)
    if not recheck_ok:
        log.warning(f"  RECHECK FAIL — kill 취소: {recheck_reason}")
        log_job_detail(job, "  [RECHECK-FAIL] ")
        return False

    log.warning(f"KILL → {len(kill_pids)} pids, {rss_gb:.1f}GB (policy={job['policy']})")
    log_job_detail(job, "  ")

    # SIGTERM to all
    for pid in kill_pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass

    # 대기
    for _ in range(SIGTERM_WAIT):
        time.sleep(1)
        alive = sum(1 for pid in kill_pids if pid_exists(pid))
        if alive == 0:
            log.info(f"  All {len(kill_pids)} pids terminated gracefully")
            return True

    # SIGKILL remaining
    alive_pids = [pid for pid in kill_pids if pid_exists(pid)]
    if alive_pids:
        log.warning(f"  SIGKILL → {len(alive_pids)} still alive: {alive_pids[:5]}")
        for pid in alive_pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    time.sleep(1)
    return True

def pid_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists but no permission

def check_gpu_orphans():
    try:
        r = subprocess.run(['nvidia-smi', '--query-compute-apps=pid,used_memory',
                           '--format=csv,noheader,nounits'],
                          capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            log.info(f"GPU processes after kill: {r.stdout.strip()}")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

# ============================================================================
# kill 직전 재검증
# ============================================================================
def revalidate_before_kill(job):
    """
    kill 직전에 대상 PID들이 여전히 유효한지 재검증.
    PID reuse, cgroup 변경, 보호 대상 혼입 등을 체크.
    """
    for pid in job['kill_pids']:
        # PID가 아직 존재하는지
        if not pid_exists(pid):
            continue  # 이미 죽은 건 OK

        # 현재 정보 재수집
        current = get_proc_info(pid)
        if current is None:
            # proc 읽기 실패 — 프로세스가 사라졌거나 system 프로세스로 변경
            continue

        # 원래 후보 선정 시점의 정보와 비교
        original = next((m for m in job['members'] if m['pid'] == pid), None)
        if original is None:
            continue

        # start_time 불일치 → PID reuse
        if current['start_time'] != original['start_time']:
            return False, f"PID reuse detected: pid={pid} original_start={original['start_time']} current_start={current['start_time']}"

        # UID 변경
        if current['uid'] != original['uid']:
            return False, f"UID changed: pid={pid} original={original['uid']} current={current['uid']}"

        # cgroup scope 변경
        if current['cgroup_scope'] != original['cgroup_scope']:
            return False, f"cgroup scope changed: pid={pid} original={original['cgroup_scope']} current={current['cgroup_scope']}"

        # 보호 대상으로 변경
        if current['comm'] in PROTECTED_COMMS:
            return False, f"comm changed to protected: pid={pid} comm={current['comm']}"

    # kill 대상에 여러 UID가 섞이지 않았는지 최종 확인
    live_uids = set()
    for pid in job['kill_pids']:
        if pid_exists(pid):
            info = get_proc_info(pid)
            if info:
                live_uids.add(info['uid'])
    if len(live_uids) > 1:
        return False, f"Multiple UIDs in kill list: {live_uids}"

    return True, "recheck passed"

# ============================================================================
# 메모리 압박 처리
# ============================================================================
def handle_pressure(usage, limit):
    all_procs = get_all_user_procs()
    if not all_procs:
        log.warning("No user processes found in user.slice")
        return

    jobs = identify_jobs(all_procs)
    if not jobs:
        log.warning("No killable jobs identified")
        return

    # 가장 최근 시작된 작업부터 (oldest_start_time 역순)
    jobs.sort(key=lambda j: j['oldest_start_time'], reverse=True)

    ratio = usage / limit
    log.warning(f"Memory pressure: {usage/(1024**3):.1f}GB / {limit/(1024**3):.1f}GB ({ratio*100:.1f}%)")
    log.warning(f"Identified {len(jobs)} jobs (newest first):")
    for i, j in enumerate(jobs[:7]):
        rss_gb = j['total_rss'] / (1024**3)
        log.warning(f"  [{i}] policy={j['policy']} scope={j.get('scope','?')} "
                    f"comm={j['leader']['comm']} rss={rss_gb:.1f}GB "
                    f"members={len(j['members'])} uid={j['uid']}({j['username']}) "
                    f"oldest_start={j['oldest_start_time']}")

    kills = 0
    for job in jobs:
        if kills >= MAX_KILLS_PER_CYCLE:
            log.warning(f"Max kills/cycle ({MAX_KILLS_PER_CYCLE}) reached")
            break

        # fail-safe 검증
        safe, reason = validate_kill_target(job)
        if not safe:
            log.info(f"  SKIP: {reason}")
            log_job_detail(job, "  [SKIP] ")
            continue

        killed = kill_job(job)
        if killed:
            kills += 1

        if not DRY_RUN:
            time.sleep(1)
            check_gpu_orphans()
            new_usage = get_user_slice_usage()
            if new_usage is None:
                break
            new_ratio = new_usage / limit
            log.info(f"After kill: {new_usage/(1024**3):.1f}GB ({new_ratio*100:.1f}%)")
            if new_ratio < KILL_THRESHOLD:
                log.info(f"Below threshold ({KILL_THRESHOLD*100:.0f}%), stopping")
                break

    mode = 'dry-run' if DRY_RUN else 'killed'
    log.info(f"Cycle complete: {kills} job(s) {mode}")

# ============================================================================
# 메인 루프
# ============================================================================
def main():
    log.info("=" * 60)
    log.info(f"oom-guard v3 starting {'(DRY-RUN)' if DRY_RUN else ''}")
    log.info(f"  cgroup: {CGROUP_VERSION}")
    log.info(f"  poll: {POLL_INTERVAL}s | warn: {WARN_THRESHOLD*100:.0f}% | "
             f"kill: {KILL_THRESHOLD*100:.0f}% | sigterm_wait: {SIGTERM_WAIT}s")
    log.info(f"  max_kills/cycle: {MAX_KILLS_PER_CYCLE} | min_rss: {MIN_RSS_BYTES/(1024**2):.0f}MB")
    log.info(f"  dry-run: {DRY_RUN}")
    log.info(f"  policies: cgroup_scope > process_tree > pgid > single_pid")

    total_mem = get_total_memory()
    if total_mem:
        log.info(f"  total memory: {total_mem/(1024**3):.1f}GB")

    limit = get_user_slice_limit()
    if limit:
        log.info(f"  user.slice limit: {limit/(1024**3):.1f}GB")
    else:
        log.error("Cannot read user.slice memory limit. Exiting.")
        sys.exit(1)

    log.info("=" * 60)

    running = True
    def handle_sig(signum, frame):
        nonlocal running
        log.info(f"Signal {signum}, shutting down")
        running = False

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    warn_logged = False

    while running:
        try:
            usage = get_user_slice_usage()
            if usage is None:
                time.sleep(POLL_INTERVAL)
                continue

            limit = get_user_slice_limit()
            if limit is None or limit == 0:
                time.sleep(POLL_INTERVAL)
                continue

            ratio = usage / limit

            if ratio >= KILL_THRESHOLD:
                warn_logged = False
                handle_pressure(usage, limit)
            elif ratio >= WARN_THRESHOLD:
                if not warn_logged:
                    log.warning(f"Memory warning: {usage/(1024**3):.1f}GB / "
                                f"{limit/(1024**3):.1f}GB ({ratio*100:.1f}%)")
                    warn_logged = True
            else:
                warn_logged = False

        except Exception as e:
            log.error(f"Error: {e}", exc_info=True)

        time.sleep(POLL_INTERVAL)

    log.info("oom-guard v3 stopped")

if __name__ == '__main__':
    main()
