#!/usr/bin/env bash
# =============================================================================
# generate_report.sh — GitHub Issue 형식 기술 리포트 자동 생성
#
# 증거 디렉터리(evidence/<scene>_before_*, <scene>_after_*)의 실제 데이터로
# Description / Evidence / Root Cause / Workaround(Before & After) 를 채운다.
# Before & After 표의 숫자는 run_meta.txt 에서 읽는다 (하드코딩 없음).
#
# 사용법:
#   bash generate_report.sh --scenario oom|cpu|deadlock [--output DIR]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SCENARIO=""
OUTPUT_DIR="$REPORT_DIR"

while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario|-s) SCENARIO="$2"; shift 2 ;;
        --output|-o)   OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h) echo "사용법: $0 --scenario [oom|cpu|deadlock] [--output DIR]"; exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done
[[ -z "$SCENARIO" ]] && { echo "오류: --scenario 필요 (oom|cpu|deadlock)" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
REPORT_FILE="$OUTPUT_DIR/issue_${SCENARIO}_$(date '+%Y%m%d_%H%M%S').md"

# ─── 증거 디렉터리 ────────────────────────────────────────────────────────────
BEFORE_DIR=$(ls -td "$EVIDENCE_BASE/${SCENARIO}_before_"* 2>/dev/null | head -1 || true)
AFTER_DIR=$(ls -td "$EVIDENCE_BASE/${SCENARIO}_after_"* 2>/dev/null | head -1 || true)
[[ -z "$BEFORE_DIR" ]] && BEFORE_DIR=$(ls -td "$EVIDENCE_BASE/${SCENARIO}_"* 2>/dev/null | grep -v _after_ | head -1 || true)

if [[ -z "$BEFORE_DIR" ]]; then
    echo "오류: 증거 디렉터리가 없습니다. 먼저 run_all_scenarios.sh $SCENARIO 를 실행하세요." >&2
    exit 1
fi

# ─── 헬퍼 ─────────────────────────────────────────────────────────────────────
meta() {   # meta DIR KEY
    grep -m1 "^$2=" "$1/run_meta.txt" 2>/dev/null | cut -d= -f2- || true
}
file_or_note() {  # file_or_note DIR FILE
    if [[ -f "$1/$2" ]]; then sed 's/\r$//' "$1/$2"; else echo "(수집되지 않음: $2)"; fi
}
code_block() { echo '```'; cat; echo '```'; }

monitor_table() {  # monitor_table DIR [max_rows]
    local csv="$1/monitor_data.csv" max=${2:-25}
    if [[ ! -f "$csv" ]]; then echo "(monitor 데이터 없음)"; return; fi
    echo "| 시각 | PID | CPU 순간(top) % | CPU 누적평균(ps) % | RSS (MB) | 스레드 | STAT | 상태 |"
    echo "|---|---|---|---|---|---|---|---|"
    tail -n +2 "$csv" | head -"$max" | awk -F',' '{printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$7,$8,$9}'
}

phase_summary_row() {  # phase_summary_row DIR LABEL
    local d=$1 label=$2
    [[ -z "$d" || ! -f "$d/run_meta.txt" ]] && { echo "| $label | (실행 데이터 없음) | | | | | |"; return; }
    local oc; oc=$(meta "$d" OUTCOME)
    local oc_ko
    case "$oc" in
        EXITED)       oc_ko="스스로 종료" ;;
        ALIVE_KILLED) oc_ko="관찰 종료까지 생존 (수동 kill)" ;;
        *)            oc_ko="$oc" ;;
    esac
    local ec; ec=$(meta "$d" EXIT_CODE)
    local ec_ko="$ec"
    [[ "$ec" == "137" ]] && ec_ko="137 (128+9, SIGKILL)"
    [[ "$ec" == "143" ]] && ec_ko="143 (128+15, SIGTERM)"
    [[ -z "$ec" ]] && ec_ko="- (종료 안 됨)"
    printf "| %s | MEMORY_LIMIT=%s, CPU_MAX_OCCUPY=%s, MULTI_THREAD_ENABLE=%s | %s | %s | %s | %s |\n" \
        "$label" "$(meta "$d" MEMORY_LIMIT)" "$(meta "$d" CPU_MAX_OCCUPY)" "$(meta "$d" MULTI_THREAD_ENABLE)" \
        "$(meta "$d" SURVIVAL_SEC)" "$oc_ko" "$ec_ko" "$(meta "$d" MAX_RSS_MB)"
}

