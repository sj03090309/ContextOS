# Windows 준비와 공유 계약

현재는 2.1.0 기준의 미배포 준비 변경입니다. Windows 지원 완료, Windows GUI 제공 또는 고객 배포 가능한 패키지를 의미하지 않습니다. 설치된 Mac 앱과 AI 설정은 이 소스 변경으로 교체되지 않습니다.

## 구현한 경계

- `Platform/macOS/`에 프로젝트의 링크 우회 방지 읽기, SQLite 열기, 설정 잠금·private 백업·원자 교체, FSEvents 어댑터를 모았습니다. 기존 Mac 구현은 유지합니다.
- Windows manifest는 이 어댑터와 아직 분리되지 않은 인덱싱·분석·설정·GUI 계층을 제외합니다. 순수 Swift 모델·파서·슬라이서·토큰 추정·질의 교정·세션 중복 기억과 공유 계약은 같은 소스로 컴파일합니다.
- Windows 준비 CLI는 같은 명령·옵션을 파싱합니다. MCP는 같은 버전·도구 스키마를 광고합니다. 보호가 필요한 모든 명령과 도구 호출은 오류로 중단합니다. 설정 변경만 막고 프로젝트 읽기를 허용하는 우회 경로는 없습니다.
- `RuntimeSupport`는 실제 보안 어댑터 구현 여부를 판단합니다. OS의 Swift 지원 여부나 바이너리 파일 존재를 기능 지원으로 표시하지 않습니다.
- CLI `contract`와 MCP `--contract`는 단일 `ContextOSVersion`·`RuntimeContract`·`MCPToolContract`에서 생성합니다. `doctor`는 준비 빌드를 사용 가능한 설치로 표시하지 않습니다.

## 개발자 검증

