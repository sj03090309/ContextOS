# 설치·업데이트·해제·복구

대상은 macOS 14 이상, Claude Code와 Codex입니다. ZIP 파일 이름의 `arm64`는 Apple Silicon, `x86_64`는 Intel용입니다. 소스 빌드는 Swift 6와 Xcode Command Line Tools가 필요합니다.

## 처음 사용하는 고객의 확인 순서

1. 공개 배포된 서명·공증 완료 패키지가 있는지 확인하고 Mac의 칩에 맞는 ZIP을 선택합니다. 현재 저장소의 로컬 ad-hoc 패키지는 고객 배포 완료를 뜻하지 않습니다.
2. 앱 전체를 최종 위치에 둡니다. CLI·MCP 파일만 따로 옮기거나 이전 앱과 섞지 않습니다.
3. 앱의 AI 탭에서 Claude Code 또는 Codex 연결 미리보기를 확인하고 적용합니다. 해당 AI 도구를 다시 시작합니다.
4. AI 도구의 MCP 목록에서 ContextOS의 6개 도구가 보이는지 확인합니다. 시험 프로젝트에서 관련 코드 요청을 한 번 실행해 실제 도구 호출을 확인합니다. 설치·등록 성공과 실제 호출 성공을 구분합니다.
5. 연결이 실패하면 아래 설치 진단 결과와 개인정보를 지운 오류 요약을 지원 요청에 포함합니다. 계정 설정·백업·세션 원문은 첨부하지 않습니다.

## 설치 구성을 읽기 전용으로 진단

이 준비 변경을 포함해 만든 빌드에서 제공하는 새 명령입니다. 이전에 설치한 2.1.0 번들에는 `doctor`가 없을 수 있습니다.

```sh
"$HOME/Applications/ContextOS.app/Contents/Resources/contextos" doctor
"$HOME/Applications/ContextOS.app/Contents/Resources/contextos" doctor --json
```

- CLI·MCP 누락: 앱 전체를 동일한 설치 위치에 다시 복사합니다.
- 버전 불일치: 개별 실행 파일을 교체하지 말고 동일 패키지의 앱 전체를 사용합니다.
- 진단 통과 후 도구가 안 보임: AI 도구 재시작 후 목록을 확인하고 연결 미리보기의 대상 위치를 다시 확인합니다.

`readyToConnect`는 실행 파일 구성과 버전 검사 결과입니다. 실제 AI 도구 호출, 서명·공증·업데이트 또는 고객 설치 성공을 인증하지 않습니다. `agentToolCallVerified`는 이 진단에서 항상 false입니다. Windows 준비 빌드는 실패 결과와 비활성화 이유를 출력하며 연결을 적용하지 않습니다.

## 로컬 시험 빌드

```sh
swift build -c release
swift test
./scripts/package_app.sh
```

`dist/`에 앱, ZIP, SHA256과 JSON 메타데이터를 만듭니다. 패키징은 설치 앱을 교체하거나 실행하지 않습니다. 기본값은 로컬 ad-hoc 서명이며 Developer ID 서명·Apple 공증을 대신하지 않습니다. 다운로드한 미공증 앱은 Gatekeeper에서 차단될 수 있습니다. 보안 기능을 끄는 방법은 제공하지 않습니다.

```sh
# 설치를 원하는 사용자가 명시적으로 실행합니다.
./scripts/install_app.sh dist/ContextOS.app --to "$HOME/Applications/ContextOS.app"
```

설치 스크립트는 실행 중인 대상 앱이 있으면 중단하고, 기존 ContextOS 앱만 이전 버전 백업으로 옮긴 뒤 검증된 번들을 복사합니다. 설정·인덱스·사용 기록은 삭제하지 않고 앱을 자동 실행하지 않습니다. 개발 환경이 없는 최종 사용자는 서명·공증 완료된 ZIP의 앱을 같은 설치 위치에 복사하는 흐름을 사용합니다.

## 연결 설정

메뉴바의 AI 탭에서 **연결 설정 → 대상 파일·안내 확인 → 적용**을 선택합니다. 취소하면 설정과 백업을 쓰지 않습니다. 터미널에서도 미리보기와 적용을 구분합니다.

