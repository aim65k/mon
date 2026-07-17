# ============================================================================
# maria_collect_merge_01_02.sql  (MariaDB UPSERT 전용 — MERGE 파서)
#   에이전트가 MERGE INTO ... 를 PostgreSQL INSERT ... ON CONFLICT 로 변환.
#   - WHEN MATCHED THEN UPDATE 있으면  → ON CONFLICT (key) DO UPDATE
#   - WHEN MATCHED 없이 NOT MATCHED 만 → ON CONFLICT (key) DO NOTHING
#   대상 별칭 t, 소스 별칭 s. USING 안의 SELECT 는 MariaDB 에서 실행.
#   INSERT 전용 잡은 maria_collect_insert_01_13.sql 참조.
# ============================================================================

# ----------------------------------------------------------------------------
# 01. M_SQL_TEXT  (SQL Digest 차원 테이블)
#   PK(schema_name,digest) 에 collect_time 없음 → 매 주기 동일 digest 재유입.
#   → ON CONFLICT (schema_name,digest) DO UPDATE (last_seen/텍스트 갱신).
#   P_S OFF(Basic) 이면 소스 0행 → no-op.
# ----------------------------------------------------------------------------
[M_SQL_TEXT, Y, 60]
MERGE INTO itstone.m_sql_text t
USING
(
    SELECT
        COALESCE(NULLIF(d.SCHEMA_NAME, ''), '(global)')                        AS schema_name,
        d.DIGEST                                                                AS digest,
        d.DIGEST_TEXT                                                           AS digest_text,
        SHA2(IFNULL(d.DIGEST_TEXT, ''), 256)                                    AS digest_text_hash,
        CASE
            WHEN UPPER(TRIM(d.DIGEST_TEXT)) LIKE 'SELECT%'  THEN 'SELECT'
            WHEN UPPER(TRIM(d.DIGEST_TEXT)) LIKE 'INSERT%'  THEN 'INSERT'
            WHEN UPPER(TRIM(d.DIGEST_TEXT)) LIKE 'UPDATE%'  THEN 'UPDATE'
            WHEN UPPER(TRIM(d.DIGEST_TEXT)) LIKE 'DELETE%'  THEN 'DELETE'
            WHEN UPPER(TRIM(d.DIGEST_TEXT)) LIKE 'CALL%'    THEN 'CALL'
            WHEN UPPER(TRIM(d.DIGEST_TEXT)) LIKE 'REPLACE%' THEN 'REPLACE'
            ELSE 'ETC'
        END                                                                     AS sql_type,
        d.FIRST_SEEN                                                            AS first_seen,
        d.LAST_SEEN                                                             AS last_seen
    FROM performance_schema.events_statements_summary_by_digest d
    WHERE d.DIGEST IS NOT NULL
) s
ON
(
        t.schema_name = s.schema_name
    AND t.digest      = s.digest
)
WHEN MATCHED THEN UPDATE SET
    digest_text      = s.digest_text,
    digest_text_hash = s.digest_text_hash,
    sql_type         = s.sql_type,
    last_seen        = s.last_seen
WHEN NOT MATCHED THEN INSERT
(
    schema_name,
    digest,
    digest_text,
    digest_text_hash,
    sql_type,
    first_seen,
    last_seen
)
VALUES
(
    s.schema_name,
    s.digest,
    s.digest_text,
    s.digest_text_hash,
    s.sql_type,
    s.first_seen,
    s.last_seen
)
;

# ----------------------------------------------------------------------------
# 02. M_SLOW_QUERY_LOG  (Recent Slow SQL)
#   최근 90초 윈도우를 60초 주기로 재조회 → 최소 30초 의도적 중복.
#   → ON CONFLICT (start_time,sql_hash) DO NOTHING (WHEN MATCHED 없음).
# ----------------------------------------------------------------------------
[M_SLOW_QUERY_LOG, Y, 60]
MERGE INTO itstone.m_slow_query_log t
USING
(
    SELECT
        sq.start_time                                                         AS start_time,
        sq.user_host                                                          AS user_host,
        TIME_TO_SEC(sq.query_time) * 1000 + MICROSECOND(sq.query_time) / 1000 AS query_time_ms,
        TIME_TO_SEC(sq.lock_time)  * 1000 + MICROSECOND(sq.lock_time)  / 1000 AS lock_time_ms,
        sq.rows_sent                                                          AS rows_sent,
        sq.rows_examined                                                      AS rows_examined,
        sq.db                                                                 AS db_name,
        sq.sql_text                                                           AS sql_text,
        SHA2(sq.sql_text, 256)                                                AS sql_hash
    FROM mysql.slow_log sq
    WHERE sq.start_time > (NOW(6) - INTERVAL 90 SECOND)
    ORDER BY sq.start_time
    LIMIT 1000
) s
ON
(
        t.start_time = s.start_time
    AND t.sql_hash   = s.sql_hash
)
WHEN NOT MATCHED THEN INSERT
(
    start_time,
    user_host,
    query_time_ms,
    lock_time_ms,
    rows_sent,
    rows_examined,
    db_name,
    sql_text,
    sql_hash
)
VALUES
(
    s.start_time,
    s.user_host,
    s.query_time_ms,
    s.lock_time_ms,
    s.rows_sent,
    s.rows_examined,
    s.db_name,
    s.sql_text,
    s.sql_hash
)
;
