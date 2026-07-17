# monitoring을 위한 실행 시나리오 (MariaDB 수집)
# 작성규칙
# 주석: 문장 앞 #
# 제목: '['으로 시작하고 제목
# 사용유무: 제목뒤 ',' 로 구분
# 반복주기(초): 사용유무뒤 ',' 로 구분
# query: [..] 다음줄 부터 공백줄이나 다음 '[' 만나기 전까지
#
# [MariaDB 전용 주의]
#  - collect_time 은 SELECT 의 NOW(6)(대상 MariaDB 시계) → INSERT 컬럼 목록의 첫 컬럼.
#    (Oracle 은 PG DEFAULT 였으나 MariaDB staging 은 에이전트 바인딩 = NOW(6))
#  - INSERT 컬럼 순서 = SELECT 출력 컬럼 순서 1:1 (positional 바인딩 — 순서 어긋나면 무성 오염).
#    기동 시 ResultSet 메타데이터로 컬럼수/순서 검증 권장(Agent인계문서 참조).
#  - 03 M_ACTIVE_SESSION(P_S ON) 과 04 M_PROCESSLIST(P_S OFF) 는 배타 —
#    capability(performance_schema_yn)로 한쪽만 실행, 나머지는 SKIP(collector_health 기록).
#  - 08 M_INNODB_LOCK_WAIT 는 capability(lock_wait_table_yn) 부재/권한부족 시 SKIP.
#  - 06 M_SQL_TEXT 는 UPSERT(ON CONFLICT DO NOTHING) 대상(차원 테이블).
#  - 누적(_cum) 컬럼은 raw 저장, 초당/평균/risk 는 PostgreSQL 화면 뷰에서 계산.
#  - OS(CPU/Memory)는 MariaDB SQL 수집 불가 → Host Agent(선택)가 별도 처리(본 파일 제외).
#  - 15 M_SLOW_QUERY_LOG(Recent Slow SQL, MVP 옵션)는 무상태 시간윈도우형으로 포함(UPSERT). 커서형은 v1.1.
#


#################################
## 1. M_INSTANCE_STATUS   (인스턴스 개요/커넥션/누적카운터)
#################################
[M_INSTANCE_STATUS, Y, 10]
INSERT INTO ITSTONE.M_INSTANCE_STATUS
(
	collect_time,
	server_id,
	host_name,
	port,
	version,
	version_comment,
	datadir,
	read_only_yn,
	uptime_sec,
	uptime_days,
	max_connections,
	threads_connected,
	threads_running,
	threads_cached,
	threads_created,
	connection_usage_pct,
	max_used_connections,
	max_used_conn_pct,
	connections_cum,
	aborted_connects_cum,
	aborted_clients_cum,
	questions_cum,
	queries_cum,
	slow_queries_cum,
	com_select_cum,
	com_insert_cum,
	com_update_cum,
	com_delete_cum,
	bytes_received_cum,
	bytes_sent_cum,
	created_tmp_tables_cum,
	created_tmp_disk_tables_cum,
	open_tables,
	opened_tables_cum,
	thread_cache_size,
	performance_schema_yn
)
SELECT
    NOW(6)                                                                  AS collect_time,
    g.server_id,
    g.host_name,
    g.port,
    g.version,
    g.version_comment,
    g.datadir,
    g.read_only_yn,
    g.uptime_sec,
    ROUND(g.uptime_sec / 86400, 2)                                          AS uptime_days,
    g.max_connections,
    g.threads_connected,
    g.threads_running,
    g.threads_cached,
    g.threads_created,
    ROUND(g.threads_connected   / NULLIF(g.max_connections, 0) * 100, 2)    AS connection_usage_pct,
    g.max_used_connections,
    ROUND(g.max_used_connections / NULLIF(g.max_connections, 0) * 100, 2)   AS max_used_conn_pct,
    g.connections_cum,
    g.aborted_connects_cum,
    g.aborted_clients_cum,
    g.questions_cum,
    g.queries_cum,
    g.slow_queries_cum,
    g.com_select_cum,
    g.com_insert_cum,
    g.com_update_cum,
    g.com_delete_cum,
    g.bytes_received_cum,
    g.bytes_sent_cum,
    g.created_tmp_tables_cum,
    g.created_tmp_disk_tables_cum,
    g.open_tables,
    g.opened_tables_cum,
    g.thread_cache_size,
    g.performance_schema_yn
