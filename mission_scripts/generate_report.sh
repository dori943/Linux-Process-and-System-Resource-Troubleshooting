#!/usr/bin/env bash
# =============================================================================
# generate_report.sh — GitHub Issue 형식 기술 리포트 자동 생성
#
# 수집된 증거 데이터를 기반으로 마크다운 리포트(.md)를 생성합니다.
# Evidence 디렉터리가 있으면 실제 데이터를, 없으면 템플릿을 출력합니다.
#
# 사용법:
#   bash generate_report.sh --scenario oom
#   bash generate_report.sh --scenario cpu
#   bash generate_report.sh --scenario deadlock
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'; BOLD='\033[1m'; GREEN='\033[0;32m'; RESET='\033[0m'

SCENARIO=""
AGENT_LOG_DIR="/home/doheekim/agent_home/logs"
EVIDENCE_BASE="/home/doheekim/agent_home/evidence"
OUTPUT_DIR="/home/doheekim/agent_home/reports"

while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario|-s) SCENARIO="$2"; shift 2 ;;
        --output|-o)   OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "사용법: $0 --scenario [oom|cpu|deadlock]"
            exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SCENARIO" ]]; then
    echo "오류: --scenario 옵션이 필요합니다 (oom|cpu|deadlock)" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE_COMPACT=$(date '+%Y%m%d_%H%M%S')
REPORT_FILE="$OUTPUT_DIR/issue_${SCENARIO}_${DATE_COMPACT}.md"

# ─── 최신 증거 디렉터리 찾기 ──────────────────────────────────────────────────
EVIDENCE_DIR=$(ls -td "$EVIDENCE_BASE/${SCENARIO}_"* 2>/dev/null | head -1 || echo "")
APP_LOG="$AGENT_LOG_DIR/agent_app.log"

load_evidence() {
    local file="$EVIDENCE_DIR/$1"
    if [[ -n "$EVIDENCE_DIR" ]] && [[ -f "$file" ]]; then
        cat "$file"
    else
        echo "(증거 파일 없음 — collect_evidence.sh 를 먼저 실행하세요)"
    fi
}

key_log_section() {
    local log_file="$EVIDENCE_DIR/key_logs_${SCENARIO}.txt"
    if [[ -n "$EVIDENCE_DIR" ]] && [[ -f "$log_file" ]]; then
        cat "$log_file"
    elif [[ -f "$APP_LOG" ]]; then
        tail -20 "$APP_LOG"
    else
        echo "(로그 없음)"
    fi
}

monitor_summary() {
    local csv="$EVIDENCE_DIR/monitor_data.csv"
    if [[ -n "$EVIDENCE_DIR" ]] && [[ -f "$csv" ]]; then
        echo "| Timestamp | CPU% | RSS(MB) | Threads | Status |"
        echo "|-----------|------|---------|---------|--------|"
        tail -n +2 "$csv" | awk -F',' '{
            printf "| %s | %s | %s | %s | %s |\n", $1, $3, $4, $6, $7
        }' | head -20
    else
        echo "(monitor.sh 데이터 없음 — monitor.sh 를 실행 후 수집하세요)"
    fi
}

