# Windows 준비와 공유 계약

현재는 2.1.0 기준의 미배포 준비 변경입니다. Windows 지원 완료, Windows GUI 제공 또는 고객 배포 가능한 패키지를 의미하지 않습니다. 설치된 Mac 앱과 AI 설정은 이 소스 변경으로 교체되지 않습니다.

## 구현한 경계

- `Platform/macOS/`에 프로젝트의 링크 우회 방지 읽기, SQLite 열기, 설정 잠금·private 백업·원자 교체, FSEvents 어댑터를 모았습니다. 기존 Mac 구현은 유지합니다.
- Windows manifest는 이 어댑터와 아직 분리되지 않은 인덱싱·분석·설정·GUI 계층을 제외합니다. 순수 Swift 모델·파서·순위 계산·슬라이서·토큰 추정·질의 교정·세션 중복 기억과 공유 계약은 같은 소스로 컴파일합니다.
- Windows 준비 CLI는 같은 명령·옵션을 파싱합니다. MCP는 같은 버전·도구 스키마를 광고합니다. 보호가 필요한 모든 명령과 도구 호출은 오류로 중단합니다. 설정 변경만 막고 프로젝트 읽기를 허용하는 우회 경로는 없습니다.
- `RuntimeSupport`는 실제 보안 어댑터 구현 여부를 판단합니다. OS의 Swift 지원 여부나 바이너리 파일 존재를 기능 지원으로 표시하지 않습니다.
- CLI `contract`와 MCP `--contract`는 단일 `ContextOSVersion`·`RuntimeContract`·`MCPToolContract`에서 생성합니다. `doctor`는 준비 빌드를 사용 가능한 설치로 표시하지 않습니다.

## 개발자 검증