FROM
(
    SELECT
        -- 시스템 변수 (스캔 불필요, 상수)
        CAST(@@global.server_id AS UNSIGNED)                                AS server_id,
        @@global.hostname                                                   AS host_name,
        @@global.port                                                       AS port,
        @@version                                                           AS version,
        @@version_comment                                                   AS version_comment,
        @@global.datadir                                                    AS datadir,
        CASE WHEN @@global.read_only = 1 THEN 'Y' ELSE 'N' END              AS read_only_yn,
        @@global.max_connections                                            AS max_connections,
        @@global.thread_cache_size                                          AS thread_cache_size,
        CASE WHEN @@global.performance_schema = 1 THEN 'Y' ELSE 'N' END     AS performance_schema_yn,
        -- GLOBAL_STATUS 누적 카운터 (단일 스캔 조건부 집계)
        MAX(CASE WHEN s.VARIABLE_NAME = 'Uptime'                  THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS uptime_sec,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Threads_connected'       THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS threads_connected,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Threads_running'         THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS threads_running,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Threads_cached'          THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS threads_cached,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Threads_created'         THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS threads_created,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Max_used_connections'    THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS max_used_connections,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Connections'             THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS connections_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Aborted_connects'        THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS aborted_connects_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Aborted_clients'         THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS aborted_clients_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Questions'               THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS questions_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Queries'                 THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS queries_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Slow_queries'            THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS slow_queries_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Com_select'             THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS com_select_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Com_insert'             THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS com_insert_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Com_update'             THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS com_update_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Com_delete'             THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS com_delete_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Bytes_received'          THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS bytes_received_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Bytes_sent'             THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS bytes_sent_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Created_tmp_tables'      THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS created_tmp_tables_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Created_tmp_disk_tables' THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS created_tmp_disk_tables_cum,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Open_tables'            THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS open_tables,
        MAX(CASE WHEN s.VARIABLE_NAME = 'Opened_tables'          THEN CAST(s.VARIABLE_VALUE AS UNSIGNED) END) AS opened_tables_cum
    FROM information_schema.GLOBAL_STATUS s
    WHERE s.VARIABLE_NAME IN
    (
        'Uptime','Threads_connected','Threads_running','Threads_cached','Threads_created',
        'Max_used_connections','Connections','Aborted_connects','Aborted_clients',
        'Questions','Queries','Slow_queries',
        'Com_select','Com_insert','Com_update','Com_delete',
        'Bytes_received','Bytes_sent',
        'Created_tmp_tables','Created_tmp_disk_tables',
        'Open_tables','Opened_tables'
    )
) g;

#################################
## 2. M_GLOBAL_STATUS   (워크로드 누적(QPS/TPS delta source))
#################################
[M_GLOBAL_STATUS, Y, 5]
INSERT INTO ITSTONE.M_GLOBAL_STATUS
(
	collect_time,
	variable_name,
	variable_value,
	variable_value_num,
	is_numeric_yn,
	variable_category
)
SELECT
    NOW(6)                                                                  AS collect_time,
    s.VARIABLE_NAME                                                         AS variable_name,
    s.VARIABLE_VALUE                                                        AS variable_value,
    CASE WHEN s.VARIABLE_VALUE REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
         THEN CAST(s.VARIABLE_VALUE AS DECIMAL(65,6)) END                   AS variable_value_num,
    CASE WHEN s.VARIABLE_VALUE REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
         THEN 'Y' ELSE 'N' END                                             AS is_numeric_yn,
    CASE
        WHEN s.VARIABLE_NAME IN ('Connections','Aborted_connects','Aborted_clients','Max_used_connections',
                                 'Threads_connected','Threads_running','Threads_cached','Threads_created') THEN 'CONNECTION'
        WHEN s.VARIABLE_NAME IN ('Questions','Queries','Slow_queries','Com_select','Com_insert','Com_update',
                                 'Com_delete','Com_commit','Com_rollback') THEN 'SQL'
        WHEN s.VARIABLE_NAME IN ('Bytes_received','Bytes_sent') THEN 'NETWORK'
        WHEN s.VARIABLE_NAME IN ('Open_tables','Opened_tables') THEN 'TABLE_CACHE'
        WHEN s.VARIABLE_NAME IN ('Created_tmp_tables','Created_tmp_disk_tables','Created_tmp_files') THEN 'TEMP'
        WHEN s.VARIABLE_NAME LIKE 'Handler_%' THEN 'HANDLER'
        WHEN s.VARIABLE_NAME LIKE 'Innodb_buffer_pool%' THEN 'INNODB_BUFFER'
        -- ★ 'Innodb_os_log%' 포함: Innodb_os_log_written 은 'Innodb_log%' 에 안 걸려 ETC 로 빠지던 redo 쓰기량.
        WHEN s.VARIABLE_NAME LIKE 'Innodb_data%' OR s.VARIABLE_NAME LIKE 'Innodb_log%'
          OR s.VARIABLE_NAME LIKE 'Innodb_os_log%' THEN 'INNODB_IO'
        WHEN s.VARIABLE_NAME LIKE 'Innodb_row_lock%' OR s.VARIABLE_NAME LIKE 'Innodb_rows_%' THEN 'INNODB_ROW'
        WHEN s.VARIABLE_NAME LIKE 'Slave_%' OR s.VARIABLE_NAME LIKE 'Rpl_%' THEN 'REPLICATION'
        ELSE 'ETC'
    END                                                                     AS variable_category
FROM information_schema.GLOBAL_STATUS s
WHERE s.VARIABLE_NAME IN
(
    'Connections','Aborted_connects','Aborted_clients','Max_used_connections',
    'Threads_connected','Threads_running','Threads_cached','Threads_created',
    'Questions','Queries','Slow_queries','Com_select','Com_insert','Com_update','Com_delete','Com_commit','Com_rollback',
    'Bytes_received','Bytes_sent','Created_tmp_tables','Created_tmp_disk_tables','Created_tmp_files',
    'Open_tables','Opened_tables','Handler_read_key','Handler_read_rnd_next','Handler_write','Handler_update','Handler_delete',
    'Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads','Innodb_buffer_pool_write_requests',
    'Innodb_buffer_pool_pages_total','Innodb_buffer_pool_pages_data','Innodb_buffer_pool_pages_dirty','Innodb_buffer_pool_pages_free',
    'Innodb_data_read','Innodb_data_written','Innodb_data_fsyncs','Innodb_os_log_written','Innodb_log_waits',
    'Innodb_rows_read','Innodb_rows_inserted','Innodb_rows_updated','Innodb_rows_deleted',
    'Innodb_row_lock_waits','Innodb_row_lock_time','Innodb_row_lock_current_waits'
);

#################################
## 3. M_ACTIVE_SESSION   (Enhanced 세션(P_S ON) — processlist와 배타)
#################################
[M_ACTIVE_SESSION, Y, 1]
INSERT INTO ITSTONE.M_ACTIVE_SESSION
(
        collect_time,
        thread_id,
        processlist_id,
        user_name,
        host,
        db_name,
        command,
        session_state,
        wait_event,
        wait_class,
        wait_object,
        proc_state,
        time_sec,
        stmt_elapsed_ms,
        digest,
        current_schema_name,
        sql_text_sample,
        sql_text_hash,
        lock_time_ms,
        rows_examined,
        rows_sent
)
SELECT
    NOW(6)                                                                  AS collect_time,
    t.THREAD_ID                                                             AS thread_id,
    t.PROCESSLIST_ID                                                        AS processlist_id,
    t.PROCESSLIST_USER                                                      AS user_name,
    t.PROCESSLIST_HOST                                                      AS host,
    t.PROCESSLIST_DB                                                        AS db_name,
    t.PROCESSLIST_COMMAND                                                   AS command,
    CASE
        WHEN w.EVENT_NAME IS NOT NULL
         AND w.END_EVENT_ID IS NULL
         AND w.EVENT_NAME <> 'idle'
        THEN 'WAITING'
        ELSE 'ON CPU'
    END                                                                     AS session_state,
    CASE
        WHEN w.END_EVENT_ID IS NULL AND w.EVENT_NAME <> 'idle'
        THEN w.EVENT_NAME
    END                                                                     AS wait_event,
    CASE
        WHEN w.END_EVENT_ID IS NOT NULL OR w.EVENT_NAME IS NULL OR w.EVENT_NAME = 'idle' THEN NULL
        WHEN w.EVENT_NAME LIKE 'wait/io/file/%'      THEN 'IO_FILE'
        WHEN w.EVENT_NAME LIKE 'wait/io/table/%'     THEN 'IO_TABLE'
        WHEN w.EVENT_NAME LIKE 'wait/io/%'           THEN 'IO'
        WHEN w.EVENT_NAME LIKE 'wait/lock/%'         THEN 'LOCK'
        WHEN w.EVENT_NAME LIKE 'wait/synch/mutex/%'  THEN 'MUTEX'
        WHEN w.EVENT_NAME LIKE 'wait/synch/rwlock/%' THEN 'RWLOCK'
        WHEN w.EVENT_NAME LIKE 'wait/synch/cond/%'   THEN 'COND'
        WHEN w.EVENT_NAME LIKE 'wait/synch/%'        THEN 'SYNCH'
        ELSE 'OTHER'
    END                                                                     AS wait_class,
    CASE
        WHEN w.END_EVENT_ID IS NULL AND w.EVENT_NAME <> 'idle'
             AND w.OBJECT_NAME IS NOT NULL
        THEN CONCAT_WS('.', NULLIF(w.OBJECT_SCHEMA,''), w.OBJECT_NAME)
    END                                                                     AS wait_object,
    t.PROCESSLIST_STATE                                                     AS proc_state,
    t.PROCESSLIST_TIME                                                      AS time_sec,
    ROUND(st.TIMER_WAIT / 1000000000, 3)                                    AS stmt_elapsed_ms,
    st.DIGEST                                                               AS digest,
    st.CURRENT_SCHEMA                                                       AS current_schema_name,
    st.SQL_TEXT                                                             AS sql_text_sample,
    SHA2(IFNULL(st.SQL_TEXT, ''), 256)                                      AS sql_text_hash,
    ROUND(st.LOCK_TIME / 1000000000, 3)                                     AS lock_time_ms,
    st.ROWS_EXAMINED                                                        AS rows_examined,
    st.ROWS_SENT                                                            AS rows_sent
FROM performance_schema.threads t
LEFT JOIN performance_schema.events_waits_current       w  ON w.THREAD_ID  = t.THREAD_ID
LEFT JOIN performance_schema.events_statements_current  st
       ON st.THREAD_ID = t.THREAD_ID
      AND st.EVENT_ID = (
              -- thread당 statement 여러 행(프로시저 nesting) → 가장 안쪽(실제 실행 중) 1건만.
              --   PK(collect_time, thread_id) 충돌 방지 + "지금 도는 말단 SQL" 채택(오라클 v$session.sql_id 개념).
              SELECT MAX(s2.EVENT_ID)
              FROM performance_schema.events_statements_current s2
              WHERE s2.THREAD_ID = t.THREAD_ID
          )
WHERE t.TYPE = 'FOREGROUND'
  AND t.PROCESSLIST_ID IS NOT NULL
  AND t.PROCESSLIST_ID <> CONNECTION_ID()
  AND (
        -- 활동 세션 판별 = Command 상태가 아니라 "진행 중 대기 이벤트" 기준 (오라클 ASH 방식).
        --   Command='Sleep' 이어도 wait/io·wait/lock 등을 대기 중이면 실제 활동 세션 → 포함.
        --   idle 이벤트 또는 이벤트 없음(진짜 유휴)만 제외.
        ( w.EVENT_NAME IS NOT NULL AND w.END_EVENT_ID IS NULL AND w.EVENT_NAME <> 'idle' )
        -- 위 대기 이벤트가 안 잡혀도, 실제 명령 실행 중(Sleep 아님)이면 포함 (ON CPU 순간 포착)
        OR t.PROCESSLIST_COMMAND <> 'Sleep'
      )
;
#################################
## 4. M_PROCESSLIST   (Basic 세션(P_S OFF) — active_session과 배타)
#################################
[M_PROCESSLIST, Y, 1]
INSERT INTO ITSTONE.M_PROCESSLIST
(
	collect_time,
	id,
	user_name,
	host,
	db_name,
	command,
	time_sec,
	time_ms,
	proc_state,
	info,
	info_hash,
	progress,
	examined_rows
)
SELECT
    NOW(6)                              AS collect_time,    -- 수집 시각(INSERT 1번 컬럼)
    p.ID                                AS id,              -- 커넥션 ID (PK 일부)
    p.USER                              AS user_name,       -- 접속 사용자
    p.HOST                              AS host,            -- 접속지(host:port)
    p.DB                                AS db_name,         -- 현재 DB
    p.COMMAND                           AS command,         -- Query/Connect/Binlog Dump 등
    p.TIME                              AS time_sec,        -- 현재 상태 경과(초)
    p.TIME_MS                           AS time_ms,         -- 경과 ms 정밀(MariaDB)
    p.STATE                             AS proc_state,      -- thread state 문자열(★실제 wait event 아님)
    p.INFO                              AS info,            -- 현재 실행 SQL 전문(I_S 는 비절단)
    SHA2(COALESCE(p.INFO, ''), 256)     AS info_hash,       -- 원문 그룹핑용 해시
    p.PROGRESS                          AS progress,        -- 진행률 0~100 (MariaDB; ALTER/DDL 등)
    p.EXAMINED_ROWS                     AS examined_rows    -- 현재까지 검사 행수(MariaDB)
FROM information_schema.PROCESSLIST p
WHERE p.ID <> CONNECTION_ID()           -- ★ 모니터 자기 세션 제외(자기오염 방지)
  AND p.COMMAND <> 'Sleep'              -- 활동 세션만(Sleep 제외; idle-in-trx 는 m_innodb_trx)
ORDER BY p.TIME DESC;

#################################
## 5. M_SQL_DIGEST   (SQL digest 누적(Top SQL delta source))
#################################
[M_SQL_DIGEST, Y, 60]
INSERT INTO ITSTONE.M_SQL_DIGEST
(
	collect_time,
	schema_name,
	digest,
	count_star_cum,
	sum_timer_wait_ps_cum,
	max_timer_wait_ps,
	sum_lock_time_ps_cum,
	sum_rows_examined_cum,
	sum_rows_affected_cum,
	sum_rows_sent_cum,
	sum_created_tmp_tables_cum,
	sum_created_tmp_disk_tables_cum,
	sum_select_full_join_cum,
	sum_select_scan_cum,
	sum_no_index_used_cum,
	sum_no_good_index_used_cum,
	sum_sort_merge_passes_cum,
	sum_errors_cum,
	sum_warnings_cum,
	first_seen,
	last_seen
)
SELECT
    NOW(6)                                                                  AS collect_time,
    COALESCE(NULLIF(d.SCHEMA_NAME, ''), '(global)')                        AS schema_name,
    d.DIGEST                                                                AS digest,
    d.COUNT_STAR                                                            AS count_star_cum,
    d.SUM_TIMER_WAIT                                                        AS sum_timer_wait_ps_cum,
    d.MAX_TIMER_WAIT                                                        AS max_timer_wait_ps,
    d.SUM_LOCK_TIME                                                         AS sum_lock_time_ps_cum,
    d.SUM_ROWS_EXAMINED                                                     AS sum_rows_examined_cum,
    d.SUM_ROWS_AFFECTED                                                     AS sum_rows_affected_cum,
    d.SUM_ROWS_SENT                                                         AS sum_rows_sent_cum,
    d.SUM_CREATED_TMP_TABLES                                                AS sum_created_tmp_tables_cum,
    d.SUM_CREATED_TMP_DISK_TABLES                                           AS sum_created_tmp_disk_tables_cum,
    d.SUM_SELECT_FULL_JOIN                                                  AS sum_select_full_join_cum,
    d.SUM_SELECT_SCAN                                                       AS sum_select_scan_cum,
    d.SUM_NO_INDEX_USED                                                     AS sum_no_index_used_cum,
    d.SUM_NO_GOOD_INDEX_USED                                                AS sum_no_good_index_used_cum,
    d.SUM_SORT_MERGE_PASSES                                                 AS sum_sort_merge_passes_cum,
    d.SUM_ERRORS                                                            AS sum_errors_cum,
    d.SUM_WARNINGS                                                          AS sum_warnings_cum,
    d.FIRST_SEEN                                                            AS first_seen,
    d.LAST_SEEN                                                             AS last_seen
FROM performance_schema.events_statements_summary_by_digest d
WHERE d.DIGEST IS NOT NULL
  AND d.COUNT_STAR > 0;

#################################
## 7. M_INNODB_TRX   (InnoDB 트랜잭션)
#################################
[M_INNODB_TRX, Y, 1]
INSERT INTO ITSTONE.M_INNODB_TRX
(
	collect_time,
	trx_id,
	trx_state,
	trx_started,
	trx_age_sec,
	trx_requested_lock_id,
	trx_wait_started,
	trx_wait_sec,
	trx_weight,
	trx_mysql_thread_id,
	trx_operation_state,
	trx_tables_in_use,
	trx_tables_locked,
	trx_lock_structs,
	trx_lock_memory_bytes,
	trx_rows_locked,
	trx_rows_modified,
	trx_isolation_level,
	trx_is_read_only,
	user_name,
	host,
	db_name,
	command,
	process_state,
	process_time_sec,
	sql_text_hash,
	sql_text_sample
)
SELECT
    NOW(6)                                                                  AS collect_time,
    t.TRX_ID                                                                AS trx_id,
    t.TRX_STATE                                                             AS trx_state,
    t.TRX_STARTED                                                           AS trx_started,
    TIMESTAMPDIFF(SECOND, t.TRX_STARTED, NOW())                             AS trx_age_sec,
    t.TRX_REQUESTED_LOCK_ID                                                 AS trx_requested_lock_id,
    t.TRX_WAIT_STARTED                                                      AS trx_wait_started,
    CASE WHEN t.TRX_WAIT_STARTED IS NOT NULL
         THEN TIMESTAMPDIFF(SECOND, t.TRX_WAIT_STARTED, NOW()) END          AS trx_wait_sec,
    t.TRX_WEIGHT                                                            AS trx_weight,
    t.TRX_MYSQL_THREAD_ID                                                   AS trx_mysql_thread_id,
    t.TRX_OPERATION_STATE                                                   AS trx_operation_state,
    t.TRX_TABLES_IN_USE                                                     AS trx_tables_in_use,
    t.TRX_TABLES_LOCKED                                                     AS trx_tables_locked,
    t.TRX_LOCK_STRUCTS                                                      AS trx_lock_structs,
    t.TRX_LOCK_MEMORY_BYTES                                                 AS trx_lock_memory_bytes,
    t.TRX_ROWS_LOCKED                                                       AS trx_rows_locked,
    t.TRX_ROWS_MODIFIED                                                     AS trx_rows_modified,
    t.TRX_ISOLATION_LEVEL                                                   AS trx_isolation_level,
    t.TRX_IS_READ_ONLY                                                      AS trx_is_read_only,
    p.USER                                                                  AS user_name,
    p.HOST                                                                  AS host,
    p.DB                                                                    AS db_name,
    p.COMMAND                                                               AS command,
    p.STATE                                                                 AS process_state,
    p.TIME                                                                  AS process_time_sec,
    SHA2(IFNULL(COALESCE(t.TRX_QUERY, p.INFO), ''), 256)                    AS sql_text_hash,
    COALESCE(t.TRX_QUERY, p.INFO)                                           AS sql_text_sample
FROM information_schema.INNODB_TRX t
LEFT JOIN information_schema.PROCESSLIST p
       ON p.ID = t.TRX_MYSQL_THREAD_ID
WHERE t.TRX_MYSQL_THREAD_ID <> CONNECTION_ID()
  AND t.TRX_ID <> 0;   -- PK중복 방지: 미배정(read-only) trx_id=0 다수 → (collect_time,0) 중복 제외

#################################
## 8. M_INNODB_LOCK_WAIT   (Lock 대기(capability lock_wait_table_yn))
#################################
[M_INNODB_LOCK_WAIT, Y, 1]
INSERT INTO ITSTONE.M_INNODB_LOCK_WAIT
(
	collect_time,
	wait_key_hash,
	waiting_trx_id,
	blocking_trx_id,
	requested_lock_id,
	blocking_lock_id,
	wait_started,
	wait_sec,
	waiting_thread_id,
	waiting_user,
	waiting_host,
	waiting_db,
	waiting_sql_hash,
	waiting_sql_sample,
	blocking_thread_id,
	blocking_user,
	blocking_host,
	blocking_db,
	blocking_sql_hash,
	blocking_sql_sample,
	lock_object,
	lock_type_summary
)
SELECT
    NOW(6)                                                                  AS collect_time,
    SHA2(CONCAT_WS('|', lw.REQUESTING_TRX_ID, lw.BLOCKING_TRX_ID,
                        lw.REQUESTED_LOCK_ID, lw.BLOCKING_LOCK_ID), 256)     AS wait_key_hash,
    lw.REQUESTING_TRX_ID                                                    AS waiting_trx_id,
    lw.BLOCKING_TRX_ID                                                      AS blocking_trx_id,
    lw.REQUESTED_LOCK_ID                                                    AS requested_lock_id,
    lw.BLOCKING_LOCK_ID                                                     AS blocking_lock_id,
    wt.TRX_WAIT_STARTED                                                     AS wait_started,
    CASE WHEN wt.TRX_WAIT_STARTED IS NOT NULL
         THEN TIMESTAMPDIFF(SECOND, wt.TRX_WAIT_STARTED, NOW()) END         AS wait_sec,
    wt.TRX_MYSQL_THREAD_ID                                                  AS waiting_thread_id,
    wp.USER                                                                 AS waiting_user,
    wp.HOST                                                                 AS waiting_host,
    wp.DB                                                                   AS waiting_db,
    SHA2(IFNULL(wp.INFO, ''), 256)                                          AS waiting_sql_hash,
    wp.INFO                                                                 AS waiting_sql_sample,
    bt.TRX_MYSQL_THREAD_ID                                                  AS blocking_thread_id,
    bp.USER                                                                 AS blocking_user,
    bp.HOST                                                                 AS blocking_host,
    bp.DB                                                                   AS blocking_db,
    SHA2(IFNULL(bp.INFO, ''), 256)                                          AS blocking_sql_hash,
    bp.INFO                                                                 AS blocking_sql_sample,
    CONCAT_WS('.', rl.LOCK_TABLE, rl.LOCK_INDEX)                            AS lock_object,
    CONCAT_WS('/', rl.LOCK_TYPE, rl.LOCK_MODE, bl.LOCK_TYPE, bl.LOCK_MODE)  AS lock_type_summary
FROM information_schema.INNODB_LOCK_WAITS lw
LEFT JOIN information_schema.INNODB_TRX   wt ON wt.TRX_ID  = lw.REQUESTING_TRX_ID
LEFT JOIN information_schema.INNODB_TRX   bt ON bt.TRX_ID  = lw.BLOCKING_TRX_ID
LEFT JOIN information_schema.INNODB_LOCKS rl ON rl.LOCK_ID = lw.REQUESTED_LOCK_ID
LEFT JOIN information_schema.INNODB_LOCKS bl ON bl.LOCK_ID = lw.BLOCKING_LOCK_ID
LEFT JOIN information_schema.PROCESSLIST  wp ON wp.ID      = wt.TRX_MYSQL_THREAD_ID
LEFT JOIN information_schema.PROCESSLIST  bp ON bp.ID      = bt.TRX_MYSQL_THREAD_ID;

#################################
## 9. M_INNODB_METRICS   (InnoDB 메트릭)
#################################
[M_INNODB_METRICS, Y, 10]
INSERT INTO ITSTONE.M_INNODB_METRICS
(
	collect_time,
	metric_name,
	subsystem,
	metric_category,
	metric_count,
	max_count,
	min_count,
	avg_count,
	count_reset,
	max_count_reset,
	min_count_reset,
	avg_count_reset,
	time_enabled,
	time_disabled,
	time_elapsed_sec,
	time_reset,
	metric_type,
	is_counter_yn
)
SELECT
    NOW(6)                                                                  AS collect_time,
    m.NAME                                                                  AS metric_name,
    m.SUBSYSTEM                                                             AS subsystem,
    CASE
        WHEN m.SUBSYSTEM = 'buffer'              THEN 'BUFFER'
        WHEN m.SUBSYSTEM = 'lock'                THEN 'LOCK'
        WHEN m.SUBSYSTEM = 'transaction'         THEN 'TRX'
        WHEN m.SUBSYSTEM = 'purge'               THEN 'PURGE'
        WHEN m.SUBSYSTEM IN ('file_system','os') THEN 'FILE_IO'
        WHEN m.SUBSYSTEM = 'index'               THEN 'INDEX'
        WHEN m.SUBSYSTEM = 'log'                 THEN 'LOG'
        ELSE 'ETC'
    END                                                                     AS metric_category,
    m.`COUNT`                                                               AS metric_count,
    m.MAX_COUNT                                                             AS max_count,
    m.MIN_COUNT                                                             AS min_count,
    m.AVG_COUNT                                                             AS avg_count,
    m.COUNT_RESET                                                           AS count_reset,
    m.MAX_COUNT_RESET                                                       AS max_count_reset,
    m.MIN_COUNT_RESET                                                       AS min_count_reset,
    m.AVG_COUNT_RESET                                                       AS avg_count_reset,
    m.TIME_ENABLED                                                          AS time_enabled,
    m.TIME_DISABLED                                                         AS time_disabled,
    m.TIME_ELAPSED                                                          AS time_elapsed_sec,
    m.TIME_RESET                                                            AS time_reset,
    m.TYPE                                                                  AS metric_type,
    CASE WHEN m.TYPE IN ('counter','status_counter') THEN 'Y' ELSE 'N' END  AS is_counter_yn
FROM information_schema.INNODB_METRICS m
WHERE m.SUBSYSTEM IN ('buffer','lock','transaction','purge','file_system','os','index','log');

#################################
## 10. M_INNODB_BUFFER_POOL   (Buffer Pool)
#################################
[M_INNODB_BUFFER_POOL, Y, 10]
INSERT INTO ITSTONE.M_INNODB_BUFFER_POOL
(
	collect_time,
	pool_id,
	pool_size_pages,
	free_buffers,
	database_pages,
	old_database_pages,
	modified_database_pages,
	pending_reads,
	pending_flush_lru,
	pending_flush_list,
	number_pages_read_cum,
	number_pages_created_cum,
	number_pages_written_cum,
	number_pages_get_cum,
	hit_rate_per_1000,
	pages_made_young_cum,
	pages_not_made_young_cum,
	number_pages_read_ahead_cum,
	number_read_ahead_evicted_cum,
	pages_read_rate,
	pages_written_rate,
	pages_created_rate
)
SELECT
    NOW(6)                              AS collect_time,
    b.POOL_ID                           AS pool_id,
    b.POOL_SIZE                         AS pool_size_pages,
    b.FREE_BUFFERS                      AS free_buffers,
    b.DATABASE_PAGES                    AS database_pages,
    b.OLD_DATABASE_PAGES                AS old_database_pages,
    b.MODIFIED_DATABASE_PAGES           AS modified_database_pages,
    b.PENDING_READS                     AS pending_reads,
    b.PENDING_FLUSH_LRU                 AS pending_flush_lru,
    b.PENDING_FLUSH_LIST                AS pending_flush_list,
    b.NUMBER_PAGES_READ                 AS number_pages_read_cum,
    b.NUMBER_PAGES_CREATED              AS number_pages_created_cum,
    b.NUMBER_PAGES_WRITTEN              AS number_pages_written_cum,
    b.NUMBER_PAGES_GET                  AS number_pages_get_cum,
    b.HIT_RATE                          AS hit_rate_per_1000,
    b.PAGES_MADE_YOUNG                  AS pages_made_young_cum,
    b.PAGES_NOT_MADE_YOUNG              AS pages_not_made_young_cum,
    b.NUMBER_PAGES_READ_AHEAD           AS number_pages_read_ahead_cum,
    b.NUMBER_READ_AHEAD_EVICTED         AS number_read_ahead_evicted_cum,
    b.PAGES_READ_RATE                   AS pages_read_rate,
    b.PAGES_WRITTEN_RATE                AS pages_written_rate,
    b.PAGES_CREATE_RATE                 AS pages_created_rate
FROM information_schema.INNODB_BUFFER_POOL_STATS b;

#################################
## 11. M_INDEX_IO_STAT   (인덱스 I/O(풀스캔 탐지))
#################################
[M_INDEX_IO_STAT, Y, 60]
INSERT INTO ITSTONE.M_INDEX_IO_STAT
(
	collect_time,
	object_schema,
	table_name,
	index_name,
	count_star_cum,
	sum_timer_wait_ps_cum,
	count_read_cum,
	sum_timer_read_ps_cum,
	count_write_cum,
	sum_timer_write_ps_cum,
	count_fetch_cum,
	count_insert_cum,
	count_update_cum,
	count_delete_cum
)
SELECT
    NOW(6)                                  AS collect_time,
    t.OBJECT_SCHEMA                         AS object_schema,
    t.OBJECT_NAME                           AS table_name,
    t.INDEX_NAME                            AS index_name,
    t.COUNT_STAR                            AS count_star_cum,
    t.SUM_TIMER_WAIT                        AS sum_timer_wait_ps_cum,
    t.COUNT_READ                            AS count_read_cum,
    t.SUM_TIMER_READ                        AS sum_timer_read_ps_cum,
    t.COUNT_WRITE                           AS count_write_cum,
    t.SUM_TIMER_WRITE                       AS sum_timer_write_ps_cum,
    t.COUNT_FETCH                           AS count_fetch_cum,
    t.COUNT_INSERT                          AS count_insert_cum,
    t.COUNT_UPDATE                          AS count_update_cum,
    t.COUNT_DELETE                          AS count_delete_cum
FROM performance_schema.table_io_waits_summary_by_index_usage t
WHERE t.OBJECT_SCHEMA NOT IN ('mysql','performance_schema','information_schema','sys')
  AND t.COUNT_STAR > 0;

#################################
## 12. M_TABLE_LOCK_STAT   (테이블 Lock 누적)
#################################
[M_TABLE_LOCK_STAT, Y, 60]
INSERT INTO ITSTONE.M_TABLE_LOCK_STAT
(
	collect_time,
	object_schema,
	table_name,
	count_star_cum,
	sum_timer_wait_ps_cum,
	count_read_cum,
	sum_timer_read_ps_cum,
	count_write_cum,
	sum_timer_write_ps_cum
)
SELECT
    NOW(6)                              AS collect_time,
    t.OBJECT_SCHEMA                     AS object_schema,
    t.OBJECT_NAME                       AS table_name,
    t.COUNT_STAR                        AS count_star_cum,
    t.SUM_TIMER_WAIT                    AS sum_timer_wait_ps_cum,
    t.COUNT_READ                        AS count_read_cum,
    t.SUM_TIMER_READ                    AS sum_timer_read_ps_cum,
    t.COUNT_WRITE                       AS count_write_cum,
    t.SUM_TIMER_WRITE                   AS sum_timer_write_ps_cum
FROM performance_schema.table_lock_waits_summary_by_table t
WHERE t.OBJECT_SCHEMA NOT IN ('mysql','performance_schema','information_schema','sys')
  AND t.COUNT_STAR > 0;

#################################
## 13. M_FILE_IO_STAT   (파일 I/O 유형별)
#################################
[M_FILE_IO_STAT, Y, 60]
INSERT INTO ITSTONE.M_FILE_IO_STAT
(
	collect_time,
	event_name,
	file_category,
	count_star_cum,
	count_read_cum,
	sum_timer_read_ps_cum,
	sum_bytes_read_cum,
	count_write_cum,
	sum_timer_write_ps_cum,
	sum_timer_wait_ps_cum,
	sum_bytes_write_cum,
	count_misc_cum,
	sum_timer_misc_ps_cum
)
SELECT
    NOW(6)                              AS collect_time,
    f.EVENT_NAME                        AS event_name,
    CASE
        WHEN f.EVENT_NAME LIKE 'wait/io/file/innodb/innodb_data_file%' THEN 'DATA'
        WHEN f.EVENT_NAME LIKE 'wait/io/file/innodb/innodb_log_file%'  THEN 'LOG'
        WHEN f.EVENT_NAME LIKE 'wait/io/file/innodb/innodb_temp%'      THEN 'TEMP'
        WHEN f.EVENT_NAME LIKE 'wait/io/file/sql/binlog%'             THEN 'BINLOG'
        WHEN f.EVENT_NAME LIKE 'wait/io/file/sql/relaylog%'          THEN 'RELAYLOG'
        WHEN f.EVENT_NAME LIKE '%temp%' OR f.EVENT_NAME LIKE '%tmp%'   THEN 'TEMP'
        ELSE 'OTHER'
    END                                 AS file_category,
    f.COUNT_STAR                        AS count_star_cum,
    f.COUNT_READ                        AS count_read_cum,
    f.SUM_TIMER_READ                    AS sum_timer_read_ps_cum,
    f.SUM_NUMBER_OF_BYTES_READ          AS sum_bytes_read_cum,
    f.COUNT_WRITE                       AS count_write_cum,
    f.SUM_TIMER_WRITE                   AS sum_timer_write_ps_cum,
    f.SUM_TIMER_WAIT                    AS sum_timer_wait_ps_cum,
    f.SUM_NUMBER_OF_BYTES_WRITE         AS sum_bytes_write_cum,
    f.COUNT_MISC                        AS count_misc_cum,
    f.SUM_TIMER_MISC                    AS sum_timer_misc_ps_cum
FROM performance_schema.file_summary_by_event_name f
WHERE f.EVENT_NAME LIKE 'wait/io/file/%'
  AND f.COUNT_STAR > 0;

#################################
## 14. M_VARIABLE_SNAPSHOT   (글로벌 설정 스냅샷/변경감지)
#################################
[M_VARIABLE_SNAPSHOT, Y, 3600]
INSERT INTO ITSTONE.M_VARIABLE_SNAPSHOT
(
	collect_time,
	variable_name,
	variable_value,
	is_numeric_yn
)
SELECT
    NOW(6)                                                                  AS collect_time,
    v.VARIABLE_NAME                                                         AS variable_name,
    v.VARIABLE_VALUE                                                        AS variable_value,
    CASE WHEN v.VARIABLE_VALUE REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
         THEN 'Y' ELSE 'N' END                                             AS is_numeric_yn
FROM information_schema.GLOBAL_VARIABLES v;

#################################
## M_TARGET_CAPABILITY   (대상 DB 기능/설정 능력 — slow log·P_S·권한)
##   주기 60초(설정 변화 감지용). collect_time=NOW(6). 20컬럼 positional 1:1.
##   slow_log_* 가 여기서 채워져야 v_m_slow_sql_status 가 OK 로 판정.
#################################
[M_TARGET_CAPABILITY, Y, 60]
INSERT INTO ITSTONE.M_TARGET_CAPABILITY
(
        collect_time,
        performance_schema_yn,
        ps_statements_digest_yn,
        ps_statements_current_yn,
        ps_waits_yn,
        ps_io_yn,
        digest_capable_yn,
        lock_wait_table_yn,
        innodb_trx_table_yn,
        metadata_lock_yn,
        priv_process_yn,
        priv_select_ps_yn,
        collection_mode,
        os_agent_yn,
        slow_log_enabled_yn,
        slow_log_output,
        slow_log_table_yn,
        slow_log_query_time,
        server_version,
        notes
)
SELECT
    NOW(6)                                                                  AS collect_time,
    IF(@@performance_schema=1,'Y','N')                                      AS performance_schema_yn,
    (SELECT IF(SUM(ENABLED='YES')>0,'Y','N') FROM performance_schema.setup_consumers WHERE NAME='statements_digest')            AS ps_statements_digest_yn,
    (SELECT IF(SUM(ENABLED='YES')>0,'Y','N') FROM performance_schema.setup_consumers WHERE NAME='events_statements_current')    AS ps_statements_current_yn,
    (SELECT IF(SUM(ENABLED='YES')>0,'Y','N') FROM performance_schema.setup_consumers WHERE NAME='events_waits_current')         AS ps_waits_yn,
    (SELECT IF(SUM(ENABLED='YES')>0,'Y','N') FROM performance_schema.setup_consumers WHERE NAME='events_stages_current')        AS ps_io_yn,
    IF(@@performance_schema=1 AND (SELECT SUM(ENABLED='YES') FROM performance_schema.setup_consumers WHERE NAME IN ('statements_digest','events_statements_current'))=2,'Y','N') AS digest_capable_yn,
    'Y'                                                                     AS lock_wait_table_yn,
    'Y'                                                                     AS innodb_trx_table_yn,
    'Y'                                                                     AS metadata_lock_yn,
    'Y'                                                                     AS priv_process_yn,
    IF(@@performance_schema=1,'Y','N')                                      AS priv_select_ps_yn,
    IF(@@performance_schema=1,'ENHANCED','BASIC')                           AS collection_mode,
    'N'                                                                     AS os_agent_yn,
    IF(@@slow_query_log=1,'Y','N')                                          AS slow_log_enabled_yn,
    @@log_output                                                            AS slow_log_output,
    IF(@@log_output LIKE '%TABLE%','Y','N')                                 AS slow_log_table_yn,
    @@long_query_time                                                       AS slow_log_query_time,
    VERSION()                                                               AS server_version,
    NULL                                                                    AS notes