before_after_table() {
    echo "| 구분 | 환경변수 | 생존 시간(초) | 결과 | 종료 코드 | 최대 RSS(MB) |"
    echo "|---|---|---|---|---|---|"
    phase_summary_row "$BEFORE_DIR" "Before"
    phase_summary_row "$AFTER_DIR"  "After"
    echo ""
    echo "마지막 로그 한 줄:"
    echo ""
    echo "- Before: \`$(meta "$BEFORE_DIR" LAST_LOG)\`"
    [[ -n "$AFTER_DIR" ]] && echo "- After: \`$(meta "$AFTER_DIR" LAST_LOG)\`"
    echo ""
    echo "종료 배너(터미널 출력):"
    echo ""
    echo "- Before: \`$(meta "$BEFORE_DIR" BANNER)\`"
    [[ -n "$AFTER_DIR" ]] && echo "- After: \`$(meta "$AFTER_DIR" BANNER)\`"
}

env_block() {  # env_block DIR
    echo '```'
    echo "MEMORY_LIMIT=$(meta "$1" MEMORY_LIMIT)"
    echo "CPU_MAX_OCCUPY=$(meta "$1" CPU_MAX_OCCUPY)"
    echo "MULTI_THREAD_ENABLE=$(meta "$1" MULTI_THREAD_ENABLE)"
    echo "실행 시각: $(meta "$1" START_TIME)   워커 PID: $(meta "$1" WORKER_PID)"
    echo '```'
}

B_MEM=$(meta "$BEFORE_DIR" MEMORY_LIMIT); B_CPU=$(meta "$BEFORE_DIR" CPU_MAX_OCCUPY); B_THR=$(meta "$BEFORE_DIR" MULTI_THREAD_ENABLE)
A_MEM=$(meta "$AFTER_DIR" MEMORY_LIMIT);  A_CPU=$(meta "$AFTER_DIR" CPU_MAX_OCCUPY);  A_THR=$(meta "$AFTER_DIR" MULTI_THREAD_ENABLE)
B_SURV=$(meta "$BEFORE_DIR" SURVIVAL_SEC); B_EXIT=$(meta "$BEFORE_DIR" EXIT_CODE); B_RSS=$(meta "$BEFORE_DIR" MAX_RSS_MB)
A_SURV=$(meta "$AFTER_DIR" SURVIVAL_SEC);  A_RSS=$(meta "$AFTER_DIR" MAX_RSS_MB)

