-- RDS (PostgreSQL) 에서 1회 실행: CDC 계정 및 복제 대상 테이블 지정
CREATE ROLE debezium WITH LOGIN PASSWORD :'debezium_password';
GRANT rds_replication TO debezium;
GRANT USAGE ON SCHEMA users, asset, point TO debezium;
GRANT SELECT ON users.app_user, users.user_credential, asset.linked_account,
                point.point_wallet, point.point_ledger, point.refund_request,
                public.dr_heartbeat TO debezium;
GRANT UPDATE ON public.dr_heartbeat TO debezium;   -- heartbeat.action.query

CREATE PUBLICATION dr_publication FOR TABLE
  users.app_user, users.user_credential, asset.linked_account,
  point.point_wallet, point.point_ledger, point.refund_request,
  public.dr_heartbeat;

-- ADR-0018: 일괄 정산 테이블(reward_pending, event_settlement)은 미사용 → Publication 에서 뺐다.
--   이미 추가한 환경: ALTER PUBLICATION dr_publication DROP TABLE point.reward_pending, point.event_settlement;
