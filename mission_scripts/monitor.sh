#!/usr/bin/env bash
# =============================================================================
# monitor.sh — agent-leak-app 프로세스 실시간 관제 스크립트
#
# 기능:
#   - 순간 CPU(top) / 누적 평균 CPU(ps) / RSS / VSZ / 스레드 수 주기적 샘플링
#   - 터미널 실시간 대시보드 출력
#   - CSV 로그 파일 저장 (이슈 리포트 증거용)
#   - 프로세스 종료 감지 및 원인 분류 (OOM / CPU Spike / Deadlock)
#
# 사용법:
#   bash monitor.sh                   # 기본 (3초 간격)
#   bash monitor.sh --interval 2      # 2초 간격
#   bash monitor.sh --output my.csv   # 출력 파일 지정
#   bash monitor.sh --no-color        # 색상 없음 (리다이렉션용)
#
# 측정 대상은 PyInstaller 런처(부모)가 아니라 실제 워커(자식) 프로세스다.
# (common.sh 의 find_app_pid 참고)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

INTERVAL=3
OUTPUT_FILE=""
NO_COLOR=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --interval|-i) INTERVAL="$2"; shift 2 ;;
        --output|-o)   OUTPUT_FILE="$2"; shift 2 ;;
        --no-color)    NO_COLOR=true; shift ;;
        --help|-h)
            echo "사용법: $0 [옵션]"
            echo "  --interval INT   샘플링 간격 (초, 기본: 3)"
            echo "  --output   FILE  CSV 저장 경로"
            echo "  --no-color       색상 비활성화"
            exit 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done

if $NO_COLOR; then
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; MAGENTA=''; RESET=''
fi

# ─── 출력 파일 설정 ───────────────────────────────────────────────────────────
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
if [[ -z "$OUTPUT_FILE" ]]; then
    mkdir -p "$AGENT_LOG_DIR"
    OUTPUT_FILE="$AGENT_LOG_DIR/monitor_${TIMESTAMP}.csv"
fi

# CSV 헤더
#   cpu_now : top 순간값 (급상승 구간 증거)
#   cpu_avg : ps 누적 평균 (참고용)
echo "timestamp,pid,cpu_now,cpu_avg,rss_mb,vsz_mb,threads,stat,status,note" > "$OUTPUT_FILE"

# ─── 유틸 함수 ────────────────────────────────────────────────────────────────
get_process_stats() {
    local pid=$1
    # pcpu(avg), rss(kB), vsz(kB), nlwp, stat
    ps -p "$pid" -o pcpu=,rss=,vsz=,nlwp=,stat= 2>/dev/null || echo "0 0 0 0 ?"
}

bar() {
    local val=$1 max=$2 width=${3:-30} color=${4:-$GREEN}
    local filled=$(( val * width / (max > 0 ? max : 1) ))
    [[ $filled -gt $width ]] && filled=$width
    local empty=$(( width - filled ))
    printf "${color}"
    printf '%*s' "$filled" '' | tr ' ' '█'
    printf "${RESET}"
    printf '%*s' "$empty" ''
}

classify_exit() {
    local last_log="$AGENT_LOG_DIR/agent_app.log"
    if [[ -f "$last_log" ]]; then
        if grep -q "MemoryGuard.*Self-terminating\|Memory limit exceeded" "$last_log" 2>/dev/null; then
            echo "OOM_CRASH"
        elif grep -q "CPU Threshold Violated\|SIGTERM\|Watchdog" "$last_log" 2>/dev/null; then
            echo "CPU_SPIKE"
        elif grep -q "BLOCKED\|WAITING for\|DEADLOCK" "$last_log" 2>/dev/null; then
            echo "DEADLOCK"
        else
            echo "UNKNOWN"
        fi
    else
        echo "UNKNOWN"
    fi
}

# ─── 상태 변수 ────────────────────────────────────────────────────────────────
SAMPLE=0
MAX_CPU=0
MAX_MEM=0
START_TIME=$(date +%s)
PREV_PID=""
PREV_MEM=0
STALE_COUNT=0

clear
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         agent-leak-app  실시간 관제 대시보드                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  대상 프로세스 : ${CYAN}$TARGET${RESET} (워커/자식 PID)"
echo -e "  샘플링 간격   : ${CYAN}${INTERVAL}s${RESET}"
echo -e "  CSV 저장      : ${CYAN}$OUTPUT_FILE${RESET}"
echo -e "  종료          : ${YELLOW}Ctrl+C${RESET}"
echo ""

trap 'echo -e "\n${YELLOW}[모니터 종료]${RESET} 총 ${SAMPLE}회 샘플링, 데이터: $OUTPUT_FILE"; exit 0' INT TERM

