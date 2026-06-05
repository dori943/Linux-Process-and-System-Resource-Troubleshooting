#!/usr/bin/env bash
# =============================================================================
# collect_evidence.sh — 장애 유형별 증거 자료 자동 수집 스크립트
#
# 기능:
#   - 실행 중 or 실행 후 프로세스 상태 스냅샷
#   - ps / top / pstree 결과 저장
#   - 로그 핵심 구간 추출
#   - Deadlock 스레드 상태 추출
#   - 증거 디렉터리에 타임스탬프 폴더로 정리
#
# 사용법:
#   bash collect_evidence.sh --scenario oom
#   bash collect_evidence.sh --scenario cpu
#   bash collect_evidence.sh --scenario deadlock
#   bash collect_evidence.sh --all         # 현재 상태 전체 수집
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()     { echo -e "${GREEN}[수집]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[경고]${RESET}  $*"; }
info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}==== $* ====${RESET}\n"; }

TARGET="agent-leak-app"
AGENT_LOG_DIR="/home/claude/agent_home/logs"
EVIDENCE_BASE="/home/claude/agent_home/evidence"
SCENARIO=""
COLLECT_ALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario|-s) SCENARIO="$2"; shift 2 ;;
        --all)         COLLECT_ALL=true; shift ;;
        --help|-h)
            echo "사용법: $0 --scenario [oom|cpu|deadlock] | --all"
            exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done

# ─── 증거 저장 디렉터리 ───────────────────────────────────────────────────────
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LABEL="${SCENARIO:-snapshot}"
EVIDENCE_DIR="$EVIDENCE_BASE/${LABEL}_${TIMESTAMP}"
mkdir -p "$EVIDENCE_DIR"

header "증거 수집: $LABEL  →  $EVIDENCE_DIR"

# ─── PID 확인 ─────────────────────────────────────────────────────────────────
PID=$(pgrep -f "$TARGET" 2>/dev/null | head -1 || echo "")
if [[ -n "$PID" ]]; then
    ok "프로세스 발견: PID=$PID"
else
    warn "프로세스가 실행 중이지 않습니다. 사후 증거만 수집합니다."
fi

# ─── 1. ps 전체 스냅샷 ────────────────────────────────────────────────────────
{
    echo "=== ps aux ($(date)) ==="
    ps aux --sort=-%cpu | head -20
    echo ""
    echo "=== ps -ef | grep $TARGET ==="
    ps -ef | grep "$TARGET" | grep -v grep || echo "(프로세스 없음)"
} > "$EVIDENCE_DIR/ps_snapshot.txt"
ok "ps 스냅샷 저장: ps_snapshot.txt"

