#!/usr/bin/env bash
# =============================================================================
# run_agent.sh — agent-leak-app 시나리오별 실행 스크립트 (수동 실행용)
#
# 사용법:
#   bash run_agent.sh --scenario oom
#   bash run_agent.sh --scenario cpu
#   bash run_agent.sh --scenario deadlock
#   bash run_agent.sh --scenario healthy
#   bash run_agent.sh --scenario oom --memory 300        # After 실험: 값 하나만 덮어쓰기
#   bash run_agent.sh --memory 200 --cpu 30 --thread false
#   bash run_agent.sh --scenario cpu --background        # 백그라운드 (다른 터미널에서 monitor.sh)
#
# 실행은 script(가상 터미널) 아래에서 이루어져 ">>> [SYSTEM] ... <<<" 종료 배너와
# EXIT_CODE 가 로그 파일에도 남는다. (nohup > file 로 돌리면 버퍼링 때문에 사라짐)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}==== $* ====${RESET}\n"; }

SCENARIO=""; MEMORY_LIMIT_VAL=""; CPU_MAX_OCCUPY_VAL=""; MULTI_THREAD_VAL=""; BACKGROUND=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario|-s)   SCENARIO="$2"; shift 2 ;;
        --memory)        MEMORY_LIMIT_VAL="$2"; shift 2 ;;
        --cpu)           CPU_MAX_OCCUPY_VAL="$2"; shift 2 ;;
        --thread)        MULTI_THREAD_VAL="$2"; shift 2 ;;
        --background|-b) BACKGROUND=true; shift ;;
        --help|-h)
            echo "사용법: $0 [옵션]"
            echo "  --scenario  oom|cpu|deadlock|healthy  시나리오 선택"
            echo "  --memory    INT   MEMORY_LIMIT 수동 설정 (50~512)"
            echo "  --cpu       INT   CPU_MAX_OCCUPY 수동 설정 (10~100)"
            echo "  --thread    BOOL  MULTI_THREAD_ENABLE (true/false)"
            echo "  --background      백그라운드 실행"
            echo ""
            echo "시나리오별 기본 환경변수:"
            echo "  oom      → MEMORY_LIMIT=80,  CPU=50, THREAD=false"
            echo "  cpu      → MEMORY_LIMIT=512, CPU=80, THREAD=false"
            echo "  deadlock → MEMORY_LIMIT=512, CPU=50, THREAD=true"
            echo "  healthy  → MEMORY_LIMIT=512, CPU=10, THREAD=false"
            exit 0 ;;
        *) error "알 수 없는 옵션: $1"; exit 1 ;;
    esac
done

header "agent-leak-app 실행기"

if [[ "$(id -u)" -eq 0 ]]; then
    error "root 로는 실행할 수 없습니다 (앱이 부팅 단계에서 거부). 일반 사용자로 실행하세요."
    exit 1
fi
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    ok "환경변수 로드: $ENV_FILE"
else
    error "환경변수 파일 없음: $ENV_FILE  → 먼저 'bash setup.sh' 를 실행하세요."
    exit 1
fi

