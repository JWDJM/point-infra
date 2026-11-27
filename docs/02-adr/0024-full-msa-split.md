# ADR-0024: core-service 를 user-service · point-command · point-query 로 분리 (ADR-0001 대체)
- 상태: **Proposed**
- 날짜: 2026-11-27 KST
- 대체: ADR-0001 (모듈러 모놀리스 + 선택적 MSA)
- 수정: ADR-0004 — "DR 시 core-service 만 복구" 를 "DR 시 user-service · point-command · point-query 복구" 로 읽는다 (본문 수정 없이 상태 줄에 용어 갱신만 추가, #35 선례)
- 논의: #51, #53 (라우팅·운영 API 보정, Decision Lock 전환 중 표기)
- 진행 단계 (이 ADR 에서 쓰는 용어):
  1. **제안 승인** — 이 PR 이 리뷰 승인을 받아 머지된 상태 (상태는 Proposed 유지). 이때부터 구현 이슈를 만들고 작업을 시작할 수 있다.
  2. **Accepted 전환** — 구현 완료 후 DR 리허설로 RTO ≤ 30분을 확인하고 결과를 기록한 뒤 별도 PR 로 상태를 바꾼다. ADR-0001/0004 상태와 Decision Lock 최종 문구도 이때 바꾼다. (제안 승인 직후 Decision Lock 에는 "ADR-0024 로 전환 중" 으로 표기해 구현 착수를 허용한다 — 공통 규칙 v1.6.0, #53)

## 맥락
- 팀에서 core-service 를 기능 단위 서비스로 분리하기로 결정했다 (2026-11-27 KST, #51).
- 목표:
  1. **돈이 움직이는 경로(포인트 사용·적립)를 조회 부하에서 격리한다.** 잔액·내역 조회는 앱 진입 때마다 호출되는 가장 잦은 요청이고, 사용·적립은 빈도는 낮지만 실패하면 금전 영향이 있다.
  2. **조회만 독립적으로 확장한다.** 지금은 조회가 몰려도 core-service 전체를 늘려야 한다.
  3. **인증과 포인트를 독립 배포한다.** 포인트 배포 실패·롤백이 로그인에 영향을 주지 않게 한다.
- **구현된 기능만 분리 대상으로 한다.** asset(자산조회)·cs(고객센터)·포인트 환불은 코드가 없으므로 (테이블·패키지 골격뿐) 이 ADR 에서 다루지 않는다. 구현할 때 어느 서비스에 둘지 별도로 정한다.
- 현재 core-service 는 분리 비용이 낮은 상태다 (2026-11-27 KST, point-backend `main` 기준):

  | 도메인 | 구현된 API·처리 | DB | 다른 도메인 코드 참조 | 다른 스키마 SQL 참조 |
  |---|---|---|---|---|
  | user | `/api/auth/**` (가입·로그인·재발급·로그아웃·JWKS), `/api/users/me` | `users.*` | 없음 | 없음 |
  | point | `GET /api/points/balance`, `GET /api/points/history`, `POST /api/points/use`, Redis Stream 적립 consumer (ADR-0019), `/api/system/ledger` 집계 | `point.*` | 없음 | 없음 (지갑은 `point` 안에서 지연 생성) |

  - 도메인 간 공유는 `common` 패키지(에러 응답, 보안 설정, `LoginUser`)뿐이고, 스키마 간 FK 와 도메인을 넘는 트랜잭션이 없다.
  - event-service 가 이미 JWKS 로 JWT 를 자체 검증한다 → 같은 방식을 새 서비스에 재사용할 수 있다.

## 결정
**core-service 를 user-service / point-command / point-query 3개로 분리한다.** event-service 는 그대로 둔다.

| 서비스 | 담당 | 경로 (HTTPRoute) | DB 권한 |
|---|---|---|---|
| user-service | 회원가입·로그인·토큰 재발급·로그아웃, JWT(RS256) **발급 주체**, JWKS 공개, 내 정보 | `/api/auth/**`, `/api/users/**` | `users` 스키마 읽기·쓰기 |
| point-command | 포인트 **사용** + **적립**(Redis Stream consumer) — 원장에 쓰는 모든 처리 | `/api/points/use` | `point` 스키마 읽기·쓰기 |
| point-query | 잔액·내역 조회, 원장 집계, 서비스 이용 가능 여부(`/api/health`) | `/api/points/**` (위 경로 제외), `/api/health` | `point` 스키마 **SELECT 만** |
| event-service | 변경 없음 | `/api/events/**` | Redis |

**데이터 저장소** — 분리하는 3개 서비스만 RDS 를 쓰고, event-service 는 지금처럼 ElastiCache(Redis)만 쓴다 (RDS 접근 없음).

| 서비스 | RDS (PostgreSQL) | ElastiCache (Redis) |
|---|---|---|
| user-service | `users` 스키마 | 사용 안 함 |
| point-command | `point` 스키마 (소유) | 보상 Stream **읽기만** (consumer group, ADR-0019) — 저장소가 아니라 event-service → 원장 반영 통로 |
| point-query | `point` 스키마 (SELECT 만) | 사용 안 함 |
| event-service | **사용 안 함** | 판정·대기열·보상 Stream 쓰기 (ADR-0007·0019) |

### 세부 원칙
1. **원장 쓰기는 point-command 한 곳에서만 한다.** 적립도 "사용" 서비스에 둔다. 지갑 행 잠금·멱등키·음수 잔액 차단이 한 서비스 안에서만 동작해야 잔액이 꼬이지 않는다. 원장 append-only 원칙은 그대로다.
2. **point-query 는 Primary DB 를 읽기 전용 계정으로 읽는다 (Read Replica 아님).** 사용 직후 잔액 조회에 바로 반영돼야 한다 (read-your-writes). 쓰기는 DB 권한으로 원천 차단한다. 조회 부하가 커져 Replica 가 필요하면 별도 ADR 로 다룬다.
3. **point 스키마 공유는 의도된 예외다.** "서비스 = 자기 DB 소유" 원칙에서 벗어나므로 다음을 지킨다.
   - 스키마 변경의 소유자는 point-command. 변경은 **하위 호환(Expand → Migrate → Contract)** 으로만 하고, point-query 가 새 구조를 읽도록 배포한 뒤 옛 컬럼을 지운다.
   - point-query 가 읽는 테이블·컬럼은 point-command 코드 리뷰 시 함께 확인한다.
4. **DB 마이그레이션은 서비스가 아니라 `db-migration` Job 하나가 담당한다.**
   - 기존 `V202611050000__init_schema.sql` 이 users·point·asset·cs 스키마를 한 파일에서 만들고, 기존 마이그레이션 파일은 수정 금지이므로 서비스별로 나눌 수 없다.
   - 배포 전 k8s Job(ArgoCD sync hook)으로 Flyway 를 한 번 실행하고, 각 서비스는 Flyway 를 끈다. asset·cs 테이블도 지금처럼 이 Job 이 관리한다.
   - Job 은 마이그레이션 전용 DB 계정을 쓰고, 서비스 계정에는 DDL 권한을 주지 않는다.
5. **DB 인스턴스는 나누지 않는다 — 같은 RDS 인스턴스, 서비스별 DB 계정.** ADR-0013(RDS PostgreSQL), ADR-0020(논리 복제 PUBLICATION → SUBSCRIPTION) 구조를 그대로 유지해 DR 복제 경로가 바뀌지 않는다.
6. **인증** — user-service 만 서명 키(`JWT_PRIVATE_KEY`)를 가진다. point-command · point-query 는 공개키(`JWT_PUBLIC_KEY`, local 은 JWKS)로 자체 검증한다 (event-service 와 동일).
7. **서비스 간 동기 호출은 두지 않는다.** 사용자 식별은 JWT 의 `sub` 로 해결한다. 비동기는 Redis Stream(ADR-0019) + 멱등키를 쓴다. 새 메시징 인프라는 도입하지 않는다.
8. **라우팅 — 경로(PathPrefix)로만 나눈다.** `/api/points/use` → point-command, 나머지 `/api/points/**` → point-query (긴 경로 우선).
   - HTTP 메서드 매칭은 쓰지 않는다: AWS ALB(LBC)는 지원하지만 **GKE Gateway 는 HTTPRoute `matches[].method` 를 지원하지 않아** (GatewayClass capabilities, 모든 클래스 N/A) DR 에서 라우팅이 깨진다 (ADR-0014·0010, #53).
   - point-command 에 쓰기 API 를 추가하면 HTTPRoute 규칙(aws·gcp-dr 양쪽)도 같은 PR 묶음에서 추가한다. 경로를 정할 때 조회 API 와 접두어가 겹치지 않게 한다.
   - API 경로가 바뀌지 않으므로 프론트 화면 코드와 OpenAPI 의 업무 API 경로는 그대로다.
9. **운영 API — 모든 서비스가 `/api/system/{서비스}/**` 한 형식을 쓴다 (event-service 포함).**
   - 경로 형식만 맞추는 것이다. 각 서비스는 자기 저장소 상태만 보여준다 (event-service 는 Redis, 나머지는 RDS·Stream). 저장소를 공유한다는 뜻이 아니다.
   | 서비스 | 경로 (예) |
   |---|---|
   | user-service | `/api/system/user/{info,whoami}` |
   | point-command | `/api/system/point-command/{info,whoami}` — 적립 Stream 소비 상태 포함 |
   | point-query | `/api/system/point-query/{info,whoami,ledger}` |
   | event-service | `/api/system/event/{info,whoami}` — 기존 `/api/events/system/**` 에서 옮긴다 |
   - HTTPRoute 는 `/api/system/{서비스}` 접두어로 각 서비스에 보낸다. DR 에서 `/api/system/event/**` 는 `/api/events/**` 와 같이 maintenance 로 보낸다.
   - 모두 `OPS_API_ENABLED` 로 끌 수 있어야 한다 (기존 규칙). 지금 `/api/system/info` 하나가 DB·Stream·원장 집계를 함께 보여주므로, 서비스별로 자기 상태만 응답하도록 나눈다.
   - 프론트 시스템 대시보드(`features/system`)가 운영 API 를 쓰므로 경로 변경은 backend·frontend 연계 PR 로 한다 (Expand → Migrate → Contract: 새 경로 추가 → 프론트 전환 → 옛 경로 제거).
10. **공통 코드** — `common` 을 공유 Gradle 모듈(라이브러리)로 추출한다. 도메인 로직은 넣지 않는다 (에러 응답 형식, 보안 필터, `LoginUser` 수준).
11. **배포 단위** — 서비스마다 이미지·`k8s/base/<서비스>`·HTTPRoute·ArgoCD Application·PDB·probe·non-root securityContext 를 갖춘다 (레포별 규칙). 이미지 태그 bump 는 backend CI 봇 PR 만 허용 (기존 규칙 유지).
12. **확장** — EKS + Karpenter + KEDA 범위 안에서 한다 (ADR-0002). point-query 는 요청량 기준 HPA/KEDA 로 따로 늘린다. 노드 풀은 ADR-0022(Proposed, #48) 의 general 풀 — taint 가 없어 nodeSelector 가 필요 없다.

### DR (ADR-0004 수정)
| 서비스 | DR 복구 | 근거 |
|---|---|---|
| user-service | ✅ | 로그인 불가 시 모든 기능 불가 |
| point-command | ✅ | 포인트 사용 — 금전 영향 |
| point-query | ✅ | 잔액·내역 조회 — 고객 불안·민원 |
| event-service | ❌ | 변경 없음 — `/api/events/**` 503 점검 안내 |

- 복구 대상 "기능" 은 ADR-0004 와 같다 (자산조회는 미구현이라 제외). 배포 단위만 1개 → 3개(+ `db-migration` Job)로 늘어난다.
- **DB 계정:** 논리 복제는 DB 계정(role)을 복제하지 않는다. Cloud SQL 에도 서비스별 계정을 NOLOGIN 으로 미리 만들고, 승격(`promote-cloudsql.sh`) 때 `app_rw` 대신 서비스 계정 모두를 LOGIN 으로 바꾼다. 비밀번호는 양쪽 Secret 에 같은 값.
- DR 에서는 Redis 가 없으므로 point-command 의 적립 consumer 는 대기 상태가 된다 — ADR-0004 의 "이벤트 미반영 건은 Failback 후 재처리" 와 같다. consumer 가 Redis 연결 실패로 서비스 전체를 죽이지 않도록 구현한다 (readiness 에서 Redis 제외).
- ArgoCD 가 병렬로 동기화하므로 RTO 증가는 제한적일 것으로 예상하나, **Accepted 전환 전에 DR 리허설로 재측정한다.**
- DR 경로에서 AWS 리소스 참조 금지(ADR-0010)는 새 서비스에도 그대로 적용한다 (이미지는 Artifact Registry 이중 푸시).

## 고려한 대안
| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| A. 현행 유지 (core-service + event) | 가장 단순, 운영 비용 최소 | 조회 부하가 사용·적립과 같은 파드를 공유, 조회만 따로 확장 불가, 포인트 배포가 로그인과 묶임 | 목표 1·2·3 모두 충족 못 함 |
| B. user + point 단일 서비스 (2개) | 스키마 공유 예외 없음, 변경 적음 | 조회 부하가 사용·적립과 같은 파드를 공유 | 목표 3 만 충족 — 목표 1·2(조회 격리·독립 확장) 미충족 |
| **C. user + point-command + point-query (3개)** | 돈이 움직이는 경로 격리, 조회만 독립 확장, 인증·포인트 독립 배포 | point 스키마 공유 예외, 배포 단위 증가 | **채택** |
| D. 도메인 전체 분리 (user/point/asset/cs) | 향후 도메인 경계까지 미리 확보 | 코드가 없는 서비스 2개의 배포·운영 비용, 조회 격리 없음 | 미구현 기능은 분리 대상에서 제외 — 구현 시 재결정 |
| E. 서비스별 DB 인스턴스 | 데이터 완전 격리 | RDS·Cloud SQL·논리 복제 경로 증가, DR 비용·RTO 증가, command·query 간 복제 지연 | 현재 트래픽에서 비용 대비 이득 없음, read-your-writes 위반 |

## 결과
- (+) 조회 폭주가 포인트 사용·적립에 영향을 주지 않는다. 조회는 HPA/KEDA 로 따로 늘린다.
- (+) 원장 쓰기 경로가 한 서비스로 좁혀져 리뷰·감사 범위가 명확하다.
- (+) 인증 배포와 포인트 배포가 분리된다.
- (−) point 스키마를 두 서비스가 공유 → 스키마 변경 시 하위 호환·배포 순서를 지켜야 한다.
- (−) 배포 단위 2개 → 4개(+ 마이그레이션 Job): 이미지, CI 파이프라인, 태그 bump PR, 대시보드·알람이 늘어난다.
- (−) DR 에서 띄울 배포 단위 증가 → RTO 재측정 필요.
- (−) 공유 DB 인스턴스는 여전히 공동 장애점이다 (E 안을 택하지 않은 대가).
- (−) 로컬 개발: 띄울 프로세스가 늘어난다 → Makefile 에 일괄 실행 타깃 필요.

## 후속 과제 (제안 승인 후 goal + sub-issue 로 생성, backend PR ↔ infra PR 은 `Related:` 로 상호 링크)
1. **공통 모듈 추출** — `common` → 공유 Gradle 모듈 (전역 영향 변경이므로 단독 이슈·단독 PR)
2. **`db-migration` Job** — Flyway 를 서비스에서 분리, 마이그레이션 전용 계정, ArgoCD sync hook (infra + backend)
3. **DB 계정·권한 분리** — user-service(users RW), point-command(point RW), point-query(point SELECT), 서비스 계정 DDL 권한 제거. Cloud SQL 에 같은 계정 NOLOGIN 생성 + `promote-cloudsql.sh`·DR 런북의 LOGIN 전환 대상 갱신
4. **point-query 분리** — 조회 API·원장 집계·`/api/health` 이관, HTTPRoute 경로 규칙, 읽기 전용 계정으로 쓰기 차단 확인 (위험이 낮아 첫 분리 대상, 새 서비스 템플릿 확립: Gradle 모듈·Dockerfile·CI 이중 푸시·태그 bump·`k8s/base`·overlays·ExternalSecret·ArgoCD Application)
5. **point-command 분리** — 사용 API·Redis Stream consumer group 이관, 멱등키·음수 잔액 차단 재검증, DR 재정산 스크립트(`scripts/dr/*`) 재검증
6. **core-service → user-service 정리** — 인증·JWKS·내 정보만 남기고 이름 변경. JWT 발급자(`JWT_ISSUER=point-core`)는 바꾸지 않는다 (event-service 등이 이 값으로 검증 — 바꾸면 기존 토큰 무효). event-service `JWT_JWK_SET_URI` 등 참조 갱신, 로컬 `vite.config.ts` proxy·Makefile 갱신
7. **운영 API 경로 통일** — 4개 서비스 `/api/system/{서비스}/**` (event-service 포함), HTTPRoute(aws·gcp-dr), OpenAPI, 프론트 시스템 대시보드 (backend·frontend·infra 연계)
8. **DR 리허설** — 3개 서비스 기준 RTO 재측정 → 결과 기록 후 Accepted 전환 PR
9. **문서·규칙 동기화 (Accepted 전환 PR)** — Decision Lock "아키텍처"·"DR" 행의 "전환 중" 표기를 최종 문구로, ADR-0001 `Superseded by ADR-0024`, ADR-0004 용어 갱신, 공통 규칙 버전 업 + `make sync-ai-rules`, `01-architecture/hybrid-msa.md`·`api-spec.md`·DR 런북 갱신
