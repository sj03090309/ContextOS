# ContextOS

**Claude Code를 위한 로컬 컨텍스트 최적화 도구.** AI를 쓰지 않고, 전부 내 컴퓨터에서만 동작합니다.

ContextOS는 Claude Code가 코드베이스 전체를 뒤지는 대신 **작업에 관련된 파일·함수만** 읽도록 도와줍니다. 그 결과 **더 적은 토큰으로 더 정확하게** 작업하게 됩니다.

> OpenAI / Claude / Gemini API 없음. LLM 호출 없음. 외부 서버 없음.
> AST·Tree-sitter 스타일 정적 분석·Git·파일시스템·규칙 기반 엔진만 사용합니다.

---

## 어떻게 동작하나요

1. `contextos connect` 를 한 번 실행하면, Claude Code에 **"파일을 직접 탐색하기 전에 ContextOS부터 써라"** 는 지침이 심어지고 MCP 서버가 등록됩니다.
2. 이후 아무 프로젝트에서 Claude Code로 작업하면, Claude Code가 **자동으로** ContextOS를 호출해 관련 파일만 받아 읽습니다.
3. 메뉴바 앱은 **얼마나 아꼈는지**를 실시간으로 보여줍니다.

당신은 아무것도 안 해도 됩니다. 최적화는 눈에 안 보이게 돌아갑니다.

```
평소처럼 Claude Code에 질문
   → ContextOS가 관련 파일·함수만 골라서 전달
   → 토큰 절약, 응답 품질 향상
```

---

## 주요 기능

- **프로젝트 인덱서** — 파일·심볼·import 관계를 한 번 분석해 로컬 SQLite에 저장. 이후엔 전체를 다시 읽지 않습니다.
- **스마트 파일 필터** — `node_modules`·`.git`·`build`·바이너리 등 노이즈 자동 제외.
- **컨텍스트 옵티마이저** — 어휘 매칭 + **IDF 가중치**(희귀 심볼 우대) + import 그래프 확장으로 관련 파일을 랭킹하고, 토큰 예산 안에서 선택.
- **심볼 단위 슬라이싱** — 파일 전체 대신 **관련 함수 본문 + 나머지는 시그니처(목차)만** 전달. 큰 파일에서 토큰을 크게 절감.
- **능동적 쿼리 보정** — 한↔영 개발용어 사전, 오타 교정(프로젝트 실제 심볼과 대조), 인덱스 기반 확장. "로그인 고쳐줘" → `login, authenticate` 로 알아서 이해.
- **Git 신호** — 지금 편집 중인(커밋 안 된) 파일을 감지해 관련 컨텍스트를 미리 준비.
- **파일 감시** — 파일이 바뀌면 인덱스를 자동 갱신.
- **로컬 토큰 추정** — 외부 API 없이 토큰 수를 근사.
- **메뉴바 모니터** — 아낀 토큰(오늘/누적), AI 토큰 사용량, 연결된 AI 도구를 표시.

---

## 설치 & 사용

### 1. 빌드

```sh
swift build -c release          # CLI / MCP / 앱 빌드
swift test                      # 테스트
```

### 2. Claude Code에 연결 (핵심)

```sh
.build/release/contextos connect
```

이 한 줄이 (1) `~/.claude/CLAUDE.md` 에 자동 사용 지침을 넣고 (2) MCP 서버를 전역 등록합니다. **Claude Code를 재시작**하면 이후 모든 프로젝트에서 자동으로 적용됩니다.

### 3. 메뉴바 앱 (선택)

```sh
./scripts/build_app.sh          # → dist/ContextOS.app
open dist/ContextOS.app
```

더블클릭으로 실행되는 메뉴바 앱입니다. 아이콘을 클릭하면 절약량·AI 사용량·연결된 도구를 볼 수 있습니다.

---

## 구성

모든 로직은 `ContextOSCore` 에 있고, 나머지는 얇은 어댑터입니다.

```
Claude Code ──MCP(stdio)──▶ contextos-mcp ──▶ ContextOSCore ──▶ SQLite 인덱스
메뉴바 앱   ────────────────────────────────────┘
CLI (개발용) ───────────────────────────────────┘
```

| 타깃 | 역할 |
|---|---|
| `ContextOSCore` | 인덱싱·최적화·슬라이싱·보정 등 순수 로직 |
| `contextos` | CLI (`connect` · `context` · `watch`) |
| `contextos-mcp` | Claude Code용 MCP 서버 (stdio JSON-RPC) |
| `ContextOSApp` | SwiftUI 메뉴바 모니터 |

### CLI 명령

| 명령 | 설명 |
|---|---|
| `contextos connect` | Claude Code 자동 연동 (지침 설치 + MCP 등록) |
| `contextos context "<작업>"` | 관련 파일을 직접 찾기 (붙여넣기용) |
| `contextos watch [경로]` | 파일 변경 시 자동 재인덱싱 |

### MCP 도구 (Claude Code가 자동 호출)

| 도구 | 설명 |
|---|---|
| `get_relevant_context` | 작업에 관련된 최소 파일 목록 반환 |
| `read_optimized` | 관련 파일 내용을 (슬라이싱해) 반환 |
| `index_project` | 프로젝트 강제 재인덱싱 |
| `project_stats` | 인덱스 통계 |

---

## 개발 환경

- macOS 14+ / Swift 6
- 의존성: `swift-argument-parser` (그 외 외부 의존성 없음, SQLite는 시스템 제공)

```sh
swift build        # 디버그 빌드
swift test         # 테스트
swift run contextos context "로그인 수정"   # CLI 실행
```

---

## 설계 철학

- 최대한 적은 컨텍스트로 최대한 높은 정확도.
- 프로젝트 전체를 반복해서 읽지 않는다.
- 모든 처리는 로컬에서. 개인정보는 외부로 나가지 않는다.
- 사용자는 가능한 한 아무것도 설정하지 않는다.