case "$SCENARIO" in
    oom)
        warn "시나리오: [OOM / Memory Leak] — MEMORY_LIMIT 초과 시 MemoryGuard 가 SIGKILL"
        MEMORY_LIMIT_VAL="${MEMORY_LIMIT_VAL:-80}"; CPU_MAX_OCCUPY_VAL="${CPU_MAX_OCCUPY_VAL:-50}"; MULTI_THREAD_VAL="${MULTI_THREAD_VAL:-false}" ;;
    cpu)
        warn "시나리오: [CPU Spike] — Load 가 임계치를 넘으면 Watchdog 이 SIGTERM"
        MEMORY_LIMIT_VAL="${MEMORY_LIMIT_VAL:-512}"; CPU_MAX_OCCUPY_VAL="${CPU_MAX_OCCUPY_VAL:-80}"; MULTI_THREAD_VAL="${MULTI_THREAD_VAL:-false}" ;;
    deadlock)
        warn "시나리오: [Deadlock] — 두 스레드가 서로의 락을 무한 대기, 프로세스는 살아있음"
        MEMORY_LIMIT_VAL="${MEMORY_LIMIT_VAL:-512}"; CPU_MAX_OCCUPY_VAL="${CPU_MAX_OCCUPY_VAL:-50}"; MULTI_THREAD_VAL="${MULTI_THREAD_VAL:-true}" ;;
    healthy)
        ok "시나리오: [Healthy / 정상]"
        MEMORY_LIMIT_VAL="${MEMORY_LIMIT_VAL:-512}"; CPU_MAX_OCCUPY_VAL="${CPU_MAX_OCCUPY_VAL:-10}"; MULTI_THREAD_VAL="${MULTI_THREAD_VAL:-false}" ;;
    "")
        if [[ -z "$MEMORY_LIMIT_VAL" || -z "$CPU_MAX_OCCUPY_VAL" || -z "$MULTI_THREAD_VAL" ]]; then
            error "--scenario 또는 --memory/--cpu/--thread 를 모두 지정해야 합니다."; exit 1
        fi ;;
    *) error "알 수 없는 시나리오: $SCENARIO (oom|cpu|deadlock|healthy)"; exit 1 ;;
esac

export MEMORY_LIMIT="$MEMORY_LIMIT_VAL" CPU_MAX_OCCUPY="$CPU_MAX_OCCUPY_VAL" MULTI_THREAD_ENABLE="$MULTI_THREAD_VAL"
export AGENT_HOME AGENT_PORT AGENT_UPLOAD_DIR AGENT_KEY_PATH AGENT_LOG_DIR

echo ""
echo -e "${BOLD}실행 설정:${RESET}"
echo -e "  MEMORY_LIMIT        = ${CYAN}${MEMORY_LIMIT}MB${RESET}"
echo -e "  CPU_MAX_OCCUPY      = ${CYAN}${CPU_MAX_OCCUPY}%${RESET}"
echo -e "  MULTI_THREAD_ENABLE = ${CYAN}${MULTI_THREAD_ENABLE}${RESET}"
echo -e "  LOG_DIR             = ${CYAN}${AGENT_LOG_DIR}${RESET}"
echo ""

# 이전 프로세스 정리 (런처+워커 모두)
if [[ -n "$(find_app_pids_all)" ]]; then
    warn "기존 프로세스 발견. 종료 중..."
    stop_app
    ok "기존 프로세스 종료됨"
fi
rm -f "$AGENT_LOG_DIR/agent_app.log"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
RUN_LOG="$AGENT_LOG_DIR/run_${SCENARIO:-manual}_${TIMESTAMP}.log"
mkdir -p "$AGENT_LOG_DIR"

if $BACKGROUND; then
    info "백그라운드 실행 중..."
    start_app_logged "$RUN_LOG"
    sleep 3
    PID=$(find_app_pid)
    echo "${PID:-}" > "$AGENT_LOG_DIR/agent.pid"
    ok "실행됨 (워커 PID: ${PID:-?}, 런처 PID: $(ps -o ppid= -p "${PID:-0}" 2>/dev/null | tr -d ' '))"
    info "로그 확인: tail -f $RUN_LOG"
    info "관제 시작: bash $SCRIPT_DIR/monitor.sh"
else
    info "포그라운드 실행 중... (Ctrl+C 로 중단; 로그: $RUN_LOG)"
    if command -v script >/dev/null 2>&1; then
        script -q -f -c "'$BINARY_PATH'; echo \"EXIT_CODE=\$?\"" "$RUN_LOG"
    else
        "$BINARY_PATH" 2>&1 | tee "$RUN_LOG"
        echo "EXIT_CODE=${PIPESTATUS[0]}" | tee -a "$RUN_LOG"
    fi
fi
