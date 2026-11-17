-- Failover 시 퀴즈 이벤트 정산 판정 + 누락분 재정산 (ADR-0017)
-- 실행 순서: fix-sequences.sql → reconcile-wallet.sql → 이 파일 (앱 트래픽 유입 전 1회, 재실행 안전)
--   · fix-sequences 가 먼저여야 한다: 원장 INSERT 가 IDENTITY 시퀀스를 쓰는데 시퀀스 값은 CDC 로 복제되지 않는다
--   · reconcile-wallet 가 먼저여야 한다: 지갑을 원장 기준으로 맞춘 뒤 그 잔액 위에 누락분을 더한다
--
-- 판정 (monolith GET /api/admin/events/{id}/settlement 의 state 와 같은 기준)
--   NOT_SETTLED : 정산 전 재해 → 원장에 이 이벤트 지급 0건 (전원 미지급). 여기서는 정산하지 않는다
--                 (대기 건이 Kafka lag 만큼 모자랄 수 있어 당첨자 전원이라는 보장이 없음 → Failback 후 정산)
--   COMPLETE    : 원장 건수 = 정산 건수
--   INCOMPLETE  : 정산은 끝났는데 원장 일부가 복제되지 않음 → 대기 건으로 누락분 지급
--                 대기 건까지 모자라면(shortfall > 0) 남은 건은 Failback 시 RDS 기준으로 완성된다
\set ON_ERROR_STOP on

\echo '== 퀴즈 이벤트 정산 판정 (재정산 전) =='
WITH ledger AS (
  SELECT reference_id AS event_id, count(*) AS cnt
  FROM point.point_ledger WHERE source = 'EVENT' AND type = 'EARN'
  GROUP BY reference_id
), pending AS (
  SELECT event_id, count(*) AS cnt FROM point.reward_pending GROUP BY event_id
)
SELECT e.event_id,
       CASE WHEN s.event_id IS NULL THEN 'NOT_SETTLED'
            WHEN COALESCE(l.cnt, 0) >= s.row_count THEN 'COMPLETE'
            ELSE 'INCOMPLETE' END AS state,
       s.row_count            AS settled_rows,
       COALESCE(l.cnt, 0)     AS ledger_rows,
       COALESCE(p.cnt, 0)     AS pending_rows
FROM (SELECT event_id FROM point.event_settlement UNION SELECT event_id FROM pending) e
LEFT JOIN point.event_settlement s ON s.event_id = e.event_id
LEFT JOIN ledger l ON l.event_id = e.event_id
LEFT JOIN pending p ON p.event_id = e.event_id
ORDER BY state, e.event_id;

-- 정산된 이벤트의 누락분만 지급. 이벤트 하나씩 처리한다:
-- 이벤트당 사용자 1건(uq_reward_pending_event_user)이므로 balance_after = 지갑 잔액 + 금액 이 정확하다.
-- 여러 이벤트를 한 문장으로 처리하면 같은 사용자의 두 행이 같은 잔액을 기준으로 balance_after 를 계산해
-- 이후 reconcile-wallet 기준(마지막 balance_after)이 틀어진다.
BEGIN;
DO $$
DECLARE
  ev        text;
  n_applied bigint;
  total     bigint := 0;
BEGIN
  FOR ev IN
    SELECT s.event_id FROM point.event_settlement s
    WHERE EXISTS (
      SELECT 1 FROM point.reward_pending p
      WHERE p.event_id = s.event_id
        AND NOT EXISTS (SELECT 1 FROM point.point_ledger l WHERE l.idempotency_key = p.idempotency_key))
    ORDER BY s.event_id
  LOOP
    INSERT INTO point.point_wallet (user_id, balance)
    SELECT DISTINCT user_id, 0 FROM point.reward_pending WHERE event_id = ev
    ON CONFLICT (user_id) DO NOTHING;

    PERFORM 1 FROM point.point_wallet w
    WHERE w.user_id IN (SELECT user_id FROM point.reward_pending WHERE event_id = ev)
    ORDER BY w.user_id FOR UPDATE;

    WITH ins AS (
      INSERT INTO point.point_ledger
        (user_id, type, amount, balance_after, idempotency_key, source, reference_id)
      SELECT p.user_id, 'EARN', p.amount, w.balance + p.amount, p.idempotency_key, 'EVENT', p.event_id
      FROM point.reward_pending p
      JOIN point.point_wallet w ON w.user_id = p.user_id
      WHERE p.event_id = ev
        AND NOT EXISTS (SELECT 1 FROM point.point_ledger l WHERE l.idempotency_key = p.idempotency_key)
      ON CONFLICT (idempotency_key) DO NOTHING
      RETURNING user_id, amount
    ), upd AS (
      UPDATE point.point_wallet w
      SET balance = w.balance + ins.amount, version = w.version + 1, updated_at = now()
      FROM ins WHERE w.user_id = ins.user_id
      RETURNING w.user_id
    )
    SELECT count(*) INTO n_applied FROM upd;

    RAISE NOTICE 'repaired event=% applied=%', ev, n_applied;
    total := total + n_applied;
  END LOOP;
  RAISE NOTICE 'repaired total=%', total;
END $$;
COMMIT;

\echo '== 재정산 후: 아직 모자란 정산 이벤트 (Failback 시 RDS 기준으로 완성) =='
SELECT s.event_id, s.row_count AS settled_rows,
       (SELECT count(*) FROM point.point_ledger l
        WHERE l.source = 'EVENT' AND l.type = 'EARN' AND l.reference_id = s.event_id) AS ledger_rows,
       s.row_count - (SELECT count(*) FROM point.point_ledger l
        WHERE l.source = 'EVENT' AND l.type = 'EARN' AND l.reference_id = s.event_id) AS shortfall
FROM point.event_settlement s
WHERE s.row_count > (SELECT count(*) FROM point.point_ledger l
                     WHERE l.source = 'EVENT' AND l.type = 'EARN' AND l.reference_id = s.event_id)
ORDER BY s.event_id;
