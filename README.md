# agent-leak-app 시스템 장애 분석 미션

`agent-leak-app` 을 운영 환경처럼 실행하면서 세 가지 장애(OOM, CPU Spike, Deadlock)를 재현하고,
관제 데이터와 로그를 근거로 원인을 분석해 GitHub Issue 형식 리포트로 정리했다.
이 문서의 모든 수치는 **2026-10-21 20:33~20:38 실측값**이며, 원본은 `agent_home/` 아래에 있다.

---

## 목차

1. [한눈에 보는 결과](#1-한눈에-보는-결과)
2. [실행 환경과 실행 방법](#2-실행-환경과-실행-방법)
3. [관제 방법](#3-관제-방법)
4. [OOM — 메모리 누수](#4-oom--메모리-누수)
5. [CPU Spike — CPU 과점유](#5-cpu-spike--cpu-과점유)
6. [Deadlock — 교착상태](#6-deadlock--교착상태)
7. [트러블슈팅: 미션 중 직접 겪은 문제 3가지](#7-트러블슈팅-미션-중-직접-겪은-문제-3가지)
8. [심화 분석](#8-심화-분석)
9. [산출물 위치](#9-산출물-위치)

---

## 1. 한눈에 보는 결과

시나리오마다 환경변수 **하나만** 바꿔 Before / After 를 같은 방식으로 실행했다.

| 시나리오 | 바꾼 값 | Before | After |
|---|---|---|---|
| OOM | `MEMORY_LIMIT` 80 → 300 | 12초 만에 종료, EXIT_CODE **137** (SIGKILL), RSS 최대 92.6MB | 종료 없음. 292.9MB 에서 캐시 정리 후 17.8MB 로 복구, 50초 이상 생존 |
| CPU | `CPU_MAX_OCCUPY` 80 → 30 | 38초 만에 종료, EXIT_CODE **143** (SIGTERM), Load 50.25% 에서 Watchdog 발동 | 종료 없음. Load 30% 에서 쿨다운 → 5% → 재상승 반복, 50초 이상 생존 |
| Deadlock | `MULTI_THREAD_ENABLE` true → false | PID 는 살아있으나 9초 후부터 로그·CPU·메모리 모두 정지, 스레드 3개 모두 futex 대기 | 정상 동작. Thread-A/B/C 작업 완료 후 로그 계속 출력 |

리포트 3건: [OOM](agent_home/reports/issue_oom_20261021_203508.md) · [CPU](agent_home/reports/issue_cpu_20261021_203654.md) · [Deadlock](agent_home/reports/issue_deadlock_20261021_203840.md)

---

## 2. 실행 환경과 실행 방법

| 항목 | 값 |
|---|---|
| 실행 환경 | Windows 11 + WSL2 (Ubuntu), x86_64 |
| 실행 계정 | 일반 사용자 `doheekim` (앱이 root 실행을 거부) |
| 바이너리 | `agent-app-leak/agent-leak-app-x86` (PyInstaller 로 포장된 Python 앱) |
| AGENT_HOME | `/home/doheekim/agent_home` (setup.sh 가 생성) |

```bash
cd mission_scripts
bash setup.sh                     # AGENT_HOME, secret.key, agent.env, 바이너리 링크 생성
bash run_all_scenarios.sh all     # 3개 시나리오 × Before/After, 약 6분
```

> PowerShell 에서 `bash` 를 입력하면 WSL 의 bash 가 실행된다. 결과는 WSL 의 `~/agent_home` 에 생기므로
> 제출용으로 리포지토리의 `agent_home/` 에 복사했다.

### 스크립트 구성

| 파일 | 역할 |
|---|---|
| `common.sh` | 공통 함수: 워커 PID 찾기, 순간 CPU 측정, 앱 실행(종료 배너·EXIT_CODE 기록), 앱 종료 |
| `setup.sh` | 실행 환경 초기화 |
| `run_agent.sh` | 시나리오 하나를 수동 실행 (`--memory`, `--cpu`, `--thread` 로 값 덮어쓰기) |
| `monitor.sh` | 실시간 관제 대시보드 + CSV 저장 |
| `collect_evidence.sh` | ps, pstree, /proc, 스레드 상태, 핵심 로그를 증거 폴더에 수집 |
| `generate_report.sh` | 증거 폴더의 실측값으로 GitHub Issue 형식 리포트 생성 |
| `run_all_scenarios.sh` | Before → 증거 수집 → 정리 → After → 리포트 를 시나리오별로 자동 실행 |

```
run_all_scenarios.sh
 ├─ Before 실행 ─ 관제(3초 간격) ─ 증거 수집 ─ 프로세스 정리 ─ run_meta.txt
 ├─ After  실행 ─ 관제(3초 간격) ─ 증거 수집 ─ 프로세스 정리 ─ run_meta.txt
 └─ generate_report.sh → reports/issue_<시나리오>_*.md
```

---

## 3. 관제 방법

### 측정 명령

```bash
# ① 대상 PID: 이름이 정확히 같은 프로세스 중, 부모 이름도 agent-leak-app 인 것(=워커)
pgrep -x agent-leak-app                 # common.sh find_app_pid()
ps -o ppid= -p $P ; ps -o comm= -p $PPID

# ② 수치: 누적평균 CPU, RSS(KB), VSZ(KB), 스레드 수, 상태
ps -p $PID -o pcpu=,rss=,vsz=,nlwp=,stat=   # monitor.sh get_process_stats()

# ③ 순간 CPU: 1초 간격 2회 샘플링, 두 번째 값 사용
top -b -n 2 -d 1 -p $PID                # common.sh cpu_now()

# ④ 기록: 3초마다 CSV 한 줄 추가
echo "$NOW,$PID,$CPU_NOW,$CPU_AVG,$RSS_MB,$VSZ_MB,$THREADS,$STAT,$STATUS," >> monitor.csv
```

| 옵션 | 의미 |
|---|---|
| `pgrep -x` | 이름이 정확히 일치하는 프로세스만. `-f` 는 명령줄 전체를 검색해 스크립트·grep 자신까지 잡는다 |
| `ps -p PID` | 그 PID 만 |
| `ps -o 컬럼=` | 원하는 컬럼만, `=` 를 붙이면 헤더 없이 숫자만 |
| `rss` / `vsz` | 실제 RAM 에 올라온 메모리 / 예약한 가상 주소 공간. 누수는 RSS 로 본다 |
| `nlwp` | 스레드(경량 프로세스) 수 |
| `top -b -n 2 -d 1` | 배치 모드, 2회, 1초 간격. 첫 화면은 누적값이라 두 번째를 쓴다 |

### 관제에서 주의한 두 가지

**프로세스가 두 개다.** PyInstaller 런처(부모)가 실제 Python 워커(자식)를 띄운다. 메모리와 스레드는 워커에만 있다.

```
agent-leak-app(2171)---agent-leak-app(2172)-+-{agent-leak-app}(2247)
     런처: RSS ≈ 2MB              워커     `-{agent-leak-app}(2248)
```

**`ps` 의 %CPU 는 누적 평균이다.** 프로세스가 생긴 뒤 전체 시간 대비 비율이라 시간이 지날수록 둔해진다.
CPU Before 실행에서 `ps` 값은 1.4 → 0.7 → 0.9% 로 거의 움직이지 않았고, 순간값은 `top` 으로 따로 쟀다.

---

## 4. OOM — 메모리 누수

### 현상

`MEMORY_LIMIT=80` 으로 실행하면 12초 뒤 `SELF-TERMINATED` 와 함께 프로세스가 사라진다.
부팅 단계에서 이미 `[ MEMORY ] Limit: 80MB [ WARNING: Recommend Over 256MB ]` 경고가 출력된다.

### 증거

워커(PID 60) 관제 데이터 — RSS 가 3초마다 25MB 씩 증가:

| 시각 | RSS (MB) | 상태 |
|---|---|---|
| 20:33:52 | 42.6 | RUNNING |
| 20:33:55 | 67.6 | RUNNING |
| 20:33:58 | 92.6 | RUNNING |
| 20:34:01 | - | EXITED |

앱 로그와 터미널 출력:

```
20:33:51,763 [INFO] [MemoryWorker] Current Heap: 25MB
20:33:54,800 [INFO] [MemoryWorker] Current Heap: 50MB
20:33:57,835 [INFO] [MemoryWorker] Current Heap: 75MB
20:34:00,876 [INFO] [MemoryWorker] Current Heap: 100MB
20:34:00,876 [CRITICAL] [MemoryGuard] Memory limit exceeded (100MB >= 80MB) / (Recommend Over 256MB)
20:34:00,876 [CRITICAL] [MemoryGuard] Self-terminating process 60 to prevent system instability.
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<
Killed
EXIT_CODE=137          ← 128 + 9 = SIGKILL
```

### 원인

- 앱 로그의 Heap(25 → 50 → 75MB)과 OS 가 잰 RSS(42.6 → 67.6 → 92.6MB, 기본 약 18MB + 힙)가
  **같은 기울기로 증가**하고 한 번도 줄지 않는다. 할당한 데이터의 참조가 남아 회수되지 않는 메모리 누수다.
- 힙이 `MEMORY_LIMIT` 을 넘는 순간 앱의 **MemoryGuard** 가 자기 자신에게 SIGKILL 을 보낸다.
  그대로 두면 RAM 고갈 → 스와핑으로 시스템 전체가 느려지고, 결국 커널 **OOM Killer** 가
  `oom_score` 가 높은 프로세스를 죽이는데 그게 다른 정상 서비스일 수도 있다. MemoryGuard 는 그 전에
  피해를 자기 프로세스로 한정하는 보호 정책이다.
- SIGTERM 이 아니라 SIGKILL 인 이유: 메모리는 즉시 회수해야 하고, 정리 작업 자체가 메모리를 더 쓸 수 있다.

### 조치와 검증 (Before & After)

| | Before (`MEMORY_LIMIT=80`) | After (`MEMORY_LIMIT=300`) |
|---|---|---|
| 결과 | 12초 후 SIGKILL (EXIT_CODE 137) | 관찰 50초 동안 종료 없음 |
| 최대 RSS | 92.6MB | 292.9MB |
| 마지막 동작 | `Self-terminating process 60` | `Memory Cache Flushed. Process Stabilized.` 후 재시작 |

After 에서 한도에 닿았을 때의 동작:

```
20:34:41,027 [INFO]    [MemoryWorker] Current Heap: 300MB
20:34:41,027 [WARNING] [MemoryWorker] Memory Usage Reached Limit (300MB). Starting cleanup...
20:34:41,035 [INFO]    [System] Memory Cache Flushed. Process Stabilized.     ← 8ms 만에 정리
>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<
20:34:46,076 [INFO]    [MemoryWorker] Current Heap: 25MB                      ← 처음부터 다시 증가
```

같은 순간 RSS 는 292.9MB(20:34:39) → 17.8MB(20:34:42)로 한 번에 떨어졌다. 메모리가 실제로 OS 에 반환되고,
같은 PID 로 계속 동작한다. 그래프가 천천히 오르다 수직으로 떨어지는 **톱니 모양**이다.

> 한도를 올리면 정리 루틴이 동작할 여유가 생겨 종료를 피하지만, 약 36초마다 다시 한도까지 차오른다.
> 누수 자체는 그대로이므로 **임시 조치**다.

### 근본 해결 (코드)

```python
# 누적만 하는 구조 → 크기 상한이 있는 구조로
from collections import deque
store = deque(maxlen=8)        # 오래된 것부터 자동으로 버림
store.append(chunk)

# 다 쓴 데이터는 참조를 끊기
del big_buffer
```

배포 전에 `tracemalloc` 으로 메모리 추이를 테스트하고, 캐시에는 LRU 같은 상한 정책을 둔다.

---

## 5. CPU Spike — CPU 과점유

### 현상

`CPU_MAX_OCCUPY=80` 으로 실행하면 앱이 보고하는 Load 가 3초마다 오르다가 38초 뒤 Watchdog 이 프로세스를 종료한다.
부팅 단계에서 `[ CPU ] Limit: 80% [ WARNING: Recommend Under 50% ]` 경고가 출력된다.

### 증거

```
20:35:11,527 [INFO] [CpuWorker] Started. Maximum CPU Limit: 80%
20:35:11,527 [INFO] [CpuWorker] Current Load: 5.00%
20:35:14,643 [INFO] [CpuWorker] Current Load: 14.41%
20:35:23,991 [INFO] [CpuWorker] Current Load: 25.29%
20:35:36,456 [INFO] [CpuWorker] Current Load: 32.93%
20:35:39,572 [INFO] [CpuWorker] Current Load: 40.00%
20:35:42,688 [INFO] [CpuWorker] Current Load: 49.18%
20:35:45,804 [INFO] [CpuWorker] Current Load: 50.25%
20:35:45,905 [CRITICAL] [CpuWorker] CPU Threshold Violated! (50.25%).
>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
Terminated
EXIT_CODE=143          ← 128 + 15 = SIGTERM
```

같은 시간 워커(PID 1005)의 OS 측정값:

| 시각 | top 순간 CPU | ps 누적평균 CPU | 상태 |
|---|---|---|---|
| 20:35:12 | 0.0% | 1.4% | RUNNING |
| 20:35:28 | 0.0% | 0.7% | RUNNING |
| 20:35:44 | 5.0% | 0.9% | RUNNING |
| 20:35:47 | - | - | EXITED |

### 원인

- **보호 조치이지 오류가 아니다.** 근거는 세 가지다. 종료 직전 로그가 Traceback 이 아니라 CRITICAL 레벨의
  임계치 위반 메시지이고, Watchdog 배너가 출력되며, 종료 코드가 143(SIGTERM)이다.
- **80 으로 설정했는데 50% 에서 종료된 이유.** 앱은 권장치(50%)를 넘는 설정을 위험 구성으로 분류하고,
  그때는 설정값이 아니라 자체 보호 임계치(약 50%)에서 Watchdog 을 발동한다. 50 이하 설정에서는 설정값이
  쿨다운 목표로 쓰인다(아래 After).
- **앱 Load 와 OS 측정값이 다른 이유.** `Current Load` 는 앱이 내부에서 시뮬레이션하는 부하이고, 실제 OS 측정
  CPU 는 0~5% 였다. Watchdog 은 앱 내부 값을 기준으로 동작하므로, 리포트에는 두 값을 함께 제시해 교차 검증했다.
- **단일 프로세스 종료가 필요한 이유.** CPU 코어는 한 번에 한 스레드만 실행하고 스케줄러가 시간을 나눠준다.
  한 프로세스가 계속 실행 가능 상태(R)로 남아 있으면 대기열(load average)이 길어지고 웹서버·DB 같은 다른 서비스의
  응답이 늦어진다. 앱이 시작 시 `nice=10` 으로 우선순위를 낮추는 것도 같은 이유다.
- 메모리와 달리 SIGTERM 을 쓰는 이유: CPU 는 당장 회수하지 않아도 시스템이 죽지 않으므로 정리할 기회를 준다.

### 조치와 검증 (Before & After)

| | Before (`CPU_MAX_OCCUPY=80`) | After (`CPU_MAX_OCCUPY=30`) |
|---|---|---|
| 결과 | 38초 후 SIGTERM (EXIT_CODE 143) | 관찰 50초 동안 종료 없음 |
| Load 최고치 | 50.25% → Watchdog 종료 | 30.00% → 쿨다운 |
| 동작 | 오르기만 하다 종료 | 오르고 내려오기를 반복 |

```
20:36:05,050 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...
20:36:09,172 [INFO] [CpuWorker] Current Load: 28.87%
20:36:12,288 [INFO] [CpuWorker] Current Load: 21.73%
20:36:23,748 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
20:36:42,446 [INFO] [CpuWorker] Peak reached (30.00%). Starting cooldown...     ← 약 37초 주기
```

메모리 회복이 한 번에 비우는 것과 달리, CPU 쿨다운은 약 18초에 걸쳐 천천히 내려온다.

### 근본 해결 (코드 / OS)

```python
for job in jobs:
    heavy_work(job)
    time.sleep(0.01)            # 루프마다 CPU 양보
```

작업량에 상한(rate limit)을 두고 무거운 작업은 큐로 나눈다. OS 레벨에서는 cgroups `cpu.max` 로 상한을 강제한다.

---

## 6. Deadlock — 교착상태

### 현상

`MULTI_THREAD_ENABLE=true` 로 실행하면 프로세스는 종료되지 않는데 약 9초 후부터 로그가 완전히 멈춘다.
부팅 단계에서 `>>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.` 경고가 출력된다.

### 증거

**PID 존재** — 프로세스는 살아있다:

```
$ ps -ef | grep agent-leak-app
doheekim  2171  2170  0 20:36 pts/1  00:00:00 /home/doheekim/agent_home/agent-leak-app   ← 런처
doheekim  2172  2171  0 20:36 pts/1  00:00:00 /home/doheekim/agent_home/agent-leak-app   ← 워커
```

**스레드 상태** — 세 스레드 모두 잠든(S) 채 futex(락) 대기:

```
$ ps -L -p 2172 -o pid,lwp,pcpu,stat,wchan:25,comm
  PID   LWP %CPU STAT WCHAN                     COMMAND
 2172  2172  0.0 SNl+ futex_wait_queue          agent-leak-app   ← 메인 (join 대기)
 2172  2247  0.0 SNl+ futex_wait_queue          agent-leak-app   ← Worker-Thread-1
 2172  2248  0.0 SNl+ futex_wait_queue          agent-leak-app   ← Worker-Thread-2

$ top -H -b -n 1 -p 2172
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 2172 doheekim  30  10  170544  18016   9644 S   0.0   0.2   0:00.03 agent-lea+
 2247 doheekim  30  10  170544  18016   9644 S   0.0   0.2   0:00.00 agent-lea+
 2248 doheekim  30  10  170544  18016   9644 S   0.0   0.2   0:00.00 agent-lea+
```

**CPU·메모리 정체** — 관제 30초 동안 RSS 17.6MB, 순간 CPU 0.0% 고정. 증거 수집 시 5회 재측정:

```
[20:37:40] CPU_now=0.0%  RSS=18016KB
[20:37:42] CPU_now=0.0%  RSS=18016KB
[20:37:43] CPU_now=0.0%  RSS=18016KB
[20:37:44] CPU_now=0.0%  RSS=18016KB
[20:37:45] CPU_now=0.0%  RSS=18016KB
```

**마지막 로그** — 20:37:04 이후 40초 넘게 한 줄도 없음:

```
20:37:02,624 [INFO] [AgentWorker] Waiting for worker threads to complete transactions...
20:37:02,625 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
20:37:02,625 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
20:37:04,645 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
20:37:04,645 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
20:37:04,645 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
20:37:04,645 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```

### 진단 순서

다른 가능성을 하나씩 지우는 순서로 판단했다.

| 단계 | 확인 | 결과 | 지운 가능성 |
|---|---|---|---|
| 1 | `ps -ef` | PID 2172 존재 | 프로세스 사망 |
| 2 | `top -b -n 2` 순간 CPU | 0.0% | 무한루프(busy-wait). 무한루프면 CPU 가 100% 에 가깝다 |
| 3 | RSS 반복 측정 + `tail` | 18016KB 고정, 마지막 로그 20:37:04 고정 | 느리게라도 일하는 중 |
| 4 | `ps -L`, `top -H`, `/proc/PID/task/*/wchan` | 3개 모두 S 상태, `futex_wait_queue` | 디스크·네트워크 I/O 대기. 그 경우 D 상태이거나 다른 커널 함수다 |
| 5 | 로그 마지막 두 줄 | 서로 상대의 자원을 WAITING | 락 하나를 오래 기다리는 상황. 서로를 기다리므로 순환 대기 |

### 원인

로그를 스레드별로 정리하면 순환이 드러난다.

| 스레드 | 가진 자원 | 기다리는 자원 | 그 자원을 가진 스레드 |
|---|---|---|---|
| Worker-Thread-1 | Shared_Memory_A | Socket_Pool_B | Worker-Thread-2 |
| Worker-Thread-2 | Socket_Pool_B | Shared_Memory_A | Worker-Thread-1 |

```
Thread-1 ──보유──▶ A        Thread-1 ──대기──▶ B ──보유── Thread-2
Thread-2 ──보유──▶ B        Thread-2 ──대기──▶ A ──보유── Thread-1   → 원이 닫힘
```

교착상태 4대 조건이 모두 성립한다.

| 조건 | 이 앱에서 |
|---|---|
| 상호 배제 | A, B 는 각각 락으로 보호되어 한 스레드만 사용 |
| 점유 대기 | 각 스레드가 하나를 쥔 채 다른 하나를 기다림 |
| 비선점 | 남이 쥔 락을 강제로 빼앗을 수 없음 |
| 순환 대기 | T1 → B → T2 → A → T1 |

근본 원인은 **두 스레드가 락을 서로 반대 순서로 획득**(T1: A→B, T2: B→A)하는 것이다.
멀티스레드는 데드락의 전제 조건일 뿐이고, 순서가 같았다면 발생하지 않는다.
식사하는 철학자 문제에서 두 사람이 동시에 왼쪽 포크를 집은 상황과 같은 구조다.

상태가 D 가 아니라 S(인터럽트 가능한 sleep)이므로 `kill`(SIGTERM)로 정리할 수 있었다. 증거는 kill 하기 전에 수집했다.

### 조치와 검증 (Before & After)

| | Before (`MULTI_THREAD_ENABLE=true`) | After (`MULTI_THREAD_ENABLE=false`) |
|---|---|---|
| 부팅 메시지 | `POTENTIAL DEADLOCK IN CONCURRENT MODE` | `ALL CONFIGURATIONS OPTIMAL` |
| 로그 | 20:37:04 `BLOCKED` 이후 정지 | 20:38:36 까지 계속 출력 |
| RSS | 17.6MB 고정 | 17.6 → 242.8MB 변화 (정상 작업) |
| 스레드 wchan | 3개 모두 `futex_wait_queue` | 워커 2개는 `do_select` (시간 지정 대기, 스스로 깨어남) |
| 작업 결과 | 완료 없음 | Thread-A/B/C 작업 완료 |

```
20:37:52,279 [INFO] [Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
20:37:52,279 [INFO] [Thread-A] Task Started. Calculating... (20%)
20:37:52,380 [INFO] [Thread-A] Preempted. Progress saved at (40%)
20:37:52,735 [INFO] [Thread-A] Resumed. Calculating... (60%)
20:37:53,191 [INFO] [Thread-A] Resumed. Calculating... (100%)
20:37:53,342 [INFO] [Scheduler] All tasks completed.
```

`false` 에서도 스레드는 3개였다. 꺼지는 것은 두 자원을 동시에 잡는 **동시 트랜잭션 경로**이고,
그 대신 작업이 차례를 넘기며(Preempted / Resumed) 진행된다. 동시성을 포기한 **우회책**이다.

### 근본 해결 (코드)

```python
# 모든 스레드가 항상 같은 순서로 획득 → 순환 대기 제거
def with_both(work):
    with lock_A:
        with lock_B:
            work()

# 또는 타임아웃 후 반납 → 비선점 조건 제거
if not lock_B.acquire(timeout=5):
    lock_A.release()
    retry()
```

---

## 7. 트러블슈팅: 미션 중 직접 겪은 문제 3가지

### 7-1. RSS 가 2MB 로 고정돼 보였다

- **현상:** 앱 로그는 `Current Heap: 100MB` 인데 관제 CSV 의 RSS 는 2.0MB, Deadlock 인데 스레드가 1개.
- **원인:** `pgrep -f agent-leak-app | head -1` 이 PID 가 가장 작은 **런처**를 잡았다.
  `ps -eo pid,ppid,rss,nlwp,cmd | grep agent-leak-app` 로 전부 출력하자 프로세스가 두 개였다.
- **해결:** 부모 이름도 agent-leak-app 인 프로세스(워커)를 고르도록 `common.sh` 의 `find_app_pid()` 작성.
  증거에 `pstree -p` 를 넣어 구조를 함께 보여준다.
- **교훈:** 관제 수치가 앱 로그와 안 맞으면 도구보다 **측정 대상 PID** 부터 의심한다.

### 7-2. Deadlock 증거가 "프로세스 없음" 으로 찍혔다

- **현상:** Deadlock 리포트의 `ps -ef` 결과가 "(프로세스 없음)", 스레드 상태가 비어 있었다.
- **원인:** 자동화 스크립트가 "관제 → **kill** → 증거 수집" 순서였다.
- **해결:** "관제 → 증거 수집 → kill" 로 순서 변경 (`run_all_scenarios.sh` STEP 3 → STEP 4).
  재부팅부터 하면 원인이 묻힌다는 미션의 취지를 그대로 겪은 문제다.
- **추가:** 종료 배너(`>>> [SYSTEM] ... <<<`)가 로그 파일에 안 남았다. `nohup ... > file` 로 실행하면
  `print()` 가 블록 버퍼링되어 시그널로 죽을 때 파일에 쓰이지 않는다. `script -q -f` 로 가상 터미널 아래에서
  실행해 배너와 `EXIT_CODE` 가 남게 했다.

### 7-3. CPU 80% 로 설정했는데 50% 에서 종료됐다

- **현상:** `CPU_MAX_OCCUPY=80` 인데 `CPU Threshold Violated! (50.25%)`.
- **처음 가설:** WSL 이 Windows 쪽 CPU 까지 합산한다 → 틀렸다. OS 측정 CPU 는 0~5% 였다.
- **확인:** 부팅 로그의 `[WARNING: Recommend Under 50%]` 를 다시 읽고, 값을 바꿔 재실행했다.
  50 초과 설정은 Load 약 50% 에서 SIGTERM, 50 이하 설정은 설정값에서 쿨다운.
- **결론:** 권장치를 넘는 설정에 대한 앱의 안전 정책. 해결(After)은 임계치를 올리는 게 아니라 권장 범위(30)로 낮추는 것.
- **교훈:** 추측보다 이미 출력된 로그를 먼저 다시 읽는다.

---

## 8. 심화 분석

### 운영 서버라면 monitor.sh 를 어떻게 개선할까

지금은 "죽은 뒤 알려주는" 도구다. "죽기 전에 경고하는" 도구로 바꾼다.

1. **추세 경고:** RSS 가 N회 연속 증가하면 경고. 이번 OOM 은 3초마다 +25MB 가 한 번도 꺾이지 않았다.
2. **도달 시간 예측:** (한도 − 현재) ÷ 증가율. 예: (80 − 42.6) ÷ (25MB/3초) ≈ 4.5초.
3. **단계별 임계치:** 한도의 70% WARNING, 90% CRITICAL.
4. **알림과 자동 증거 수집:** Slack/메일로 알리고 `collect_evidence.sh` 를 자동 호출해 죽기 전 상태를 남긴다.
5. **"일하고 있나" 감시:** 로그가 N초 이상 안 바뀌거나 포트 15034 응답이 없으면 경고 (Deadlock 대응).
6. **상시 실행:** systemd/cron, 장기적으로는 Prometheus + Grafana.

```bash
if (( RSS_MB > PREV_RSS )); then UP=$((UP+1)); else UP=0; fi
if (( UP >= 3 && RSS_MB * 100 / MEMORY_LIMIT >= 70 )); then
  curl -s -X POST -d "{\"text\":\"[WARN] RSS ${RSS_MB}MB, 3회 연속 증가\"}" "$SLACK_WEBHOOK"
  bash collect_evidence.sh --scenario oom
fi
```


### 소스 코드를 고칠 수 있다면

| 장애 | 원인 | 코드 개선 |
|---|---|---|
| OOM | 할당한 데이터의 참조가 남아 회수 안 됨 | 크기 상한(deque maxlen, LRU), 다 쓴 데이터 `del`, `tracemalloc` 테스트 |
| CPU | 부하 루프에 상한·양보 없음 | rate limit, 루프마다 `sleep`, 작업 큐 분할, cgroups `cpu.max` |
| Deadlock | 락을 반대 순서로 획득 | 획득 순서 통일(A→B), `acquire(timeout)` 후 반납, 단일 락으로 통합 |

### 다시 처음부터 한다면

1. **측정 대상부터 검증한다.** 런처 PID 를 재서 시간을 잃었다.
2. **증거 먼저, 정리는 나중.** 처음엔 kill 후에 증거를 모았다.
3. **도구가 무엇을 재는지 먼저 확인한다.** `ps` %CPU 가 누적 평균인 줄 모르고 썼다.
4. **변수는 하나만 바꾼다.** Before/After 는 환경변수 하나, 관찰 시간과 측정 방법은 고정.
5. **설정과 동작이 다르면 로그부터 다시 읽는다.** CPU 50% 문제의 답은 부팅 로그에 있었다.

---

## 9. 산출물 위치

```
agent_home/
├── reports/                          # GitHub Issue 제출용 리포트
│   ├── issue_oom_20261021_203508.md
│   ├── issue_cpu_20261021_203654.md
│   └── issue_deadlock_20261021_203840.md
├── evidence/                         # 실행별 증거 (Before/After × 3)
│   └── <시나리오>_<before|after>_<시각>/
│       ├── run_meta.txt              # 설정값, 생존 시간, 결과, EXIT_CODE, 최대 RSS, 마지막 로그
│       ├── monitor_data.csv          # 3초 간격 관제 데이터
│       ├── agent_app_full.log        # 앱 로그 전체
│       ├── key_logs_<시나리오>.txt    # 핵심 로그 발췌
│       ├── run_output.log            # 터미널 출력 (부팅 시퀀스, 종료 배너, EXIT_CODE)
│       ├── ps_snapshot.txt           # ps -ef, pstree
│       ├── thread_status.txt         # ps -L, top -H, 스레드별 wchan (실행 중일 때)
│       └── deadlock_diagnosis.txt    # Deadlock 진단 체크리스트 (Deadlock 실행 중일 때)
└── logs/                             # 원본 실행 로그와 관제 CSV
mission_scripts/                      # 실행·관제·수집·리포트 스크립트
```
