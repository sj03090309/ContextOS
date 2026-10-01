# 배포 준비 상태와 공개 배포 절차

2.1.0은 Claude Code·Codex 연결 설정과 로컬 컨텍스트 도구를 첫 기능 묶음으로 준비한 버전입니다. 로컬 앱·ZIP·체크섬, 안전 설치/업데이트·이전 앱 복구 스크립트, 설정 복구, 회귀 검사와 macOS CI를 제공합니다. **이 저장소의 CI 성공이나 로컬 ad-hoc 서명은 공개 배포 완료를 의미하지 않습니다.** CI는 로컬 패키징을 검증하며 Release를 게시하거나 바이너리를 외부에 업로드하지 않습니다.

## 준비된 코드

- 연결·해제·복구의 변경 전 미리보기, 명시적 적용, 멱등성, private 백업과 충돌·부분 실패 보호.
- Claude/Codex의 사용자 설정·다른 서버·혼합 훅 보존. 지원하지 않는 설정 형식에서는 중단.
- 민감 파일·중첩 `.gitignore` 보호와 오래된 인덱스의 민감 행 정리.
- CLI·MCP·번들의 단일 버전과 현재 실행한 번들의 경로 우선 사용.
- 인덱싱·검색·파일 감시의 회귀 검사, 합성 입력에 근거한 성능 비교.
- 설치·수동 업데이트·제거·백업과 개인정보 문서, 의존성 라이선스 고지.

## 공개·판매 전에 소유자가 완료할 항목

- [ ] ContextOS 소스/바이너리 라이선스 또는 판매 이용조건 결정. 현재 이 작업은 오픈소스 라이선스나 상업 계약을 임의로 추가하지 않음.
- [ ] 앱 아이콘·마스코트·기존 자산과 의존성의 배포 권리 검토.
- [ ] 대상 고객, 지원 채널·대응 범위, 환불·업데이트 제공 기간, 판매 방식 결정. 가격·결제·라이선스 키는 이 버전에 구현하지 않음.
- [ ] 앱이 로컬 AI 세션 로그를 읽는다는 점과 MCP를 통해 선택된 코드가 AI 에이전트에 전달된다는 점을 사용자에게 안내. 첫 사용 동의·로그 집계 끄기 같은 UX는 외부 시험 전 결정해야 할 항목.
- [ ] Apple Developer 계정의 Developer ID Application 인증서와 공증 인증 준비. 현재 로컬 사전 확인에서 사용 가능한 Developer ID 인증서를 찾지 못함. 새 계정·인증서·비밀·결제를 자동 생성하지 않음.
- [ ] 지원할 아키텍처와 macOS 최소 버전의 실제 깨끗한 Mac에서 설치·실행·업데이트·복구 시험. CI의 두 아키텍처 빌드가 오래된 macOS 실기기 시험을 대신하지 않음.
- [ ] 실제 Claude Code와 Codex에서 도구 연결·호출·변경 감지·해제를 확인. 설정 파일과 합성 MCP 검사가 에이전트의 자동 사용을 보장하지 않음.
- [ ] Developer ID 서명·Apple 공증·staple·Gatekeeper 평가가 통과한 정확한 패키지의 체크섬을 확인.
- [ ] 공개 GitHub Release 또는 다른 배포 목적지에 대한 명시적 게시 결정.

## 서명·공증 작업 예시

아래 명령은 소유자가 기존 인증서와 Keychain profile을 준비한 뒤 명시적으로 실행하는 단계입니다. 인증서 이름·프로필은 실제 준비한 값으로 바꾸고 비밀번호/API 키를 저장소나 명령 기록에 넣지 않습니다.

```sh
./scripts/package_app.sh --sign-identity "Developer ID Application: <name> (<team>)"
# 정확한 ZIP을 Apple에 제출하고 결과가 Accepted인지 확인합니다.
xcrun notarytool submit dist/ContextOS-2.1.0-macos-arm64.zip --keychain-profile "<existing-profile>" --wait
xcrun stapler staple dist/ContextOS.app
xcrun stapler validate dist/ContextOS.app
codesign --verify --deep --strict dist/ContextOS.app
spctl --assess --type execute --verbose dist/ContextOS.app
```

staple한 앱으로 ZIP을 **다시 만들고** SHA256을 다시 계산해야 합니다. 패키징을 다시 실행하면 앱을 재서명하므로 공증 ticket을 유지하는 최종 ZIP 재생성은 `ditto`로 수행하세요. 로컬 JSON의 `notarized: false`는 자동 변경되지 않습니다. Accepted 결과·stapler·Gatekeeper 확인 후 최종 메타데이터를 검토하고 업데이트하세요.

이 절차는 [Apple의 macOS 공증 문서](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)를 기준으로 한 준비 안내입니다. 타임스탬프·Hardened Runtime을 사용하고 중첩 바이너리부터 서명합니다. 공증은 앱 업로드를 포함하므로 이번 구현 작업에서는 실행하지 않습니다.

## 처음 시험할 기능 묶음 제안

첫 시험 대상은 macOS에서 Claude Code 또는 Codex로 중간 규모 저장소를 작업하는 개인 개발자가 적합합니다. 기능은 안전 연결·해제, 관련 코드 선택/슬라이싱, 세션 중복 제거, 민감 파일 제외, 로컬 사용량 대시보드로 좁힙니다. 실제 유료 구매자가 관리·설치 편의와 결과 품질에 가치를 느끼는지 먼저 확인합니다.

무료 시험은 기능을 인위적으로 막기보다 **한 프로젝트에서 연결·탐색·수정·반복 질문·해제까지 완료하는 제한된 평가**로 제안합니다. 설치 성공, 관련 코드 누락, 응답 지연, 수동 탐색 필요 횟수와 지원 부담을 기록합니다. 현재 앱에는 과금·평가 만료·라이선스 키 제한이 없으며 이 문서는 판매 정책을 확정하지 않습니다. 토큰 추정 감소를 실제 청구액 절감이나 수익성의 증거로 삼지 않습니다.