Windows에서 기존에 준비한 [공식 Swift Windows 도구 체인](https://www.swift.org/install/windows/), Windows SDK와 Python 3가 필요합니다. 일반 고객에게 개발 도구 설치를 요구하는 배포 흐름은 제공하지 않습니다. PowerShell 7에서:

```powershell
./scripts/check_windows.ps1
```

스크립트는 빌드 작업 1개로 CLI/MCP·공유 테스트·명시적인 임시 보안 fixture·WPF 빌드와 화면 검사를 실행합니다. 새 도구를 설치하거나 앱·계정 설정을 변경하거나 릴리스를 게시하지 않습니다. .NET 10 SDK도 기존 환경에 필요합니다. `windows-preflight.yml`은 준비된 `contextos-windows` 레이블의 Windows x64 self-hosted runner에서 수동 실행하는 구성입니다. self-hosted runner는 아직 확인되지 않았습니다.

## 2차 구현과 Windows 검증 브랜치

- `CWindowsNative`와 내부 Swift 브리지에 로컬 NTFS/ReFS 루트의 조상 핸들 유지, 쓰기·삭제 공유 차단, reparse point·junction·hardlink 거부, 핸들의 volume GUID 경계 검사, 제한된 읽기를 구현했습니다. UNC·장치 namespace·ADS·예약 파일 이름은 거부합니다. 다른 OS는 명시적인 unavailable을 반환하며 안전하지 않은 파일 I/O로 대체하지 않습니다.
- 현재 사용자 SID만 허용하는 protected ACL의 private 디렉터리·새 파일, 덮어쓰기 거부, 배타 잠금과 BCrypt SHA-256을 구현했습니다. 이 API는 설정의 원자 교체·충돌 복구 구현이 아닙니다. Windows 핵심 명령은 계속 차단합니다.
- `Windows/ContextOS.Windows`는 .NET 10의 WPF 준비 화면입니다. 기존 Mac SwiftUI·대시보드 코드는 변경하지 않았습니다. 프로젝트·활동·AI 연결의 정보 구조, 크림·잉크 브랜드 색을 따릅니다. 수치는 측정 전 상태로 표시하며 프로젝트/연결 버튼은 비활성입니다.
- GUI identity와 포함된 계약은 컴파일한 Swift 계약에서 생성하고 `ContextOSVersion.current`와 대조합니다. 화면은 같은 설치의 `runtime/contextos.exe`·`runtime/contextos-mcp.exe`만 shell 없이 실행하여 계약과 준비 상태를 확인합니다. 에이전트 설정·사용자 대화·계정 비밀값·프로젝트를 읽지 않습니다.
- `windows-validation.yml`은 승인된 `codex/windows-validation-*` 브랜치 push만 자동 검증합니다. 공개 저장소의 표준 `windows-2025` runner이며 유료 larger runner, cache·artifact 저장, 고객 credentials, 서명·게시·설치 앱 교체를 사용하지 않습니다. 계정 예산 API는 연결 도구에서 지원하지 않지만, 공개 저장소/표준 runner의 무료 조건과 기존 실행의 `billable.total_ms = 0`을 확인했습니다. 계정 과금 설정을 변경하지 않았습니다.
- CI 도구는 공식 Swift 설치 페이지에서 6.4 x64 stable 링크만 선택하고 Authenticode 서명·발행자를 확인한 뒤 폐기되는 runner에 설치합니다. .NET 10 SDK는 SHA로 고정한 공식 `actions/setup-dotnet`을 사용합니다. Microsoft Windows SDK/MSVC·Python은 runner image의 기존 도구를 사용합니다. 출처: [Swift Windows](https://www.swift.org/install/windows/), [WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/), [.NET 지원 정책](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core), [Actions 무료 조건](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
- Mac 공유 검사 12개 통과, Windows fixture 검사 3개는 Windows가 아닌 호스트라 제외됐습니다. Windows Server 2025 x64의 검증 SHA `9b9ff4b`에서는 실제 CLI/MCP 빌드와 공유·native Swift 검사 13개가 통과했고, 다른 호스트 전용 2개만 제외됐습니다. 이후 직접 C 호출 검사가 실패했으므로 전체 CI 통과 또는 Windows 지원 완료로 기록하지 않습니다. 독립적인 검사 결과를 함께 수집하고 실제 실패 단계·오류 코드를 출력하도록 검증 스크립트를 보완했습니다. 최종 결과는 해당 원격 SHA의 CI 기록으로 확인해야 합니다.

Windows 보안 fixture는 임시 GUID 폴더의 dummy 본문·junction·hardlink만 사용합니다. Swift 검사와 직접 C 호출 검사, 부모 rename 거부, 별도 자식 프로세스의 잠금 충돌, 기존 private 파일 보존, SHA-256 알려진 값을 확인합니다. WPF self-test는 계약 불일치·예상 밖 준비 완료 표시를 차단하고 3개 탭의 XAML 레이아웃을 확인합니다. 실제 Windows 11 표준 사용자/고객 설치·화면 조작 시험을 대신하지 않습니다.

`dc21c34`의 독립 검사에서 메타데이터 전용 디렉터리 핸들이 rename을 막지 못하는 문제와 CI PATH의 Microsoft Store Python 별칭 우선 문제가 확인됐습니다. 디렉터리 핸들은 실제 공유 검사에 참여하는 `FILE_LIST_DIRECTORY` 권한을 요청하고 조상에서 이 권한이 거부되면 중단합니다. CI는 전체 machine/user PATH를 다시 내보내지 않고 설치한 Swift 경로만 추가하여 기존 runner의 Python·.NET 경로 순서를 보존합니다. 실패 검사는 제외하지 않습니다. 참고: [CreateFile 공유 모드](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew), [파일·디렉터리 접근 권한](https://learn.microsoft.com/en-us/windows/win32/fileio/file-access-rights-constants).

Mac에서는 같은 제외 목록과 컴파일 분기를 별도 scratch 경로로 검증할 수 있습니다:

```sh
CONTEXTOS_PORTABLE_BUILD=1 swift build --scratch-path .build-portable --jobs 1
CONTEXTOS_PORTABLE_BUILD=1 swift test --scratch-path .build-portable --jobs 1 --filter 'PortableContractTests|SnapshotOptimizerTests'
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

## 공유 순위 계산기의 최소 분리

`ContextOptimizer`는 파일·심볼·import의 `IndexSnapshot`을 받아 I/O 없이 순위를 계산합니다. 기존 Mac의 `IndexStore` 호출은 macOS 어댑터가 같은 스냅샷을 만드는 형태로 유지합니다. `GitSignals` 데이터만 공유하며 Git 프로세스 실행과 상태 수집은 Windows 빌드에 포함하지 않습니다. 기존 점수식·그래프 확장·파일 정렬·토큰 예산 계산은 변경하지 않습니다.

분리 전 Mac 검증 SHA `ce795e7`의 실제 SQLite 메모리 저장소 계산으로 고정한 fixture 10개를 양쪽 준비 테스트에서 사용합니다. 영어·한국어 질의, import 연결, 복수 seed, 명시적 파일 요청, Git 데이터, 동점 정렬, 빈 결과와 제한된 예산을 포함합니다. 파일 선택 순서·점수·토큰 추정·예산·context score는 그대로 비교합니다. 기존 Dictionary 순회에 따라 순서가 달라지는 연결 사유는 비교 보고서에서만 정렬하고 실제 결과 생성 순서는 변경하지 않습니다. 실제 Windows 실행 결과는 해당 원격 SHA의 CI로 확인합니다.

이 단위는 SQLite 연동·프로젝트 탐색·실제 Git 실행·설정 연결·감시를 Windows에서 활성화하지 않습니다. `RuntimeSupport`의 보호 작업 차단과 CLI/MCP 버전·도구 계약은 유지합니다.

## Windows 핵심 기능을 활성화하기 전에 필요한 작업

1. Windows 파일 핸들 기반 읽기로 reparse point·junction·링크 교체·루트 이탈·대소문자/드라이브/UNC 경계를 보호하고 회귀 입력으로 검증합니다. Mac의 `O_NOFOLLOW`를 문자열 검사만으로 대체하지 않습니다.
2. 프로세스 간 설정 잠금, 충돌 검사·복구, 사용자에게만 허용되는 백업 ACL과 원자 교체를 구현합니다. 보호가 구현되지 않으면 미리보기와 적용 모두 비활성 상태를 유지합니다.
3. SQLite와 내용 해시 의존성을 Windows에서 준비하고, 인덱싱·검색·슬라이싱·예산·중복 제거 결과를 동일 fixture로 비교합니다. 현재 Windows 준비 빌드에는 실제 인덱스 엔진이 없습니다.
4. Windows 파일 감시·실행 파일 탐색·Claude/Codex 설치 경로를 실제 환경에서 검증합니다. 현재 `.exe` 경로 해석은 동봉한 CLI/MCP만 대상으로 합니다.
5. 같은 커밋·버전에서 Mac/Windows 패키지를 만들고 계약·보안·실행 검사를 모두 통과한 경우에만 공동 릴리스에 포함합니다. 버전 문자열 일치만으로 기능 동등성을 판정하지 않습니다.

## GUI·배포 결정 제안

승인된 경로는 기존 SwiftUI Mac 앱을 유지하고 Windows WPF 화면을 같은 공유 코어·계약·버전에 연결하는 구조입니다. 첫 지원 대상으로 Windows 11 x64를 정했습니다. ARM64는 실제 검증 후 별도로 추가합니다. 현재 CI는 Windows Server 2025 x64에서 준비 바이너리·native fixture·WPF를 검사하며 고객 Windows 11 설치 지원 완료를 의미하지 않습니다.

소유자가 결정할 항목은 첫 공동 버전에 포함할 대시보드·사용량 기능 범위, Windows 최소 버전/아키텍처와 GUI 방식, 양쪽 코드 서명·업데이트 채널과 제공 기간입니다. 현재는 자동 업데이트·서명된 Windows 설치 프로그램·공동 릴리스 manifest가 없습니다. 향후 하나의 버전·커밋을 가진 manifest에 OS별 서명 패키지와 체크섬을 묶고 두 플랫폼 검증 실패 시 공동 발행을 보류하는 구조가 적합합니다.

## 고객 가치의 검증 범위

기존 합성 성능·추정 토큰 측정은 유지하되 고객 청구액 절감과 품질 유지로 확대 해석하지 않습니다. 첫 외부 시험에서는 도움 없는 설치/연결 성공률·첫 실제 도구 호출까지 걸린 시간, 동일 작업의 전체 소요 시간·실제 에이전트 토큰·누락/수정 품질, 반복 사용·구매 의향을 별도로 기록해야 합니다. 이 변경은 고객 실험 결과나 재사용·지불 가치 증거를 만들지 않습니다.
