# 측정 시간 후보: 정의와 지원 범위
2026-10-13 조사. 설치 앱·에디터 확장·시스템 권한은 변경하지 않았다.

## 먼저 표시할 측정값
| 이름 | 실제 관측하는 것 | 의미하지 않는 것 |
|---|---|---|
| 작업 타이머 | 사용자의 시작·종료 사이, 중앙 프로세스의 단조 시계로 측정한 경과 시간 | 자동 판별한 편집·생각 시간. 사용자가 타이머를 켜 둔 방치도 포함될 수 있음 |
| 전경 에디터 체류 | 알려진 에디터의 전경 전환 알림 수신 구간 | 사람이 계속 코딩했다는 증거. 유휴·읽기·다른 작업 가능 |
| 편집 이벤트 수 | 내용 변경 콜백의 발생 횟수·수신 시각 | 키 입력 수, 편집 소요 시간, 사람/AI 작성자 구분 |
| AI 실행구간 | 시작과 종료가 모두 관측된 AI 작업 구간의 합집합 | 사람의 코딩 시간, 모델 CPU/GPU 시간, 응답 생성 전체 시간 |

이 네 값을 합쳐서 하나의 ‘실제 코딩 시간’으로 표시하지 않는다. 이벤트 사이에 임의의 idle 임계값을 채우지 않는다. 여러 AI 세션은 구간 합집합으로 겹침을 제거한다. 미관측/재시작/절전/연결 끊김/시간대 변경 경계에는 자동 보간·재개를 하지 않는다. 미지원이나 관측 없음은 0이 아닌 미확인 값이다.