```sh
CLI="$HOME/Applications/ContextOS.app/Contents/Resources/contextos"
"$CLI" connect --agent "Claude Code"
"$CLI" connect --agent "Claude Code" --apply
"$CLI" connect --agent "Codex"
"$CLI" connect --agent "Codex" --apply
```

앱을 최종 위치에 설치한 뒤 연결하세요. 실행한 앱에 포함된 CLI·MCP 경로를 우선 등록합니다. 설정 적용 후 해당 AI 도구를 다시 시작하고 MCP 도구 목록에서 ContextOS를 확인합니다. 설정 파일에 항목이 있다는 사실만으로 에이전트의 실제 호출까지 확인되지는 않습니다.

기존 다른 MCP 서버·사용자 키·지침은 보존합니다. JSON 형식이 깨졌거나 JSONC 주석, 중복 키, 안전하게 해석할 수 없는 TOML 항목, 심볼릭 링크, 이후 사용자 변경이 있으면 중단합니다. 지원하지 않는 형식을 자동으로 재작성하지 않습니다.

## 연결 해제·설정 복구

```sh
"$CLI" disconnect --agent "Claude Code"
"$CLI" disconnect --agent "Claude Code" --apply
"$CLI" disconnect --agent "Codex" --apply
"$CLI" restore-settings --agent "Codex"
"$CLI" restore-settings --agent "Codex" --apply
```

해제는 관리 기록에 있는 ContextOS 변경만 되돌립니다. 사용자가 원래 등록한 서버의 `command`·`args`를 바꿨다면 그 값을 복원하며 등록 전체를 지우지 않습니다. 관리 기록이 없는 항목은 유지합니다. 기존 ContextOS 항목을 관리하려면 먼저 연결 미리보기를 확인하세요.

최근 백업 복구는 마지막 연결·해제 직전 상태로 돌아갑니다. 그 뒤 사용자가 설정을 수정했다면 덮어쓰지 않습니다. 실패 시 부분 변경을 롤백하고, 동시 변경 때문에 롤백할 수 없으면 해당 사용자 내용을 보존하고 오류를 알립니다.

설정 백업은 `~/.contextos-backups/history/`에, 관리 기록은 `~/.contextos-backups/owners/`에 있습니다. 백업에는 기존 설정 전체가 포함될 수 있습니다. 폴더는 0700, 백업·관리 파일은 0600으로 저장하며 공유하지 않아야 합니다. 다른 프로그램과의 잠금은 강제할 수 없으므로 설정을 동시에 편집하지 않는 것이 좋습니다.

## 수동 업데이트·앱 버전 복구

자동 다운로드·자동 업데이트는 없습니다. 새 패키지의 버전·아키텍처·체크섬을 확인하고 앱을 종료한 뒤 **같은 설치 경로**에 명시적으로 설치합니다. 그 뒤 AI 도구도 재시작하면 새 MCP 바이너리를 사용합니다. 다른 경로에 복사하면 연결 설정의 경로를 다시 미리보기·적용해야 합니다.

이전 번들은 `ContextOS.previous-<날짜>-<식별자>.app`으로 남습니다. 백업 앱을 동시에 실행하지 마세요.

```sh
./scripts/install_app.sh /path/to/ContextOS.previous-....app --restore --to "$HOME/Applications/ContextOS.app"
```

앱 버전 복구와 연결 설정 백업 복구는 별도입니다. 최신 앱의 설정 관리 코드가 필요하면 앱을 되돌리기 전에 연결 해제를 완료합니다.

## 제거·지원

먼저 AI 연결을 해제하고 AI 도구를 재시작한 뒤 ContextOS를 종료하고 설치한 앱만 휴지통으로 옮깁니다. 로그인 시 시작을 사용했다면 앱에서 먼저 해제합니다. 프로젝트 `.contextos/`, 전역 사용 기록, 설정 백업은 자동 삭제하지 않습니다. 이 데이터까지 지우려면 사용자가 각 경로를 확인하고 별도로 정리해야 합니다.

지원 요청에는 앱 버전, macOS/아키텍처, 사용 도구, 재현 절차와 개인정보를 지운 오류 요약을 포함하세요. 설정 백업·키·원본 세션 로그를 첨부하지 마세요. [GitHub Issues](https://github.com/sj03090309/ContextOS/issues)에 직접 등록할 수 있습니다. 앱은 지원 자료를 자동 전송하지 않습니다.
