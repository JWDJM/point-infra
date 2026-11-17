-- RDS (PostgreSQL) 에서 1회 실행: CDC 계정 및 복제 대상 테이블 지정
CREATE ROLE debezium WITH LOGIN PASSWORD :'debezium_password';
GRANT rds_replication TO debezium;
GRANT USAGE ON SCHEMA users, asset, point TO debezium;
GRANT SELECT ON users.app_user, users.user_credential, asset.linked_account,
                point.point_wallet, point.point_ledger, point.refund_request,
                point.reward_pending, point.event_settlement,
                public.dr_heartbeat TO debezium;
GRANT UPDATE ON public.dr_heartbeat TO debezium;   -- heartbeat.action.query

CREATE PUBLICATION dr_publication FOR TABLE
  users.app_user, users.user_credential, asset.linked_account,
  point.point_wallet, point.point_ledger, point.refund_request,
  point.reward_pending, point.event_settlement,   -- 퀴즈 일괄 정산 (ADR-0017): DR 판정·재정산 근거
  public.dr_heartbeat;

-- 이미 Publication 이 있는 환경에 정산 테이블 추가 (monolith Flyway V202611170200 적용 후, Cloud SQL 에도 같은 DDL 선적용):
--   GRANT SELECT ON point.reward_pending, point.event_settlement TO debezium;
--   ALTER PUBLICATION dr_publication ADD TABLE point.reward_pending, point.event_settlement;
--   (Debezium 은 새 테이블의 기존 행을 스냅샷하지 않는다 → 추가 전 행이 있으면 incremental snapshot signal 로 보충)