## 공식 이벤트 API 조사
- VS Code: [Extension API](https://code.visualstudio.com/api/references/vscode-api)의 workspace.onDidChangeTextDocument와 window.onDidChangeWindowState. 문서 변경 콜백은 dirty 상태 등에서도 발생하므로 내용 변경 배열이 비어 있지 않은 경우만 횟수로 세는 후보이다. text/uri/전체 창 제목을 읽거나 저장하지 않는다. focused는 창 포커스이며, active는 에디터가 제공하는 최근 활동 상태여서 실제 편집시간으로 사용하지 않는다. 확장 설치 승인이 필요하다.
- JetBrains: [Documents SDK](https://plugins.jetbrains.com/docs/intellij/documents.html)의 Document.addDocumentListener / EditorFactory.getEventMulticaster().addDocumentListener. 콜백 발생만 집계하고 Document 원문·파일 경로를 취득하지 않는다. 사람/AI 분류를 보장하지 않는다. 플러그인 설치·대상 제품/버전 검토가 필요하다.
- Xcode: [XcodeKit](https://developer.apple.com/documentation/xcodekit)은 소스 편집기 커맨드와 텍스트 버퍼 API를 제공한다. 일반 편집 이벤트를 지속 관측하는 지원 API는 이번 조사에서 확인하지 못했다. 현재 최소 범위는 명시적 타이머와 전경 체류이며, 타이핑 시간을 지원한다고 주장하지 않는다. 소스 버퍼 읽기는 요구 범위 밖이다.
- macOS 전경: [NSWorkspace.didActivateApplicationNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)의 앱 활성화 알림을 후보로 사용한다. API 알림 수신 시각은 실제 편집 동작의 시작 시각이 아니다. bundle ID 허용 목록만 취급하며 창 제목·키 내용·경로를 수집하지 않는다. 현재 후보는 사용자가 전경 관측을 켠 경우에만 이 API를 연결한다. 실제 앱 전환 전달 지연은 화면 검증이 남아 있다.
- 위젯: [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date). OS가 갱신 시점을 결정한다. 타이머가 중단됐는데도 위젯이 임의로 시간을 계속 늘리는 표현을 피하고, 마지막 확인된 값·시각을 공유한다. 무제한 reload를 하지 않는다.

## 작성된 격리 코어
Sources/ContextOSUsage/MeasuredTimeLedger.swift:
- 실제 관측 지점만 받는 단조 시계 구간 코어. 한 관측 epoch 안에서만 사용한다.
- 측정 종류별 구간 합집합. 다른 종류의 시간은 합산하지 않는다.
- 최대 활성 구간 64개, 종류별 합집합 구간 512개, ID 최대 128 UTF-8 bytes. 한도 초과는 partial로 표시하며 기록을 몰래 추정하지 않는다.
- 열린 구간은 interrupt에서 폐기하고 재시작으로 복원하지 않는다.
- 편집 이벤트 수는 시간에 기여하지 않는다. nil과 명시적 0을 구분한다.
- 파일·키보드·에디터·네트워크 접근이나 저장 기능은 없다.
- 신규 경계 검사 6개 통과. 동시 구간 중복, 빈 간격, 종류 분리, 중단·재시작, 재생 이벤트/0, 시계 역전·메모리 한도를 검사했다.

이 코어는 아래 격리 후보의 시간 UI와 선택형 위젯 payload에 연결됐다. 실제 자동 코딩 시간 수집이 완료됐다는 뜻은 아니다. AI 과거 로그의 UTC 시각을 단조 시계 tick으로 임의 변환하지 않는다. 어댑터별 시계 domain과 일자 귀속은 다음 단계에서 따로 검증해야 한다.

## 최소 구현 순서와 필요한 승인
1. 앱의 명시적 시작/일시정지 타이머 및 집계 UI. ‘작업 타이머’로 표시하고 관측 없음·부분 관측 상태를 보존한다.
2. 사용자가 켠 경우만 전경 에디터 체류 어댑터. 일자/시간대/절전/재시작 경계와 실제 API 전달 지연을 검증한다.
3. VS Code부터 변경 이벤트 메타데이터 연결. 에디터 확장 설치에 별도 승인 필요. JetBrains는 이후 선택한 제품/버전에 맞춰 구현한다.
4. AI 시작·종료 로그 구간을 별도 UTC domain에서 검증하고 합집합 집계. 열린 구간/누락 종료를 자동 채우지 않는다.
5. 작은 위젯은 ‘오늘 토큰 / 작업 타이머’ 중 하나를 고르는 구성으로 검토한다. 시간 항목을 숫자 옆에 덧붙여 밀도를 높이지 않는다. 뭉치는 기존 20pt 모서리 마크를 유지한다.

접근성·입력 모니터링 권한, 지속 에디터 확장 접근, 새 폴더/계정 권한은 이 단계에서 허용된 것으로 간주하지 않는다. 설치본 교체는 시안/권한 검토 후 진행한다.

## 후보 수정 전 조사한 성능 구조
- ConcurrentUsageReader는 inode·mtime·size·파일 offset과 이벤트 중복 처리를 이미 갖고 있다.
- 대시보드 기존 타이머는 열림 32초, 닫힘 10분이다. 새 AI 로그 감지는 아직 순수 이벤트 기반이 아니다. 이 간격은 코드 설정이며 실측 표시 지연이 아니다.
- LineReader chunk는 256 KiB이나, 한 개의 매우 긴/미완성 줄의 pending buffer에는 하드 상한이 없다.
- rows/seen/metrics 및 전체 재집계·정렬도 하드 상한이 없다. ‘메모리·CPU 사용 최소화 완료’라고 주장할 수 없다.
- 원본 로그 복제/삭제를 하지 않는다. 파생 집계만 상한을 둔 원자적 저장으로 설계한다.

## 성능 측정 계획
같은 Mac/빌드 종류/합성 로그 fixture로 변경 전후를 비교한다. 금융 작업과 동시에 CPU 부하를 줄여 단일 실행부터 순차 측정한다.
| 시나리오 | 관측 항목 |
|---|---|
| 유휴 | CPU user/system 변화, 현재·peak RSS, wakeup/읽기 횟수, 파생 파일 증가 |
| 단일 AI | append→집계 완료→앱 표시의 각 지연, 읽은 bytes와 offset |
| 동시 AI | 위 항목 + 중복 구간/토큰 검증, 병합 횟수 |
| 큰 로그 | cold/warm 시간, 긴 단일 줄과 이벤트 history의 메모리 상한 |
| 회전/교체 | inode 변화, 불완전 줄, replay 중복, 재시작 후 미관측 경계 |

변경 후보는 파일 이벤트·증분 bucket 집계·짧은 병합 갱신·화면 비활성 감속·상한 있는 캐시다. 큐 지연과 실제 화면 표시 지연을 구분한다. WidgetKit OS 지연은 별도 기록한다. 아래 결과는 수집기 CPU/RSS/디스크 후보 측정이다. 앱 표시·물리 화면·WidgetKit 지연은 아직 미측정이며 수치 목표나 개선률을 보장하지 않는다.


## 2026-10-13 UI·성능 후보 결과
- WorkTimeController / WorkTimePanel: 작업 타이머 시작·일시정지·초기화, 사용자가 켠 전경 에디터 체류, 관측 경계 안내. 앱 시작 시 두 관측 모두 꺼져 있다. 창 제목·문서·키보드·파일 경로를 읽지 않는다.
- 시간은 이 프로세스의 관측 구간이다. 하루 코딩 시간이나 영구 이력으로 표시하지 않는다. 절전·세션 비활성·일자/시간대 변경·시계 불일치에서 열린 구간을 폐기하고 자동 재개하지 않는다.
- 작은 위젯 선택: 오늘 토큰 / 작업 타이머 / 전경 에디터 체류. 시간은 마지막 집계 값과 관측 시각을 표시하며 WidgetKit이 실시간 갱신한다는 약속은 없다. 중간·큰 위젯은 기존 토큰 구성을 유지한다.
- 앱 화면이 활성일 때 관측 checkpoint는 1초, 비활성일 때는 60초이며 관측 대상이 없으면 타이머가 없다. 공유 저장은 일반 갱신 60초 간격, 상태·선택 변경은 별도 반영하며 WidgetKit reload는 15분으로 제한한다.
- 이미 존재하는 로그 쓰기 알림을 앱 화면 열림 0.2초 / 닫힘 2초 큐로 합친다. 이 설정은 실제 화면 표시 지연 실측이 아니다. 기존 복구용 주기 갱신도 유지한다.
- 수집기: 변경 없는 집계 메모, 긴 줄 2 MiB / 호출당 읽기 4 MiB, 제공자당 탐색 4096항목·최신 128파일, 파일당 4096 / 전체 20000 metric 상한. 손실·잘린 범위는 partial로 표시한다. 기존 다른 수집기 전체가 상한 구조로 바뀐 것은 아니다.

### 검증과 한계
- 시간 코어·수집기·통합 3개 suite의 27개 검사가 통과했다. nil/0, 중복 구간, 중단, 캐시 상태 노화, append, 긴 줄·읽기 상한, 최신 파일 선택·partial을 포함한다.
- WidgetKit 확장 및 앱 Debug 빌드 성공. 합성 시안 54개를 렌더링했고 시간 작은 위젯 라이트·다크와 미관측 시안을 확인했다.
- 성능 근거: artifacts/usage-baseline.json, usage-improved-final.json, usage-performance-comparison.json. 같은 Mac의 합성 데이터 수집기 Debug 단일 실행이며 전체 GUI 프로세스 측정이 아니다. cold 시나리오에는 fixture 생성 비용이 포함된다.
- 큰 로그 변경 없는 5회 읽기: wall 82.219→4.068 ms, CPU 75.710→4.030 ms. RSS 약 30 MB로 거의 같았다. 작은 로그 5회는 wall 2.621→5.649 ms로 악화됐다. 모든 시나리오의 개선이나 메모리 최소화를 보장하지 않는다.
- 별도 com.contextos.timecandidate 앱을 artifacts/time-candidate-inspection 안에 만들었다. App Group·위젯 확장·설치 기능이 없는 격리 UI 후보다. 운영 앱과 기존 설치된 Review 앱은 교체하지 않았다.
- 마지막 GUI 시도에서 Mac 잠금이 확인됐다. 실제 타이머 버튼·전경 전환·AppKit draw 진단·물리 화면 표시 지연은 확인하지 못했다. 최신 시간/뭉치 디자인은 설치 위젯에 적용되지 않았다. 이전 설치 위젯의 합성 공유 파일 읽기 확인과 새 시간 기능 검증을 구분한다.

### 추가 승인이 필요한 범위
현재 후보에는 에디터 확장 설치나 새로운 시스템 권한이 필요하지 않다. 지속 편집 이벤트를 연결하려면 ContextOS Observation Bridge 로컬 VSIX(우선 VS Code/Insiders)의 설치 승인이 별도로 필요하다. 제안 payload는 버전·정적 editorKind·focus/editCount·sequence·restart nonce이며 중앙 앱이 수신 시각을 기록한다. text/URI/제목/키 입력은 읽거나 저장하지 않는다. 같은 사용자 Unix socket, 작은 패킷 상한, 재시작·공백 상태, 7일 집계/256 KiB 상한은 설계안이며 아직 구현·설치하지 않았다. JetBrains는 제품·버전 선택 이후 별도 검토한다. 접근성·입력 모니터링 권한을 요청하지 않는다. AI 실행 시간 연결도 별도 미완료다.

부모가 알려 준 대기 승인 manager:1a69882170d447c9807fdbf51ae28c9f:1의 정확한 대상 동작은 로컬 실행 결과에 제공되지 않았다. 이 승인과 관련된 설치·권한·설정 동작은 진행하지 않는다.

## 명시적 AI 구간·Observation Bridge 준비 결과
- Codex 공식 [protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)를 2026-10-13 확인했다. TurnStarted/TurnComplete는 같은 turn_id를 제공하며 wire 이름 task_started/task_complete, alias turn_started/turn_complete를 사용한다.
- 기존 메타데이터 읽기에 turn_id와 사건 종류·UTC 기록 시각만 추가했다. 같은 session/turn ID에 유일한 시작·완료 쌍이 있는 경우만 완료 구간이다. user_message·토큰·assistant 메시지·stop_reason·파일 mtime은 시간 근거로 사용하지 않는다. 별도 개인 로그 열람이나 새로운 수집 프로세스는 실행하지 않았다.
- 복사·재생한 동일 사건은 제거한다. 겹친 완료 구간은 합집합이고, 오늘 현지 일자 경계에서 자른다. DST 일자 길이를 달력으로 계산한다. 종료 없는 구간·고아 완료·서로 다른 중복 시작/완료·abort·시계 역전·미래 종료·ID/시각 누락·수집 제한은 시간에 기여하지 않는다. 누락/partial/unavailable/noRecords와 측정된 0을 구분한다.
- 이 값은 로그 시작·완료 사건 사이 경과 시간이며 대기·권한 승인 시간을 포함할 수 있다. 모델 CPU/GPU 실행 시간이나 사람의 실제 코딩 시간이 아니다. 앱 단조 타이머와 UTC 로그 구간을 합산하지 않는다. Claude/Cursor/Gemini의 명시 구간 어댑터는 미지원이며 추정값을 표시하지 않는다. 오늘 값·시간대·집계 시각·누락 쌍 수를 시간 화면에서 표시하고 위젯 기본 화면에는 추가하지 않았다.
- 브리지 소스는 ObservationBridge/vscode, 수신기는 Sources/ContextOSCore/Registry/ObservationBridge.swift이다. 기본 꺼짐, 로컬 trusted macOS VS Code/Insiders 창만 지원한다. remote/virtual/untrusted 창은 미지원이다. 편집 콜백 배열 길이가 0보다 큰 콜백 1회를 이벤트 1개로 센다. 배열 내용·document·URI는 읽지 않는다. undo/redo·AI·프로그램 변경과 사람 편집을 구분하지 못한다.
- 전달 필드: version=1, 정적 editor 종류, 연결별 임의 UUID nonce, sequence, kind, focus boolean 또는 1–256 callback count. heartbeat/gap에는 추가 데이터·시각이 없다. 수신 앱 메모리에서만 순서·연결·횟수를 유지한다. 어떤 이벤트 간격도 편집 시간으로 환산하지 않는다.
- 위치: 사용자가 후보 수신을 켜면 ~/Library/Application Support/ContextOS Observation Candidate/observations.sock. 디렉터리 0700·소켓 0600, macOS getpeereid로 같은 UID만 허용, 연결 1개·프레임 1 KiB·초당 64패킷·불완전 프레임 5초/무통신 180초 상한. 기존 경로는 덮어쓰지 않으며 중지 시 자신의 inode인 소켓만 제거한다. 앱 종료·절전/세션/일자 경계에서는 자동 재개하지 않는다.
- 외부 전송: 없음. TCP endpoint·원격 서비스·원문/키/제목/경로/프로젝트/언어·로그 파일·원시 이벤트 저장 없음. 이번 구현은 프로세스 메모리 집계만이며 7일 저장 기능은 없다. 확장의 enabled 설정만 에디터의 사용자 설정으로 남는다. 같은 UID의 다른 프로그램이 패킷을 흉내 낼 수 있어 서명된 확장 출처 인증으로 주장하지 않는다.
- 승인 범위: 로컬 VSIX 설치, 사용자 enabled 설정, 후보 앱의 로컬 수신을 켜는 동작. 새로운 Accessibility/Input Monitoring, Apple 인증서, 계정 로그인, 네트워크 권한, 결제는 요구하지 않는다. 실제 설치·활성화는 진행하지 않았다. 알려지지 않은 manager 승인 ID는 이를 승인한 것으로 취급하지 않는다.
- 제거: enabled 설정 끄기 → 후보 앱 수신 끄기 → VS Code/Insiders에서 contextos.observation-bridge 제거. 남은 빈 ContextOS Observation Candidate 디렉터리는 별도로 제거할 수 있다. 원본 AI 로그·프로젝트·운영 앱은 변경하지 않는다.
- 로컬 패키지: artifacts/contextos-observation-bridge-0.1.0-candidate.vsix. ZIP/XML/기본 꺼짐 검사 완료. 실제 VS Code Extension Host 로드·설치·macOS 화면은 미검증이다. 패키지는 로컬 검토용이며 Marketplace에 게시하지 않았다.

정상 앱 종료는 소켓을 동기 정리한다. 강제 종료/크래시로 소켓 파일이 남으면 다음 수신 시작은 기존 경로를 덮어쓰지 않고 실패를 표시한다. 승인 후 검토한 후보 소켓만 수동 제거할 수 있으며 자동 광범위 삭제는 없다. 합성 관련 Swift 검사 34개·브리지 JS 검사 5개가 통과했다. 소켓 실전달 검사는 /tmp의 합성 패킷이며 실제 에디터 Extension Host 검증과 구분한다.

### 2026-10-21 수신 재시작 및 집계 진단 수정

위의 초기 후보 정책을 좁은 자동 복구로 보완했다. 소유자 전용 디렉터리와 영구 `receiver.lock` inode의 배타 잠금을 먼저 검증한다. 같은 UID의 비공개 소켓에 연결했을 때 `ECONNREFUSED`이고 device/inode가 재확인된 경우에만 오래된 소켓을 제거한다. 살아 있는 수신기, 일반 파일, 심볼릭 링크, 공개 권한 경로, 불확실한 오류는 그대로 보존한다. 끄기 동작은 소켓 정리가 끝난 뒤 반환하므로 바로 다시 켤 수 있다. 새 OS 권한이나 외부 전송은 없다.

집계 상태에는 경로 없는 사유 코드를 추가했다. 파일·탐색·이벤트·줄 크기 상한, 진행 중 읽기, 중복 방지용 하위 작업 제외, 실제 토큰 미제공 기록은 `집계 범위 제한`으로 구분한다. 손상되거나 읽을 수 없는 기록은 계속 `일부 수집 불가` 경고를 표시한다. Claude `<synthetic>` 기록의 0은 실제 사용량으로 만들지 않는다. 검증되지 않은 `token_usage_record` 형식은 별도 제외 사유로 표시하며 기존 `token_count`와 합쳐 이중 집계하지 않는다. dot·클라우드 전체 사용량은 계속 지원 범위 밖이다. 이전 버전의 사유 없는 partial 스냅샷은 경고를 유지한다.
