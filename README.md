# agent-leak-app 시스템 장애 분석 미션

---

## 목차
1. [미션 개요 및 스크립트 구성](#1-미션-개요-및-스크립트-구성)
2. [실행 방법](#2-실행-방법)
3. [OOM — 메모리 누수 장애](#3-oom--메모리-누수-장애)
4. [CPU Spike — CPU 과점유 장애](#4-cpu-spike--cpu-과점유-장애)
5. [Deadlock — 교착상태 장애](#5-deadlock--교착상태-장애)
6. [트러블슈팅: 미션 중 직접 겪은 두 가지 문제](#6-트러블슈팅-미션-중-직접-겪은-두-가지-문제)
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
| `common.sh` | 공통 경로(`$AGENT_HOME`, 기본 `~/agent_home`)와 함수: 워커 PID 찾기, 순간 CPU 측정, 앱 실행/종료 |
| `setup.sh` | AGENT_HOME 디렉터리, secret.key, 환경변수 파일 생성. 바이너리는 아키텍처에 맞춰 자동 탐색 |
| `run_agent.sh` | 시나리오별 환경변수 설정 후 앱 실행 (수동 실험용, 포그라운드/백그라운드) |
| `monitor.sh` | 워커 프로세스의 순간 CPU / RSS / 스레드 수를 주기적으로 측정 → 대시보드 + CSV |
| `collect_evidence.sh` | ps, pstree, /proc, 스레드 wchan, top -H, 핵심 로그, 터미널 출력을 증거 폴더에 수집 |
| `generate_report.sh` | Before/After 증거 폴더의 실측값(run_meta.txt)으로 GitHub Issue 형식 `.md` 생성 |
| `run_all_scenarios.sh` | 시나리오마다 Before → After 두 번 실행하며 위 과정을 자동화 |

### monitor 데이터 수집 방식 — 두 가지 함정

**함정 1: 프로세스가 2개다.** `agent-leak-app` 은 PyInstaller 로 포장된 파이썬 앱이라 실행하면
런처(부모)가 먼저 뜨고, 런처가 실제 파이썬 워커(자식)를 띄운다. 메모리와 스레드를 쓰는 것은 자식이다.

```
agent-leak-app(2517)---agent-leak-app(2518)-+-{agent-leak-app}(2593)   ← pstree -p
   런처 (RSS 2MB, 스레드 1)   워커 (RSS 증가, 스레드 3)
```

`pgrep -f agent-leak-app | head -1` 은 PID 가 작은 런처를 잡기 때문에 RSS 가 2MB 로 고정된 것처럼 보인다.
`common.sh` 의 `find_app_pid` 는 "부모 이름도 agent-leak-app 인 프로세스" = 워커를 고른다.

**함정 2: `ps` 의 %CPU 는 누적 평균이다.** 프로세스가 생긴 이후 전체 시간 대비 CPU 시간 비율이라
시작 직후 값이 점점 낮아지기만 한다. 순간값은 `top` 을 1초 간격으로 두 번 찍어 두 번째 값을 쓴다.

```bash
# 워커 PID 의 누적평균 CPU / RSS(KB) / VSZ(KB) / 스레드 수 / 상태
ps -p $PID -o pcpu=,rss=,vsz=,nlwp=,stat=

# 순간 CPU: -b 배치 모드, -n 2 두 번, -d 1 1초 간격 → 두 번째 샘플이 순간값
top -b -n 2 -d 1 -p $PID | awk -v p=$PID '$1==p {v=$9} END {print v}'

# CSV 한 줄: 시각, PID, 순간CPU, 누적평균CPU, RSS_MB, VSZ_MB, 스레드, STAT, 상태, 비고
echo "$NOW,$PID,$CPU_NOW,$CPU_AVG,$RSS_MB,$VSZ_MB,$THREADS,$STAT,RUNNING," >> monitor.csv
```

**로그 캡처:** 앱의 종료 배너(`>>> [SYSTEM] ... <<<`)는 `print()` 로 출력되는데 `nohup ... > file` 로
리다이렉션하면 블록 버퍼링 때문에 시그널로 죽는 순간 파일에 남지 않는다. 그래서 `script -q -c` 로
가상 터미널 아래에서 실행해 배너와 `EXIT_CODE=N` (137 = SIGKILL, 143 = SIGTERM) 을 함께 기록한다.

### 산출물 위치

```
$AGENT_HOME (기본 ~/agent_home)
├── logs/          # run_<시나리오>_<before|after>_*.log (터미널 출력), monitor_*.csv, agent_app.log
├── evidence/      # <시나리오>_<before|after>_<타임스탬프>/ : ps, pstree, 스레드, 로그, run_meta.txt
└── reports/       # issue_oom_*.md / issue_cpu_*.md / issue_deadlock_*.md  (GitHub Issue 제출용)
```

---

## 2. 실행 방법

```bash
# 일반 사용자로 (root 는 앱이 거부)
cd mission_scripts
chmod +x *.sh
bash setup.sh                       # 리포지토리의 agent-app-leak/agent-leak-app-x86 을 자동으로 찾음
# bash setup.sh --binary /path/to/agent-leak-app-arm64   # 직접 지정도 가능

# 시나리오별 Before → After 자동 실행 + 증거 수집 + 리포트 생성
bash run_all_scenarios.sh oom
bash run_all_scenarios.sh cpu
bash run_all_scenarios.sh deadlock
bash run_all_scenarios.sh all       # 3개 한번에 (약 6분)

# 수동 실험: 터미널 1 에서 앱, 터미널 2 에서 관제
bash run_agent.sh --scenario oom --memory 300
bash monitor.sh
```

> WSL / Linux 환경에서 실행. macOS 는 Linux ELF 바이너리 미지원.
> `script` 명령(util-linux)이 없으면 종료 배너가 로그에 안 남을 수 있다.

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

워커 PID 를 기준으로 재면 RSS 는 앱 로그의 `Current Heap` 과 같은 기울기(+25MB / 3초)로 오른다.
(기본 RSS 약 18MB + 힙)

```
| 시각     | PID | CPU 순간 | CPU 누적평균 | RSS (MB) | 스레드 | STAT | 상태    |
| 18:11:18 | 275 | 0.0      | 2.3          | 42.6     | 1      | SN+  | RUNNING |
| 18:11:22 | 275 | 0.0      | 1.2          | 67.6     | 1      | SN+  | RUNNING |
| 18:11:25 | 275 | 0.0      | 0.9          | 92.6     | 1      | SN+  | RUNNING |
| 18:11:28 |     | 0        | 0            | 0        | 0      | -    | EXITED  |
```

종료 직후 터미널 출력과 종료 코드:

```
[CRITICAL] [MemoryGuard] Self-terminating process 275 to prevent system instability.
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<
Killed
EXIT_CODE=137        ← 128 + 9 (SIGKILL)
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

### 종료 직후 터미널 출력

```
[CRITICAL] [CpuWorker] CPU Threshold Violated! (55.94%).
>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
Terminated
EXIT_CODE=143        ← 128 + 15 (SIGTERM)
```

### CPU 사용률 확인 도구

```bash
# 1. ps — 누적 평균 (프로세스 생성 이후 전체 기간). 급상승 구간 관찰엔 부적합
ps -p $PID -o pid,pcpu,comm

# 2. top — 순간값. 첫 화면은 누적값이므로 -n 2 로 두 번 찍고 두 번째를 본다
top -b -n 2 -d 1 -p $PID

# 3. ps aux — 전체 프로세스 CPU 내림차순
ps aux --sort=-%cpu | head -10

# 4. uptime — load average (런큐 길이). nproc 보다 크면 CPU 대기 발생 중
uptime; nproc
```

**주의:** 이 앱의 `Current Load` 는 실제 연산 부하가 아니라 앱이 내부적으로 시뮬레이션하는 값이다.
`top` 으로 재면 워커의 실제 CPU 는 0~5% 수준이다. Watchdog 은 앱 내부 값을 기준으로 동작하므로
리포트에는 앱 로그(Current Load)와 OS 관제값(top)을 나란히 제시해 교차 검증했다고 쓰는 것이 정확하다.

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
# → PID가 있으면 프로세스는 살아있음 (런처+워커 2개가 보임)

# 2단계: CPU/메모리 변화 여부 확인 (움직이는지 체크)
top -b -n 2 -d 1 -p $PID | tail -1 ; ps -p $PID -o rss=
# → 순간 CPU 0% (무한루프 아님), RSS 변화 없음 = 아무 작업 안 함

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

`futex_wait_queue_me` (커널 버전에 따라 `futex_do_wait`) = 뮤텍스/락 대기 중임을 OS 레벨에서 확인

### Before & After 비교 (MULTI_THREAD_ENABLE 조정)

| 항목 | Before (MULTI_THREAD=true) | After (MULTI_THREAD=false) |
|------|---------------------------|---------------------------|
| 실행 결과 | 프로세스 무응답 (BLOCKED) | 정상 작업 완료 |
| 로그 상태 | 특정 시점에서 완전히 멈춤 | Thread-A,B,C 순차 100% 완료 |
| CPU | ≈ 0% (대기) | 정상 사용 후 복귀 |
| PID | 계속 존재 (상태 S, 세 스레드 모두 futex 대기) | 작업 완료 후 정상 진행 |

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

## 6. 트러블슈팅: 미션 중 직접 겪은 두 가지 문제

### 6-1. CPU 80% 로 설정했는데 50% 에서 종료된 문제

**현상**

```
설정: CPU_MAX_OCCUPY=80
실제 종료 시점: Current Load 50.66% ~ 55.94%
[CRITICAL] [CpuWorker] CPU Threshold Violated! (55.94%).
```

**분석 과정**

1. 환경변수 전달 확인 → 부팅 로그 `CPU_MAX_OCCUPY=80%` 로 정상 전달됨.
2. 부팅 로그의 Resource Check 를 다시 읽음:
   ```
   [ CPU    ] Limit: 80%   [ WARNING: Recommend Under 50% ]
   ```
3. 값을 바꿔가며 재실행 (10, 30, 50, 60, 80):
   - 50 이하 → `Peak reached (N%). Starting cooldown...` 후 5% 로 내려갔다 다시 상승, 종료 없음
   - 50 초과 → 설정값과 무관하게 Load 가 약 50% 를 넘는 순간 SIGTERM

**결론**

앱은 `CPU_MAX_OCCUPY` 가 권장 상한(50%)을 넘으면 "위험 구성" 으로 분류하고, 그때는 설정값이 아니라
자체 보호 임계치(약 50%)에서 Watchdog 을 발동한다. 설정값은 쿨다운 목표치로만 쓰인다.
즉 "80 인데 50 에서 죽었다" 는 버그가 아니라, 권장치를 넘는 설정에 대한 앱의 안전 정책이다.
해결(After)은 임계치를 올리는 것이 아니라 권장 범위 안(30)으로 낮추는 것이었다.

### 6-2. monitor 가 RSS 2MB, 스레드 1개만 찍던 문제

**현상**

앱 로그는 `Current Heap: 100MB` 인데 monitor CSV 의 RSS 는 2.0MB 로 고정, Deadlock 인데 스레드가 1개.

**원인**

`pgrep -f agent-leak-app | head -1` 이 PID 가 가장 작은 프로세스 = PyInstaller 런처(부모)를 잡았다.
`ps -eo pid,ppid,rss,nlwp,cmd | grep agent-leak-app` 으로 전부 출력하니 두 개가 보였다.

```
  PID  PPID   RSS NLWP CMD
  336     1  2216    1 ./agent-leak-app     ← 런처
  339   336 94892    1 ./agent-leak-app     ← 워커 (힙이 여기 쌓임)
```

**해결**

`common.sh` 의 `find_app_pid` 가 "부모의 이름도 agent-leak-app 인 프로세스" 를 고르도록 수정.
`pstree -p` 를 증거에 포함해 런처 → 워커 구조를 리포트에서 보여준다.

**교훈**

관제 수치가 앱 로그와 안 맞으면 도구를 의심하기 전에 "내가 측정하는 PID 가 맞는지" 부터 확인한다.

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
4. **측정 대상 PID 부터 검증**: 앱 로그 수치와 관제 수치가 다르면 `ps -eo pid,ppid,rss,cmd` 로 프로세스가 몇 개인지 먼저 본다

---