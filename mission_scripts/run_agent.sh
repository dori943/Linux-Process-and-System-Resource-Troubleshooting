#!/usr/bin/env bash
# =============================================================================
# run_agent.sh — agent-leak-app 시나리오별 실행 스크립트
#
# 사용법:
#   bash run_agent.sh --scenario oom
#   bash run_agent.sh --scenario cpu
#   bash run_agent.sh --scenario deadlock
#   bash run_agent.sh --scenario healthy
#   bash run_agent.sh --memory 200 --cpu 30 --thread false   # 직접 지정
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}==== $* ====${RESET}\n"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_USER="doheekim"
AGENT_HOME_DIR="/home/$AGENT_USER/agent_home"
BINARY_PATH="$AGENT_HOME_DIR/agent-leak-app"
ENV_FILE="$AGENT_HOME_DIR/agent.env"

# ─── 기본값 ───────────────────────────────────────────────────────────────────
SCENARIO=""
MEMORY_LIMIT_VAL=""
CPU_MAX_OCCUPY_VAL=""
MULTI_THREAD_VAL=""
BACKGROUND=false

# ─── 인자 파싱 ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario|-s) SCENARIO="$2"; shift 2 ;;
        --memory)      MEMORY_LIMIT_VAL="$2"; shift 2 ;;
        --cpu)         CPU_MAX_OCCUPY_VAL="$2"; shift 2 ;;
        --thread)      MULTI_THREAD_VAL="$2"; shift 2 ;;
        --background|-b) BACKGROUND=true; shift ;;
        --help|-h)
            echo "사용법: $0 [옵션]"
            echo ""
            echo "  --scenario  oom|cpu|deadlock|healthy  시나리오 선택"
            echo "  --memory    INT   MEMORY_LIMIT 수동 설정 (50~512)"
            echo "  --cpu       INT   CPU_MAX_OCCUPY 수동 설정 (10~100)"
            echo "  --thread    BOOL  MULTI_THREAD_ENABLE (true/false)"
            echo "  --background      백그라운드 실행 (nohup)"
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

# ─── 환경변수 파일 로드 ───────────────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
    ok "환경변수 로드: $ENV_FILE"
else
    error "환경변수 파일 없음: $ENV_FILE"
    error "먼저 'bash setup.sh' 를 실행하세요."
    exit 1
fi

# ─── 시나리오 적용 ────────────────────────────────────────────────────────────
case "$SCENARIO" in
    oom)
        warn "시나리오: [OOM / Memory Leak]"
        warn "  메모리가 빠르게 증가하여 MEMORY_LIMIT 초과 후 강제 종료됩니다."
        MEMORY_LIMIT_VAL="${MEMORY_LIMIT_VAL:-80}"
        CPU_MAX_OCCUPY_VAL="${CPU_MAX_OCCUPY_VAL:-50}"
        MULTI_THREAD_VAL="${MULTI_THREAD_VAL:-false}"
        ;;
    cpu)
        warn "시나리오: [CPU Spike / 과점유]"
        warn "  CPU 사용률이 점진적으로 상승하여 Watchdog가 SIGTERM을 보냅니다."
        MEMORY_LIMIT_VAL="${MEMORY_LIMIT_VAL:-512}"
        CPU_MAX_OCCUPY_VAL="${CPU_MAX_OCCUPY_VAL:-80}"
        MULTI_THREAD_VAL="${MULTI_THREAD_VAL:-false}"
        ;;
    deadlock)
        warn "시나리오: [Deadlock / 교착상태]"
        warn "  두 스레드가 서로의 자원을 무한 대기합니다. 프로세스는 살아있지만 멈춥니다."
        MEMORY_LIMIT_VAL="${MEMORY_LIMIT_VAL:-512}"
        CPU_MAX_OCCUPY_VAL="${CPU_MAX_OCCUPY_VAL:-50}"
        MULTI_THREAD_VAL="${MULTI_THREAD_VAL:-true}"
        ;;
    healthy)
        ok "시나리오: [Healthy / 정상]"
        MEMORY_LIMIT_VAL="${MEMORY_LIMIT_VAL:-512}"
        CPU_MAX_OCCUPY_VAL="${CPU_MAX_OCCUPY_VAL:-10}"
        MULTI_THREAD_VAL="${MULTI_THREAD_VAL:-false}"
        ;;
    "")
        # 시나리오 없이 직접 지정
        if [[ -z "$MEMORY_LIMIT_VAL" || -z "$CPU_MAX_OCCUPY_VAL" || -z "$MULTI_THREAD_VAL" ]]; then
            error "--scenario 또는 --memory/--cpu/--thread 를 모두 지정해야 합니다."
            exit 1
        fi
        ;;
    *)
        error "알 수 없는 시나리오: $SCENARIO (oom|cpu|deadlock|healthy 중 선택)"
        exit 1 ;;
