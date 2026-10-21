#!/usr/bin/env bash
# =============================================================================
# collect_evidence.sh — 장애 유형별 증거 자료 자동 수집 스크립트
#
# 기능:
#   - 실행 중 or 실행 후 프로세스 상태 스냅샷 (ps / top / pstree / /proc)
#   - 스레드 상태 (ps -L, top -H, /proc/PID/task/*/wchan)  ← Deadlock 핵심 증거
#   - 로그 핵심 구간 추출
#   - 증거 디렉터리에 정리
#
# 사용법:
#   bash collect_evidence.sh --scenario oom|cpu|deadlock [--out DIR] [--run-log FILE] [--monitor-csv FILE]
#
# ※ Deadlock 은 프로세스가 살아있을 때 실행해야 PID/스레드 증거가 남는다.
#    run_all_scenarios.sh 는 kill 하기 전에 이 스크립트를 호출한다.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

ok()     { echo -e "${GREEN}[수집]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[경고]${RESET}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}==== $* ====${RESET}\n"; }

SCENARIO=""
EVIDENCE_DIR=""
RUN_LOG=""
MONITOR_CSV=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario|-s)  SCENARIO="$2"; shift 2 ;;
        --out|-o)       EVIDENCE_DIR="$2"; shift 2 ;;
        --run-log)      RUN_LOG="$2"; shift 2 ;;
        --monitor-csv)  MONITOR_CSV="$2"; shift 2 ;;
        --help|-h)
            echo "사용법: $0 --scenario [oom|cpu|deadlock] [--out DIR]"
            exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LABEL="${SCENARIO:-snapshot}"
[[ -z "$EVIDENCE_DIR" ]] && EVIDENCE_DIR="$EVIDENCE_BASE/${LABEL}_${TIMESTAMP}"
mkdir -p "$EVIDENCE_DIR"

header "증거 수집: $LABEL  →  $EVIDENCE_DIR"

# ─── PID 확인 (워커/자식) ─────────────────────────────────────────────────────
PID=$(find_app_pid)
if [[ -n "$PID" ]]; then
    ok "프로세스 발견: PID=$PID (워커)"
else
    warn "프로세스가 실행 중이지 않습니다. 사후 증거만 수집합니다."
fi

# ─── 1. ps 전체 스냅샷 ────────────────────────────────────────────────────────
{
    echo "=== ps -ef | grep $TARGET ($(date)) ==="
    ps -ef | grep "$TARGET" | grep -v grep || echo "(프로세스 없음)"
    echo ""
    if [[ -n "$PID" ]]; then
        echo "=== pstree -p (런처 → 워커 구조) ==="
        PPID_=$(ps -o ppid= -p "$PID" | tr -d ' ')
        pstree -p "$PPID_" 2>/dev/null || ps -o pid,ppid,stat,cmd -p "$PPID_","$PID"
        echo ""
    fi
    echo "=== ps aux --sort=-%cpu | head -8 (시스템 전체 상위) ==="
    ps aux --sort=-%cpu | head -8
} > "$EVIDENCE_DIR/ps_snapshot.txt"
ok "ps 스냅샷 저장: ps_snapshot.txt"