# =============================================================================
# ─── OOM 리포트 ───────────────────────────────────────────────────────────────
# =============================================================================
write_oom_report() {
cat > "$REPORT_FILE" <<'MDEOF'
# [Bug] OOM Crash - 메모리 누수로 인한 프로세스 강제 종료

> **심각도**: Critical | **유형**: Memory Leak / OOM | **상태**: 분석 완료

---

## 1. Description (현상 설명)

- **무슨 일이 발생했는가?**
  `agent-leak-app` 프로세스가 예고 없이 종료되는 현상이 반복적으로 관측되었다.
  프로세스가 시작된 지 약 12~15초 후 자동으로 사라지며, 재시작 없이 종료된다.

- **언제, 어떤 조건에서 발생했는가?**
  `MEMORY_LIMIT=100` (MB) 환경변수 설정 상태에서 실행 시 재현 가능.
  메모리 사용량이 `25MB → 50MB → 75MB → 100MB` 패턴으로 선형 증가 후 종료.
MDEOF

echo "" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"
echo "실행 환경:" >> "$REPORT_FILE"
echo "  MEMORY_LIMIT=100" >> "$REPORT_FILE"
echo "  CPU_MAX_OCCUPY=50" >> "$REPORT_FILE"
echo "  MULTI_THREAD_ENABLE=false" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

---

## 2. Evidence & Logs (증거 자료)

### 2-1. monitor.sh 관제 데이터
MDEOF

monitor_summary >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

### 2-2. 프로그램 실행 로그 (핵심 구간)

```
MDEOF
key_log_section >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

### 2-3. ps 스냅샷 (종료 직전)

```
MDEOF
load_evidence "ps_snapshot.txt" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

---

## 3. Root Cause Analysis (원인 분석)

### 기술적 원인

`agent-leak-app`은 내부 `MemoryWorker` 스레드가 매 약 3초마다 **25MB씩 힙 메모리를 추가 할당**한다.
할당된 메모리가 해제되지 않으므로 이는 전형적인 **메모리 누수(Memory Leak)** 패턴이다.

```
[MemoryWorker] Current Heap: 25MB
[MemoryWorker] Current Heap: 50MB   ← +25MB / 3초
[MemoryWorker] Current Heap: 75MB   ← +25MB / 3초
[MemoryWorker] Current Heap: 100MB  ← LIMIT 도달
```

### 애플리케이션 보호 메커니즘 (MemoryGuard)

앱 내부 `MemoryGuard` 정책은 `MEMORY_LIMIT` 임계치 도달 시 **자기 자신에게 SIGKILL을 보내**
프로세스를 강제 종료한다. 이는 시스템 전체의 OOM Killer 발동을 예방하기 위한 안전장치이다.

### OS 동작 원리

| 단계 | 설명 |
|------|------|
| 메모리 누수 | 객체가 GC/free 없이 누적 할당 → RSS 단조 증가 |
| 임계치 도달 | MEMORY_LIMIT 값에 물리 RSS가 도달 |
| MemoryGuard 발동 | `os.kill(os.getpid(), signal.SIGKILL)` 또는 동등한 자기 종료 |
| 커널 처리 | SIGKILL 수신 → 프로세스 즉시 소멸, 자식 프로세스 고아 처리 |

만약 MemoryGuard가 없다면, 물리 메모리 고갈 시 OS의 **OOM Killer**가 개입하여
점수(oom_score)가 높은 프로세스를 강제로 종료하며, 다른 정상 프로세스가 피해를 입을 수 있다.

---

## 4. Workaround & Verification (조치 및 검증)

### 조치: MEMORY_LIMIT 환경변수 상향 조정

메모리 누수 자체를 고치지 않고 임계치를 높여 **생존 시간을 연장**하는 임시 조치이다.

```bash
# Before (기존 설정)
export MEMORY_LIMIT=100

# After (조치 후)
export MEMORY_LIMIT=300
```

### Before & After 비교

| 항목 | Before (MEMORY_LIMIT=100) | After (MEMORY_LIMIT=300) |
|------|--------------------------|--------------------------|
| 생존 시간 | ~12초 | ~36초 (3배 연장) |
| 종료 원인 | MemoryGuard (100MB) | MemoryGuard (300MB) |
| 메모리 패턴 | 25→50→75→100MB → 종료 | 25→50→...→300MB → 종료 |

> ⚠️ **임시 조치임**: `MEMORY_LIMIT`을 높여도 누수가 계속되므로 결국 종료된다.

### 근본 해결 제안

1. **코드 수정**: `MemoryWorker` 내 메모리 할당 후 명시적 해제 구현
2. **메모리 프로파일링**: `valgrind`, `memory_profiler` 등으로 누수 지점 정확히 특정
3. **정기 재시작 정책**: 임시방편으로 cron/systemd를 통한 주기적 프로세스 재시작 적용

---

*리포트 생성 시각:*
MDEOF

echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
}

