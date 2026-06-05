# agent-leak-app 미션 스크립트 패키지

시스템 장애(OOM / CPU Spike / Deadlock) 분석 및 GitHub Issue 리포트 작성 자동화 도구입니다.

## 파일 구조

```
mission_scripts/
├── README.md              # 이 파일
├── setup.sh               # 환경 초기화 (1회 실행)
├── run_agent.sh           # 단일 시나리오 실행
├── monitor.sh             # 실시간 관제 대시보드
├── collect_evidence.sh    # 증거 자동 수집
├── generate_report.sh     # GitHub Issue 리포트 생성
└── run_all_scenarios.sh   # 전체 자동화 (위 모두 순차 실행)
```

## 빠른 시작

### 1. 환경 설정 (최초 1회)
```bash
# agent-leak-app 바이너리를 scripts 상위 폴더에 위치시킨 후:
bash setup.sh
```

### 2. 시나리오별 실행 방법

#### 방법 A — 전체 자동화 (권장)
```bash
bash run_all_scenarios.sh all        # 3가지 시나리오 모두
bash run_all_scenarios.sh oom        # OOM만
bash run_all_scenarios.sh cpu        # CPU만
bash run_all_scenarios.sh deadlock   # Deadlock만
```

#### 방법 B — 단계별 수동 실행
```bash
# 터미널 1: 앱 실행
bash run_agent.sh --scenario oom

# 터미널 2: 관제 (동시 실행)
bash monitor.sh --interval 3

# 앱 종료 후: 증거 수집
bash collect_evidence.sh --scenario oom

# 리포트 생성
bash generate_report.sh --scenario oom
```

## 시나리오 환경변수

| 시나리오 | MEMORY_LIMIT | CPU_MAX_OCCUPY | MULTI_THREAD_ENABLE |
|---------|--------------|----------------|---------------------|
| oom     | 80 MB        | 50%            | false               |
| cpu     | 512 MB       | 80%            | false               |
| deadlock| 512 MB       | 50%            | true                |

## 출력 경로

| 종류 | 경로 |
|------|------|
| 실행 로그 | `~/agent_home/logs/run_*.log` |
| 관제 CSV | `~/agent_home/logs/monitor_*.csv` |
| 증거 폴더 | `~/agent_home/evidence/<시나리오>_<타임스탬프>/` |
| 이슈 리포트 | `~/agent_home/reports/issue_<시나리오>_*.md` |
