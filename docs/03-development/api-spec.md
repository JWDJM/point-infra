# API 명세

> 계약의 원본은 **`point-backend/api/openapi.yaml`** (프론트는 여기서 타입 생성). 이 문서는 설계 관점의 목록이며 `상태` 열로 구현 여부를 표시한다.
> 상태: ✅ 구현 · ❌ 설계만 (미구현) · 🧪 `local` 프로필 전용 — 전체 현황: [implementation-status](../00-overview/implementation-status.md)

Base: `https://api.<domain>` · 인증: `Authorization: Bearer <access token>` · 응답 공통 포맷 `{ "code": "...", "data": {...}, "message": "..." }`

## 인증 방식
| 토큰 | 형태 | 수명 (기본) | 전달 · 저장 |
|---|---|---|---|
| access token | RS256 JWT (`iss=point-monolith`, `sub`=사용자 id) | 15분 (`JWT_ACCESS_TTL`) | 응답 본문 → 브라우저 메모리, 요청 헤더 `Authorization: Bearer` |
| refresh token | 256bit 랜덤 | 14일 (`JWT_REFRESH_TTL`) | HttpOnly 쿠키 `point_refresh` (`Path=/api/auth`, `SameSite=Strict`, Secure=`AUTH_COOKIE_SECURE`). DB 에는 SHA-256 해시만 |

- refresh 는 **한 번 쓰면 폐기하고 새로 발급**(rotation) → 탈취된 토큰은 한 번만 유효. 로그아웃 시 폐기.
- event-service 는 monolith 를 호출하지 않고 공개키(`JWT_PUBLIC_KEY`, 없으면 `JWT_JWK_SET_URI`)로 자체 검증 (hybrid-msa §4).
- `refresh_token` 테이블은 CDC 복제 대상이 아니다 → DR 전환 후에는 다시 로그인 (access token 은 양쪽 같은 서명 키면 유효).

## monolith

| Method | Path | 설명 | 도메인 | 상태 |
|---|---|---|---|---|
| POST | `/api/auth/signup` | 회원가입 → 바로 로그인 (access 본문 + refresh 쿠키) | user | ✅ |
| POST | `/api/auth/login` | 로그인 (JWT 발급 + refresh 쿠키) | user | ✅ |
| POST | `/api/auth/refresh` | refresh 쿠키로 access 재발급 + refresh 교체 | user | ✅ |
| POST | `/api/auth/logout` | refresh 폐기 + 쿠키 삭제 | user | ✅ |
| GET | `/api/auth/jwks.json` | 서명 공개키 (JWKS) | user | ✅ |
| GET | `/api/users/me` | 내 정보 | user | ✅ |
| GET | `/api/assets` | 연동 자산 목록 (Mock 마이데이터) | asset | ❌ |
| GET | `/api/points/balance` | 포인트 잔액 | point | ✅ |
| GET | `/api/points/history` | 포인트 거래 내역 — **현재 최근 20건 고정** | point | ✅ |
| GET | `/api/points/history?cursor=` | 커서 페이지네이션 (`(created_at, id)` keyset) · 기간/유형 필터 | point | ❌ |
| POST | `/api/points/use` | 포인트 사용 (헤더 `Idempotency-Key` 필수, 사용자별로 범위 구분 `use:{userId}:{key}`) · 잔액 부족 409 | point | ✅ |
| POST | `/api/points/refunds` | 환불 요청 | point | ❌ |
| GET | `/api/cs/notices` | 공지 목록 | cs | ❌ |
| GET | `/api/health` | 앱 헬스 (화면 점검 감지용) | common | ✅ |

## event-service