# =============================================================================
# ─── CPU 리포트 ───────────────────────────────────────────────────────────────
# =============================================================================
write_cpu_report() {
cat > "$REPORT_FILE" <<'MDEOF'
# [Bug] CPU Spike - CPU 과점유로 인한 Watchdog 강제 종료

> **심각도**: High | **유형**: CPU Spike / Watchdog | **상태**: 분석 완료

---

## 1. Description (현상 설명)

- **무슨 일이 발생했는가?**
  `agent-leak-app` 프로세스의 CPU 사용률이 시간이 지남에 따라 점진적으로 상승하다가,
  내부 `Watchdog` 정책에 의해 SIGTERM이 전송되어 프로세스가 강제 종료된다.

- **언제, 어떤 조건에서 발생했는가?**
  `CPU_MAX_OCCUPY=80` 환경변수 설정 상태에서 실행 시 재현 가능.
  CPU 사용률이 `5% → 57%` 수준으로 점진 상승 후 임계치 초과 시 종료.
MDEOF

echo "" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"
echo "실행 환경:" >> "$REPORT_FILE"
echo "  MEMORY_LIMIT=512" >> "$REPORT_FILE"
echo "  CPU_MAX_OCCUPY=80" >> "$REPORT_FILE"
echo "  MULTI_THREAD_ENABLE=false" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

---

## 2. Evidence & Logs (증거 자료)

### 2-1. monitor.sh 관제 데이터 (CPU 급상승 구간)
MDEOF

monitor_summary >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

### 2-2. 프로그램 실행 로그 (Watchdog 발동 구간)

```
MDEOF
key_log_section >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

### 2-3. ps / top 스냅샷 (CPU 상승 구간)

```
MDEOF
load_evidence "resource_measure.txt" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

---

## 3. Root Cause Analysis (원인 분석)

### 기술적 원인

`agent-leak-app` 내부 `CpuWorker` 스레드는 시간 경과에 따라
**CPU 부하를 점진적으로 증가**시키도록 설계되어 있다.

```
[CpuWorker] Current Load:  5.00%  ← 시작
[CpuWorker] Current Load:  8.09%  ← 상승
[CpuWorker] Current Load: 16.34%  ← 가속
[CpuWorker] Current Load: 41.26%  ← 급등
[CpuWorker] CPU Threshold Violated! (57.83%)  ← Watchdog 발동
```

### Watchdog 메커니즘

내부 `Watchdog` 모듈은 `CPU_MAX_OCCUPY` 임계치를 초과하는 순간
**SIGTERM 시그널**을 프로세스에 전송하여 종료를 유도한다.

이는 단일 프로세스가 시스템 CPU 전체를 점거하는 것을 방지하는 **과점유 방지 정책**이다.

### OS 동작 원리

| 단계 | 설명 |
|------|------|
| CPU 부하 상승 | 연산 루프가 스케줄러에게 CPU 타임을 점점 더 많이 요구 |
| 타 프로세스 지연 | 런큐 길이 증가, 컨텍스트 스위칭 지연, 시스템 응답성 저하 |
| Watchdog 감지 | 현재 CPU% ≥ CPU_MAX_OCCUPY |
| SIGTERM 발송 | 프로세스에 Graceful Shutdown 요청 |
| 프로세스 종료 | 시그널 핸들러 실행 후 exit |

---

## 4. Workaround & Verification (조치 및 검증)

### 조치: CPU_MAX_OCCUPY 환경변수 하향 조정

임계치를 낮춰 Watchdog가 **더 일찍 개입**하도록 하거나,
임계치를 높여 **더 오래 생존**하도록 하는 트레이드오프를 확인한다.

```bash
# Before (과도한 허용치)
export CPU_MAX_OCCUPY=80

# After (보수적 설정)
export CPU_MAX_OCCUPY=30
```

### Before & After 비교

| 항목 | Before (CPU_MAX_OCCUPY=80) | After (CPU_MAX_OCCUPY=30) |
|------|---------------------------|--------------------------|
| 종료 시점 CPU | ~57% | ~30% |
| 생존 시간 | ~30초 | ~15초 (더 일찍 종료) |
| 시스템 영향 | 타 프로세스 지연 발생 | 영향 최소화 |

### 근본 해결 제안

1. **코드 수정**: `CpuWorker`의 부하 증가 로직에 상한 캡 설정
2. **cgroups 적용**: Linux cgroup의 `cpu.cfs_quota_us`로 OS 레벨 CPU 상한 강제
3. **nice/ionice 튜닝**: 프로세스 우선순위를 낮춰 타 프로세스 영향 최소화

---

*리포트 생성 시각:*
MDEOF

echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
}