esac

export MEMORY_LIMIT="$MEMORY_LIMIT_VAL"
export CPU_MAX_OCCUPY="$CPU_MAX_OCCUPY_VAL"
export MULTI_THREAD_ENABLE="$MULTI_THREAD_VAL"
export AGENT_HOME AGENT_PORT AGENT_UPLOAD_DIR AGENT_KEY_PATH AGENT_LOG_DIR

echo ""
echo -e "${BOLD}실행 설정:${RESET}"
echo -e "  MEMORY_LIMIT        = ${CYAN}${MEMORY_LIMIT}MB${RESET}"
echo -e "  CPU_MAX_OCCUPY      = ${CYAN}${CPU_MAX_OCCUPY}%${RESET}"
echo -e "  MULTI_THREAD_ENABLE = ${CYAN}${MULTI_THREAD_ENABLE}${RESET}"
echo -e "  LOG_DIR             = ${CYAN}${AGENT_LOG_DIR}${RESET}"
echo ""

# ─── 이전 PID 정리 ────────────────────────────────────────────────────────────
EXISTING_PID=$(pgrep -f "agent-leak-app" 2>/dev/null | head -1 || true)
if [[ -n "$EXISTING_PID" ]]; then
    warn "기존 프로세스 발견 (PID: $EXISTING_PID). 종료 중..."
    kill "$EXISTING_PID" 2>/dev/null || true
    sleep 1
    ok "기존 프로세스 종료됨"
fi

# ─── 실행 ─────────────────────────────────────────────────────────────────────
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
RUN_LOG="$AGENT_LOG_DIR/run_${SCENARIO:-manual}_${TIMESTAMP}.log"

if [[ "$(id -u)" -eq 0 ]]; then
    # root에서 claude로 전환
    if $BACKGROUND; then
        info "백그라운드 실행 중 (as $AGENT_USER)..."
        su -s /bin/bash "$AGENT_USER" -c "
            export AGENT_HOME='$AGENT_HOME'
            export AGENT_PORT='$AGENT_PORT'
            export AGENT_UPLOAD_DIR='$AGENT_UPLOAD_DIR'
            export AGENT_KEY_PATH='$AGENT_KEY_PATH'
            export AGENT_LOG_DIR='$AGENT_LOG_DIR'
            export MEMORY_LIMIT='$MEMORY_LIMIT'
            export CPU_MAX_OCCUPY='$CPU_MAX_OCCUPY'
            export MULTI_THREAD_ENABLE='$MULTI_THREAD_ENABLE'
            nohup '$BINARY_PATH' > '$RUN_LOG' 2>&1 &
            echo \$!
        " > /tmp/agent_pid.tmp
        PID=$(cat /tmp/agent_pid.tmp 2>/dev/null || echo "")
        ok "백그라운드 실행됨 (PID: $PID)"
        echo "$PID" > "$AGENT_LOG_DIR/agent.pid"
        info "로그 확인: tail -f $RUN_LOG"
    else
        info "포그라운드 실행 중 (as $AGENT_USER)..."
        su -s /bin/bash "$AGENT_USER" -c "
            export AGENT_HOME='$AGENT_HOME'
            export AGENT_PORT='$AGENT_PORT'
            export AGENT_UPLOAD_DIR='$AGENT_UPLOAD_DIR'
            export AGENT_KEY_PATH='$AGENT_KEY_PATH'
            export AGENT_LOG_DIR='$AGENT_LOG_DIR'
            export MEMORY_LIMIT='$MEMORY_LIMIT'
            export CPU_MAX_OCCUPY='$CPU_MAX_OCCUPY'
            export MULTI_THREAD_ENABLE='$MULTI_THREAD_ENABLE'
            '$BINARY_PATH' 2>&1 | tee '$RUN_LOG'
        "
    fi
else
    # 이미 일반 유저
    if $BACKGROUND; then
        info "백그라운드 실행 중..."
        nohup "$BINARY_PATH" > "$RUN_LOG" 2>&1 &
        PID=$!
        ok "백그라운드 실행됨 (PID: $PID)"
        echo "$PID" > "$AGENT_LOG_DIR/agent.pid"
        info "로그 확인: tail -f $RUN_LOG"
    else
        info "포그라운드 실행 중..."
        "$BINARY_PATH" 2>&1 | tee "$RUN_LOG"
    fi
fi