Windows에서 기존에 준비한 [공식 Swift Windows 도구 체인](https://www.swift.org/install/windows/), Windows SDK와 Python 3가 필요합니다. 일반 고객에게 개발 도구 설치를 요구하는 배포 흐름은 제공하지 않습니다. PowerShell 7에서:

```powershell
./scripts/check_windows.ps1
```

스크립트는 최대 2개 빌드 작업으로 CLI/MCP·공유 테스트를 검사합니다. 새 도구를 설치하거나 앱·계정 설정을 변경하거나 릴리스를 게시하지 않습니다. `windows-preflight.yml`은 준비된 `contextos-windows` 레이블의 Windows x64 self-hosted runner에서 수동 실행하는 구성입니다. runner는 아직 확인되지 않았으며 자동 실행·자동 설치가 아닙니다.

Mac에서는 같은 제외 목록과 컴파일 분기를 별도 scratch 경로로 검증할 수 있습니다:

```sh
CONTEXTOS_PORTABLE_BUILD=1 swift build --scratch-path .build-portable --jobs 2
CONTEXTOS_PORTABLE_BUILD=1 swift test --scratch-path .build-portable --jobs 2 --filter PortableContractTests
python3 scripts/verify_contract.py --cli .build-portable/debug/contextos --mcp .build-portable/debug/contextos-mcp --preparation
```

이 검사는 Mac에서 준비 소스가 컴파일되고 보호 작업이 실패하는지 확인합니다. 실제 Windows SDK 컴파일·실행, x64/arm64 지원과 설치 시험은 별도이며 완료됐다고 기록하지 않습니다.

### 2026-10-05 1차 검증 결과

- Apple Silicon Mac, Swift 6.4의 Debug 빌드에서 Mac 앱·CLI·MCP를 컴파일했습니다. Release 패키징·설치·공개 배포는 실행하지 않았습니다.
- Mac 회귀 검사: XCTest 100개와 Swift Testing 205개, 총 305개 통과했습니다. 새 공유 테스트 7개가 포함됩니다. 처음 제한된 실행 샌드박스에서 실패한 FSEvents 테스트 2개는 임시 fixture만 사용하는 샌드박스 밖 검사에서 통과했고 최종 전체 검사도 통과했습니다. 시스템 권한 설정을 변경하지 않았습니다.
- 같은 Mac에서 준비 소스 빌드가 성공했습니다. 테스트 6개 통과, Mac 전용 설치 진단 테스트 1개는 제외됐습니다.
- 실제 CLI/MCP 버전·도구 목록·JSON 스키마가 일치했고, 준비 빌드와 Mac 계약 JSON도 동일했습니다. 준비 CLI 보호 명령 6개와 MCP 도구 호출 6개가 모두 오류로 중단됐으며 임시 홈·프로젝트의 파일 목록과 내용 해시는 변하지 않았습니다.
- 기존 Mac stdio MCP 회귀 검사가 통과했습니다. 민감 fixture 제외, 잘못된 JSON 복구, 규칙 링크 제외, 링크된 인덱스 거부와 보호 루트 검사를 포함합니다.
- **Windows SDK에서의 컴파일·실행, Windows 인덱스 엔진·보안 어댑터·GUI·설치 프로그램, 공동 업데이트 채널, 실제 고객 실험은 미완료입니다.** Mac 준비 소스 검사 결과를 Windows 지원 완료로 사용하지 않습니다.

## Windows 핵심 기능을 활성화하기 전에 필요한 작업

1. Windows 파일 핸들 기반 읽기로 reparse point·junction·링크 교체·루트 이탈·대소문자/드라이브/UNC 경계를 보호하고 회귀 입력으로 검증합니다. Mac의 `O_NOFOLLOW`를 문자열 검사만으로 대체하지 않습니다.
2. 프로세스 간 설정 잠금, 충돌 검사·복구, 사용자에게만 허용되는 백업 ACL과 원자 교체를 구현합니다. 보호가 구현되지 않으면 미리보기와 적용 모두 비활성 상태를 유지합니다.
3. SQLite와 내용 해시 의존성을 Windows에서 준비하고, 인덱싱·검색·슬라이싱·예산·중복 제거 결과를 동일 fixture로 비교합니다. 현재 Windows 준비 빌드에는 실제 인덱스 엔진이 없습니다.
4. Windows 파일 감시·실행 파일 탐색·Claude/Codex 설치 경로를 실제 환경에서 검증합니다. 현재 `.exe` 경로 해석은 동봉한 CLI/MCP만 대상으로 합니다.
5. 같은 커밋·버전에서 Mac/Windows 패키지를 만들고 계약·보안·실행 검사를 모두 통과한 경우에만 공동 릴리스에 포함합니다. 버전 문자열 일치만으로 기능 동등성을 판정하지 않습니다.

## GUI·배포 결정 제안

공유 코어는 유지하고 OS별 어댑터로 기능을 검증하는 경로를 추천합니다. 단기에는 기존 SwiftUI Mac 앱을 유지하고 Windows 전용 GUI를 같은 계약에 연결하면 Mac 변경 위험이 작습니다. 양쪽 화면과 조작까지 동일하게 유지하는 것이 필수라면 공통 UI 도입을 별도 결정해야 합니다. 이 변경에서는 새 UI 프레임워크를 도입하지 않습니다.

소유자가 결정할 항목은 첫 공동 버전에 포함할 대시보드·사용량 기능 범위, Windows 최소 버전/아키텍처와 GUI 방식, 양쪽 코드 서명·업데이트 채널과 제공 기간입니다. 현재는 자동 업데이트·서명된 Windows 설치 프로그램·공동 릴리스 manifest가 없습니다. 향후 하나의 버전·커밋을 가진 manifest에 OS별 서명 패키지와 체크섬을 묶고 두 플랫폼 검증 실패 시 공동 발행을 보류하는 구조가 적합합니다.

## 고객 가치의 검증 범위

기존 합성 성능·추정 토큰 측정은 유지하되 고객 청구액 절감과 품질 유지로 확대 해석하지 않습니다. 첫 외부 시험에서는 도움 없는 설치/연결 성공률·첫 실제 도구 호출까지 걸린 시간, 동일 작업의 전체 소요 시간·실제 에이전트 토큰·누락/수정 품질, 반복 사용·구매 의향을 별도로 기록해야 합니다. 이 변경은 고객 실험 결과나 재사용·지불 가치 증거를 만들지 않습니다.
