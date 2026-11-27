-- 서비스별 DB 계정 (ADR-0024, #57) — point DB 에서 관리 계정(RDS 마스터 / Cloud SQL 관리 계정)으로 실행
--
-- usage (RDS, 평시 사용):
--   psql -d point -v login=LOGIN \
--        -v point_migrator_password="$(Secrets Manager 에서 조회)" \
--        -v user_service_password="..." -v point_command_password="..." -v point_query_password="..." \
--        -f scripts/db/app-roles.sql
-- usage (Cloud SQL, 평시 standby): 같은 명령에 -v login=NOLOGIN — 승격 때 promote-cloudsql.sh 가 LOGIN 으로 바꾼다
--   비밀번호는 양쪽 같은 값 (Failover 후 같은 Secret 으로 접속). 파일·커밋·로그에 쓰지 않는다
--
-- 여러 번 실행해도 된다 (없으면 만들고, 있으면 비밀번호·LOGIN 만 다시 설정).
-- 논리 복제는 계정(role)과 GRANT 를 복제하지 않는다 → RDS·Cloud SQL 양쪽에서 각각 실행한다 (ADR-0020).
--
-- 여기서는 계정과 DB 수준 권한만 만든다. 스키마·테이블 권한은 스키마가 생긴 뒤에만 걸 수 있으므로
-- db-migration 의 Flyway afterMigrate.sql 이 마이그레이션마다 다시 건다 (point-backend#26).
--
-- | 계정 | 쓰는 곳 | 권한 |
-- |---|---|---|
-- | point_migrator | db-migration Job | DB CREATE(스키마 생성) + public 스키마 CREATE(Flyway 이력 테이블). 스키마·테이블 소유자 |
-- | user_service   | user-service    | users 스키마 DML (afterMigrate) |
-- | point_command  | point-command   | point 스키마 SELECT·INSERT·UPDATE, point_ledger 는 SELECT·INSERT 만 (afterMigrate) |
-- | point_query    | point-query     | point 스키마 SELECT 만 (afterMigrate) |
-- 서비스 계정에는 DDL 권한(CREATE)을 주지 않는다.
--
-- 관리 계정이 CREATE ROLE·GRANT 를 할 수 있는 범위(rds_superuser / cloudsqlsuperuser)와 제약: 공식 문서 확인 필요

\set ON_ERROR_STOP on

-- 1. 계정 (없으면 생성)
SELECT format('CREATE ROLE %I', r)
FROM unnest(ARRAY['point_migrator', 'user_service', 'point_command', 'point_query']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)
\gexec

-- 2. 비밀번호·LOGIN (매번 다시 설정 — 비밀번호 교체도 이 스크립트로 한다)
ALTER ROLE point_migrator WITH :login PASSWORD :'point_migrator_password';
ALTER ROLE user_service   WITH :login PASSWORD :'user_service_password';
ALTER ROLE point_command  WITH :login PASSWORD :'point_command_password';
ALTER ROLE point_query    WITH :login PASSWORD :'point_query_password';

-- 3. DB 수준 권한
GRANT CONNECT ON DATABASE point TO point_migrator, user_service, point_command, point_query;
GRANT CREATE ON DATABASE point TO point_migrator;              -- Flyway 가 users·point·asset·cs 스키마를 만든다
GRANT USAGE, CREATE ON SCHEMA public TO point_migrator;        -- public.flyway_schema_history (PostgreSQL 15+ 는 public CREATE 가 기본으로 없다)

-- 4. 기존 환경 이행: app_rw 가 만든 스키마·테이블을 point_migrator 가 바꿀 수 있게 (소유 계정의 멤버면 ALTER 가능)
--    app_rw 는 core-service 가 user-service 로 바뀔 때(#60) 제거하고, 그때 REASSIGN OWNED BY app_rw TO point_migrator
SELECT 'GRANT app_rw TO point_migrator'
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')
\gexec
