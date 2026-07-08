# agent-leak-app 시스템 장애 분석 미션

---

## 목차
1. [미션 개요 및 스크립트 구성](#1-미션-개요-및-스크립트-구성)
2. [실행 방법](#2-실행-방법)
3. [OOM — 메모리 누수 장애](#3-oom--메모리-누수-장애)
4. [CPU Spike — CPU 과점유 장애](#4-cpu-spike--cpu-과점유-장애)
5. [Deadlock — 교착상태 장애](#5-deadlock--교착상태-장애)
6. [트러블슈팅: CPU 80% 설정 시 50%에서 종료된 문제](#6-트러블슈팅-cpu-80-설정-시-50에서-종료된-문제)
7. [심화 분석](#7-심화-분석)

---

## 1. 미션 개요 및 스크립트 구성

### 전체 흐름

```
setup.sh → run_agent.sh → monitor.sh → collect_evidence.sh → generate_report.sh
                   ↑
     run_all_scenarios.sh 가 위 과정을 자동으로 순서대로 실행
```

### 스크립트 설명

| 파일 | 역할 |
|------|------|
| `setup.sh` | AGENT_HOME 디렉터리, secret.key, 환경변수 파일 자동 생성 |
| `run_agent.sh` | 시나리오별 환경변수 설정 후 앱 실행 (포그라운드/백그라운드 선택) |
| `monitor.sh` | CPU/메모리/스레드를 주기적으로 측정 → 터미널 출력 + CSV 저장 |
| `collect_evidence.sh` | ps, /proc, 스레드 wchan, 핵심 로그를 증거 폴더에 자동 수집 |
| `generate_report.sh` | 수집된 증거로 GitHub Issue 형식 `.md` 리포트 자동 생성 |
| `run_all_scenarios.sh` | 위 4단계를 시나리오별로 순차 자동 실행 |

### monitor.sh 데이터 수집 방식

```bash
# 핵심 명령어: ps로 PID별 CPU/메모리/스레드 수 측정
ps -p $PID -o pid=,pcpu=,rss=,vsz=,nlwp=,stat= --no-headers

# 옵션 의미
# pcpu  : 해당 프로세스의 CPU 사용률 (%)
# rss   : Resident Set Size — 실제 물리 메모리 사용량 (KB)
# vsz   : Virtual Memory Size — 가상 메모리 크기 (KB)
# nlwp  : 스레드(경량 프로세스) 수
# stat  : 프로세스 상태 (R=실행, S=슬립, D=대기, Z=좀비)

# 결과를 CSV로 저장하여 리포트 증거로 활용
echo "$NOW,$PID,$CPU,$RSS_MB,$VSZ_MB,$THREADS,$STATUS" >> monitor.csv
```

### 산출물 위치

```
~/agent_home/
├── logs/          # 실행 로그, 관제 CSV
├── evidence/      # 시나리오별 증거 파일
└── reports/       # GitHub Issue 제출용 마크다운 리포트
    ├── issue_oom_*.md
    ├── issue_cpu_*.md
    └── issue_deadlock_*.md
```

---

## 2. 실행 방법

```bash
# 환경 초기화 (최초 1회)
chmod +x *.sh
bash setup.sh --binary ./agent-leak-app-x86

# 시나리오별 실행 (리포트까지 자동 생성)
bash run_all_scenarios.sh oom
bash run_all_scenarios.sh cpu
bash run_all_scenarios.sh deadlock
bash run_all_scenarios.sh all   # 3개 한번에
```

> WSL / Linux 환경에서 실행. macOS는 Linux ELF 바이너리 미지원.

---

## 3. OOM — 메모리 누수 장애

### 개념

프로그램이 메모리를 계속 할당하기만 하고 해제하지 않아 임계치를 초과하면 강제 종료되는 현상.
애플리케이션 내부 `MemoryGuard`가 먼저 감지하여 자기 자신을 종료함으로써 OS의 OOM Killer 발동을 예방한다.

메모리 누수가 위험한 이유는 OS의 OOM Killer가 발동되면 누수 프로세스뿐만 아니라 
**다른 정상 프로세스까지 종료**될 수 있기 때문이다. MemoryGuard의 자기 종료는 이를 방지하는 보호 정책이다.

### 발생 현상

```
2026-07-08 09:03:23,059 [INFO] [MemoryWorker] Current Heap: 25MB
2026-07-08 09:03:26,238 [INFO] [MemoryWorker] Current Heap: 50MB   ← +25MB / 3초
2026-07-08 09:03:29,423 [INFO] [MemoryWorker] Current Heap: 75MB   ← +25MB / 3초
2026-07-08 09:03:32,604 [INFO] [MemoryWorker] Current Heap: 100MB  ← 임계치 도달
2026-07-08 09:03:32,605 [CRITICAL] [MemoryGuard] Memory limit exceeded (100MB >= 100MB)
2026-07-08 09:03:32,605 [CRITICAL] [MemoryGuard] Self-terminating process 543
```

- 매 3초마다 25MB씩 선형 증가 → 해제 없이 누적 → **메모리 누수** 패턴
- MEMORY_LIMIT 도달 즉시 MemoryGuard가 강제 종료
- 실행 시작 후 약 12초 만에 종료

### ps / monitor 관제 데이터

```bash
# 측정 도구: ps 명령어
ps -p $PID -o pid,pcpu,rss,nlwp,stat --no-headers

# 측정 결과 (RSS = 실제 물리 메모리)
# 앱 내부 힙은 증가하지만 RSS는 낮게 잡히는 특성 있음 (시뮬레이션 방식)
# 핵심 증거는 앱 로그의 [MemoryWorker] Current Heap 수치
```

### Before & After 비교 (MEMORY_LIMIT 조정)

| 항목 | Before (MEMORY_LIMIT=100) | After (MEMORY_LIMIT=300) |
|------|--------------------------|--------------------------|
| 생존 시간 | 약 12초 | 약 36초 (3배 연장) |
| 종료 원인 | MemoryGuard (100MB 초과) | 300MB 도달 후 캐시 정리 후 반복 |
| 메모리 패턴 | 25→50→75→100MB → 종료 | 25→...→300MB → 캐시 정리 → 재시작 |
| 최종 로그 | `Self-terminating process` | `Memory Cache Flushed. Process Stabilized.` |

**After 실행 결과 (MEMORY_LIMIT=300):**
```
2026-07-08 09:04:15,499 [WARNING] [MemoryWorker] Memory Usage Reached Limit (300MB). Starting cleanup...
2026-07-08 09:04:15,603 [INFO] [System] Memory Cache Flushed. Process Stabilized.
>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<
```
→ 300MB에서는 강제 종료 대신 캐시 정리 후 재시작. 100MB는 너무 낮아 정상 복구 불가한 임계치였음.

### 근본 해결 방안 (코드 레벨)

```python
# 문제 코드 (추정): 할당만 하고 해제하지 않음
data_store.append(allocate_chunk(25 * 1024 * 1024))  # 25MB 계속 추가

# 개선 코드: 일정 크기 초과 시 오래된 데이터 제거
if get_heap_size() > SOFT_LIMIT:
    data_store.pop(0)  # 가장 오래된 청크 해제
```

### monitor.sh 개선 제안 (실제 서버 운영 시)

장애 발생 전에 탐지하려면:
1. **증가율 기반 경고**: 3회 연속 메모리 증가 시 Slack/이메일 알림
2. **임계치 단계별 경보**: 70% 도달 시 WARNING, 90% 도달 시 CRITICAL
3. **자동 스크린샷**: 임계치 도달 시 `ps aux` 결과 자동 저장

```bash
# 개선 예시: 연속 증가 감지 로직
if [[ $PREV_MEM -lt $CURR_MEM ]]; then
    INCREASE_COUNT=$((INCREASE_COUNT + 1))
    if [[ $INCREASE_COUNT -ge 3 ]]; then
        echo "ALERT: 메모리 3회 연속 증가 감지!" | mail -s "OOM 위험" admin@company.com
    fi
fi
```

---

## 4. CPU Spike — CPU 과점유 장애

### 개념

특정 프로세스가 CPU를 독점하면 다른 프로세스들이 CPU 타임을 받지 못해 시스템 전체가 느려진다.
내부 `Watchdog`이 시스템 전체 CPU 사용률을 감시하다가 `CPU_MAX_OCCUPY` 임계치 초과 시 SIGTERM을 전송해 강제 종료한다.

단일 프로세스 종료가 시스템 보호에 필요한 이유: CPU 과점유가 지속되면 웹서버, DB 등 
**다른 모든 서비스의 응답 지연**이 발생하고 결국 전체 서비스 장애로 이어지기 때문이다.

### 발생 현상

```
2026-07-08 09:04:56,763 [INFO] [CpuWorker] Started. Maximum CPU Limit: 80%
2026-07-08 09:04:56,764 [INFO] [CpuWorker] Current Load: 5.00%
2026-07-08 09:04:59,869 [INFO] [CpuWorker] Current Load: 6.85%
2026-07-08 09:05:06,081 [INFO] [CpuWorker] Current Load: 13.20%
2026-07-08 09:05:18,510 [INFO] [CpuWorker] Current Load: 32.78%
2026-07-08 09:05:24,720 [INFO] [CpuWorker] Current Load: 46.84%
2026-07-08 09:05:27,828 [INFO] [CpuWorker] Current Load: 52.68%
2026-07-08 09:05:27,929 [CRITICAL] [CpuWorker] CPU Threshold Violated! (52.68%)
Terminated
```

### CPU 사용률 확인 도구

```bash
# 1. ps — 특정 프로세스 CPU 확인
ps -p $PID -o pid,pcpu,comm
# pcpu: 해당 프로세스의 CPU 점유율(%)

# 2. top — 실시간 전체 시스템 모니터링
top -b -n 1 -p $PID
# -b: 배치 모드 (스크립트에서 사용 가능)
# -n 1: 1회만 출력
# -p $PID: 특정 PID만 표시

# 3. ps aux — 전체 프로세스 CPU 내림차순 정렬
ps aux --sort=-%cpu | head -10
```

### Before & After 비교 (CPU_MAX_OCCUPY 조정)

| 항목 | Before (CPU_MAX_OCCUPY=80) | After (CPU_MAX_OCCUPY=30) |
|------|---------------------------|--------------------------|
| 종료 시점 CPU | 52.68% | 30% (Peak 도달 즉시 쿨다운) |
| 생존 시간 | 약 33초 | 더 오래 생존 (쿨다운 반복) |
| 시스템 영향 | CPU 52%까지 허용 → 타 프로세스 지연 | CPU 30% 초과 방지 → 시스템 안정 |
| 종료 방식 | SIGTERM (Watchdog) | 쿨다운 후 반복 (안정적) |

**After 실행 결과 (CPU_MAX_OCCUPY=30):**
```
2026-07-08 09:05:47,857 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
2026-07-08 09:05:48,861 [INFO] [CpuWorker] Current Load: 30.00%
2026-07-08 09:05:51,965 [INFO] [CpuWorker] Current Load: 21.98%   ← 쿨다운 진행
2026-07-08 09:06:03,385 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
```
→ 30%로 낮추자 Watchdog 종료 없이 쿨다운-재시작 사이클로 안정 운영됨.

### 근본 해결 방안 (코드 레벨)

```python
# 문제: 연산 루프에 제한 없이 CPU 자원 소모
while True:
    heavy_computation()

# 개선 1: cgroups로 OS 레벨 CPU 상한 강제
# /sys/fs/cgroup/cpu/myapp/cpu.cfs_quota_us = 30000  (30% 제한)

# 개선 2: nice 값으로 프로세스 우선순위 낮춤
import os
os.nice(10)  # 높을수록 낮은 우선순위 (이미 SafetyGuard가 적용 중)

# 개선 3: 연산 사이에 의도적 sleep으로 CPU 양보
heavy_computation()
time.sleep(0.01)  # 타 프로세스에게 CPU 양보
```

---

## 5. Deadlock — 교착상태 장애

### 개념

두 개 이상의 스레드가 서로 상대방이 점유한 자원을 기다리며 영원히 진행하지 못하는 상태.
프로세스는 살아있지만 아무 작업도 하지 않는다.

**교착상태 4대 조건 — 모두 충족 시 발생:**

| 조건 | 설명 | 이 앱에서 |
|------|------|-----------|
| 상호 배제 | 자원은 한 번에 하나만 사용 | Shared_Memory_A, Socket_Pool_B는 동시 접근 불가 |
| 점유 대기 | 자원을 가진 채로 다른 자원 대기 | Thread-1: A 보유 + B 대기 |
| 비선점 | 강제로 자원 빼앗기 불가 | OS가 락을 강제 해제하지 않음 |
| 순환 대기 | Thread-1→B 대기, Thread-2→A 대기 (원형) | ✅ 완전 충족 |

### 발생 현상 및 로그 추적

```
2026-07-08 09:06:32,294 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]
2026-07-08 09:06:32,294 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]
                                 ↑ Thread-1: A 획득 / Thread-2: B 획득

2026-07-08 09:06:34,299 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... BLOCKED
2026-07-08 09:06:34,299 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... BLOCKED
                                 ↑ 이후 로그 없음 → 무한 대기 진입
```

**순환 대기 구조:**
```
Thread-1: [A 보유] ──────────→ [B 필요] ──┐
                                            ↓ (순환)
Thread-2: [B 보유] ←────────── [A 필요] ──┘
→ 양쪽 모두 영원히 대기 = Deadlock
```

### Deadlock 진단 도구 사용 순서

```bash
# 1단계: PID 존재 여부 확인 (살아있는지 체크)
ps -ef | grep agent-leak-app
# → PID가 있으면 프로세스는 살아있음

# 2단계: CPU/메모리 변화 여부 확인 (움직이는지 체크)
ps -p $PID -o pid,pcpu,rss --no-headers
# → CPU ≈ 0%, RSS 변화 없음 = 아무 작업 안 함

# 3단계: 스레드 상태 확인 (어디서 멈췄는지 체크)
ps -L -p $PID -o lwp,stat,wchan:30,comm
# stat=S(슬립), wchan=futex → 락 대기 상태

# 4단계: 로그 마지막 줄 확인 (언제부터 멈췄는지)
tail -5 ~/agent_home/logs/agent_app.log
# → BLOCKED 이후 로그 없음 = 교착상태 진입 시점 특정
```

**판단 흐름:**
PID 존재 → CPU 0% → 로그 멈춤 → 스레드 BLOCKED → **Deadlock 확정**

### ps -L 출력 예시

```
LWP   STAT  WCHAN                          COMMAND
569   Sl    futex_wait_queue_me            agent-leak-app   ← 메인 스레드 (락 대기)
570   Sl    futex_wait_queue_me            agent-leak-app   ← Worker-Thread-1 (BLOCKED)
571   Sl    futex_wait_queue_me            agent-leak-app   ← Worker-Thread-2 (BLOCKED)
```

`futex_wait_queue_me` = 뮤텍스/락 대기 중임을 OS 레벨에서 확인

### Before & After 비교 (MULTI_THREAD_ENABLE 조정)

| 항목 | Before (MULTI_THREAD=true) | After (MULTI_THREAD=false) |
|------|---------------------------|---------------------------|
| 실행 결과 | 프로세스 무응답 (BLOCKED) | 정상 작업 완료 |
| 로그 상태 | 특정 시점에서 완전히 멈춤 | Thread-A,B,C 순차 100% 완료 |
| CPU | ≈ 0% (대기) | 정상 사용 후 복귀 |
| PID | 계속 존재 (좀비처럼) | 작업 완료 후 정상 진행 |

**After 실행 결과 (MULTI_THREAD=false):**
```
2026-07-08 09:07:20,242 [INFO] [Thread-B] Task Started. Calculating... (20%)
2026-07-08 09:07:20,331 [INFO] [Thread-B] Task Completed. (100%)
2026-07-08 09:07:20,495 [INFO] [Thread-C] Task Started. Calculating... (20%)
2026-07-08 09:07:20,584 [INFO] [Thread-C] Task Completed. (100%)
2026-07-08 09:07:20,748 [INFO] [Thread-A] Task Started. Calculating... (20%)
2026-07-08 09:07:20,951 [INFO] [Thread-A] Task Completed. (100%)
2026-07-08 09:07:21,002 [INFO] [Scheduler] All tasks completed.
```
→ 단일 스레드 모드에서는 자원 경합 없이 순차 실행 → 정상 완료.

### 근본 해결 방안 (코드 레벨)

```python
# 문제: 락 획득 순서가 스레드마다 다름
# Thread-1: lock(A) → lock(B)
# Thread-2: lock(B) → lock(A)  ← 순서가 반대라서 순환 대기 발생

# 개선 1: 락 획득 순서 통일 (모든 스레드가 항상 A→B 순서로만 획득)
with lock_A:
    with lock_B:
        do_work()

# 개선 2: tryLock + 타임아웃 (획득 실패 시 보유 자원 반납)
if not lock_B.acquire(timeout=5):
    lock_A.release()  # 보유한 A를 반납하고 재시도
    retry()

# 개선 3: 단일 락으로 통합 (자원 계층 단순화)
with global_lock:
    access_memory_and_socket()
```

---

## 6. 트러블슈팅: CPU 80% 설정 시 50%에서 종료된 문제

### 현상

```
설정: CPU_MAX_OCCUPY=80
실제 종료 시점: CPU 52.68%

[CRITICAL] [CpuWorker] CPU Threshold Violated! (52.68%)
```

### 원인 분석 과정

**1단계: 환경변수 정상 전달 여부 확인**
```
[6/6] Verifying Mission Environment [OK]
... MEMORY_LIMIT=512MB, CPU_MAX_OCCUPY=80%, MULTI_THREAD_ENABLE=False
```
→ 80%로 정상 전달됨. 앱 설정 문제 아님.

**2단계: 앱 내부 하드코딩 확인**

바이너리에서 추출한 float 상수:
```
발견된 상수: 0.01, 0.05, 0.1, 5.0, 10.0, 100.0
50.0 등장 횟수: 0회
80.0 등장 횟수: 0회
```
→ 앱 내부에 50% 하드코딩 없음.

**3단계: CPU 측정 방식 확인**

앱은 `psutil.cpu_percent()` 로 **시스템 전체 CPU**를 측정한다.
WSL(Windows Subsystem for Linux) 환경에서는 Windows 프로세스의 CPU 사용량까지
합산되어 측정값이 실제보다 높게 나온다.

```
Windows 백그라운드 프로세스: ~30%
앱 CpuWorker 부하:           +22%
─────────────────────────────────
psutil 측정값 (전체):         52.68% → Threshold Violated (설정: 80%)
```

### 결론

| 항목 | 결과 |
|------|------|
| 환경변수 전달 | 정상 (80% 확인) |
| 앱 내부 50% 하드코딩 | 없음 |
| 실제 원인 | WSL 환경에서 psutil이 Windows 포함 전체 CPU 측정 |
| 앱 버그 여부 | 아님 — WSL 환경 특성 |

실제 Linux 서버나 Docker 환경에서는 앱 부하만 측정되므로 80%에 훨씬 가깝게 올라가다 종료된다.

---

## 7. 심화 분석

### 3가지 장애 중 가장 치명적인 것은?

**Deadlock이 가장 치명적**이라고 판단한다.

| 장애 | 감지 난이도 | 복구 | 서비스 영향 |
|------|-----------|------|-----------|
| OOM | 쉬움 (메모리 증가 관측) | 재시작으로 즉시 복구 | 프로세스 종료 후 끝 |
| CPU Spike | 보통 (CPU% 모니터링) | Watchdog 종료 후 재시작 | 일시적 시스템 느림 |
| Deadlock | 어려움 (프로세스가 살아있음) | 강제 kill 필요 | 무기한 서비스 중단 |

Deadlock은 프로세스가 살아있어 보이기 때문에 모니터링 알람이 울리지 않고, 
원인을 파악하기 전까지 서비스가 무기한 중단된다.

### OOM + Deadlock 동시 발생 시 트러블슈팅 우선순위

**OOM을 먼저 처리한다.**

이유: OOM은 메모리를 계속 소비하며 다른 프로세스까지 위협하는 **진행형 장애**다.
방치하면 OS OOM Killer가 무고한 프로세스까지 종료시킨다.
Deadlock은 이미 멈춰있어 추가 피해를 주지 않으므로 후순위로 처리한다.

```
1. OOM 프로세스 즉시 kill → 메모리 확보
2. Deadlock 프로세스 스레드 덤프 수집 (증거 확보)
3. Deadlock 프로세스 kill → 서비스 재시작
4. 각각 근본 원인 분석 및 코드 수정
```

### 다시 미션을 처음부터 수행한다면?

1. **모니터링을 먼저 붙이고 앱 실행**: 앱 실행 전 터미널 분할로 monitor.sh를 먼저 켜고 앱 시작
2. **증거 실시간 수집**: 장애 발생 즉시 `ps`, `top`, `스레드 상태`를 자동 스냅샷
3. **Before/After를 동일 조건에서 비교**: 환경변수 하나만 바꾸고 나머지는 동일하게 유지
4. **WSL 환경 특성 먼저 파악**: CPU 측정이 전체 시스템 기준임을 인지하고 테스트

---