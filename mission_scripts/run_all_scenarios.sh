#!/usr/bin/env bash
# =============================================================================
# run_all_scenarios.sh — 3가지 장애 시나리오를 Before / After 로 실행하고
#                        증거 수집 + 이슈 리포트 생성까지 자동화
#
# 사용법: bash run_all_scenarios.sh [oom|cpu|deadlock|all]
#
# 시나리오마다 두 번 실행한다.
#   Before : 장애가 재현되는 설정
#   After  : 환경변수 하나만 바꾼 설정 (조치)
#
# 각 실행 순서:
#   1. 앱 실행 (script 로 가상 터미널 → 종료 배너/EXIT_CODE 가 로그에 남음)
#   2. 모니터링 (워커 PID 의 순간 CPU / RSS / 스레드 수를 CSV 로)
#   3. 증거 수집  ← 프로세스가 살아있는 동안 (Deadlock 의 PID/스레드 증거)
#   4. 프로세스 정리 (살아있으면 kill)
#   5. 실행 요약(run_meta.txt) 기록
# 시나리오의 Before/After 가 끝나면 generate_report.sh 로 리포트 생성.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; \
           echo -e "${BOLD}${CYAN}  $*${RESET}"; \
           echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}\n"; }
ok()     { echo -e "${GREEN}  ✔ $*${RESET}"; }
info()   { echo -e "${CYAN}  → $*${RESET}"; }
warn()   { echo -e "${YELLOW}  ⚠ $*${RESET}"; }
step()   { echo -e "\n${BOLD}[STEP $1]${RESET} $2"; }

RUN_SCENARIO="${1:-all}"
case "$RUN_SCENARIO" in
    --scenario|-s) RUN_SCENARIO="${2:-all}" ;;
    --help|-h) echo "사용법: $0 [oom|cpu|deadlock|all]"; exit 0 ;;
esac

# ─── 사전 점검 ────────────────────────────────────────────────────────────────
header "사전 환경 점검"

if [[ "$(id -u)" -eq 0 ]]; then
    echo -e "${RED}root 로는 실행할 수 없습니다 (앱이 부팅 단계에서 거부). 일반 사용자로 실행하세요.${RESET}" >&2
    exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
    warn "환경 파일 없음. setup.sh 자동 실행 중..."
    bash "$SCRIPT_DIR/setup.sh"
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
if [[ ! -x "$BINARY_PATH" ]]; then
    echo -e "${RED}오류: 바이너리를 찾을 수 없습니다: $BINARY_PATH (setup.sh --binary PATH)${RESET}" >&2
    exit 1
fi
command -v script >/dev/null || warn "'script' 명령이 없어 종료 배너가 로그에 안 남을 수 있습니다 (apt install bsdutils)"
mkdir -p "$AGENT_LOG_DIR" "$EVIDENCE_BASE" "$REPORT_DIR"
ok "환경 점검 완료 (AGENT_HOME=$AGENT_HOME)"

