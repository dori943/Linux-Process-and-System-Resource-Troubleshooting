#!/usr/bin/env bash
# =============================================================================
# run_all_scenarios.sh — 3가지 장애 시나리오 순차 실행 & 증거 수집 자동화
#
# 사용법: bash run_all_scenarios.sh [--scenario oom|cpu|deadlock|all]
#
# 각 시나리오를 순차적으로:
#   1. 앱 실행 (백그라운드)
#   2. 모니터링 (지정 시간)
#   3. 증거 수집
#   4. 이슈 리포트 생성
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'; RESET='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════╗${RESET}"; \
           echo -e "${BOLD}${CYAN}║  $*$(printf '%*s' $((38-${#1})) '')  ║${RESET}"; \
           echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${RESET}\n"; }
ok()     { echo -e "${GREEN}  ✔ $*${RESET}"; }
info()   { echo -e "${CYAN}  → $*${RESET}"; }
warn()   { echo -e "${YELLOW}  ⚠ $*${RESET}"; }
step()   { echo -e "\n${BOLD}[STEP $1]${RESET} $2"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_HOME="/home/doheekim/agent_home"
AGENT_LOG_DIR="$AGENT_HOME/logs"
BINARY_PATH="$AGENT_HOME/agent-leak-app"
ENV_FILE="$AGENT_HOME/agent.env"
TARGET="agent-leak-app"
RUN_SCENARIO="${1:-all}"

# 인자 파싱
if [[ $# -gt 0 ]]; then
    case "$1" in
        --scenario|-s) RUN_SCENARIO="${2:-all}"; ;;
        all|oom|cpu|deadlock) RUN_SCENARIO="$1" ;;
        --help|-h)
            echo "사용법: $0 [--scenario oom|cpu|deadlock|all]"
            exit 0 ;;
    esac
fi

# ─── 사전 점검 ────────────────────────────────────────────────────────────────
header "사전 환경 점검"

if [[ ! -f "$ENV_FILE" ]]; then
    warn "환경 파일 없음. setup.sh 자동 실행 중..."
    bash "$SCRIPT_DIR/setup.sh"
fi
source "$ENV_FILE"

if [[ ! -f "$BINARY_PATH" ]]; then
    warn "바이너리 링크 없음: $BINARY_PATH"
    # x86 바이너리 자동 탐색
    X86_BIN=$(find /home/doheekim -name "agent-leak-app*x86*" -o -name "agent-leak-app" 2>/dev/null | head -1 || echo "")
    if [[ -n "$X86_BIN" ]]; then
        ln -sf "$X86_BIN" "$BINARY_PATH"
        ok "바이너리 링크 생성: $BINARY_PATH → $X86_BIN"
    else
        echo -e "${RED}오류: agent-leak-app 바이너리를 찾을 수 없습니다.${RESET}" >&2
        exit 1
    fi
fi
ok "환경 점검 완료"

# ─── 시나리오 실행 함수 ───────────────────────────────────────────────────────
run_scenario() {
    local SCENE=$1
    local MEM=$2
    local CPU=$3
    local THREAD=$4
    local WAIT_SEC=$5
    local LABEL=$6

    header "시나리오: [$LABEL]"

    # 기존 프로세스 종료
    pgrep -f "$TARGET" | xargs kill 2>/dev/null || true
    sleep 1
    rm -f "$AGENT_LOG_DIR/agent_app.log"

    step "1" "환경변수 설정 및 앱 실행"
    export MEMORY_LIMIT=$MEM
    export CPU_MAX_OCCUPY=$CPU
    export MULTI_THREAD_ENABLE=$THREAD
    info "MEMORY_LIMIT=$MEM  CPU_MAX_OCCUPY=$CPU  MULTI_THREAD_ENABLE=$THREAD"

    # 실행 로그 파일
    TS=$(date '+%Y%m%d_%H%M%S')
    RUN_LOG="$AGENT_LOG_DIR/run_${SCENE}_${TS}.log"

    # claude 유저로 백그라운드 실행
    if [[ "$(id -u)" -eq 0 ]]; then
        su -s /bin/bash claude -c "
            export AGENT_HOME='$AGENT_HOME'
            export AGENT_PORT=15034
            export AGENT_UPLOAD_DIR='$AGENT_HOME/upload_files'
            export AGENT_KEY_PATH='$AGENT_HOME/api_keys'
            export AGENT_LOG_DIR='$AGENT_LOG_DIR'
            export MEMORY_LIMIT='$MEM'
            export CPU_MAX_OCCUPY='$CPU'
            export MULTI_THREAD_ENABLE='$THREAD'
            nohup '$BINARY_PATH' > '$RUN_LOG' 2>&1 &
            echo \$! > '$AGENT_LOG_DIR/agent.pid'
        "
    else
        nohup "$BINARY_PATH" > "$RUN_LOG" 2>&1 &
        echo $! > "$AGENT_LOG_DIR/agent.pid"
    fi

    sleep 2
    PID=$(pgrep -f "$TARGET" | head -1 || echo "")
    if [[ -n "$PID" ]]; then
        ok "앱 실행됨 (PID: $PID)"
    else
        warn "앱 즉시 종료됨 (부팅 실패 가능성). 로그 확인: $RUN_LOG"
    fi

    step "2" "모니터링 수집 (${WAIT_SEC}초)"
    MONITOR_CSV="$AGENT_LOG_DIR/monitor_${SCENE}_${TS}.csv"
    echo "timestamp,pid,cpu_percent,rss_mb,vsz_mb,threads,status,note" > "$MONITOR_CSV"

    for i in $(seq 1 $((WAIT_SEC / 3))); do
        MPID=$(pgrep -f "$TARGET" | head -1 || echo "")
        NOW=$(date '+%Y-%m-%d %H:%M:%S')
        if [[ -n "$MPID" ]]; then
            STATS=$(ps -p "$MPID" -o pcpu=,rss=,vsz=,nlwp=,stat= --no-headers 2>/dev/null || echo "0 0 0 1 ?")
            read CPU_P RSS VSZ NLW STAT <<< "$STATS"
            RSS_MB=$(echo "scale=1; ${RSS:-0}/1024" | bc 2>/dev/null || echo "0")
            echo "$NOW,$MPID,${CPU_P:-0},$RSS_MB,$(echo "${VSZ:-0}/1024"|bc),$NLW,RUNNING," >> "$MONITOR_CSV"
            printf "  [%s] PID=%-6s CPU=%-6s MEM=%sMB\n" "$NOW" "$MPID" "${CPU_P:-0}%" "$RSS_MB"
        else
            echo "$NOW,,0,0,0,0,EXITED," >> "$MONITOR_CSV"
            printf "  [%s] 프로세스 종료됨\n" "$NOW"
            break
        fi
        sleep 3
    done

    # Deadlock은 kill로 정리
    if [[ "$SCENE" == "deadlock" ]]; then
        DPID=$(pgrep -f "$TARGET" | head -1 || echo "")
        if [[ -n "$DPID" ]]; then
            warn "Deadlock 프로세스 강제 종료 (PID: $DPID)"
            kill "$DPID" 2>/dev/null || true
            sleep 1
        fi
    fi

    step "3" "증거 수집"
    # monitor CSV를 표준 이름으로 복사 (collect_evidence.sh가 읽을 수 있도록)
    cp "$MONITOR_CSV" "$AGENT_LOG_DIR/monitor_latest_${SCENE}.csv" 2>/dev/null || true

    bash "$SCRIPT_DIR/collect_evidence.sh" --scenario "$SCENE" 2>/dev/null || \
        warn "collect_evidence.sh 수집 일부 실패 (계속 진행)"
    ok "증거 수집 완료"

    step "4" "이슈 리포트 생성"
    bash "$SCRIPT_DIR/generate_report.sh" --scenario "$SCENE" 2>/dev/null || \
        warn "리포트 생성 실패"
    ok "리포트 생성 완료"

    echo ""
    ok "시나리오 [$LABEL] 완료!"
    echo "  ─────────────────────────────────"
    sleep 2
}

# ─── 실행 ─────────────────────────────────────────────────────────────────────
case "$RUN_SCENARIO" in
    oom)
        run_scenario "oom"      80  50  false  30  "OOM / Memory Leak"
        ;;
    cpu)
        run_scenario "cpu"      512 80  false  50  "CPU Spike / Watchdog"
        ;;
    deadlock)
        run_scenario "deadlock" 512 50  true   35  "Deadlock / Thread Hang"
        ;;
    all)
        run_scenario "oom"      80  50  false  30  "OOM / Memory Leak"
        run_scenario "cpu"      512 80  false  50  "CPU Spike / Watchdog"
        run_scenario "deadlock" 512 50  true   35  "Deadlock / Thread Hang"
        ;;
    *)
        echo "알 수 없는 시나리오: $RUN_SCENARIO" >&2
        exit 1 ;;
esac

# ─── 최종 요약 ────────────────────────────────────────────────────────────────
header "전체 실행 완료 요약"

echo -e "  ${BOLD}생성된 리포트:${RESET}"
ls "$AGENT_HOME/reports/"*.md 2>/dev/null | while read f; do
    echo -e "    ${CYAN}$f${RESET}"
done

echo ""
echo -e "  ${BOLD}증거 디렉터리:${RESET}"
ls -d "$AGENT_HOME/evidence/"*/ 2>/dev/null | while read d; do
    echo -e "    ${CYAN}$d${RESET}"
done

echo ""
echo -e "${GREEN}${BOLD}미션 완료! 리포트를 GitHub Issue에 업로드하세요.${RESET}"
