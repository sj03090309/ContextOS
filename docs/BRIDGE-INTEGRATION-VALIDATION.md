# 비 GUI 브리지 통합 검증

## 공식 VS Code 경로와 초기 비 GUI 실행 범위
[VS Code 공식 Testing Extensions](https://code.visualstudio.com/api/working-with-extensions/testing-extension)는 `--extensionDevelopmentPath`와 `--extensionTestsPath`를 이용해 별도 Extension Development Host를 실행하는 경로를 제공한다. 기존 VS Code 바이너리를 이용할 수 있지만 Workbench/Extension Host 인스턴스를 실행하는 검사이며, 단순 Node 검사와 다르다. 공식 npm runner는 별도 test-cli/test-electron 의존성과 다운로드도 지원한다. 초기 비 GUI 검사에서는 새 패키지를 설치하거나 GUI 인스턴스를 실행하지 않았다. 아래 추가 smoke에서 공식 Extension Host 실행을 별도로 확인했다.

대신 **확장의 실제 activate 코드 + 모의 VS Code API + 실제 Unix 소켓 + 운영 코드와 같은 Swift 집계/저장**을 연결했다. 실제 VS Code API 활성화·물리적 창 포커스·화면 상태 표시줄·사용자 활동은 검증하지 않았다고 명시한다. 시간은 테스트가 직접 공급한 합성 단조 시계이며 실제 5분 대기 측정과 구분한다.

## 격리
- Node가 생성한 `/tmp/cxi-*` 아래의 가짜 home 및 private 소켓/집계만 사용한다. Swift 테스트 호스트는 이 접두사 밖 경로를 거부한다. 정상 종료 시 해당 테스트 디렉터리만 제거한다.
- 실제 수신기, 운영 `activity-day-v1.json`, 사용자 설정, 실제 편집 파일, 거래 프로그램에는 접근하지 않는다. 모의 VS Code module의 enabled 값만 true로 공급한다. 앱/확장 설치나 업데이트를 하지 않는다.
- 테스트용 Swift executable product는 AppKit을 구성하지 않고 일반 앱 번들에 포함되지 않는다. 외부 의존성 추가·다운로드·네트워크 전송이 없다.

## 통과한 교차 프로세스 검사
1. 실제 extension.js activate 진입·콜백 등록 후 Unix 소켓 연결 및 중앙 snapshot 회신.
2. 모의 문서·위치 객체에 접근하면 예외를 던지는 privacy guard 아래 edit/selection/scroll 사건 전달.
3. 두 모의 편집기 status item에 중앙 값과 같은 문자열 표시. 겹친 창 시간 1회 집계, 이전 창의 blur가 현재 창을 중단시키지 않음.
4. heartbeat가 활동 창을 연장하지 않음. 합성 300초 이후 자동 pause, 새 scroll 사건에서 공백을 채우지 않고 resume.
5. 실제 production aggregate store에 임시 파일 저장·0600/16KiB 한도·허용 필드 확인. 저장값 복원에서 열린 시간이나 공백을 복구하지 않음.
6. 실제 소켓 종료·새 연결에서 새 사건으로만 재개.
7. 중앙 호스트의 snapshot 20개 전송과 양쪽 수신/표시 횟수 확인. OS의 임의 청크 크기를 가정하지 않는다. 2KiB 초과 묶음은 별도 결정적 Node fixture로 재현한다.

## 발견·수정한 결함
v0.2.0은 Node `data` 이벤트 전체가 2048 bytes를 넘으면 먼저 연결을 끊어, 개별적으로 정상인 프레임 20개도 처리하지 못했다. 실패 회귀검사로 재현했다. v0.2.1 후보는 프레임을 분리한 다음 각 프레임/미완성 버퍼를 1024 bytes로 제한하며, UTF-8 분할을 보존한다. 한 data 청크는 64KiB로 제한한다. 이 범위 내 많은 완성 프레임을 이유 없이 거부하지 않는다.

v0.2.1은 기존 수집·저장·권한 범위를 바꾸지 않는다. 수정 후보만 작성·검사하며 설치된 v0.2.0은 갱신하지 않았다. 새 설치/패치 적용이 필요한 단계는 부모에게 보고하고 보류한다.

## 재현
```sh
swift build --jobs 2 --product contextos-bridge-integration-host
node --test ObservationBridge/vscode/protocol.test.js ObservationBridge/vscode/extension.test.js
node --test ObservationBridge/vscode/integration.test.js
```

근거: `artifacts/bridge-coalesced-before.log`(재현 실패), `bridge-patch-unit-tests.log`, `bridge-cross-process-test.log`, `bridge-cross-process-integration.json`. 실제 GUI 및 Extension Host 확인은 별도 잔여 항목이다.

최종 결과: Node 단위 10개, 교차 프로세스 통합 1개, 기존 관련 Swift 46개 통과. 이 초기 결과의 실제 Extension Host 확인은 아래 추가 smoke로 보완했으며, 실제 사용자 GUI 활동/물리적 절전 복귀는 미검증이다. 수정 패키지는 v0.2.1이며 설치된 v0.2.0은 그대로 유지한다.


## 실제 공식 Extension Host smoke 추가 확인 (2026-10-15)
기존 VS Code 1.140.0 바이너리의 공식 `--extensionDevelopmentPath` / `--extensionTestsPath` 경로를 임시 user-data/extensions 디렉터리에서 실행했다. 새 npm 패키지·VS Code 다운로드·추가 권한 없이 v0.2.1 명시 활성화와 실제 VS Code API의 합성 untitled 문서 변경 콜백 1회를 확인했다. 검사한 extension.js 해시는 설치본과 같은 `92c9b467c45c95b9a61ced8393cd4412d437f0166fa0a4b01b632c7be8f2c414`이다.

이 smoke는 **브리지 설정 OFF를 먼저 확인**하고 명시적으로 activate한다. 운영 소켓·집계·사용자 설정을 사용하지 않는다. 임시 manifest에서 자동 activationEvents를 제거해 안전 검사 이전에 자동 연결되지 않게 했다. 따라서 자동 시작·실제 상태바 값·실제 사용자 활동·실제 5분 정지/재개를 검증했다고 하지 않는다. 기존 비 GUI IPC 검사의 모의 API와 이번 실제 Extension Host/API 확인을 구분한다.

실행기: `python3 scripts/run_vscode_host_smoke.py`. 별도 개발 호스트 창이 잠시 나타날 수 있으므로 사용 가능한 시점에 실행한다. 실제 연결은 켜지 않는다. CLI가 먼저 종료되는 macOS 동작 때문에 결과 파일을 별도로 기다리고, 테스트 프로필 프로세스가 없을 때만 그 임시 폴더를 정리한다. 실행 중 한정된 잠자기 방지는 종료 때 해제한다. 결과는 `artifacts/vscode-extension-host-smoke.json`에 기록한다.
