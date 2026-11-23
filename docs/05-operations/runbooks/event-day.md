# Runbook: 이벤트 당일 운영

## D-1
- [ ] 이벤트 메타데이터 등록 (시작 시각, 당첨 수량) → Redis 초기화 Job 예약
  - ⚠️ 운영(aws) 프로필에는 아직 이벤트 생성 API·Job 이 없다. `POST /api/events/{id}/open` 은 `local` 프로필 전용 ([api-spec](../../03-development/api-spec.md#event-service))
- [ ] KEDA ScaledObject Cron 시간 확인 (시작 5분 전 ~ 종료 30분 후)
- [ ] ArgoCD Sync Window: 이벤트 시간대 배포 차단 확인
- [ ] Spot 용량 리스크 대비: NodePool에 On-Demand fallback 허용 확인
- [ ] 서브넷 가용 IP 확인 (피크 노드 수 × 노드당 파드)
- [ ] WAF Rate Limit 임계값 검토

## T-10분
- [ ] Grafana Business / Scaling 대시보드 열기
- [ ] DLQ = 0, consumer lag ≈ 0 확인

## T-5분 (자동)
- [ ] KEDA가 event-service 목표 레플리카로 확장했는지 확인
- [ ] Karpenter 노드 Ready, Pending 파드 0

## T+0 ~ 종료
| 관찰 지표 | 정상 | 조치 |
|---|---|---|
| event p95 | < 500ms | 초과 시 HPA 상한/노드 확인 |
| 5xx | < 0.1% | 급증 시 incident-response |
| Kafka consumer lag | 감소 추세 | 증가만 하면 point consumer 확장 |
| Redis CPU | < 70% | 초과 시 읽기 경로 점검 |

## 종료 후
- [ ] **퀴즈 일괄 정산** (ADR-0017): consumer lag = 0 확인 → 당첨자 수 확인 (`SCARD event:{id}:winners`) →
      `POST /api/admin/events/{id}/settlement {"expectedCount": n}`
  - 409 `SETTLEMENT_NOT_READY` 면 lag 해소 후 재시도 (원장은 바뀌지 않음)
  - 200 확인 후 `GET .../settlement` 의 `state = COMPLETE`, `unappliedCount = 0` 확인
- [ ] 대사 배치 실행 (출석 보상: Redis 비트맵 ↔ ledger) — *배치 미구현* ([domain-model §4](../../03-development/domain-model.md))
- [ ] DLQ 처리
- [ ] 스케일 인/노드 회수 확인
- [ ] 이벤트 비용·지표 기록 → finops.md
