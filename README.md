<p align="center"><img src="assets/icon.png" width="100" alt="ContextOS 아이콘"></p>
<h1 align="center">ContextOS</h1>
<p align="center">Claude Code · Codex를 위한 로컬 컨텍스트 도구</p>

ContextOS는 작업에 관련된 파일·심볼을 찾고, 필요한 함수 본문과 주변 시그니처를 토큰 예산 안에서 선택하는 macOS 앱입니다. 분석과 집계에 자체 AI API·원격 서버를 사용하지 않습니다. 선택된 코드는 MCP 또는 Claude 훅을 통해 연결한 AI 에이전트에 전달됩니다.

**현재 버전: 2.1.0 · macOS 14+ · Swift 6.** 이 버전은 안전한 연결과 배포 준비를 위한 코드입니다. 로컬 시험용 패키징을 제공하며 Developer ID 서명·Apple 공증·공개 Release·판매 정책은 별도 단계입니다. [배포 준비 상태](docs/RELEASE.md)를 확인하세요.

Windows용은 **빌드 준비 단계**입니다. 같은 Swift 순수 로직·CLI 명령·MCP 도구 계약을 사용하지만, 프로젝트 읽기·인덱싱·연결 설정 변경·파일 감시·GUI는 제공하지 않습니다. 미구현 보안 어댑터를 우회하지 않고 오류로 중단합니다. [Windows 준비와 동일 버전 배포 계획](docs/WINDOWS.md)을 확인하세요. 이 준비 변경은 설치된 기존 앱에 자동 적용되지 않습니다.

## 주요 기능

- 파일·심볼·import 관계를 프로젝트별 SQLite에 인덱싱하고 변경 파일만 재파싱합니다. 쿼리마다 파일 메타데이터를 확인해 최신 편집을 반영합니다.
- 파일명·심볼·경로·import의 어휘 매칭, IDF, import 그래프와 선택적 Git 신호로 관련 파일을 고릅니다. 규칙 기반 휴리스틱이며 정확도나 작업 성공을 보장하는 판정은 아닙니다.
- 함수 단위 슬라이싱, 예산에 맞는 주변 심볼 목차, MCP 세션 안의 중복 전달 제거를 제공합니다. `fresh=true`로 다시 받을 수 있습니다.
- `.env`, 자격증명·개인 키 파일 등은 기본 제외합니다. 중첩 `.gitignore`를 적용하고 심볼릭 링크·루트 밖 본문 읽기를 제한합니다. 허용된 소스에 하드코딩한 비밀을 완전히 탐지하지는 못합니다.
- Claude Code·Codex 연결/해제/복구는 미리보기 후 적용합니다. 사용자 키·다른 MCP·혼합 훅·주석을 보존하고 변경 전 private 백업을 남깁니다. 형식 오류·동시 수정이 감지되면 중단합니다.
- Claude의 `UserPromptSubmit` 훅은 관련 파일·심볼 힌트를 제공합니다. Codex는 MCP 등록과 지침을 제공합니다. 에이전트가 실제로 도구를 호출하는지는 해당 도구에서 확인해야 합니다.
- 메뉴바 앱은 로컬 기록의 사용량·활동, ContextOS의 추정 전달량, Git 빌드 로그·코드 부채 휴리스틱과 마스코트를 표시합니다. Gemini/Cursor/Windsurf의 탐지 코드는 남아 있으나 이번 자동 설정 관리 범위는 Claude Code·Codex입니다.

토큰 수는 로컬 근사치입니다. 전체 파일 대비 선택한 텍스트의 추정 차이는 실제 모델 청구액 절감·모델별 호환성·생산성·수익성이 검증됐다는 뜻이 아닙니다. 기존 UI 자료와 수치는 현재 릴리스의 외부 고객 실험을 대신하지 않습니다.

## 빌드·패키징

```sh
swift build
swift test
swift build -c release
./scripts/package_app.sh
```

`dist/`에 `ContextOS.app`, 아키텍처별 ZIP, SHA256과 메타데이터를 만듭니다. 기본은 **로컬 ad-hoc 서명**입니다. 앱을 설치하거나 실행 중인 앱을 종료하지 않습니다. 기존 `build_app.sh`도 이제 패키징만 수행합니다.

```sh
# 사용자가 설치를 원할 때만 명시적으로 실행
./scripts/install_app.sh dist/ContextOS.app --to "$HOME/Applications/ContextOS.app"
```