# =============================================================================
write_oom_report() {
{
cat <<EOF
# [Bug] OOM Crash - 메모리 누수로 MEMORY_LIMIT(${B_MEM}MB) 초과, MemoryGuard 가 SIGKILL 로 자기 종료

> **심각도**: Critical | **유형**: Memory Leak / OOM | **상태**: 분석 완료

## 1. Description (현상 설명)

- **무슨 일이 발생했는가?** \`agent-leak-app\` 을 실행하면 약 ${B_SURV}초 뒤 터미널에 \`SELF-TERMINATED (Memory Limit Exceeded)\` 가 찍히며 프로세스가 사라진다. 종료 코드는 ${B_EXIT} (128+9 = SIGKILL).
- **언제, 어떤 조건에서?** \`MEMORY_LIMIT=${B_MEM}\` 으로 실행할 때 매번 재현된다. 워커 프로세스의 RSS 가 3초마다 약 25MB 씩 증가해 최대 ${B_RSS}MB 에 도달한 직후 종료된다.

실행 환경 (Before):
$(env_block "$BEFORE_DIR")

## 2. Evidence & Logs (증거 자료)

### 2-1. monitor 관제 데이터 — RSS 가 단조 증가 (워커 PID 기준)

$(monitor_table "$BEFORE_DIR")

> 측정 대상은 PyInstaller 런처(부모, RSS 약 2MB 고정)가 아니라 실제 작업을 하는 워커(자식) 프로세스다. 런처 → 워커 구조는 아래 \`pstree\` 참고.

### 2-2. 프로그램 실행 로그 (핵심 구간)

$(file_or_note "$BEFORE_DIR" "key_logs_oom.txt" | code_block)

### 2-3. 터미널 출력 (종료 배너 + 종료 코드)

$(grep -a -E 'MemoryGuard|>>> \[SYSTEM\]|Killed|EXIT_CODE' "$BEFORE_DIR/run_output.log" 2>/dev/null | code_block)

### 2-4. ps / pstree 스냅샷

$(file_or_note "$BEFORE_DIR" "ps_snapshot.txt" | head -25 | code_block)

## 3. Root Cause Analysis (원인 분석)

**현상 분석.** 앱 로그의 \`[MemoryWorker] Current Heap\` 과 OS 가 측정한 RSS 가 같은 기울기(+25MB / 3초)로 오른다. 할당한 객체에 대한 참조가 계속 남아 GC 가 회수하지 못하는 전형적인 힙 메모리 누수(Memory Leak) 패턴이다. CPU 사용률은 낮게 유지되므로 연산 부하와는 무관하다.

**앱의 보호 정책(MemoryGuard).** 힙이 \`MEMORY_LIMIT\` 에 도달하는 순간 \`Memory limit exceeded\` → \`Self-terminating process\` 로그를 남기고 자기 자신에게 SIGKILL 을 보낸다. 종료 코드 137 과 터미널의 \`Killed\` 가 그 증거다. SIGKILL 은 프로세스가 받아서 처리할 수 없고 커널이 즉시 제거하므로 정리 작업(cleanup) 없이 사라진다.

**OS 동작 원리.** 커널은 프로세스에 가상 주소 공간을 주고 실제로 쓴 페이지만 물리 메모리(RSS)에 올린다. 누수가 계속되면 free 메모리가 줄고, 페이지 캐시 축소 → 스왑 → 시스템 전체 지연으로 번진다. 끝까지 가면 커널의 OOM Killer 가 \`oom_score\` 가 높은 프로세스를 SIGKILL 하는데, 누수 프로세스가 아닌 다른 서비스가 희생될 수 있다. MemoryGuard 는 그 전에 자기 자신을 먼저 종료해 시스템 전체 장애를 막는 앱 레벨 안전장치다. (이 실행에서는 앱이 먼저 종료되어 \`dmesg\` 에 커널 OOM 기록이 남지 않는다.)

## 4. Workaround & Verification (조치 및 검증)

**조치.** 다른 환경변수는 그대로 두고 \`MEMORY_LIMIT\` 만 ${B_MEM} → ${A_MEM} 으로 상향해 재실행했다.

\`\`\`bash
export MEMORY_LIMIT=${A_MEM}   # Before: ${B_MEM}
\`\`\`

**Before & After (실측).**

$(before_after_table)

**해석.** ${B_MEM}MB 에서는 ${B_SURV}초 만에 SIGKILL 되었지만, ${A_MEM}MB 에서는 임계치 도달 시 \`Memory Cache Flushed. Process Stabilized.\` 와 함께 힙을 비우고 계속 동작한다 (RSS 최대 ${A_RSS}MB 후 다시 감소). 즉 상향 조정으로 프로세스가 관찰 시간 내내 생존했다. 다만 누적 자체는 그대로이므로 임시 조치이며, 근본 해결은 코드에서 참조를 끊거나(\`del\`/\`pop\`) 캐시 크기 상한을 두는 리팩터링이다.

After 실행의 핵심 로그:

$(file_or_note "$AFTER_DIR" "key_logs_oom.txt" | tail -12 | code_block)

---
*증거 디렉터리: \`$BEFORE_DIR\`, \`$AFTER_DIR\` · 생성 시각 $(date '+%Y-%m-%d %H:%M:%S')*
EOF
} > "$REPORT_FILE"
}

# =============================================================================
write_cpu_report() {
{
cat <<EOF
# [Bug] CPU Spike - CpuWorker 부하 상승으로 Watchdog 이 SIGTERM 으로 프로세스 종료

> **심각도**: High | **유형**: CPU Spike / Watchdog | **상태**: 분석 완료

## 1. Description (현상 설명)

- **무슨 일이 발생했는가?** \`agent-leak-app\` 을 실행하면 약 ${B_SURV}초 뒤 \`CPU Threshold Violated!\` 로그와 \`WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM)\` 배너가 출력되고 프로세스가 종료된다. 종료 코드 ${B_EXIT} (128+15 = SIGTERM).
- **언제, 어떤 조건에서?** \`CPU_MAX_OCCUPY=${B_CPU}\` (50 초과) 로 실행할 때 매번 재현된다. 앱이 보고하는 \`Current Load\` 가 5% 에서 3초마다 상승해 약 50% 를 넘는 순간 종료된다.

실행 환경 (Before):
$(env_block "$BEFORE_DIR")

## 2. Evidence & Logs (증거 자료)

### 2-1. 프로그램 실행 로그 — Current Load 상승 구간

$(file_or_note "$BEFORE_DIR" "key_logs_cpu.txt" | code_block)

### 2-2. 터미널 출력 — Watchdog 배너와 종료 코드

$(grep -a -E 'Violated|>>> \[SYSTEM\]|Terminated|EXIT_CODE' "$BEFORE_DIR/run_output.log" 2>/dev/null | code_block)

### 2-3. monitor 관제 데이터 (워커 PID, top 순간값 / ps 누적평균)

$(monitor_table "$BEFORE_DIR")

> 관제 데이터의 OS 측정 CPU 는 낮다. 이 앱의 \`Current Load\` 는 실제 연산 부하가 아니라 앱 내부에서 시뮬레이션하는 값이며, Watchdog 은 그 값을 기준으로 동작한다. 그래서 앱 로그(2-1)와 OS 관제(2-3)를 함께 제시해 교차 검증했다. \`ps\` 의 %CPU 는 프로세스 생성 이후 누적 평균이라 급상승 구간을 보려면 \`top -b -n 2\` 의 두 번째 샘플(순간값)을 써야 한다.

### 2-4. 프로세스 스냅샷

$(file_or_note "$BEFORE_DIR" "resource_measure.txt" | code_block)

## 3. Root Cause Analysis (원인 분석)

**현상 분석.** \`CpuWorker\` 는 시작 후 부하를 계단식으로 올린다 (5% → … → 50%+). 부팅 로그의 \`[CPU] Limit: ${B_CPU}% [WARNING: Recommend Under 50%]\` 가 말하듯, 50 을 초과하는 설정은 앱이 "위험 구성" 으로 분류한다. 이 구성에서는 Load 가 약 50% 를 넘는 순간 \`CPU Threshold Violated!\` 를 남기고 Watchdog 이 SIGTERM 을 보낸다.

**이것은 오류가 아니라 보호 조치다.** 근거는 세 가지다. (1) 종료 직전 로그가 Traceback 이 아니라 CRITICAL 레벨의 임계치 위반 메시지다. (2) 터미널에 \`WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM)\` 배너가 찍힌다. (3) 종료 코드가 143 = 128 + SIGTERM(15) 이다. 메모리 보호가 SIGKILL(즉시 제거)을 쓰는 것과 달리 CPU 보호는 SIGTERM(정리 후 종료 요청)을 쓴다. CPU 과점유는 당장 자원을 회수하지 않아도 시스템이 죽지 않으므로 graceful shutdown 기회를 준다.

**OS 동작 원리.** CPU 는 코어당 한 번에 한 스레드만 실행한다. 항상 실행 가능(R) 상태인 프로세스가 있으면 런큐가 길어지고(load average 상승) 다른 프로세스는 타임슬라이스를 기다리며 응답이 늦어진다. 컨텍스트 스위칭 비용도 늘어난다. 앱이 시작 시 \`nice=10\` 으로 우선순위를 낮추는 것도 같은 이유의 완화책이다(CFS 스케줄러가 nice 가 높은 프로세스에 CPU 시간을 덜 배분).

## 4. Workaround & Verification (조치 및 검증)

**조치.** \`CPU_MAX_OCCUPY\` 만 ${B_CPU} → ${A_CPU} 으로 하향해 재실행했다.

\`\`\`bash
export CPU_MAX_OCCUPY=${A_CPU}   # Before: ${B_CPU}
\`\`\`

**Before & After (실측).**

$(before_after_table)

**해석.** ${B_CPU} 에서는 ${B_SURV}초 만에 SIGTERM 으로 종료됐지만, ${A_CPU} 에서는 Load 가 ${A_CPU}% 에 닿으면 \`Peak reached. Starting cooldown...\` 후 5% 까지 내려갔다 다시 오르는 사이클을 반복하며 종료되지 않는다. 임계치를 낮추면 Watchdog 이 "종료" 대신 "쿨다운" 으로 대응할 여유가 생긴다. 근본 해결은 부하 로직에 상한을 두거나 cgroups \`cpu.max\` 로 OS 레벨에서 CPU 시간을 제한하는 것이다.

After 실행의 핵심 로그:

$(file_or_note "$AFTER_DIR" "key_logs_cpu.txt" | tail -12 | code_block)

---
*증거 디렉터리: \`$BEFORE_DIR\`, \`$AFTER_DIR\` · 생성 시각 $(date '+%Y-%m-%d %H:%M:%S')*
EOF
} > "$REPORT_FILE"
}

# =============================================================================
write_deadlock_report() {
{
cat <<EOF
# [Bug] Deadlock - 두 워커 스레드의 순환 락 대기로 프로세스 무응답 (PID 는 살아있음)

> **심각도**: Critical | **유형**: Deadlock / Thread Hang | **상태**: 분석 완료

## 1. Description (현상 설명)

- **무슨 일이 발생했는가?** \`MULTI_THREAD_ENABLE=true\` 로 실행하면 시작 약 10초 안에 두 워커 스레드가 각각 \`WAITING for ... (Status: BLOCKED)\` 를 남긴 뒤 로그가 완전히 멈춘다. 프로세스는 종료되지 않고 PID 가 유지되지만 CPU 는 0% 에 가깝고 RSS 도 변하지 않는다. 관찰 시간 $(meta "$BEFORE_DIR" OBSERVE_SEC)초 동안 그대로였고 수동 \`kill\` 로 정리했다.
- **언제, 어떤 조건에서?** \`MULTI_THREAD_ENABLE=true\` 일 때 매번 재현된다.

실행 환경 (Before):
$(env_block "$BEFORE_DIR")

## 2. Evidence & Logs (증거 자료)

### 2-1. PID 존재 증거 — 프로세스는 살아있다

$(file_or_note "$BEFORE_DIR" "ps_snapshot.txt" | sed '/=== ps aux/,$d' | code_block)

### 2-2. 스레드 상태 — 모든 스레드가 S(sleep) 상태, wchan 이 futex

$(file_or_note "$BEFORE_DIR" "thread_status.txt" | code_block)

### 2-3. CPU / 메모리 정체 — 반복 측정과 관제 데이터

$(file_or_note "$BEFORE_DIR" "deadlock_diagnosis.txt" | code_block)

$(monitor_table "$BEFORE_DIR" 12)

### 2-4. 프로그램 로그의 마지막 기록

$(file_or_note "$BEFORE_DIR" "key_logs_deadlock.txt" | code_block)

## 3. Root Cause Analysis (원인 분석)

**로그로 재구성한 교착 흐름.**

\`\`\`
Worker-Thread-1  LOCK ACQUIRED [Shared_Memory_A]   (A 보유)
Worker-Thread-2  LOCK ACQUIRED [Socket_Pool_B]     (B 보유)
Worker-Thread-1  Need [Socket_Pool_B]   → WAITING ... BLOCKED   (B 는 Thread-2 가 보유)
Worker-Thread-2  Need [Shared_Memory_A] → WAITING ... BLOCKED   (A 는 Thread-1 이 보유)
                 ↑ 이후 로그 없음 = 양쪽 모두 영원히 대기
\`\`\`

두 스레드가 락을 서로 반대 순서(T1: A→B, T2: B→A)로 잡기 때문에 각자 하나를 쥔 채 상대가 쥔 것을 기다린다. 교착상태 4대 조건이 모두 성립한다.

| 조건 | 이 앱에서 |
|---|---|
| 상호 배제 (Mutual Exclusion) | Shared_Memory_A, Socket_Pool_B 는 Lock 으로 보호되어 한 스레드만 사용 |
| 점유 대기 (Hold and Wait) | T1 은 A 를 쥔 채 B 를, T2 는 B 를 쥔 채 A 를 기다림 |
| 비선점 (No Preemption) | OS 는 사용자 공간 뮤텍스를 강제로 빼앗지 않음 |
| 순환 대기 (Circular Wait) | T1 → B → T2 → A → T1 의 원 |

**시스템 도구로 "멈춤" 을 식별한 논리.** (1) \`ps -ef\` 에 PID 가 있다 → 죽은 것이 아니다. (2) \`top\` 순간 CPU 가 0% 다 → 무한루프(busy-wait)가 아니다. (3) RSS 와 마지막 로그 시각이 고정이다 → 일을 하지 않는다. (4) \`ps -L\` / \`top -H\` 에서 세 스레드(메인 + 워커 2) 모두 상태 S, wchan \`futex_*\` 다 → 전부 락(뮤텍스)을 기다리는 중이다. 디스크 I/O 대기였다면 상태 D 이거나 wchan 이 다른 커널 함수였을 것이다. futex 는 리눅스가 뮤텍스/조건변수를 구현하는 시스템콜로, 파이썬 \`threading.Lock.acquire()\` 가 내부에서 사용한다. (5) 마지막 두 로그가 서로의 자원을 WAITING → 순환 대기 확정. 메인 스레드까지 futex 인 이유는 \`join()\` 으로 워커를 기다리기 때문이다.

이 상태는 "식사하는 철학자" 문제에서 모든 철학자가 왼쪽 포크만 들고 오른쪽을 기다리는 상황과 같은 구조다. 상태가 D 가 아니라 S(인터럽트 가능한 sleep)이기 때문에 \`kill\`(SIGTERM) 은 먹힌다.

## 4. Workaround & Verification (조치 및 검증)

**조치.** \`MULTI_THREAD_ENABLE\` 만 ${B_THR} → ${A_THR} 로 바꿔 재실행했다 (동시 실행 모드 해제).

\`\`\`bash
export MULTI_THREAD_ENABLE=${A_THR}   # Before: ${B_THR}
\`\`\`

**Before & After (실측).**

$(before_after_table)

**해석.** 단일 스레드 모드에서는 Thread-A/B/C 가 \`Preempted\` / \`Resumed\` 를 반복하며 순서대로 100% 까지 진행하고 \`All tasks completed.\` 로 끝난다. 두 자원을 동시에 쥐는 코드 경로 자체가 실행되지 않으므로 경합이 사라진다. 이는 동시성을 포기하는 우회책이며, 근본 해결은 (1) 모든 스레드가 락을 A → B 의 같은 순서로만 획득해 순환 대기를 제거하거나, (2) \`acquire(timeout=…)\` 실패 시 보유한 락을 반납하고 재시도해 비선점 조건을 깨거나, (3) 두 자원을 하나의 락으로 묶는 것이다.

After 실행의 핵심 로그:

$(file_or_note "$AFTER_DIR" "key_logs_deadlock.txt" | tail -14 | code_block)

---
*증거 디렉터리: \`$BEFORE_DIR\`, \`$AFTER_DIR\` · 생성 시각 $(date '+%Y-%m-%d %H:%M:%S')*
EOF
} > "$REPORT_FILE"
}

case "$SCENARIO" in
    oom)      write_oom_report ;;
    cpu)      write_cpu_report ;;
    deadlock) write_deadlock_report ;;
    *) echo "알 수 없는 시나리오: $SCENARIO" >&2; exit 1 ;;
esac

echo -e "\n${GREEN}${BOLD}리포트 생성 완료!${RESET}  ${CYAN}$REPORT_FILE${RESET}"
[[ -z "$AFTER_DIR" ]] && echo -e "${YELLOW}  (After 실행 데이터가 없어 Before 만 채웠습니다. run_all_scenarios.sh $SCENARIO 로 둘 다 실행하세요)${RESET}"
echo "  → 내용 확인 후 GitHub Repository 의 Issues > New Issue 에 붙여넣기"
