# agent-leak-app 미션 스크립트

시스템 장애(OOM / CPU Spike / Deadlock) 를 재현하고, 증거를 수집해 GitHub Issue 형식 리포트를 자동 생성하는 스크립트 모음입니다.

---

## 파일 구성

| 파일 | 역할 |
|------|------|
| `setup.sh` | 실행 환경 초기화 (폴더 생성, secret.key 생성) |
| `run_agent.sh` | 시나리오별 환경변수 설정 후 앱 실행 |
| `monitor.sh` | CPU / 메모리 / 스레드 실시간 관제 + CSV 저장 |
| `collect_evidence.sh` | ps, 로그, 스레드 상태 등 증거 파일 자동 수집 |
| `generate_report.sh` | 수집된 증거로 GitHub Issue 형식 `.md` 리포트 생성 |
| `run_all_scenarios.sh` | 위 과정을 시나리오별로 순차 자동 실행 |

---

## 실행 방법

```bash
# 최초 1회 — 환경 초기화
bash setup.sh --binary ./agent-leak-app-x86

# 시나리오별 실행 (리포트까지 자동 생성)
bash run_all_scenarios.sh oom
bash run_all_scenarios.sh cpu
bash run_all_scenarios.sh deadlock
bash run_all_scenarios.sh all   # 3개 한번에
```

---

## 산출물 위치

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

## 장애 유형 설명

### OOM (Out of Memory) — 메모리 누수

프로그램이 메모리를 계속 쌓기만 하고 해제하지 않아 한계치를 초과하면 강제 종료되는 현상입니다.

- **증상**: 프로세스가 예고 없이 갑자기 사라짐
- **감지**: 메모리 사용량이 시간이 지날수록 단조 증가 → 임계치 도달 후 종료
- **재현 환경변수**: `MEMORY_LIMIT=80`

```
[MemoryWorker] Current Heap: 25MB → 50MB → 75MB → 80MB
[CRITICAL] Memory limit exceeded → Self-terminating
```

---

### CPU Spike — CPU 과점유

특정 프로세스가 CPU를 독차지해 시스템 전체가 느려지고, 내부 Watchdog에 의해 강제 종료되는 현상입니다.

- **증상**: 시스템이 버벅이다가 프로세스가 종료됨
- **감지**: CPU 사용률이 점진적으로 치솟다가 임계치 초과 시 SIGTERM
- **재현 환경변수**: `CPU_MAX_OCCUPY=80`

```
[CpuWorker] Current Load: 5% → 16% → 41% → 57%
[CRITICAL] CPU Threshold Violated → Terminated
```

---

### Deadlock — 교착상태

두 스레드가 서로의 자원을 무한히 기다리며 아무것도 못 하는 상태입니다. 프로세스는 살아있지만 실제로는 멈춰있습니다.

- **증상**: PID는 존재하지만 CPU 0%, 메모리 변화 없음, 로그가 멈춤
- **감지**: 스레드가 BLOCKED 상태로 고착, 로그 출력이 특정 시점에서 중단
- **재현 환경변수**: `MULTI_THREAD_ENABLE=true`

```
[Worker-Thread-1] LOCK ACQUIRED: Shared_Memory_A → WAITING for Socket_Pool_B (BLOCKED)
[Worker-Thread-2] LOCK ACQUIRED: Socket_Pool_B   → WAITING for Shared_Memory_A (BLOCKED)
→ 이후 로그 없음 (무한 대기)
```

---

## 시나리오별 환경변수 요약

| 시나리오 | MEMORY_LIMIT | CPU_MAX_OCCUPY | MULTI_THREAD_ENABLE |
|---------|-------------|----------------|---------------------|
| oom | 80 MB | 50% | false |
| cpu | 512 MB | 80% | false |
| deadlock | 512 MB | 50% | true |
