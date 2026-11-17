# External Secrets Operator

| 환경 | SecretStore | 소스 |
|---|---|---|
| aws | `ClusterSecretStore/aws-sm` | AWS Secrets Manager (Pod Identity) |
| gcp-dr | `ClusterSecretStore/gcp-sm` | GCP Secret Manager (Workload Identity) |

동일한 `ExternalSecret` 이름(`monolith-db`)을 양쪽에서 생성 → 앱 매니페스트는 환경과 무관.
TODO: ClusterSecretStore, ExternalSecret 매니페스트 작성

`monolith-db` Secret 에 담을 키 (양쪽 클라우드에 **같은 값**):

| 키 | 용도 |
|---|---|
| `DB_URL`, `DB_USERNAME`, `DB_PASSWORD` | DB 접속 |
| `JWT_PRIVATE_KEY` | access token 서명 — 같은 키여야 Failover 후에도 기존 토큰이 유효 |
| `ADMIN_API_TOKEN` | `/api/admin/**` 퀴즈 일괄 정산 (ADR-0017). DR 쪽에도 있어야 Failback 전 수동 정산이 가능 |