설치 스크립트는 기존 앱을 이전 버전 백업으로 보존합니다. 설정·인덱스·사용 기록은 자동 삭제하지 않습니다. [설치·업데이트·해제·복구 안내](docs/INSTALL.md), [개인정보와 데이터 위치](docs/PRIVACY.md)를 먼저 읽어 주세요.

## AI 도구 연결

이 변경을 포함해 만든 빌드에서는 먼저 번들 CLI의 `doctor`를 실행할 수 있습니다. CLI·MCP 누락이나 서로 다른 버전을 알려 주며 계정 설정·프로젝트·대화 기록을 읽거나 바꾸지 않습니다. 기존 설치 번들에 이 명령이 없다면 해당 번들은 이 준비 변경 이전 빌드입니다.

```sh
"$HOME/Applications/ContextOS.app/Contents/Resources/contextos" doctor
```

앱을 최종 설치 위치에 둔 뒤 메뉴바의 AI 탭에서 **연결 설정 → 미리보기 → 적용**을 선택합니다. CLI 기본 실행도 미리보기만 합니다.

```sh
CLI="$HOME/Applications/ContextOS.app/Contents/Resources/contextos"
"$CLI" connect --agent "Claude Code"
"$CLI" connect --agent "Claude Code" --apply
"$CLI" connect --agent "Codex" --apply
"$CLI" disconnect --agent "Codex"            # 미리보기
"$CLI" disconnect --agent "Codex" --apply
"$CLI" restore-settings --agent "Codex" --apply
```

| 도구 | 관리하는 설정·지침 |
|---|---|
| Claude Code | `~/.claude.json`, `~/.claude/settings.json`, `~/.claude/CLAUDE.md` |
| Codex | `~/.codex/config.toml`, `~/.codex/AGENTS.md` |

설정 적용 후 AI 도구를 재시작합니다. 깨진 JSON, JSONC 주석, 중복 키/테이블 또는 안전하게 해석할 수 없는 TOML은 원본을 재작성하지 않고 오류를 표시합니다. 관리 기록 없는 기존 항목은 해제 명령으로 지우지 않습니다. 백업은 `~/.contextos-backups/`에 저장되며 개인정보·사용자 키가 들어 있을 수 있으므로 공유하지 마세요.

## MCP·CLI

| MCP 도구 | 역할 |
|---|---|
| `get_relevant_context` | 관련 파일과 선택 이유 |
| `read_optimized` | 관련 본문·시그니처, 세션 중복 제거, 예산 제한 |
| `index_project` | 강제 재인덱싱 |
| `project_stats` | 인덱스 통계 |
| `get_project_rules` | 프로젝트의 규칙 파일 |
| `restore_session` | 브랜치·미커밋 변경·최근 활동 요약 |

```sh
.build/release/contextos context "로그인 수정" --path /path/to/project
.build/release/contextos watch /path/to/project
.build/release/contextos --version
.build/release/contextos-mcp --version
.build/release/contextos contract
.build/release/contextos-mcp --contract
```

코어 로직은 `ContextOSCore`, 어댑터는 CLI `contextos`, stdio 서버 `contextos-mcp`, SwiftUI 앱 `ContextOSApp`입니다. `contextos-bench`는 합성 입력을 쓰는 개발용 벤치마크이며 앱 번들에 포함하지 않습니다.

## 검증·성능

```sh
python3 scripts/smoke_connections.py --binary .build/release/contextos
python3 scripts/benchmark_context.py --binary .build/release/contextos-mcp --verify
# 빈 임시 디렉터리 경로만 지정. 사용자 프로젝트를 사용하지 않음.
.build/release/contextos-bench /tmp/contextos-bench-example-unique 500
python3 scripts/verify_bundle.py dist/ContextOS.app
```

벤치마크는 합성 소스만 사용합니다. MCP 검사는 임시 사용자 폴더를 쓰고 실제 설정·세션·분석 기록과 네트워크를 차단합니다. 앱의 실제 에이전트 호출, 서명·공증 설치, 오래된 macOS 실기기 시험은 별도로 확인해야 합니다. 이번 검색 최적화의 시간·메모리·정확성 비교는 [성능 보고서](docs/PERFORMANCE.md)에 기록합니다.

의존성은 Apple `swift-argument-parser`와 macOS 시스템 프레임워크·SQLite입니다. [의존성 고지](THIRD_PARTY_NOTICES.md)를 포함합니다. ContextOS 자체 라이선스·판매 조건은 소유자가 공개 배포 전에 결정해야 합니다.
