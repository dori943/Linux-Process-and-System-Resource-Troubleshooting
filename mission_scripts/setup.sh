#!/usr/bin/env bash
# =============================================================================
# setup.sh — agent-leak-app 실행 환경 초기화 스크립트
# 사용법: bash setup.sh [--memory 100] [--cpu 50] [--thread true]
# =============================================================================
set -euo pipefail

# ─── 색상 정의 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}==== $* ====${RESET}\n"; }

# ─── 기본값 ───────────────────────────────────────────────────────────────────
MEMORY_LIMIT_VAL=100
CPU_MAX_OCCUPY_VAL=50
MULTI_THREAD_VAL=false
AGENT_USER="doheekim"
BINARY_NAME="agent-leak-app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/$BINARY_NAME"

# ─── 인자 파싱 ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --memory)  MEMORY_LIMIT_VAL="$2"; shift 2 ;;
        --cpu)     CPU_MAX_OCCUPY_VAL="$2"; shift 2 ;;
        --thread)  MULTI_THREAD_VAL="$2"; shift 2 ;;
        --binary)  BINARY_PATH="$2"; shift 2 ;;
        --help|-h)
            echo "사용법: $0 [옵션]"
            echo "  --memory  INT    MEMORY_LIMIT (50~512, 기본: 100)"
            echo "  --cpu     INT    CPU_MAX_OCCUPY (10~100, 기본: 50)"
            echo "  --thread  BOOL   MULTI_THREAD_ENABLE (true/false, 기본: false)"
            echo "  --binary  PATH   바이너리 경로 (기본: ../agent-leak-app)"
            exit 0 ;;
        *) error "알 수 없는 옵션: $1"; exit 1 ;;
    esac
done

header "agent-leak-app 환경 초기화"

# ─── 1. 사용자 확인 ───────────────────────────────────────────────────────────
info "실행 사용자 확인 중..."
if [[ "$(id -u)" -eq 0 ]]; then
    # root 로 실행 시 → claude 유저로 위임
    if ! id "$AGENT_USER" &>/dev/null; then
        error "'$AGENT_USER' 사용자가 존재하지 않습니다."
        error "useradd -m $AGENT_USER 으로 생성한 뒤 다시 실행하세요."
        exit 1
    fi
    warn "root 로 실행됨. 환경 구성 후 '$AGENT_USER' 로 전환합니다."
    RUN_AS_ROOT=true
else
    AGENT_USER="$(whoami)"
    RUN_AS_ROOT=false
    ok "실행 계정: $AGENT_USER (uid=$(id -u))"
fi

# ─── 2. 바이너리 확인 ─────────────────────────────────────────────────────────
info "바이너리 확인: $BINARY_PATH"
if [[ ! -f "$BINARY_PATH" ]]; then
    error "바이너리를 찾을 수 없습니다: $BINARY_PATH"
    error "--binary 옵션으로 경로를 지정하거나, 스크립트와 같은 폴더에 agent-leak-app을 두세요."
    exit 1
fi
chmod +x "$BINARY_PATH"
ok "바이너리 확인 완료"

# ─── 3. AGENT_HOME 디렉터리 구성 ──────────────────────────────────────────────
AGENT_HOME_DIR="/home/$AGENT_USER/agent_home"
info "AGENT_HOME 구성: $AGENT_HOME_DIR"

for dir in \
    "$AGENT_HOME_DIR/upload_files" \
    "$AGENT_HOME_DIR/api_keys" \
    "$AGENT_HOME_DIR/logs"; do
    mkdir -p "$dir"
    ok "디렉터리 생성: $dir"
done

# ─── 4. secret.key 생성 ───────────────────────────────────────────────────────
SECRET_PATH="$AGENT_HOME_DIR/api_keys/secret.key"
if [[ ! -f "$SECRET_PATH" ]]; then
    echo "agent_api_key_test" > "$SECRET_PATH"
    ok "secret.key 생성: $SECRET_PATH"
else
    ok "secret.key 이미 존재: $SECRET_PATH"
fi

# ─── 5. 권한 설정 ─────────────────────────────────────────────────────────────
if $RUN_AS_ROOT; then
    chown -R "$AGENT_USER":"$AGENT_USER" "$AGENT_HOME_DIR"
    chown "$AGENT_USER":"$AGENT_USER" "$BINARY_PATH" 2>/dev/null || true
fi
chmod -R 755 "$AGENT_HOME_DIR"
chmod 644 "$SECRET_PATH"
ok "권한 설정 완료"

# ─── 6. 환경변수 파일 생성 ────────────────────────────────────────────────────
ENV_FILE="$AGENT_HOME_DIR/agent.env"
cat > "$ENV_FILE" <<EOF
# agent-leak-app 환경변수 설정 파일
# setup.sh 에 의해 자동 생성됨: $(date '+%Y-%m-%d %H:%M:%S')

export AGENT_HOME="$AGENT_HOME_DIR"
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="\$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="\$AGENT_HOME/api_keys"
export AGENT_LOG_DIR="\$AGENT_HOME/logs"
export MEMORY_LIMIT=$MEMORY_LIMIT_VAL
export CPU_MAX_OCCUPY=$CPU_MAX_OCCUPY_VAL
export MULTI_THREAD_ENABLE=$MULTI_THREAD_VAL
EOF
ok "환경변수 파일 생성: $ENV_FILE"

# ─── 7. 심볼릭 링크 ───────────────────────────────────────────────────────────
LINK_PATH="$AGENT_HOME_DIR/agent-leak-app"
if [[ ! -L "$LINK_PATH" ]]; then
    ln -sf "$BINARY_PATH" "$LINK_PATH"
    ok "바이너리 링크 생성: $LINK_PATH -> $BINARY_PATH"
fi

# ─── 완료 요약 ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}────── 환경 설정 완료 ──────${RESET}"
echo -e "  AGENT_HOME       : ${CYAN}$AGENT_HOME_DIR${RESET}"
echo -e "  MEMORY_LIMIT     : ${CYAN}${MEMORY_LIMIT_VAL}MB${RESET}"
echo -e "  CPU_MAX_OCCUPY   : ${CYAN}${CPU_MAX_OCCUPY_VAL}%${RESET}"
echo -e "  MULTI_THREAD     : ${CYAN}${MULTI_THREAD_VAL}${RESET}"
echo -e "  ENV 파일         : ${CYAN}$ENV_FILE${RESET}"
echo ""
echo -e "${YELLOW}다음 단계:${RESET}"
echo -e "  앱 실행 → ${CYAN}bash run_agent.sh --scenario oom${RESET}  (또는 cpu / deadlock)"
echo -e "  관제 시작 → ${CYAN}bash monitor.sh${RESET}"