# =============================================================================
# ─── Deadlock 리포트 ──────────────────────────────────────────────────────────
# =============================================================================
write_deadlock_report() {
cat > "$REPORT_FILE" <<'MDEOF'
# [Bug] Deadlock - 스레드 간 순환 대기로 인한 프로세스 무응답

> **심각도**: Critical | **유형**: Deadlock / Thread Hang | **상태**: 분석 완료

---

## 1. Description (현상 설명)

- **무슨 일이 발생했는가?**
  `agent-leak-app` 프로세스가 종료되지 않고 PID가 유지된 상태로 **무한 대기** 상태에 빠졌다.
  로그 출력이 멈추고, CPU 사용률은 거의 0%이며, 메모리 변화도 없다.
  외부에서 보면 "프로세스가 살아있다"처럼 보이지만 실제로는 **아무 작업도 하지 않는 상태**이다.

- **언제, 어떤 조건에서 발생했는가?**
  `MULTI_THREAD_ENABLE=true` 환경변수 설정 시 100% 재현 가능.
  두 워커 스레드(`Worker-Thread-1`, `Worker-Thread-2`)가 서로의 자원을 기다리는
  순환 대기 구조로 진입한다.
MDEOF

echo "" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"
echo "실행 환경:" >> "$REPORT_FILE"
echo "  MEMORY_LIMIT=512" >> "$REPORT_FILE"
echo "  CPU_MAX_OCCUPY=50" >> "$REPORT_FILE"
echo "  MULTI_THREAD_ENABLE=true" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

---

## 2. Evidence & Logs (증거 자료)

### 2-1. PID 존재 증거 (프로세스는 살아있음)

```
MDEOF
load_evidence "ps_snapshot.txt" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

### 2-2. 스레드 상태 (CPU 점유 없음, Sleep 상태)

```
MDEOF
load_evidence "thread_status.txt" >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

### 2-3. 마지막 로그 (교착 진입 시점)

```
MDEOF
key_log_section >> "$REPORT_FILE"
echo '```' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

### 2-4. CPU 변화 없음 증거 (모니터 데이터)
MDEOF

monitor_summary >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<'MDEOF'

---

## 3. Root Cause Analysis (원인 분석)

### 기술적 원인 — 교착상태(Deadlock) 4대 조건 모두 충족

```
Worker-Thread-1: Shared_Memory_A 보유 → Socket_Pool_B 대기
Worker-Thread-2: Socket_Pool_B 보유 → Shared_Memory_A 대기
```

| 조건 | 충족 여부 | 설명 |
|------|-----------|------|
| 상호 배제 (Mutual Exclusion) | ✅ | Shared_Memory_A, Socket_Pool_B는 동시 접근 불가 |
| 점유 대기 (Hold & Wait) | ✅ | 각 스레드가 자원을 보유한 채 다른 자원을 기다림 |
| 비선점 (No Preemption) | ✅ | OS가 강제로 자원을 빼앗지 않음 |
| 순환 대기 (Circular Wait) | ✅ | Thread-1 → B 대기, Thread-2 → A 대기 (원형) |

### 로그에서 읽을 수 있는 교착 흐름

```
[Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]          ← A 획득
[Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]            ← B 획득
[Worker-Thread-2] WAITING for [Shared_Memory_A]... BLOCKED  ← A가 필요하지만 Thread-1이 보유
[Worker-Thread-1] WAITING for [Socket_Pool_B]...  BLOCKED   ← B가 필요하지만 Thread-2가 보유
                                                   ↑ 이후 로그 없음 = 무한 대기
```

### 식사하는 철학자 비유

이 상황은 "식사하는 철학자 문제"와 동일한 구조이다.
- Thread-1 = 철학자 A (왼쪽 포크=Shared_Memory_A 획득, 오른쪽 포크=Socket_Pool_B 대기)
- Thread-2 = 철학자 B (왼쪽 포크=Socket_Pool_B 획득, 오른쪽 포크=Shared_Memory_A 대기)
- 양쪽 모두 포크를 내려놓지 않으므로 식사를 영원히 시작할 수 없다.

---

## 4. Workaround & Verification (조치 및 검증)

### 조치: MULTI_THREAD_ENABLE=false 로 변경 (단일 스레드 모드)

병렬 실행을 비활성화하여 자원 경합 자체를 제거한다.

```bash
# Before (교착상태 발생)
export MULTI_THREAD_ENABLE=true

# After (단일 스레드, 정상 동작)
export MULTI_THREAD_ENABLE=false
```

### Before & After 비교

| 항목 | Before (MULTI_THREAD=true) | After (MULTI_THREAD=false) |
|------|---------------------------|---------------------------|
| 실행 결과 | 프로세스 무응답 (BLOCKED) | 정상 작업 완료 |
| 로그 진행 | 마지막 줄 이후 멈춤 | Thread-A,B,C 순차 100% 완료 |
| CPU 사용률 | ~0% (대기) | 정상 사용 후 복귀 |
| PID 존재 | 계속 존재 (좀비처럼) | 작업 완료 후 정상 종료 |

### 근본 해결 제안

1. **락 순서 통일**: 모든 스레드가 자원을 `A → B` 순서로만 획득 (순환 대기 제거)
2. **tryLock + 타임아웃**: 락 획득 실패 시 보유 자원을 반납하고 재시도
3. **교착 탐지기**: 락 대기 그래프에서 사이클을 탐지하는 알고리즘 도입
4. **자원 계층 설계**: 자원에 우선순위를 부여하여 낮은 순서부터 획득하도록 설계

---

*리포트 생성 시각:*
MDEOF

echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
}

# ─── 시나리오 분기 ────────────────────────────────────────────────────────────
case "$SCENARIO" in
    oom)      write_oom_report ;;
    cpu)      write_cpu_report ;;
    deadlock) write_deadlock_report ;;
    *)
        echo "알 수 없는 시나리오: $SCENARIO (oom|cpu|deadlock)" >&2
        exit 1 ;;
esac

echo -e "\n${GREEN}${BOLD}리포트 생성 완료!${RESET}"
echo -e "  파일: ${CYAN}$REPORT_FILE${RESET}"
echo ""
echo -e "  미리보기 (head -30):"
echo "  ─────────────────────────────────────"
head -30 "$REPORT_FILE" | sed 's/^/  /'
echo "  ─────────────────────────────────────"
echo ""
echo -e "${YELLOW}GitHub Issue 제출 방법:${RESET}"
echo "  cat $REPORT_FILE   # 내용 확인"
echo "  → GitHub Repository의 Issues > New Issue 에 내용 붙여넣기"