# ─── 한 번의 실행 = 한 phase ──────────────────────────────────────────────────
run_phase() {
    local SCENE=$1 PHASE=$2 MEM=$3 CPU=$4 THREAD=$5 WAIT_SEC=$6
    local TS; TS=$(date '+%Y%m%d_%H%M%S')
    local RUN_LOG="$AGENT_LOG_DIR/run_${SCENE}_${PHASE}_${TS}.log"
    local MONITOR_CSV="$AGENT_LOG_DIR/monitor_${SCENE}_${PHASE}_${TS}.csv"
    local EVIDENCE_DIR="$EVIDENCE_BASE/${SCENE}_${PHASE}_${TS}"
    mkdir -p "$EVIDENCE_DIR"

    header "시나리오 [$SCENE] — $PHASE"

    stop_app
    rm -f "$AGENT_LOG_DIR/agent_app.log"

    step 1 "환경변수 설정 및 앱 실행"
    export MEMORY_LIMIT=$MEM CPU_MAX_OCCUPY=$CPU MULTI_THREAD_ENABLE=$THREAD
    export AGENT_HOME AGENT_PORT AGENT_UPLOAD_DIR AGENT_KEY_PATH AGENT_LOG_DIR
    info "MEMORY_LIMIT=$MEM  CPU_MAX_OCCUPY=$CPU  MULTI_THREAD_ENABLE=$THREAD"

    local START_TS; START_TS=$(date +%s)
    start_app_logged "$RUN_LOG"
    sleep 3
    local PID; PID=$(find_app_pid)
    if [[ -n "$PID" ]]; then
        ok "앱 실행됨 (워커 PID: $PID, 런처 PID: $(ps -o ppid= -p "$PID" | tr -d ' '))"
    else
        warn "앱 즉시 종료됨 (부팅 실패 가능성). 로그 확인: $RUN_LOG"
    fi

    step 2 "모니터링 (최대 ${WAIT_SEC}초, 3초 간격)"
    echo "timestamp,pid,cpu_now,cpu_avg,rss_mb,vsz_mb,threads,stat,status,note" > "$MONITOR_CSV"
    local MAX_RSS=0 OUTCOME="ALIVE" SURVIVAL=""
    local END_TS=$(( START_TS + WAIT_SEC ))
    while [[ $(date +%s) -lt $END_TS ]]; do
        local MPID; MPID=$(find_app_pid)
        local NOW; NOW=$(date '+%Y-%m-%d %H:%M:%S')
        if [[ -z "$MPID" ]]; then
            SURVIVAL=$(( $(date +%s) - START_TS ))
            OUTCOME="EXITED"
            echo "$NOW,,0,0,0,0,0,-,EXITED," >> "$MONITOR_CSV"
            printf "  [%s] 프로세스 종료됨 (생존 %ss)\n" "$NOW" "$SURVIVAL"
            break
        fi
        local STATS; STATS=$(ps -p "$MPID" -o pcpu=,rss=,vsz=,nlwp=,stat= 2>/dev/null || echo "0 0 0 0 ?")
        read -r CPU_AVG RSS VSZ NLW STAT <<< "$STATS"
        local CPU_NOW; CPU_NOW=$(cpu_now "$MPID")
        local RSS_MB; RSS_MB=$(awk -v k="${RSS:-0}" 'BEGIN{printf "%.1f", k/1024}')
        local VSZ_MB; VSZ_MB=$(awk -v k="${VSZ:-0}" 'BEGIN{printf "%.1f", k/1024}')
        [[ ${RSS_MB%.*} -gt ${MAX_RSS%.*} ]] && MAX_RSS=$RSS_MB
        echo "$NOW,$MPID,$CPU_NOW,${CPU_AVG:-0},$RSS_MB,$VSZ_MB,${NLW:-0},${STAT:-?},RUNNING," >> "$MONITOR_CSV"
        printf "  [%s] PID=%-6s CPU_now=%5s%%  RSS=%7sMB  threads=%s  stat=%s\n" \
            "$NOW" "$MPID" "$CPU_NOW" "$RSS_MB" "${NLW:-0}" "${STAT:-?}"
        sleep 2   # cpu_now 가 1초 쓰므로 총 약 3초 간격
    done
    [[ "$OUTCOME" == "ALIVE" ]] && SURVIVAL="${WAIT_SEC}+ (관찰 종료 시점까지 생존)"

    step 3 "증거 수집 (프로세스가 살아있으면 PID/스레드 증거 포함)"
    bash "$SCRIPT_DIR/collect_evidence.sh" --scenario "$SCENE" --out "$EVIDENCE_DIR" \
        --run-log "$RUN_LOG" --monitor-csv "$MONITOR_CSV" \
        || warn "collect_evidence.sh 일부 실패 (계속 진행)"

    step 4 "프로세스 정리"
    if [[ -n "$(find_app_pid)" ]]; then
        warn "살아있는 프로세스 종료 (kill → SIGTERM)"
        stop_app
        OUTCOME="ALIVE_KILLED"
    fi
    sleep 1

    step 5 "실행 요약 기록 (run_meta.txt)"
    local EXIT_CODE=""
    [[ "$OUTCOME" == "EXITED" ]] && EXIT_CODE=$(exit_code_from_log "$RUN_LOG")   # 수동 kill 한 경우는 기록 안 함
    local BANNER; BANNER=$(banner_from_log "$RUN_LOG")
    local LAST_LOG; LAST_LOG=$(tail -1 "$AGENT_LOG_DIR/agent_app.log" 2>/dev/null | sed 's/\r$//')
    cat > "$EVIDENCE_DIR/run_meta.txt" <<EOF
SCENARIO=$SCENE
PHASE=$PHASE
MEMORY_LIMIT=$MEM
CPU_MAX_OCCUPY=$CPU
MULTI_THREAD_ENABLE=$THREAD
START_TIME=$(date -d "@$START_TS" '+%Y-%m-%d %H:%M:%S')
WORKER_PID=${PID:-}
OBSERVE_SEC=$WAIT_SEC
SURVIVAL_SEC=$SURVIVAL
OUTCOME=$OUTCOME
EXIT_CODE=${EXIT_CODE:-}
BANNER=$BANNER
MAX_RSS_MB=$MAX_RSS
LAST_LOG=$LAST_LOG
RUN_LOG=$RUN_LOG
MONITOR_CSV=$MONITOR_CSV
EOF
    cat "$EVIDENCE_DIR/run_meta.txt" | sed 's/^/    /'
    ok "[$SCENE/$PHASE] 완료 → $EVIDENCE_DIR"
}

# ─── 시나리오별 Before / After ────────────────────────────────────────────────
#                 scene     phase   MEM  CPU  THREAD  관찰초
run_oom() {
    run_phase oom      before  80   50   false   40    # 12초쯤 SIGKILL
    run_phase oom      after   300  50   false   50    # 36초에 캐시 정리 후 생존
    bash "$SCRIPT_DIR/generate_report.sh" --scenario oom
}
run_cpu() {
    run_phase cpu      before  512  80   false   50    # 30초쯤 SIGTERM
    run_phase cpu      after   512  30   false   50    # 30% 에서 쿨다운, 생존
    bash "$SCRIPT_DIR/generate_report.sh" --scenario cpu
}
run_deadlock() {
    run_phase deadlock before  512  50   true    35    # 9초 후 BLOCKED, 살아있음
    run_phase deadlock after   512  50   false   30    # Thread-A/B/C 완료
    bash "$SCRIPT_DIR/generate_report.sh" --scenario deadlock
}

case "$RUN_SCENARIO" in
    oom)      run_oom ;;
    cpu)      run_cpu ;;
    deadlock) run_deadlock ;;
    all)      run_oom; run_cpu; run_deadlock ;;
    *) echo "알 수 없는 시나리오: $RUN_SCENARIO (oom|cpu|deadlock|all)" >&2; exit 1 ;;
esac

header "전체 실행 완료"
echo -e "  ${BOLD}리포트:${RESET}";   ls "$REPORT_DIR"/*.md 2>/dev/null | sed "s/^/    /"
echo -e "  ${BOLD}증거:${RESET}";     ls -d "$EVIDENCE_BASE"/*/ 2>/dev/null | sed "s/^/    /"
echo ""
echo -e "${GREEN}${BOLD}리포트를 열어 내용을 확인한 뒤 GitHub Issue 에 올리세요.${RESET}"
