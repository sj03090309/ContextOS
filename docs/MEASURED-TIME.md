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
- macOS 전경: [NSWorkspace.didActivateApplicationNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)의 앱 활성화 알림을 후보로 사용한다. API 알림 수신 시각은 실제 편집 동작의 시작 시각이 아니다. bundle ID 허용 목록만 취급하며 창 제목·키 내용·경로를 수집하지 않는다. 후보 코어에서는 이 관측기도 아직 활성화하지 않았다.
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

이 코어는 후보이며 대시보드/위젯에 연결하거나 실제 코딩 시간을 수집한 상태가 아니다. AI 과거 로그의 UTC 시각을 단조 시계 tick으로 임의 변환하지 않는다. 어댑터별 시계 domain과 일자 귀속은 다음 단계에서 따로 검증해야 한다.

## 최소 구현 순서와 필요한 승인
1. 앱의 명시적 시작/일시정지 타이머 및 집계 UI. ‘작업 타이머’로 표시하고 관측 없음·부분 관측 상태를 보존한다.
2. 사용자가 켠 경우만 전경 에디터 체류 어댑터. 일자/시간대/절전/재시작 경계와 실제 API 전달 지연을 검증한다.
3. VS Code부터 변경 이벤트 메타데이터 연결. 에디터 확장 설치에 별도 승인 필요. JetBrains는 이후 선택한 제품/버전에 맞춰 구현한다.
4. AI 시작·종료 로그 구간을 별도 UTC domain에서 검증하고 합집합 집계. 열린 구간/누락 종료를 자동 채우지 않는다.
5. 작은 위젯은 ‘오늘 토큰 / 작업 타이머’ 중 하나를 고르는 구성으로 검토한다. 시간 항목을 숫자 옆에 덧붙여 밀도를 높이지 않는다. 뭉치는 기존 20pt 모서리 마크를 유지한다.

접근성·입력 모니터링 권한, 지속 에디터 확장 접근, 새 폴더/계정 권한은 이 단계에서 허용된 것으로 간주하지 않는다. 설치본 교체는 시안/권한 검토 후 진행한다.

## 현재 성능 구조와 확인된 개선 대상
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

변경 후보는 파일 이벤트·증분 bucket 집계·짧은 병합 갱신·화면 비활성 감속·상한 있는 캐시다. 큐 지연과 실제 화면 표시 지연을 구분한다. WidgetKit OS 지연은 별도 기록한다. 이번 1단계에서는 이 시나리오들의 CPU/RSS/디스크/표시 지연을 아직 측정하지 않았으며 수치 목표나 개선률을 보장하지 않는다.