# ─── 2. 프로세스 상세 정보 (PID 있을 때) ─────────────────────────────────────
if [[ -n "$PID" ]]; then
    {
        echo "=== /proc/$PID/status ==="
        cat "/proc/$PID/status" 2>/dev/null || echo "(없음)"
        echo ""
        echo "=== /proc/$PID/stat ==="
        cat "/proc/$PID/stat" 2>/dev/null | tr ' ' '\n' | head -30 || echo "(없음)"
        echo ""
        echo "=== 메모리 맵 (/proc/$PID/maps 요약) ==="
        wc -l "/proc/$PID/maps" 2>/dev/null || echo "(없음)"
    } > "$EVIDENCE_DIR/proc_status.txt"
    ok "프로세스 상세 저장: proc_status.txt"

    # 스레드 정보
    {
        echo "=== 스레드 목록 (ps -L) ==="
        ps -L -p "$PID" -o pid,lwp,pcpu,pmem,stat,wchan:20,comm 2>/dev/null || echo "(없음)"
        echo ""
        echo "=== /proc/$PID/task/ 디렉터리 ==="
        ls "/proc/$PID/task/" 2>/dev/null || echo "(없음)"
        echo ""
        # 각 스레드의 wchan (대기 이유) 확인
        echo "=== 스레드별 대기 채널 (wchan) ==="
        for tid in /proc/$PID/task/*/; do
            TID=$(basename "$tid")
            WCHAN=$(cat "$tid/wchan" 2>/dev/null || echo "?")
            STATUS=$(cat "$tid/status" 2>/dev/null | grep "^State:" | awk '{print $2,$3}' || echo "?")
            echo "  TID $TID : wchan=$WCHAN  state=$STATUS"
        done
    } > "$EVIDENCE_DIR/thread_status.txt"
    ok "스레드 상태 저장: thread_status.txt"

    # CPU/MEM 순간 측정
    {
        echo "=== CPU/MEM 측정 ($(date)) ==="
        ps -p "$PID" -o pid,ppid,pcpu,pmem,rss,vsz,nlwp,stat,etime,cmd \
            --no-headers 2>/dev/null || echo "(없음)"
        echo ""
        echo "=== 3회 반복 측정 (1초 간격) ==="
        for i in 1 2 3; do
            printf "  [%s] " "$(date '+%H:%M:%S')"
            ps -p "$PID" -o pcpu=,rss= --no-headers 2>/dev/null | \
                awk '{printf "CPU=%.1f%%  MEM=%dKB (%dMB)\n", $1, $2, $2/1024}' || \
                echo "프로세스 없음"
            sleep 1
        done
    } > "$EVIDENCE_DIR/resource_measure.txt"
    ok "리소스 측정 저장: resource_measure.txt"
fi

# ─── 3. 시스템 전체 리소스 ────────────────────────────────────────────────────
{
    echo "=== 시스템 메모리 (free -h) ==="
    free -h
    echo ""
    echo "=== 시스템 부하 (uptime) ==="
    uptime
    echo ""
    echo "=== top 스냅샷 (1회) ==="
    top -b -n 1 | head -25
} > "$EVIDENCE_DIR/system_resources.txt"
ok "시스템 리소스 저장: system_resources.txt"

# ─── 4. 로그 파일 복사 및 핵심 구간 추출 ─────────────────────────────────────
APP_LOG="$AGENT_LOG_DIR/agent_app.log"
if [[ -f "$APP_LOG" ]]; then
    cp "$APP_LOG" "$EVIDENCE_DIR/agent_app_full.log"
    ok "전체 로그 복사: agent_app_full.log"

    # 시나리오별 핵심 로그 추출
    case "$SCENARIO" in
        oom)
            {
                echo "=== OOM 관련 핵심 로그 ==="
                grep -E "MemoryWorker|MemoryGuard|Memory limit|Self-terminating|Heap" "$APP_LOG" || \
                    echo "(해당 로그 없음)"
            } > "$EVIDENCE_DIR/key_logs_oom.txt"
            ok "OOM 핵심 로그 추출: key_logs_oom.txt"
            ;;
        cpu)
            {
                echo "=== CPU 관련 핵심 로그 ==="
                grep -E "CpuWorker|CPU Threshold|SIGTERM|Watchdog|Current Load" "$APP_LOG" || \
                    echo "(해당 로그 없음)"
            } > "$EVIDENCE_DIR/key_logs_cpu.txt"
            ok "CPU 핵심 로그 추출: key_logs_cpu.txt"
            ;;
        deadlock)
            {
                echo "=== Deadlock 관련 핵심 로그 ==="
                grep -E "Worker-Thread|LOCK|WAITING|BLOCKED|AgentWorker|transaction" "$APP_LOG" || \
                    echo "(해당 로그 없음)"
                echo ""
                echo "=== 마지막 10줄 ==="
                tail -10 "$APP_LOG"
            } > "$EVIDENCE_DIR/key_logs_deadlock.txt"
            ok "Deadlock 핵심 로그 추출: key_logs_deadlock.txt"
            ;;
        *)
            {
                echo "=== 전체 로그 마지막 50줄 ==="
                tail -50 "$APP_LOG"
            } > "$EVIDENCE_DIR/key_logs_tail.txt"
            ok "로그 끝부분 추출: key_logs_tail.txt"
            ;;
    esac
else
    warn "앱 로그 없음: $APP_LOG"
fi

# monitor CSV 복사
LATEST_CSV=$(ls -t "$AGENT_LOG_DIR"/monitor_*.csv 2>/dev/null | head -1 || echo "")
if [[ -n "$LATEST_CSV" ]]; then
    cp "$LATEST_CSV" "$EVIDENCE_DIR/monitor_data.csv"
    ok "모니터 CSV 복사: monitor_data.csv"
fi

# ─── 5. Deadlock 전용 추가 수집 ───────────────────────────────────────────────
if [[ "$SCENARIO" == "deadlock" ]] && [[ -n "$PID" ]]; then
    {
        echo "=== Deadlock 진단 체크리스트 ==="
        echo ""
        echo "1) PID 존재 여부:"
        ps -p "$PID" -o pid,stat,etime,cmd --no-headers 2>/dev/null || echo "  없음"
        echo ""
        echo "2) 스레드 상태 (D=Disk wait, S=Sleep, R=Running):"
        ps -L -p "$PID" -o lwp,stat,wchan:30,comm 2>/dev/null || echo "  없음"
        echo ""
        echo "3) CPU 사용률 (0에 가까우면 대기 상태):"
        for i in $(seq 5); do
            printf "   [%s] " "$(date '+%H:%M:%S')"
            ps -p "$PID" -o pcpu= --no-headers 2>/dev/null | \
                awk '{printf "CPU=%.2f%%\n", $1}' || echo "프로세스 종료됨"
            sleep 2
        done
        echo ""
        echo "4) 마지막 로그 타임스탬프 (로그가 멈춰있는지 확인):"
        if [[ -f "$APP_LOG" ]]; then
            tail -5 "$APP_LOG"
        fi
    } > "$EVIDENCE_DIR/deadlock_diagnosis.txt"
    ok "Deadlock 진단 저장: deadlock_diagnosis.txt"
fi

# ─── 6. 증거 목록 출력 ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}────── 수집 완료 ──────${RESET}"
echo -e "  저장 위치: ${CYAN}$EVIDENCE_DIR${RESET}"
echo ""
echo "  수집된 파일:"
ls -lh "$EVIDENCE_DIR/" | awk '{printf "    %-35s %s\n", $9, $5}' | grep -v "^    $"
echo ""
echo -e "${YELLOW}이슈 리포트 작성 시 이 폴더의 내용을 Evidence로 사용하세요.${RESET}"
echo -e "  리포트 생성: ${CYAN}bash generate_report.sh --scenario $SCENARIO${RESET}"