| Method | Path | 설명 | 응답 | 상태 |
|---|---|---|---|---|
| GET | `/api/events/active` | 진행 중 이벤트 | 200 | ❌ |
| POST | `/api/events/attendance` | 출석체크 (KST 하루 1회) | 202 지급 예정 / 409 이미 출석 | ✅ |
| POST | `/api/events/{eventId}/queue` | 대기열 진입 | 200 `{ position }` | ❌ |
| GET | `/api/events/{eventId}/queue/me` | 내 순번 | 200 `{ position, admitted }` | ❌ |
| POST | `/api/events/{eventId}/answers` | 퀴즈 정답 제출 | 202 당첨(지급 예정 — Kafka 경유 원장 반영, 보통 1초 안쪽) / 200 낙첨(재고 소진) / 409 중복 / 410 이벤트 없음·마감 | ✅ |
| POST | `/api/events/{eventId}/open?stock=&amount=` | 이벤트 열기·초기화 (인증 없음) | 200 상태 | 🧪 |
| GET | `/api/events/{eventId}/status` | 재고·참여자·당첨자 수 (인증 없음) | 200 | 🧪 |

- 🧪 두 API 는 `@Profile("local")` 이라 **aws·gcp-dr 프로필에는 없다.** 운영에서 이벤트를 만들고(재고·금액 설정) 당첨자 수를 조회하는 경로는 아직 없다 → [event-day 런북](../05-operations/runbooks/event-day.md) D-1 단계(이벤트 생성)와 종료 후 대사(당첨자 수)가 이것에 의존한다.
- 프론트 이벤트 화면이 현재 이 두 API 를 호출한다 (point-frontend `features/event`).

## 운영·인프라 검증 (ops)

읽기 전용. 구성요소가 죽어 있어도 200 으로 응답하고 각 `status`(UP/DOWN/DISABLED) 로 구분한다. 끄려면 `OPS_API_ENABLED=false`.

| 서비스 | Method | Path | 설명 |
|---|---|---|---|
| monolith | GET | `/api/system/info` | 응답 Pod·프로필·DR 모드, PostgreSQL(버전·접속 노드·`pg_is_in_recovery`·`dr_heartbeat` 경과), Kafka(`point-ledger` 컨슈머 lag) |
| monolith | GET | `/api/system/whoami` | 응답 Pod 정보만 (부하 분산 확인용) |
| monolith | GET | `/api/system/ledger?recent=` | 원장 집계(지갑 수·잔액 합·출처별 합계) + 전체 사용자 최근 활동 |
| event-service | GET | `/api/events/system/info` | 응답 Pod, Redis(버전·role·PING), Kafka(토픽·누적 발행 offset). DR 모드에서는 503 `EVENT_MAINTENANCE` |
| event-service | GET | `/api/events/system/whoami` | 응답 Pod 정보만 |

## 관리자 (admin)

없음. ADR-0017 의 일괄 정산 API(`/api/admin/events/{id}/settlement`, `X-Admin-Token`)는 ADR-0018 로 제거됐다.

## DR 모드

| 경로 | 동작 |
|---|---|
| `/api/events/**` | 503 `{ "code": "EVENT_MAINTENANCE", "message": "이벤트는 시스템 점검으로 일시 중단되었습니다." }` |
| 그 외 | 정상 |

## Kafka 메시지: `point.reward.requested`

```json
{
  "idempotencyKey": "evt-20261111-quiz:1004",
  "userId": 1004,
  "eventId": "evt-20261111-quiz",
  "amount": 500,
  "reason": "QUIZ_REWARD",
  "occurredAt": "2026-11-11T10:00:01.234+09:00"
}
```

| 필드 | 값 |
|---|---|
| `reason` | `QUIZ_REWARD`, `ATTENDANCE_REWARD` → 둘 다 원장에 즉시 멱등 반영 (ADR-0018). 로그·대사 구분용 |
| `idempotencyKey` | `{eventId}:{userId}` — 출석은 `eventId = attendance-{yyyyMMdd}` |
| Kafka key | `userId` (같은 사용자 순서 보장) |
- 소비 실패: 1초 간격 3회 재시도 후 `point.reward.dlq` (monolith `RewardConsumerErrorConfig`)
