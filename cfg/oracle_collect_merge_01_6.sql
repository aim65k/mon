#########################################################
## s_alert_log  
#########################################################
[s_alert_log, Y, 60]
MERGE INTO itstone.s_alert_log t
USING
(
    SELECT
        ## [2026-07-19] 메시지 해시 계산은 실제 CON_ID를 유지하고 최종 적재값만 0으로 통일한다.
        0 AS CON_ID,
        TO_CHAR(SRC.ORIGINATING_TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF3') AS ORIGINATING_TIMESTAMP,
        SRC.MESSAGE_TEXT,                                                                 
        TO_NUMBER(REGEXP_SUBSTR(SRC.ORA_ERROR_CODE, '[0-9]+'))      AS ORA_ERROR_CODE,   
        SRC.ALERT_LEVEL,                                                                 
        SRC.MESSAGE_TYPE,                                                                
        SRC.MESSAGE_LEVEL,                                                               
        SRC.MODULE_ID,                                                                   
        SRC.MESSAGE_HASH                                                                 
    FROM
    (
        SELECT
            EXT.CON_ID,
            EXT.ORIGINATING_TIMESTAMP,
            EXT.MESSAGE_TEXT,
            EXT.MESSAGE_TYPE,
            EXT.MESSAGE_LEVEL,
            EXT.MODULE_ID,
            EXT.ORA_ERROR_CODE,
            CASE
                WHEN LPAD(REGEXP_SUBSTR(EXT.ORA_ERROR_CODE, '[0-9]+'), 5, '0')
                     IN ('00600', '07445', '04031', '04030', '00447',
                         '00704', '00313', '00312', '01157', '01110', '01114',
                         '01092', '03113', '03135')                     THEN 'CRITICAL'
                WHEN LPAD(REGEXP_SUBSTR(EXT.ORA_ERROR_CODE, '[0-9]+'), 5, '0')
                     IN ('01555', '01652', '01653', '01654', '00020',
                         '00018', '00060', '02049', '00239')            THEN 'WARNING'
                WHEN EXT.MESSAGE_LEVEL = 1                              THEN 'CRITICAL'
                WHEN EXT.MESSAGE_LEVEL = 2                              THEN 'WARNING'
                ELSE 'INFO'
            END                                                         AS ALERT_LEVEL,
            RAWTOHEX(STANDARD_HASH(
                NVL(TO_CHAR(EXT.CON_ID), '0')                              || '|' ||
                TO_CHAR(EXT.ORIGINATING_TIMESTAMP, 'YYYYMMDDHH24MISSFF3')  || '|' ||
                EXT.MESSAGE_TEXT,
                'SHA1'
            ))                                                           AS MESSAGE_HASH
        FROM
        (
            SELECT
                NVL(A.CON_ID, 0) AS CON_ID,
                A.ORIGINATING_TIMESTAMP,
                A.MESSAGE_TEXT,
                A.MESSAGE_TYPE,
                A.MESSAGE_LEVEL,
                A.MODULE_ID,
                REGEXP_SUBSTR(A.MESSAGE_TEXT, 'ORA-[0-9]+')                 AS ORA_ERROR_CODE
            FROM V$DIAG_ALERT_EXT A
            WHERE A.COMPONENT_ID          = 'rdbms'
              ## Agent 중단 후 누락 복구를 위해 최근 24시간을 재조회하며 ON 키로 중복 제거한다.
              AND A.ORIGINATING_TIMESTAMP > SYSTIMESTAMP - INTERVAL '1' DAY
              AND (
                    A.MESSAGE_TEXT  LIKE '%ORA-%'
                 OR A.MESSAGE_LEVEL IN (1, 2)
                  )
        ) EXT
    ) SRC

) s
ON
(
        t.con_id                = s.con_id
    AND t.originating_timestamp = s.originating_timestamp
    AND t.message_hash          = s.message_hash
)
## WHEN MATCHED 절 없음 = 매칭 시 무동작(DO NOTHING).
WHEN NOT MATCHED THEN INSERT
    (con_id, originating_timestamp, message_text, ora_error_code,
     alert_level, message_type, message_level, module_id, message_hash)
VALUES
    (s.con_id, s.originating_timestamp, s.message_text, s.ora_error_code,
     s.alert_level, s.message_type, s.message_level, s.module_id, s.message_hash)
;
#########################################################
## s_redo_log_switch
#########################################################
[s_redo_log_switch, Y, 600]
MERGE INTO itstone.s_redo_log_switch t
USING
(
    SELECT
        HIST.CON_ID,
        HIST.THREAD_NO,
        HIST.SEQUENCE_NO,
        HIST.FIRST_CHANGE_NO,
        TO_CHAR(HIST.FIRST_TIME, 'YYYY-MM-DD HH24:MI:SS') AS FIRST_TIME,
        HIST.NEXT_CHANGE_NO,
        HIST.RESETLOGS_CHANGE_NO,
        TO_CHAR(HIST.RESETLOGS_TIME, 'YYYY-MM-DD HH24:MI:SS') AS RESETLOGS_TIME,
        TO_CHAR(HIST.PREV_FIRST_TIME, 'YYYY-MM-DD HH24:MI:SS') AS PREV_FIRST_TIME,
        CASE
            WHEN HIST.PREV_FIRST_TIME IS NULL THEN NULL
            ELSE ROUND
                 (
                     (CAST(HIST.FIRST_TIME AS DATE) - CAST(HIST.PREV_FIRST_TIME AS DATE))
                     * 86400
                 )
        END                                           AS SWITCH_INTERVAL_SEC,
        CFG.ONLINE_LOG_GROUP_COUNT,
        CFG.ONLINE_LOG_MEMBER_COUNT,
        CFG.MIN_LOG_SIZE_MB,
        CFG.MAX_LOG_SIZE_MB,
        CFG.TOTAL_LOG_SIZE_MB
    FROM
    (
        SELECT
            0                                         AS CON_ID,
            THREAD#                                   AS THREAD_NO,
            SEQUENCE#                                 AS SEQUENCE_NO,
            FIRST_CHANGE#                             AS FIRST_CHANGE_NO,
            FIRST_TIME,
            NEXT_CHANGE#                              AS NEXT_CHANGE_NO,
            RESETLOGS_CHANGE#                         AS RESETLOGS_CHANGE_NO,
            RESETLOGS_TIME,
            LAG(FIRST_TIME) OVER
            (
                PARTITION BY THREAD#, RESETLOGS_CHANGE#
                ORDER BY FIRST_TIME, SEQUENCE#
            )                                         AS PREV_FIRST_TIME
        FROM V$LOG_HISTORY
    ) HIST
    CROSS JOIN
    (
        SELECT
            COUNT(*)                                  AS ONLINE_LOG_GROUP_COUNT,
            SUM(MEMBERS)                              AS ONLINE_LOG_MEMBER_COUNT,
            ROUND(MIN(BYTES) / 1048576, 2)            AS MIN_LOG_SIZE_MB,
            ROUND(MAX(BYTES) / 1048576, 2)            AS MAX_LOG_SIZE_MB,
            ROUND(SUM(BYTES) / 1048576, 2)            AS TOTAL_LOG_SIZE_MB
        FROM V$LOG
    ) CFG
    WHERE HIST.FIRST_TIME >= SYSDATE - 1
) s
ON
(
        t.thread_no           = s.thread_no
    AND t.sequence_no         = s.sequence_no
    AND t.resetlogs_change_no = s.resetlogs_change_no
)
WHEN MATCHED THEN UPDATE SET
    con_id                  = s.con_id,
    first_change_no         = s.first_change_no,
    first_time              = s.first_time,
    next_change_no          = s.next_change_no,
    resetlogs_time          = s.resetlogs_time,
    prev_first_time         = s.prev_first_time,
    switch_interval_sec     = s.switch_interval_sec,
    online_log_group_count  = s.online_log_group_count,
    online_log_member_count = s.online_log_member_count,
    min_log_size_mb         = s.min_log_size_mb,
    max_log_size_mb         = s.max_log_size_mb,
    total_log_size_mb       = s.total_log_size_mb
WHEN NOT MATCHED THEN INSERT
(
    con_id,
    thread_no,
    sequence_no,
    first_change_no,
    first_time,
    next_change_no,
    resetlogs_change_no,
    resetlogs_time,
    prev_first_time,
    switch_interval_sec,
    online_log_group_count,
    online_log_member_count,
    min_log_size_mb,
    max_log_size_mb,
    total_log_size_mb
)
VALUES
(
    s.con_id,
    s.thread_no,
    s.sequence_no,
    s.first_change_no,
    s.first_time,
    s.next_change_no,
    s.resetlogs_change_no,
    s.resetlogs_time,
    s.prev_first_time,
    s.switch_interval_sec,
    s.online_log_group_count,
    s.online_log_member_count,
    s.min_log_size_mb,
    s.max_log_size_mb,
    s.total_log_size_mb
)
;
#########################################################
## s_sql_plan
#########################################################
[s_sql_plan, Y, 180]
MERGE INTO itstone.s_sql_plan t
USING
(
	SELECT
	    ## [2026-07-19] Oracle MVP는 Non-CDB 단일 컨테이너 기준이므로 적재 CON_ID를 0으로 통일한다.
	    0 AS CON_ID,
	    P.SQL_ID,
	    P.CHILD_NUMBER,
	    P.PLAN_HASH_VALUE,
	    P.ID,
	    P.PARENT_ID,
	    p.depth,
	    P.POSITION,
	    P.OPERATION,
	    P.OPTIONS,
	    P.OBJECT_OWNER,
	    P.OBJECT_NAME,
	    P.OBJECT_TYPE,
	    CAST(SUBSTR(P.ACCESS_PREDICATES, 1, 4000) AS VARCHAR2(4000)) AS ACCESS_PREDICATES,
	    CAST(SUBSTR(P.FILTER_PREDICATES, 1, 4000) AS VARCHAR2(4000)) AS FILTER_PREDICATES,
	    P.CARDINALITY,
	    P.COST,
	    P.PROJECTION,
	    P.LAST_STARTS AS STARTS,
	    P.LAST_OUTPUT_ROWS AS A_ROWS,
	    P.LAST_ELAPSED_TIME AS A_TIME_US,
	    P.LAST_CR_BUFFER_GETS + P.LAST_CU_BUFFER_GETS AS BUFFERS,
	    P.LAST_DISK_READS AS READS,
	    P.LAST_TEMPSEG_SIZE AS TEMP_BYTES,
	    ## Oracle/PG 서버 시각 동기화 전제이며 약 1초 이내 시차를 허용한다.
	    TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF6') AS COLLECT_TIME
	FROM V$SQL_PLAN_STATISTICS_ALL P
	JOIN
	(
	    SELECT DISTINCT CON_ID, SQL_ID, PLAN_HASH_VALUE
	    FROM
	    (
	        SELECT CON_ID, SQL_ID, PLAN_HASH_VALUE
	        FROM
	        (
	            SELECT CON_ID, SQL_ID, PLAN_HASH_VALUE
	            FROM   V$SQL
	            WHERE  ELAPSED_TIME  > 0
	              AND  EXECUTIONS    > 0
	              AND  PARSING_SCHEMA_NAME NOT IN ('SYS', 'SYSTEM', 'DBSNMP')
	              AND  PARSING_SCHEMA_NAME <> 'ITSTONE'
	            ORDER BY ELAPSED_TIME DESC
	        )
	        WHERE ROWNUM <= 20
	        UNION ALL
	        SELECT CON_ID, SQL_ID, PLAN_HASH_VALUE
	        FROM
	        (
	            SELECT CON_ID, SQL_ID, PLAN_HASH_VALUE
	            FROM   V$SQL
	            WHERE  ELAPSED_TIME  > 0
	              AND  EXECUTIONS    > 0
	              AND  PARSING_SCHEMA_NAME NOT IN ('SYS', 'SYSTEM', 'DBSNMP')
	              AND  PARSING_SCHEMA_NAME <> 'ITSTONE'
	            ORDER BY BUFFER_GETS DESC
	        )
	        WHERE ROWNUM <= 10
	        UNION ALL
	        SELECT V.CON_ID, V.SQL_ID, V.PLAN_HASH_VALUE
	        FROM   V$SESSION SE
	        JOIN   V$SQL V
	          ON   V.CON_ID       = SE.CON_ID
	          AND  V.SQL_ID       = SE.SQL_ID
	          AND  V.CHILD_NUMBER = SE.SQL_CHILD_NUMBER
	        WHERE  SE.STATUS = 'ACTIVE'
	          AND  SE.TYPE   = 'USER'
	          AND  SE.SQL_ID IS NOT NULL
	          AND  V.PLAN_HASH_VALUE > 0
	          AND  V.PARSING_SCHEMA_NAME NOT IN ('SYS', 'SYSTEM', 'ITSTONE', 'DBSNMP')
	        UNION ALL
	        ## [P1 확장성] 최근 5분 활동 SQL: 무제한이면 대형 시스템서 수천 SQL×평균15 plan node 를 3분마다 조회/UPDATE(WAL·dead tuple 폭증).
	        ##   최근성(LAST_ACTIVE_TIME) 순 상한 200(건) 캡. ①elapsed20 ②bufgets10 ③active 유지로 주요 SQL 커버. 200(건) 밖 마이너 SQL plan 은 온디맨드 보완(별도 과제).
	        SELECT CON_ID, SQL_ID, PLAN_HASH_VALUE
	        FROM (
	            SELECT CON_ID, SQL_ID, PLAN_HASH_VALUE
	            FROM   V$SQL
	            WHERE  LAST_ACTIVE_TIME >= SYSDATE - (5/1440)
	              AND  PLAN_HASH_VALUE > 0
	              AND  PARSING_SCHEMA_NAME NOT IN ('SYS', 'SYSTEM', 'DBSNMP')
	              AND  PARSING_SCHEMA_NAME <> 'ITSTONE'
	            ORDER BY LAST_ACTIVE_TIME DESC
	        )
	        WHERE ROWNUM <= 200
	    )
	) T
	  ON  T.CON_ID          = P.CON_ID
	  AND T.SQL_ID          = P.SQL_ID
	  AND T.PLAN_HASH_VALUE = P.PLAN_HASH_VALUE
) s
ON
(
        t.con_id          = s.con_id
    AND t.sql_id          = s.sql_id
    AND t.child_number    = s.child_number
    AND t.plan_hash_value = s.plan_hash_value
    AND t.id              = s.id
)
## C++ Agent는 아래 SET 목록을 해석하지 않고, WHEN MATCHED 존재 여부만으로
## INSERT 비키 컬럼 전체를 DO UPDATE한다. collect_time도 INSERT 비키 컬럼으로
## 전달하여 Oracle SYSTIMESTAMP 값으로 EXCLUDED 갱신한다.
WHEN MATCHED THEN UPDATE SET
    collect_time = s.collect_time,
    starts     = s.starts,
    a_rows     = s.a_rows,
    a_time_us  = s.a_time_us,
    buffers    = s.buffers,
    reads      = s.reads,
    temp_bytes = s.temp_bytes
WHEN NOT MATCHED THEN INSERT
(
    con_id,
    sql_id,
    child_number,
    plan_hash_value,
    id,
    parent_id,
    depth,
    position,
    operation,
    options,
    object_owner,
    object_name,
    object_type,
    access_predicates,
    filter_predicates,
    cardinality,
    cost,
    projection,
    starts,
    a_rows,
    a_time_us,
    buffers,
    reads,
    temp_bytes,
    collect_time
)
VALUES
(
    s.con_id,
    s.sql_id,
    s.child_number,
    s.plan_hash_value,
    s.id,
    s.parent_id,
    s.depth,
    s.position,
    s.operation,
    s.options,
    s.object_owner,
    s.object_name,
    s.object_type,
    s.access_predicates,
    s.filter_predicates,
    s.cardinality,
    s.cost,
    s.projection,
    s.starts,
    s.a_rows,
    s.a_time_us,
    s.buffers,
    s.reads,
    s.temp_bytes,
    s.collect_time
)
;
#########################################################
## s_undo_stat
#########################################################
[s_undo_stat, Y, 660]
MERGE INTO itstone.s_undo_stat t
USING
(
		SELECT
		    ## [2026-07-19] PDB 직접 접속도 Non-CDB 논리 모델로 처리하여 적재 CON_ID를 0으로 통일한다.
		    0 AS CON_ID,
		    TO_CHAR(BEGIN_TIME, 'YYYY-MM-DD HH24:MI:SS')  AS BEGIN_TIME,
		    TO_CHAR(END_TIME,   'YYYY-MM-DD HH24:MI:SS')  AS END_TIME,
		    NVL(UNDOTSN, 0)       AS UNDOTSN,
		    UNDOBLKS,
		    TXNCOUNT,
		    MAXQUERYLEN,
		    MAXQUERYID,
		    MAXCONCURRENCY,
		    SSOLDERRCNT,
		    NOSPACEERRCNT,
		    ACTIVEBLKS,
		    UNEXPIREDBLKS,
		    EXPIREDBLKS,
		    TUNED_UNDORETENTION,
		    UNXPSTEALCNT,
		    UNXPBLKRELCNT,
		    UNXPBLKREUCNT,
		    EXPSTEALCNT,
		    EXPBLKRELCNT,
		    EXPBLKREUCNT
		FROM V$UNDOSTAT
		WHERE BEGIN_TIME >= SYSDATE - 1
) s
ON
(
        t.con_id       = s.con_id     AND
        t.undotsn      = s.undotsn    AND
        t.begin_time   = s.begin_time
)
WHEN MATCHED THEN UPDATE SET
		    END_TIME            =  S.END_TIME,            
		    UNDOBLKS            =  S.UNDOBLKS,
		    TXNCOUNT            =  S.TXNCOUNT,
		    MAXQUERYLEN         =  S.MAXQUERYLEN,
		    MAXQUERYID          =  S.MAXQUERYID,
		    MAXCONCURRENCY      =  S.MAXCONCURRENCY,
		    SSOLDERRCNT         =  S.SSOLDERRCNT,
		    NOSPACEERRCNT       =  S.NOSPACEERRCNT,
		    ACTIVEBLKS          =  S.ACTIVEBLKS,
		    UNEXPIREDBLKS       =  S.UNEXPIREDBLKS,
		    EXPIREDBLKS         =  S.EXPIREDBLKS,
		    TUNED_UNDORETENTION =  S.TUNED_UNDORETENTION,
		    UNXPSTEALCNT        =  S.UNXPSTEALCNT,
		    UNXPBLKRELCNT       =  S.UNXPBLKRELCNT,
		    UNXPBLKREUCNT       =  S.UNXPBLKREUCNT,
		    EXPSTEALCNT         =  S.EXPSTEALCNT,
		    EXPBLKRELCNT        =  S.EXPBLKRELCNT,
		    EXPBLKREUCNT        =  S.EXPBLKREUCNT    
WHEN NOT MATCHED THEN INSERT
(
		    CON_ID,
		    BEGIN_TIME,
		    END_TIME,
		    UNDOTSN,
		    UNDOBLKS,
		    TXNCOUNT,
		    MAXQUERYLEN,
		    MAXQUERYID,
		    MAXCONCURRENCY,
		    SSOLDERRCNT,
		    NOSPACEERRCNT,
		    ACTIVEBLKS,
		    UNEXPIREDBLKS,
		    EXPIREDBLKS,
		    TUNED_UNDORETENTION,
		    UNXPSTEALCNT,
		    UNXPBLKRELCNT,
		    UNXPBLKREUCNT,
		    EXPSTEALCNT,
		    EXPBLKRELCNT,
		    EXPBLKREUCNT
)
VALUES
(
		    S.CON_ID,
		    S.BEGIN_TIME,
		    S.END_TIME,
		    S.UNDOTSN,
		    S.UNDOBLKS,
		    S.TXNCOUNT,
		    S.MAXQUERYLEN,
		    S.MAXQUERYID,
		    S.MAXCONCURRENCY,
		    S.SSOLDERRCNT,
		    S.NOSPACEERRCNT,
		    S.ACTIVEBLKS,
		    S.UNEXPIREDBLKS,
		    S.EXPIREDBLKS,
		    S.TUNED_UNDORETENTION,
		    S.UNXPSTEALCNT,
		    S.UNXPBLKRELCNT,
		    S.UNXPBLKREUCNT,
		    S.EXPSTEALCNT,
		    S.EXPBLKRELCNT,
		    S.EXPBLKREUCNT
)
;
#########################################################
## s_sql_bind
#########################################################
[s_sql_bind, Y, 300]
MERGE INTO itstone.s_sql_bind t
USING
(
	SELECT
	    ## [2026-07-19] Oracle MVP는 Non-CDB 단일 컨테이너 기준이므로 적재 CON_ID를 0으로 통일한다.
	    0 AS CON_ID,
	    B.SQL_ID,
	    B.CHILD_NUMBER,
	    B.NAME         AS BIND_NAME,
	    B.POSITION,
	    B.DATATYPE_STRING,
	    B.VALUE_STRING,
	    TO_CHAR(B.LAST_CAPTURED, 'YYYY-MM-DD HH24:MI:SS') AS LAST_CAPTURED
	FROM V$SQL_BIND_CAPTURE B
	## Bind 값이 없는 행 제외 + 최근 30분 캡처분만
	WHERE B.VALUE_STRING IS NOT NULL
	  AND B.LAST_CAPTURED >= SYSDATE - (30 / 1440)
	  ## [FIX] 모니터링/시스템 세션 SQL 제외(타 V$SQL 컬렉터와 정책 통일 + 바인드값 민감정보 방어)
	  AND EXISTS (
	      SELECT 1 FROM V$SQL Q
	      WHERE Q.SQL_ID = B.SQL_ID
	        AND Q.CHILD_NUMBER = B.CHILD_NUMBER
	        AND Q.PARSING_SCHEMA_NAME NOT IN ('SYS','SYSTEM','ITSTONE','DBSNMP')
	  )
) s
ON
(
        t.con_id        = s.con_id
    AND t.sql_id        = s.sql_id
    AND t.child_number  = s.child_number
    AND t.position      = s.position
    AND t.last_captured = s.last_captured
)
## WHEN MATCHED 절 없음 = 매칭 시 무동작(DO NOTHING). 캡처 샘플 불변이라 갱신 대상 없음.
WHEN NOT MATCHED THEN INSERT
(
    con_id,
    sql_id,
    child_number,
    bind_name,
    position,
    datatype_string,
    value_string,
    last_captured
)
VALUES
(
    s.con_id,
    s.sql_id,
    s.child_number,
    s.bind_name,
    s.position,
    s.datatype_string,
    s.value_string,
    s.last_captured
)
;
#########################################################
## s_sql_text
#########################################################
[s_sql_text, Y, 60]
## [P0 확장성] 대형 공유풀(커서 5만~10만)은 LAST_ACTIVE_TIME 최근 30분 필터로
## 전체 재스캔·fulltext 전량 전송을 활성집합으로 축소한다.
## 현재 C++ Agent는 SET 목록을 해석하지 않고 INSERT 비키 컬럼 전체를 매 주기 UPDATE한다.
##  주기는 60초 유지: SQL Detail 팝업(Scatter 점 클릭)이 s_sql_text 원문을 즉시 조회하므로, 주기를 늘리면
##  신규 SQL 원문이 그만큼(최대 주기) 팝업에서 공백이 됨. 신규 SQL 은 WHEN NOT MATCHED INSERT 로 매 주기 즉시 적재.
##  ※ 출시 전 실 V$SQL 5만행 조건에서 이 섹션이 주기(60초) 내 완료되는지 부하테스트 필요.
MERGE INTO itstone.s_sql_text t
USING
(
		SELECT
		    ## [2026-07-19] Oracle MVP는 Non-CDB 단일 컨테이너 기준이므로 적재 CON_ID를 0으로 통일한다.
		    0 AS CON_ID,
		    V.SQL_ID,
		    V.CHILD_NUMBER,
		    V.PLAN_HASH_VALUE,
		    V.FORCE_MATCHING_SIGNATURE,
		    V.EXACT_MATCHING_SIGNATURE,
		    V.PARSING_SCHEMA_NAME,
		    V.MODULE,
		    V.SQL_FULLTEXT     AS SQL_TEXT,
        TO_CHAR(V.LAST_ACTIVE_TIME, 'YYYY-MM-DD HH24:MI:SS') AS LAST_SEEN,
        ## Oracle/PG 서버 시각 동기화 전제이며 약 1초 이내 시차를 허용한다.
        TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF6') AS PG_LAST_COLLECT_TIME
		FROM V$SQL V
		WHERE V.SQL_ID              IS NOT NULL
		  ## [2026-07-20] 실행계획이 없는 PL/SQL(COMMAND_TYPE=47)도 SQL 분석 팝업에서 원문을 조회할 수 있게 수집한다.
		  AND (V.PLAN_HASH_VALUE > 0 OR V.COMMAND_TYPE = 47)
		  AND V.EXECUTIONS           > 0
		  AND V.ELAPSED_TIME         > 0
		  AND V.LAST_ACTIVE_TIME    >= SYSDATE - (30/1440)
		  AND V.PARSING_SCHEMA_NAME NOT IN ('SYS', 'SYSTEM', 'ITSTONE', 'DBSNMP')
) s
ON
(
        t.con_id       = s.con_id
    AND t.sql_id       = s.sql_id
    AND t.child_number = s.child_number
)
WHEN MATCHED THEN UPDATE SET
    plan_hash_value          = s.plan_hash_value,
    force_matching_signature = s.force_matching_signature,
    exact_matching_signature = s.exact_matching_signature,
    parsing_schema_name      = s.parsing_schema_name,
    "module"                   = s.module,
    last_seen                = s.last_seen,
    pg_last_collect_time     = s.pg_last_collect_time
WHEN NOT MATCHED THEN INSERT
(
    con_id,
    sql_id,
    child_number,
    plan_hash_value,
    force_matching_signature,
    exact_matching_signature,
    parsing_schema_name,
    "module",
    sql_text,
    last_seen,
    pg_last_collect_time
)
VALUES
(
    s.con_id,
    s.sql_id,
    s.child_number,
    s.plan_hash_value,
    s.force_matching_signature,
    s.exact_matching_signature,
    s.parsing_schema_name,
    s.module,
    s.sql_text,
    s.last_seen,
    s.pg_last_collect_time
)
;