# ─── 2. 프로세스 상세 (살아있을 때) ───────────────────────────────────────────
if [[ -n "$PID" ]]; then
    {
        echo "=== /proc/$PID/status (발췌) ==="
        grep -E "^(Name|State|Pid|PPid|Threads|VmSize|VmRSS|VmHWM|voluntary_ctxt|nonvoluntary_ctxt)" \
            "/proc/$PID/status" 2>/dev/null || echo "(없음)"
        echo ""
        echo "=== /proc/$PID/wchan ==="
        cat "/proc/$PID/wchan" 2>/dev/null; echo
        echo ""
        echo "=== /proc/$PID/oom_score ==="
        cat "/proc/$PID/oom_score" 2>/dev/null || echo "(없음)"
    } > "$EVIDENCE_DIR/proc_status.txt"
    ok "프로세스 상세 저장: proc_status.txt"

    {
        echo "=== 스레드 목록 (ps -L -p $PID) ==="
        ps -L -p "$PID" -o pid,lwp,pcpu,pmem,stat,wchan:25,comm 2>/dev/null || echo "(없음)"
        echo ""
        echo "=== 스레드별 CPU (top -H -b -n 1 -p $PID) ==="
        top -H -b -n 1 -p "$PID" 2>/dev/null | sed -n '/^ *PID/,$p' || echo "(없음)"
        echo ""
        echo "=== /proc/$PID/task/*/wchan (스레드별 커널 대기 함수) ==="
        for tid in /proc/$PID/task/*/; do
            TID=$(basename "$tid")
            WCHAN=$(cat "$tid/wchan" 2>/dev/null || echo "?")
            STATE=$(grep "^State:" "$tid/status" 2>/dev/null | awk '{print $2,$3}')
            echo "  TID $TID : wchan=$WCHAN  state=$STATE"
        done
    } > "$EVIDENCE_DIR/thread_status.txt"
    ok "스레드 상태 저장: thread_status.txt"

    {
        echo "=== CPU/MEM 측정 ($(date)) ==="
        ps -p "$PID" -o pid,ppid,pcpu,pmem,rss,vsz,nlwp,stat,etime,cmd --no-headers 2>/dev/null || echo "(없음)"
        echo ""
        echo "=== 3회 반복 측정 (3초 간격): 순간 CPU(top) / 누적평균 CPU(ps) / RSS ==="
        for i in 1 2 3; do
            if ! kill -0 "$PID" 2>/dev/null; then echo "  프로세스 종료됨"; break; fi
            NOWC=$(cpu_now "$PID")
            AVG=$(ps -p "$PID" -o pcpu= 2>/dev/null | tr -d ' ')
            RSS=$(ps -p "$PID" -o rss= 2>/dev/null | tr -d ' ')
            LASTLOG=$(tail -1 "$AGENT_LOG_DIR/agent_app.log" 2>/dev/null | cut -c1-23)
            printf "  [%s] CPU_now=%s%%  CPU_avg=%s%%  RSS=%sKB (%dMB)  마지막로그시각=%s\n" \
                "$(date '+%H:%M:%S')" "$NOWC" "${AVG:-0}" "${RSS:-0}" "$(( ${RSS:-0} / 1024 ))" "$LASTLOG"
            sleep 2
        done
    } > "$EVIDENCE_DIR/resource_measure.txt"
    ok "리소스 측정 저장: resource_measure.txt"
fi

# ─── 3. 시스템 전체 리소스 ────────────────────────────────────────────────────
{
    echo "=== 시스템 메모리 (free -h) ==="
    free -h
    echo ""
    echo "=== 시스템 부하 (uptime) / 코어 수 ==="
    uptime
    echo "nproc: $(nproc)"
    echo ""
    echo "=== top 스냅샷 (1회) ==="
    top -b -n 1 | head -20
} > "$EVIDENCE_DIR/system_resources.txt"
ok "시스템 리소스 저장: system_resources.txt"

# ─── 4. 로그 복사 및 핵심 구간 추출 ──────────────────────────────────────────
APP_LOG="$AGENT_LOG_DIR/agent_app.log"
if [[ -f "$APP_LOG" ]]; then
    cp "$APP_LOG" "$EVIDENCE_DIR/agent_app_full.log"
    ok "전체 로그 복사: agent_app_full.log"

    case "$SCENARIO" in
        oom)
            PATTERN="MemoryWorker|MemoryGuard|Memory limit|Self-terminating|Heap|Cache Flushed|Reached Limit" ;;
        cpu)
            PATTERN="CpuWorker|CPU Threshold|SIGTERM|Watchdog|Current Load|Peak reached|Cooldown" ;;
        deadlock)
            PATTERN="Worker-Thread|LOCK|WAITING|BLOCKED|AgentWorker|transaction|Scheduler|Thread-[ABC]|Preempted|Resumed|completed" ;;
        *)
            PATTERN="." ;;
    esac
    {
        echo "=== ${SCENARIO:-전체} 관련 핵심 로그 ==="
        grep -E "$PATTERN" "$APP_LOG" | tail -40 || echo "(해당 로그 없음)"
        echo ""
        echo "=== 마지막 5줄 (로그 멈춤 시점 확인용) ==="
        tail -5 "$APP_LOG"
    } > "$EVIDENCE_DIR/key_logs_${LABEL}.txt"
    ok "핵심 로그 추출: key_logs_${LABEL}.txt"
else
    warn "앱 로그 없음: $APP_LOG"
fi

# 실행 로그(터미널 출력: 부팅 시퀀스 + 종료 배너 + EXIT_CODE) 복사
if [[ -z "$RUN_LOG" ]]; then
    RUN_LOG=$(ls -t "$AGENT_LOG_DIR"/run_*.log 2>/dev/null | head -1 || echo "")
fi
if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
    sed -e 's/\r$//' -e '/^Script \(started\|done\) on/d' "$RUN_LOG" > "$EVIDENCE_DIR/run_output.log"
    ok "실행 출력 복사: run_output.log"
fi

# monitor CSV 복사
if [[ -z "$MONITOR_CSV" ]]; then
    MONITOR_CSV=$(ls -t "$AGENT_LOG_DIR"/monitor_*.csv 2>/dev/null | head -1 || echo "")
fi
if [[ -n "$MONITOR_CSV" && -f "$MONITOR_CSV" ]]; then
    cp "$MONITOR_CSV" "$EVIDENCE_DIR/monitor_data.csv"
    ok "모니터 CSV 복사: monitor_data.csv"
fi

# ─── 5. Deadlock 전용 진단 ────────────────────────────────────────────────────
if [[ "$SCENARIO" == "deadlock" ]] && [[ -n "$PID" ]]; then
    {
        echo "=== Deadlock 진단 체크리스트 (PID $PID) ==="
        echo ""
        echo "1) PID 존재 여부 (ps -p):"
        ps -p "$PID" -o pid,stat,etime,nlwp,cmd --no-headers 2>/dev/null || echo "  없음"
        echo ""
        echo "2) 스레드 상태 (S=Sleep 이고 wchan 이 futex 면 락 대기):"
        ps -L -p "$PID" -o lwp,stat,wchan:30,comm 2>/dev/null || echo "  없음"
        echo ""
        echo "3) 순간 CPU 5회 (0에 가까우면 busy-wait 가 아닌 진짜 대기):"
        for i in 1 2 3 4 5; do
            printf "   [%s] CPU_now=%s%%  RSS=%sKB\n" "$(date '+%H:%M:%S')" \
                "$(cpu_now "$PID")" "$(ps -p "$PID" -o rss= 2>/dev/null | tr -d ' ')"
        done
        echo ""
        echo "4) 마지막 로그 (타임스탬프가 더 이상 안 바뀜):"
        tail -5 "$APP_LOG" 2>/dev/null
    } > "$EVIDENCE_DIR/deadlock_diagnosis.txt"
    ok "Deadlock 진단 저장: deadlock_diagnosis.txt"
fi

echo ""
echo -e "${BOLD}${GREEN}────── 수집 완료 ──────${RESET}"
echo -e "  저장 위치: ${CYAN}$EVIDENCE_DIR${RESET}"
ls -lh "$EVIDENCE_DIR/" | awk 'NR>1{printf "    %-28s %s\n", $9, $5}'
