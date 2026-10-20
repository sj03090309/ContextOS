# 설치 승인 검토: Observation Bridge v0.2 후보
**아직 설치·활성화하지 않았다.** 기존 manager 승인 ID나 v0.1 설명을 새 범위의 허가로 취급하지 않는다.

- 승인할 동작: 로컬 `contextos.observation-bridge` v0.2.0 VSIX를 VS Code/Insiders에 설치 → 사용자 설정 `contextosObservation.enabled` 켜기 → 격리 후보 앱의 `VS Code 자동 활동 연결` 켜기. 두 설정은 최초 꺼짐이고 명시적으로 켠 뒤에는 앱/에디터 재시작 시 자동 연결한다. 일상적인 시작 버튼·공백 확인 질문은 없다.
- 수집: 정적 에디터 종류, 연결 UUID·sequence, focus boolean, 비어 있지 않은 내용 변경 콜백 횟수, selection/scroll 콜백 **종류**. 배열 원문·document·URI·선택 위치·스크롤 범위·경로·프로젝트·제목·키 입력·계정·API키를 읽지 않는다. 사람/AI/프로그램 동작은 구분하지 못한다.
- 시간 의미: 포커스/활동 후 최대 **5분**을 활동으로 분류하는 제품 가정이다. 읽기·생각·방치를 정확히 재는 값이 아니며 `활동 추정`으로 표시한다. 5분 공백에는 자동 정지, 새 사건에서 자동 재개한다. 콜백 수와 추정 시간을 구분한다.
- 범위: 로컬 macOS trusted VS Code/Insiders editor host 최대 4개. 겹친 시간은 중앙에서 한 번만 합친다. remote·virtual·untrusted·JetBrains·Xcode 편집·터미널/웹 활동은 미지원이다.
- 로컬 전달: `~/Library/Application Support/ContextOS Observation Candidate/observations.sock`. 디렉터리 0700, 소켓 0600, 같은 UID 확인, 프레임 1 KiB와 속도 상한. v0.2는 **오늘 집계를 확장에 회신**하여 상태 표시줄·앱·위젯의 원천을 통일한다. heartbeat 30초는 활동 시간 창을 늘리지 않는다. 같은 UID 소프트웨어의 위조까지 막는 확장 서명 인증은 아니다.
- 저장 변경: 같은 디렉터리의 **activity-day-v1.json**에 오늘 추정 합계·일자·시간대·규칙·생성 시각·상태/누락만 저장한다. 16 KiB 상한, 파일 0600, 60초 및 상태 경계 저장. 원시 사건·nonce·창 ID·내용은 저장하지 않는다. 재시작은 저장된 합계만 paused/partial로 복원하며 공백을 채우지 않는다. extension enabled와 host receiver enabled 설정도 각 사용자 환경설정에 남는다.
- 저장 기간: 다일 이력은 없고 마지막 당일 집계 파일 1개만 유지한다. 사용 중에는 새 일자 집계로 대체되지만 중지/확장 제거 후 자동 만료·삭제는 없다. 마지막 파일은 사용자가 삭제할 때까지 남을 수 있다.
- 외부 전송: 없음. TCP endpoint·텔레메트리·공개 업로드·화면 캡처 없음. 새 Accessibility/Input Monitoring·Apple 인증서·계정 로그인·결제·외부 네트워크 설정도 요구하지 않는다.
- 중지/제거: extension enabled 끄기 → 후보 host receiver 끄기 → 에디터에서 확장 제거. 정상 종료는 자신의 소켓만 지운다. 집계 파일은 자동 삭제하지 않으며 사용자가 activity-day-v1.json과 사용하지 않는 후보 디렉터리를 제거할 수 있다. 크래시 잔여 소켓은 검토 후 후보 경로만 정리한다. 운영 앱·원본 AI 로그·프로젝트는 변경하지 않는다.

실제 VSIX 설치/Extension Host/새 상태 표시줄과 Mac 화면은 미검증이다. 후보 코드는 합성 검사·빌드·패키지 검사까지만 진행하며 실제 활성화는 이 범위의 승인 후 진행한다. 기존 수동 타이머·전경 체류·명시 Codex 로그 구간은 별도 도구이며 자동 활동에 합산하지 않는다.
