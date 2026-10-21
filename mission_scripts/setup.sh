#!/usr/bin/env bash
# =============================================================================
# setup.sh — agent-leak-app 실행 환경 초기화 스크립트
#
# 사용법: bash setup.sh [--binary PATH] [--memory 100] [--cpu 50] [--thread false]
#
# 만드는 것:
#   $AGENT_HOME (기본 ~/agent_home)/{upload_files,api_keys,logs,evidence,reports}
#   $AGENT_HOME/api_keys/secret.key   (내용: agent_api_key_test)
#   $AGENT_HOME/agent.env             (환경변수 export 파일)
#   $AGENT_HOME/agent-leak-app        (바이너리 심볼릭 링크)
# 일반 사용자로 실행한다. (앱이 root 실행을 거부함)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}==== $* ====${RESET}\n"; }

MEMORY_LIMIT_VAL=100
CPU_MAX_OCCUPY_VAL=50
MULTI_THREAD_VAL=false
BIN_ARG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --memory)  MEMORY_LIMIT_VAL="$2"; shift 2 ;;
        --cpu)     CPU_MAX_OCCUPY_VAL="$2"; shift 2 ;;
        --thread)  MULTI_THREAD_VAL="$2"; shift 2 ;;
        --binary)  BIN_ARG="$2"; shift 2 ;;
        --help|-h)
            echo "사용법: $0 [옵션]"
            echo "  --binary  PATH   바이너리 경로 (기본: 리포지토리의 agent-app-leak/agent-leak-app-<arch> 자동 탐색)"
            echo "  --memory  INT    MEMORY_LIMIT (50~512, 기본: 100)"
            echo "  --cpu     INT    CPU_MAX_OCCUPY (10~100, 기본: 50)"
            echo "  --thread  BOOL   MULTI_THREAD_ENABLE (true/false, 기본: false)"
            exit 0 ;;
        *) error "알 수 없는 옵션: $1"; exit 1 ;;
    esac
done

header "agent-leak-app 환경 초기화"

# ─── 1. 사용자 확인 ───────────────────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
    error "root 로 실행하지 마세요. 앱이 root 를 거부합니다. 일반 사용자로 다시 실행하세요."
    exit 1
fi
ok "실행 계정: $(whoami) (uid=$(id -u))"

# ─── 2. 바이너리 찾기 ─────────────────────────────────────────────────────────
if [[ -n "$BIN_ARG" ]]; then
    SRC_BIN="$BIN_ARG"
else
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)        WANT="agent-leak-app-x86" ;;
        aarch64|arm64) WANT="agent-leak-app-arm64" ;;
        *)             WANT="agent-leak-app" ;;
    esac
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    SRC_BIN=$(find "$REPO_ROOT" -maxdepth 2 -name "$WANT" -type f 2>/dev/null | head -1 || true)
    [[ -z "$SRC_BIN" ]] && SRC_BIN="$REPO_ROOT/$TARGET"
fi
if [[ ! -f "$SRC_BIN" ]]; then
    error "바이너리를 찾을 수 없습니다: $SRC_BIN"
    error "--binary 옵션으로 경로를 지정하세요. (예: --binary ../agent-app-leak/agent-leak-app-x86)"
    exit 1
fi
SRC_BIN="$(cd "$(dirname "$SRC_BIN")" && pwd)/$(basename "$SRC_BIN")"
chmod +x "$SRC_BIN"
ok "바이너리: $SRC_BIN ($(uname -m))"

# ─── 3. AGENT_HOME 구성 ───────────────────────────────────────────────────────
info "AGENT_HOME 구성: $AGENT_HOME"
for dir in upload_files api_keys logs evidence reports; do
    mkdir -p "$AGENT_HOME/$dir"
done
ok "디렉터리 생성: upload_files api_keys logs evidence reports"

SECRET_PATH="$AGENT_HOME/api_keys/secret.key"
if [[ ! -f "$SECRET_PATH" ]]; then
    printf 'agent_api_key_test' > "$SECRET_PATH"
    ok "secret.key 생성"
else
    ok "secret.key 이미 존재"
fi
chmod 755 "$AGENT_HOME" "$AGENT_HOME"/{upload_files,api_keys,logs,evidence,reports}
chmod 644 "$SECRET_PATH"

# ─── 4. 환경변수 파일 ─────────────────────────────────────────────────────────
cat > "$ENV_FILE" <<EOF
# agent-leak-app 환경변수 설정 파일
# setup.sh 에 의해 자동 생성됨: $(date '+%Y-%m-%d %H:%M:%S')
# 사용: source $ENV_FILE

export AGENT_HOME="$AGENT_HOME"
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="\$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="\$AGENT_HOME/api_keys"
export AGENT_LOG_DIR="\$AGENT_HOME/logs"
export MEMORY_LIMIT=$MEMORY_LIMIT_VAL
export CPU_MAX_OCCUPY=$CPU_MAX_OCCUPY_VAL
export MULTI_THREAD_ENABLE=$MULTI_THREAD_VAL
EOF
ok "환경변수 파일 생성: $ENV_FILE"

# ─── 5. 심볼릭 링크 ───────────────────────────────────────────────────────────
ln -sfn "$SRC_BIN" "$AGENT_HOME/$TARGET"
ok "바이너리 링크: $AGENT_HOME/$TARGET -> $SRC_BIN"

# ─── 6. 필요한 도구 확인 ──────────────────────────────────────────────────────
for t in ps top pgrep pstree script awk; do
    command -v "$t" >/dev/null 2>&1 || warn "'$t' 명령이 없습니다. (apt install procps psmisc bsdutils)"
done

echo ""
echo -e "${BOLD}${GREEN}────── 환경 설정 완료 ──────${RESET}"
echo -e "  AGENT_HOME       : ${CYAN}$AGENT_HOME${RESET}"
echo -e "  MEMORY_LIMIT     : ${CYAN}${MEMORY_LIMIT_VAL}MB${RESET}"
echo -e "  CPU_MAX_OCCUPY   : ${CYAN}${CPU_MAX_OCCUPY_VAL}%${RESET}"
echo -e "  MULTI_THREAD     : ${CYAN}${MULTI_THREAD_VAL}${RESET}"
echo ""
echo -e "${YELLOW}다음 단계:${RESET}"
echo -e "  전체 자동 실행 → ${CYAN}bash run_all_scenarios.sh all${RESET}"
echo -e "  수동 실행      → ${CYAN}bash run_agent.sh --scenario oom${RESET}  + 다른 터미널에서 ${CYAN}bash monitor.sh${RESET}"
