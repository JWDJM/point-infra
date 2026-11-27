# ADR-0024: core-service 를 도메인별 서비스로 분리 (전체 MSA, ADR-0001 대체)
- 상태: **Proposed**
- 날짜: 2026-11-27 KST
- 대체: ADR-0001 (모듈러 모놀리스 + 선택적 MSA)
- 수정: ADR-0004 — "DR 시 core-service 만 복구" 를 "DR 시 event-service 를 **제외한** 전 서비스 복구" 로 읽는다 (본문 수정 없이 상태 줄에 용어 갱신만 추가, #35 선례)
- 관련: point-backend 구현 이슈는 승인 후 생성 (후속 과제 참고)
- 논의: #51

## 맥락
- ADR-0001 은 "확장이 필요한 건 event 뿐" 이라는 이유로 user/asset/point/cs 를 하나의 core-service 에 두었다.
- 팀에서 core-service 를 전체 MSA 로 전환하기로 결정했다 (2026-11-27 KST, #51).
  - **리뷰 중 보강:** 결정 근거(무엇을 얻으려는지)를 이 줄에 구체적으로 적는다. 대안 A·D 의 기각 이유도 이 근거에 따라 확정한다.
- 현재 core-service 는 분리 비용이 낮은 상태다 (2026-11-27 KST, point-backend `main` 기준):

  | 도메인 | API | DB 스키마 | 다른 도메인 코드 참조 | 다른 스키마 SQL 참조 |
  |---|---|---|---|---|
  | user | `/api/auth/**`, `/api/users/**` (JWT 발급, JWKS) | `users.*` | 없음 | 없음 |
  | point | `/api/points/**`, Redis Stream consumer (ADR-0019) | `point.*` | 없음 | 없음 (지갑은 `point` 안에서 지연 생성) |
  | asset | 없음 (골격만) | `asset.*` | 없음 | 없음 |
  | cs | 없음 (골격만) | `cs.*` | 없음 | 없음 |

  - 도메인 간 공유는 `common` 패키지(에러 응답, 보안 설정, `LoginUser`)뿐이고, 스키마 간 FK 와 도메인을 넘는 트랜잭션이 없다.
  - event-service 가 이미 JWKS 로 JWT 를 자체 검증한다 → 같은 방식을 새 서비스에 재사용할 수 있다.

## 결정
**core-service 를 user-service / point-service / asset-service / cs-service 로 분리한다.** event-service 는 그대로 둔다.

| 서비스 | 담당 | 경로 (HTTPRoute) | DB |
|---|---|---|---|
| user-service | 회원·인증, JWT(RS256) **발급 주체**, JWKS 공개 | `/api/auth/**`, `/api/users/**` | `users` 스키마 |
| point-service | 지갑·원장(append-only)·사용·환불, Redis Stream 소비 | `/api/points/**` | `point` 스키마 |
| asset-service | 마이데이터 자산조회 | `/api/assets/**` (구현 시 OpenAPI 에 추가) | `asset` 스키마 |
| cs-service | 공지·문의 | `/api/cs/**` (구현 시 OpenAPI 에 추가) | `cs` 스키마 |
| event-service | 변경 없음 | `/api/events/**` | Redis |

### 세부 원칙
1. **DB — 같은 RDS 인스턴스, 서비스별 스키마 + 서비스별 DB 계정.**
   - 각 서비스 계정은 자기 스키마에만 권한을 가진다 (다른 스키마 SELECT 도 금지 → 경계를 DB 권한으로 강제).
   - Flyway 는 서비스별로 자기 스키마만 관리한다 (스키마별 history 테이블). 기존 마이그레이션 파일은 수정하지 않고 각 서비스로 이관만 한다.
   - DB 인스턴스를 나누지 않는 이유: ADR-0013(RDS PostgreSQL), ADR-0020(논리 복제 PUBLICATION → SUBSCRIPTION) 구조를 그대로 유지해 DR 복제 경로가 바뀌지 않는다.
2. **인증** — user-service 만 서명 키(`JWT_PRIVATE_KEY`)를 가진다. 나머지 서비스는 공개키(`JWT_PUBLIC_KEY`, local 은 JWKS)로 자체 검증한다 (event-service 와 동일).
3. **서비스 간 통신** — 동기 호출은 기본적으로 두지 않는다. 사용자 식별은 JWT 의 `sub` 로 해결한다. 비동기가 필요하면 Redis Stream(ADR-0019) + 멱등키를 쓴다. 새 메시징 인프라는 도입하지 않는다.
4. **공통 코드** — `common` 을 공유 Gradle 모듈(라이브러리)로 추출한다. 도메인 로직은 넣지 않는다 (에러 응답 형식, 보안 필터, `LoginUser` 수준).
5. **운영 API** — `/api/system/**` 은 서비스마다 경로가 겹치므로 서비스별 접두어로 나눈다 (예: `/api/points/system/ledger`). event-service 의 `/api/events/system/**` 방식과 맞춘다.
6. **배포 단위** — 서비스마다 이미지·`k8s/base/<서비스>`·HTTPRoute·ArgoCD Application·PDB·probe 를 갖춘다 (레포별 규칙). 이미지 태그 bump 는 backend CI 봇 PR 만 허용 (기존 규칙 유지).
7. **확장** — 모두 EKS + Karpenter + KEDA 범위 안에서 한다 (ADR-0002). 노드 풀 배치는 ADR-0022(Proposed, #48) 의 general 풀을 따른다 — taint 가 없는 풀이라 새 서비스 매니페스트에 nodeSelector 가 필요 없다 (event 풀은 event-service 전용 유지).

### DR (ADR-0004 수정)
| 서비스 | DR 복구 | 근거 |
|---|---|---|
| user-service | ✅ | 로그인 불가 시 모든 기능 불가 |
| point-service | ✅ | 잔액·사용·환불 — 금전 영향 |
| asset-service | ✅ | 기존에도 복구 대상이었음 (core-service 포함). 경량 서비스 |
| cs-service | ✅ | 장애 공지 수단. 경량 서비스 |
| event-service | ❌ | 변경 없음 — `/api/events/**` 503 점검 안내 |

- 복구 대상 "기능" 은 ADR-0004 와 같다. 배포 단위만 1개 → 4개로 늘어난다.
- ArgoCD 가 4개를 병렬로 동기화하므로 RTO 증가는 제한적일 것으로 예상하나, **DR 리허설로 RTO ≤ 30분을 재측정한 뒤 Accepted 로 바꾼다.**
- DR 경로에서 AWS 리소스 참조 금지(ADR-0010)는 새 서비스에도 그대로 적용한다 (이미지는 Artifact Registry 이중 푸시).

## 고려한 대안
| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| A. 현행 유지 (core-service + event) | 가장 단순, 운영 비용 최소 | 도메인별 배포·장애 경계가 패키지 규칙에만 의존 | 팀 결정(#51)과 맞지 않음 — 근거는 리뷰에서 보강 |
| **B. 도메인별 4개 서비스 + 공유 DB 인스턴스(스키마 분리)** | 독립 배포, 경계를 DB 권한으로 강제, DR 복제 구조 유지 | 배포 단위·CI·태그 bump 증가, DB 인스턴스는 공동 장애점 | **채택** |
| C. 도메인별 서비스 + 서비스별 DB 인스턴스 | 데이터 완전 격리 | RDS·Cloud SQL 4배, 논리 복제 경로 4개, DR 비용·RTO 증가 | 현재 트래픽에서 비용 대비 이득 없음 |
| D. 부분 분리 (point 만 분리, user/asset/cs 는 core 유지) | 가장 위험한 원장만 격리, 변경 최소 | 경계가 일관되지 않음, user/asset/cs 는 여전히 한 배포 단위 | 팀 결정은 전체 분리 — B 의 운영 비용이 과하다고 판단되면 재검토 후보 |

## 결과
- (+) 도메인별 독립 배포·롤백, 장애 격리 범위 축소 (예: point 배포 실패가 로그인에 영향 없음).
- (+) 서비스 경계를 패키지 규칙이 아니라 배포 단위·DB 권한으로 강제한다 (ADR-0001 후속 과제였던 ArchUnit 경계 강제를 대체).
- (−) 배포 단위 2개 → 5개: 이미지, CI 파이프라인, 태그 bump PR, 대시보드·알람이 늘어난다.
- (−) DR 에서 띄울 배포 단위 증가 → RTO 재측정 필요.
- (−) 공유 DB 인스턴스는 여전히 공동 장애점이다 (C 안을 택하지 않은 대가).
- (−) 로컬 개발: 띄울 프로세스가 늘어난다 → Makefile 에 일괄 실행 타깃 필요.

## 후속 과제 (각각 별도 이슈, backend PR ↔ infra PR 은 `Related:` 로 상호 링크)
1. **공통 모듈 추출** — `common` → 공유 Gradle 모듈 (전역 영향 변경이므로 단독 이슈·단독 PR)
2. **파일럿: asset-service 또는 cs-service** — 새 서비스 템플릿 확립
   - backend: Gradle 모듈, Dockerfile, CI 이미지 빌드·이중 푸시, 태그 bump 봇
   - infra: `k8s/base/<서비스>`, overlays(aws, gcp-dr), ExternalSecret(DB 계정), HTTPRoute, ArgoCD Application
   - frontend: `vite.config.ts` proxy 경로 추가 (화면 코드 변경 없음, 같은 출처 `/api/**` 유지)
3. **point-service 분리** — 원장 append-only, 멱등키, Redis Stream consumer group 이관, DR 재정산 스크립트(`scripts/dr/*`) 재검증
4. **core-service → user-service 정리** — 인증·JWKS 만 남기고 이름 변경. event-service `JWT_JWK_SET_URI` 등 참조 갱신
5. **DB 계정·권한 분리** — 서비스별 계정 생성, 스키마 권한 제한 (Terraform / 마이그레이션)
6. **DR 리허설** — 4개 서비스 기준 RTO 재측정 → 결과 기록 후 이 ADR 을 Accepted 로 변경
7. **문서·규칙 동기화** — Decision Lock "아키텍처"·"DR" 행 수정, 공통 규칙 버전 업 + `make sync-ai-rules`, `01-architecture/hybrid-msa.md`·`api-spec.md`·DR 런북 갱신