# ─── 메인 루프 ────────────────────────────────────────────────────────────────
while true; do
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    ELAPSED=$(( $(date +%s) - START_TIME ))
    PID=$(find_app_pid)
    SAMPLE=$(( SAMPLE + 1 ))

    # ── 프로세스 없음 ──────────────────────────────────────────────────────────
    if [[ -z "$PID" ]]; then
        if [[ -n "$PREV_PID" ]]; then
            EXIT_TYPE=$(classify_exit)
            echo ""
            echo -e "${RED}${BOLD}!!! 프로세스 종료 감지 (PID was: $PREV_PID) !!!${RESET}"
            case "$EXIT_TYPE" in
                OOM_CRASH) echo -e "${RED}  원인 추정: [OOM] MemoryGuard 강제 종료 — 메모리 임계치 초과${RESET}" ;;
                CPU_SPIKE) echo -e "${YELLOW}  원인 추정: [CPU] Watchdog SIGTERM — CPU 과점유 감지${RESET}" ;;
                DEADLOCK)  echo -e "${MAGENTA}  원인 추정: [DEADLOCK] 스레드 무한 대기 — 교착상태 진입${RESET}" ;;
                *)         echo -e "${YELLOW}  원인 추정: 알 수 없음 (로그 직접 확인 필요)${RESET}" ;;
            esac
            echo "$NOW,${PREV_PID},0,0,0,0,0,-,EXITED,${EXIT_TYPE}" >> "$OUTPUT_FILE"
        else
            printf "\r  ${YELLOW}[%s]${RESET} 프로세스 대기 중... (%s 경과)" "$NOW" "${ELAPSED}s"
        fi
        PREV_PID=""
        sleep "$INTERVAL"
        continue
    fi

    PREV_PID="$PID"

    # ── 통계 수집 ──────────────────────────────────────────────────────────────
    read CPU_AVG RSS_KB VSZ_KB THREADS STAT <<< "$(get_process_stats "$PID")"
    CPU_NOW=$(cpu_now "$PID")          # 약 1초 소요

    CPU_AVG=${CPU_AVG:-0}; CPU_NOW=${CPU_NOW:-0}
    RSS_KB=${RSS_KB:-0}; VSZ_KB=${VSZ_KB:-0}
    THREADS=${THREADS:-1}; STAT=${STAT:-?}

    RSS_MB=$(awk -v k="$RSS_KB" 'BEGIN{printf "%.1f", k/1024}')
    VSZ_MB=$(awk -v k="$VSZ_KB" 'BEGIN{printf "%.1f", k/1024}')

    CPU_INT=${CPU_NOW%.*}
    MEM_INT=${RSS_MB%.*}
    [[ ${CPU_INT:-0} -gt ${MAX_CPU:-0} ]] 2>/dev/null && MAX_CPU=$CPU_INT
    [[ ${MEM_INT:-0} -gt ${MAX_MEM:-0} ]] 2>/dev/null && MAX_MEM=$MEM_INT

    # Deadlock 의심: 순간 CPU ≈ 0 이고 메모리 변화 없음이 연속
    if [[ "${CPU_INT:-0}" -le 1 ]] && [[ "${MEM_INT}" == "${PREV_MEM}" ]]; then
        STALE_COUNT=$(( STALE_COUNT + 1 ))
    else
        STALE_COUNT=0
    fi
    PREV_MEM=$MEM_INT

    NOTE=""; STATUS="RUNNING"
    if [[ $STALE_COUNT -ge 4 ]]; then
        NOTE="STALE:possible_deadlock"; STATUS="SUSPECT_DEADLOCK"
    fi

    echo "$NOW,$PID,$CPU_NOW,$CPU_AVG,$RSS_MB,$VSZ_MB,$THREADS,$STAT,$STATUS,$NOTE" >> "$OUTPUT_FILE"

    # ── 화면 출력 ──────────────────────────────────────────────────────────────
    CPU_COLOR=$GREEN
    [[ ${CPU_INT:-0} -ge 50 ]] && CPU_COLOR=$YELLOW
    [[ ${CPU_INT:-0} -ge 80 ]] && CPU_COLOR=$RED
    MEM_COLOR=$GREEN
    [[ ${MEM_INT:-0} -ge 150 ]] && MEM_COLOR=$YELLOW
    [[ ${MEM_INT:-0} -ge 400 ]] && MEM_COLOR=$RED

    printf "\033[2K\r"
    printf "\033[8A"

    echo -e "  ${BOLD}시각:${RESET} $NOW  ${BOLD}경과:${RESET} ${ELAPSED}s  ${BOLD}샘플:${RESET} #${SAMPLE}"
    echo -e "  PID: ${CYAN}$PID${RESET}  스레드: ${CYAN}$THREADS${RESET}  상태: ${CYAN}$STAT${RESET}  (ps 누적평균 CPU: ${CPU_AVG}%)"
    echo ""
    printf  "  %-6s %s %s\n" "CPU  " "$(bar ${CPU_INT:-0} 100 35 $CPU_COLOR)" \
        "$(printf "${CPU_COLOR}%5.1f%%${RESET} (최대: %s%%)" "$CPU_NOW" "$MAX_CPU")"
    printf  "  %-6s %s %s\n" "MEM  " "$(bar ${MEM_INT:-0} 512 35 $MEM_COLOR)" \
        "$(printf "${MEM_COLOR}%6sMB${RESET} (최대: %sMB)" "$RSS_MB" "$MAX_MEM")"
    echo ""
    if [[ $STALE_COUNT -ge 4 ]]; then
        echo -e "  ${MAGENTA}${BOLD}⚠  DEADLOCK 의심: CPU/MEM 변화 없음 ${STALE_COUNT}회 연속${RESET}          "
    elif [[ ${CPU_INT:-0} -ge 70 ]]; then
        echo -e "  ${RED}${BOLD}⚠  CPU 과점유 경고: ${CPU_NOW}%${RESET}                               "
    elif [[ ${MEM_INT:-0} -ge 200 ]]; then
        echo -e "  ${YELLOW}${BOLD}⚠  메모리 증가 경고: ${RSS_MB}MB${RESET}                             "
    else
        echo -e "  ${GREEN}● 정상 운영 중${RESET}                                               "
    fi
    echo ""
    echo -e "  CSV: ${CYAN}$OUTPUT_FILE${RESET}  (${SAMPLE}행 기록됨)        "

    sleep "$INTERVAL"
done
