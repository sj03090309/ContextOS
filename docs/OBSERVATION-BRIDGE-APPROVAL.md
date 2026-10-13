# 설치 승인 검토: Observation Bridge 후보
아직 설치·활성화하지 않았다. 알 수 없는 기존 manager 승인 ID를 허가로 취급하지 않는다.

- 승인할 동작: VS Code 또는 Insiders에 로컬 `contextos.observation-bridge` VSIX 설치 → 사용자 설정 `contextosObservation.enabled` 켜기 → 후보 앱의 로컬 수신 켜기. 기본 꺼짐이다.
- 수집: 문서 내용 변경 콜백 횟수, 창 focus boolean, 정적 에디터 종류, 연결별 임의 UUID·sequence·gap/heartbeat. 콜백 배열 길이만 확인한다. 코드·텍스트·document·URI·경로·프로젝트·제목·키 입력·계정·API키는 읽거나 전송하지 않는다. 사람/AI 작성자를 구분하거나 이벤트 간격으로 시간을 계산하지 않는다.
- 범위: 로컬 macOS trusted VS Code/Insiders 한 에디터 host 연결. 여러 창 동시·remote·virtual·untrusted·JetBrains·Xcode 편집 이벤트는 미지원이다.
- 전달: 같은 사용자 Unix 소켓 `~/Library/Application Support/ContextOS Observation Candidate/observations.sock`. 디렉터리 0700, 소켓 0600, peer UID 확인. 프레임 1 KiB, batch 256회, 250ms 병합, 30초 재연결, 60초 메타데이터 heartbeat. 같은 UID의 다른 소프트웨어가 패킷을 흉내 낼 수 있으며 확장 출처 인증은 보장하지 않는다.
- 저장: 앱 프로세스 메모리의 집계·연결 상태만. 원시 이벤트·코드·시간 이력을 디스크에 저장하지 않는다. enabled 설정은 에디터 사용자 설정에 남는다. 외부 전송·TCP endpoint·텔레메트리·공개 업로드 없음.
- 권한: 확장 코드 실행·편집 콜백/창 focus API 접근과 후보 소켓 생성. 새 Accessibility/Input Monitoring·Apple 인증서·계정 로그인·결제·외부 네트워크 설정은 요구하지 않는다.
- 중지/제거: enabled 끄기 → 앱 수신 끄기 → 에디터에서 확장 제거. 정상 중지/종료는 자신의 소켓만 제거하며 빈 후보 디렉터리는 남을 수 있다. 크래시로 남은 소켓은 검토 후 후보 경로만 수동 제거한다. 기존 경로는 자동 덮어쓰기/삭제하지 않는다.

검사: 관련 Swift 34개, 신규 최종 7개, JavaScript 5개 통과. 합성 소켓 전달·ZIP/XML 검사 완료. 실제 에디터 Extension Host 실행·설치·Mac 화면은 미검증이다. VSIX는 서명 없는 로컬 검토 패키지이며 Marketplace에 게시하지 않았다.
