#!/usr/bin/env bash
# =============================================================================
# common.sh — 모든 미션 스크립트가 공유하는 경로/함수 정의
#
# 다른 스크립트에서:  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# 핵심 포인트
#   1) agent-leak-app 은 PyInstaller 로 포장된 파이썬 앱이라 프로세스가 2개 뜬다.
#        부모(런처): 압축 해제 후 자식을 기다리기만 함  → RSS 2MB, 스레드 1개
#        자식(워커): 실제 메모리/CPU/스레드 작업        → 관제 대상은 이쪽
#      find_app_pid 는 "부모 이름도 agent-leak-app 인 프로세스" = 자식을 고른다.
#   2) ps 의 %CPU 는 프로세스 생성 이후 누적 평균이라 순간 급상승을 못 본다.
#      cpu_now 는 top 을 1초 간격 2회 찍어 두 번째(순간값)를 쓴다.
#   3) 경로는 /home/<이름> 하드코딩 대신 $AGENT_HOME (기본 $HOME/agent_home).
# =============================================================================

TARGET="agent-leak-app"
AGENT_HOME="${AGENT_HOME:-$HOME/agent_home}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-$AGENT_HOME/logs}"
EVIDENCE_BASE="$AGENT_HOME/evidence"
REPORT_DIR="$AGENT_HOME/reports"
BINARY_PATH="${BINARY_PATH:-$AGENT_HOME/$TARGET}"
ENV_FILE="$AGENT_HOME/agent.env"

# ─── 색상 ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; MAGENTA='\033[0;35m'; RESET='\033[0m'

# ─── PID 찾기 ────────────────────────────────────────────────────────────────
# 이름이 정확히 agent-leak-app 인 프로세스 전부 (부모+자식). 좀비(Z)는 제외.
find_app_pids_all() {
    local p
    for p in $(pgrep -x "$TARGET" 2>/dev/null); do
        [[ "$(ps -o stat= -p "$p" 2>/dev/null)" == Z* ]] && continue
        echo "$p"
    done
}

# 실제 일을 하는 자식 PID 하나. 자식이 아직 안 떴으면 가장 최근 프로세스.
find_app_pid() {
    local p ppid pcomm
    for p in $(find_app_pids_all); do
        ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        [[ -z "$ppid" ]] && continue
        pcomm=$(ps -o comm= -p "$ppid" 2>/dev/null)
        if [[ "$pcomm" == "$TARGET" ]]; then
            echo "$p"; return 0
        fi
    done
    find_app_pids_all | tail -1
}

# ─── 순간 CPU% ───────────────────────────────────────────────────────────────
# top -b(배치) -n 2(두 번) -d 1(1초 간격): 첫 화면은 누적값, 두 번째가 순간값.
cpu_now() {
    local pid=$1
    top -b -n 2 -d 1 -p "$pid" 2>/dev/null \
        | awk -v p="$pid" '$1==p {v=$9} END {printf "%.1f", v+0}'
}

# ─── 앱 실행 ─────────────────────────────────────────────────────────────────
# 환경변수는 호출 전에 export 되어 있어야 한다.
# nohup + 파일 리다이렉션이면 print() 가 블록 버퍼링되어 시그널로 죽을 때
# ">>> [SYSTEM] ... <<<" 배너가 파일에 안 남는다. script 로 가상 터미널을 주면 남는다.
# 종료 코드는 로그 끝에 EXIT_CODE=N 으로 기록 (137=SIGKILL, 143=SIGTERM).
start_app_logged() {
    local run_log=$1
    if command -v script >/dev/null 2>&1; then
        script -q -f -c "'$BINARY_PATH'; echo \"EXIT_CODE=\$?\"" "$run_log" \
            </dev/null >/dev/null 2>&1 &
    else
        ( "$BINARY_PATH"; echo "EXIT_CODE=$?" ) </dev/null >"$run_log" 2>&1 &
    fi
}

# 실행 로그에서 종료 코드 추출 (없으면 빈 문자열)
exit_code_from_log() {
    grep -a -o -E 'EXIT_CODE=[0-9]+' "$1" 2>/dev/null | tail -1 | cut -d= -f2 || true
}

# 실행 로그에서 ">>> [SYSTEM] ... <<<" 배너 추출
banner_from_log() {
    grep -a '>>> \[SYSTEM\]' "$1" 2>/dev/null | sed 's/\r$//' | tail -1 || true
}

# ─── 앱 전체 종료 ────────────────────────────────────────────────────────────
stop_app() {
    local p
    for p in $(find_app_pids_all); do kill "$p" 2>/dev/null || true; done
    sleep 1
    for p in $(find_app_pids_all); do kill -9 "$p" 2>/dev/null || true; done
}
