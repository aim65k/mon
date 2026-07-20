# monitoring을 위한 실행 시나리오 1
# 작성규칙 
# 주석: 문장 앞 #
# 제목: '['으로 시작하고 제목 
# 사용유무:제목뒤 ',' 로 구분
# 반복주기: 사용유무뒤 ',' 로 구분
# query: [..] 다음줄 부터 공백줄이나 다음 '[' 만나기 전까지
#

#################################
## 21. S_PGA_STAT - 30초
#################################
[S_PGA_STAT, Y, 30]
INSERT INTO S_PGA_STAT
(
	con_id,
	pga_target_bytes,
	pga_allocated_bytes,
	pga_inuse_bytes,
	workarea_mem_bytes,
	cache_hit_pct,
	over_allocation_count,
	extra_bytes_rw,
	optimal_exec_cum,
	onepass_exec_cum,
	multipass_exec_cum,
	total_exec_cum
)
SELECT
    0                                   AS CON_ID,
    NVL(P.PGA_TARGET_BYTES,      0)     AS PGA_TARGET_BYTES,
    NVL(P.PGA_ALLOCATED_BYTES,   0)     AS PGA_ALLOCATED_BYTES,
    NVL(P.PGA_INUSE_BYTES,       0)     AS PGA_INUSE_BYTES,
    NVL(P.WORKAREA_MEM_BYTES,    0)     AS WORKAREA_MEM_BYTES,
    NVL(P.CACHE_HIT_PCT,         0)     AS CACHE_HIT_PCT,
    NVL(P.OVER_ALLOCATION_COUNT, 0)     AS OVER_ALLOCATION_COUNT,
    NVL(P.EXTRA_BYTES_RW,        0)     AS EXTRA_BYTES_RW,
    NVL(W.OPTIMAL_EXEC_CUM,      0)     AS OPTIMAL_EXEC_CUM,
    NVL(W.ONEPASS_EXEC_CUM,      0)     AS ONEPASS_EXEC_CUM,
    NVL(W.MULTIPASS_EXEC_CUM,    0)     AS MULTIPASS_EXEC_CUM,
    NVL(W.TOTAL_EXEC_CUM,        0)     AS TOTAL_EXEC_CUM
FROM
(
    SELECT
        MAX(CASE WHEN NAME = 'aggregate PGA target parameter'    THEN VALUE END) AS PGA_TARGET_BYTES,
        MAX(CASE WHEN NAME = 'total PGA allocated'               THEN VALUE END) AS PGA_ALLOCATED_BYTES,
        MAX(CASE WHEN NAME = 'total PGA inuse'                   THEN VALUE END) AS PGA_INUSE_BYTES,
        MAX(CASE WHEN NAME = 'total PGA used for auto workareas' THEN VALUE END) AS WORKAREA_MEM_BYTES,
        MAX(CASE WHEN NAME = 'cache hit percentage'             THEN VALUE END) AS CACHE_HIT_PCT,
        MAX(CASE WHEN NAME = 'over allocation count'            THEN VALUE END) AS OVER_ALLOCATION_COUNT,
        MAX(CASE WHEN NAME = 'extra bytes read/written'         THEN VALUE END) AS EXTRA_BYTES_RW
    FROM V$PGASTAT
    WHERE NAME IN
    (
        'aggregate PGA target parameter',
        'total PGA allocated',
        'total PGA inuse',
        'total PGA used for auto workareas',
        'cache hit percentage',
        'over allocation count',
        'extra bytes read/written'
    )
) P
CROSS JOIN
(
    SELECT
        SUM(OPTIMAL_EXECUTIONS)      AS OPTIMAL_EXEC_CUM,
        SUM(ONEPASS_EXECUTIONS)      AS ONEPASS_EXEC_CUM,
        SUM(MULTIPASSES_EXECUTIONS)  AS MULTIPASS_EXEC_CUM,
        SUM(TOTAL_EXECUTIONS)        AS TOTAL_EXEC_CUM
    FROM V$SQL_WORKAREA_HISTOGRAM
) W
;

#################################
## 21-1. S_RECOVER_FILE - 10분
## ===============================================================
## 소스 : V$RECOVER_FILE — 미디어 복구가 필요한 데이터파일.
##        정상 운영 DB 는 항상 0행이어야 한다. 1건이라도 있으면 즉시 확인 대상
##        (해당 테이블스페이스 접근 불가 상태일 수 있음).
##
## ★상세행이 아니라 "요약 1행" 을 적재한다 — 이유:
##   V$RECOVER_FILE 이 정상 시 0행이라, 상세 적재하면 테이블이 영원히 비어
##   "수집됨+0건(정상)" 과 "수집 자체가 안 됨(이상)" 을 구분할 수 없다.
##   COUNT(*) 는 0행 입력에도 1행(0)을 반환하므로, 요약하면 두 상황이 갈린다.
##   → 행이 있다 = 수집 정상 / file_cnt=0 = 복구 필요 파일 없음
##
## ★★[사고 기록 — 2026-07-16] LISTAGG / ON OVERFLOW TRUNCATE 사용 금지
##   최초 작성 시 file_list 를 LISTAGG(... ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) 로
##   담으려 했으나, 에이전트가 이 구문에서 SQL 을 잘라먹어 기동 자체가 실패했다.
##   (동일 증상이 S_INVALID_OBJECT 에서도 발생 — oracle_collect_insert_01_20.sql 의 사고 기록 참조)
##     ORA-24333: 반복 카운트가 영입니다  ← 조각난 SQL 을 오라클이 거부
##   [교훈] 기존 39개 블록에 없던 구문은 에이전트 파서가 처음 겪는 것이다.
##          집계 컬럼은 COUNT/SUM/MIN/MAX 등 기존 블록이 이미 쓰는 형태로만 작성할 것.
##   [대안] 개수만 담는다. 어떤 파일인지는 발생 시 DBA 가 직접 조회하면 된다:
##          SELECT * FROM v$recover_file;
##
## ★MIN_CHANGE_NO / OLDEST_FILE_TIME 로 "언제부터 밀린 파일인가"는 가늠할 수 있다.
##
## ★CON_ID 는 0 상수 — S_REDO_LOG_STATUS 등 다른 인스턴스 레벨 테이블과 동일 규칙.
##   (정기점검 항목의 con_scope='CDB' 와 짝을 이룬다)
#################################
[S_RECOVER_FILE, Y, 600]
INSERT INTO S_RECOVER_FILE
(
	con_id,
	file_cnt,
	error_cnt,
	min_change_no,
	oldest_file_time
)
SELECT
    0                                                     AS CON_ID,
    COUNT(*)                                              AS FILE_CNT,
    COUNT(R.ERROR)                                        AS ERROR_CNT,
    MIN(R.CHANGE#)                                        AS MIN_CHANGE_NO,
    TO_CHAR(MIN(R.TIME), 'YYYY-MM-DD HH24:MI:SS')         AS OLDEST_FILE_TIME
FROM V$RECOVER_FILE R
;

#################################
## 22. S_REDO_ACTIVITY - 30초
#################################
[S_REDO_ACTIVITY, Y, 30]
INSERT INTO S_REDO_ACTIVITY
(
	con_id,
	redo_size_bytes_cum,
	redo_writes_cum,
	user_commits_cum,
	user_rollbacks_cum,
	redo_mb_per_sec,
	created_date
)
SELECT
    0                                                                       AS CON_ID,
    NVL(MAX(CASE WHEN GS.NAME = 'redo size'      THEN GS.VALUE END), 0)   AS REDO_SIZE_BYTES_CUM,
    NVL(MAX(CASE WHEN GS.NAME = 'redo writes'    THEN GS.VALUE END), 0)   AS REDO_WRITES_CUM,
    NVL(MAX(CASE WHEN GS.NAME = 'user commits'   THEN GS.VALUE END), 0)   AS USER_COMMITS_CUM,
    NVL(MAX(CASE WHEN GS.NAME = 'user rollbacks' THEN GS.VALUE END), 0)   AS USER_ROLLBACKS_CUM,
    null  redo_mb_per_sec,
    TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS')   created_date                                                                    
## [P0-2 RAC] 단일 인스턴스 기준 GV$→V$ 변경(수집 범위 일관)
FROM V$SYSSTAT GS
WHERE GS.NAME IN
(
    'redo size',
    'redo writes',
    'user commits',
    'user rollbacks'
)
;

#################################
## 23. S_REDO_LOG_STATUS - 30초
#################################
[S_REDO_LOG_STATUS, Y, 30]
INSERT INTO S_REDO_LOG_STATUS
(
	con_id,
	group_no,
	thread_no,
	sequence_no,
	bytes_mb,
	block_size,
	members,
	archived,
	status,
	first_change_no,
	first_time,
	member_path,
	member_type,
	member_is_valid,
	member_is_fra_file
)
SELECT
    0                                          AS CON_ID,             
    L.GROUP#                                   AS GROUP_NO,           
    L.THREAD#                                  AS THREAD_NO,          
    L.SEQUENCE#                                AS SEQUENCE_NO,        
    ROUND(L.BYTES / 1048576)                   AS BYTES_MB,           
    L.BLOCKSIZE                                AS BLOCK_SIZE,         
    L.MEMBERS                                  AS MEMBERS,            
    L.ARCHIVED                                 AS ARCHIVED,           
    L.STATUS                                   AS STATUS,             
    L.FIRST_CHANGE#                            AS FIRST_CHANGE_NO,    
    TO_CHAR(L.FIRST_TIME, 'YYYY-MM-DD HH24:MI:SS')     AS FIRST_TIME,         
    F.MEMBER                                   AS MEMBER_PATH,        
    F.TYPE                                     AS MEMBER_TYPE,        
    F.STATUS                                   AS MEMBER_IS_VALID,    
    F.IS_RECOVERY_DEST_FILE                    AS MEMBER_IS_FRA_FILE  
FROM V$LOG L
JOIN V$LOGFILE F ON F.GROUP# = L.GROUP#
;

#################################
## 24. S_REDO_LOG_SWITCH - 10분
## MERGE 로 이동
#################################



#################################
## 25. S_SEGMENT_STAT - 10분
#################################
[S_SEGMENT_STAT, Y, 600]
INSERT INTO S_SEGMENT_STAT
(
	con_id,
	owner,
	object_name,
	subobject_name,
	tablespace_name,
	object_type,
	physical_reads_cum,
	logical_reads_cum,
	physical_writes_cum,
	phys_read_req_cum,
	phys_write_req_cum,
	row_lock_waits_cum,
	buffer_busy_waits_cum,
	itl_waits_cum
)
SELECT
    ## [2026-07-19] 내부 집계는 실제 CON_ID를 유지하고 최종 적재값만 0으로 통일한다.
    0 AS CON_ID, OWNER, OBJECT_NAME, SUBOBJECT_NAME, TABLESPACE_NAME, OBJECT_TYPE,
    PHYSICAL_READS_CUM, LOGICAL_READS_CUM, PHYSICAL_WRITES_CUM,
    PHYS_READ_REQ_CUM, PHYS_WRITE_REQ_CUM,
    ROW_LOCK_WAITS_CUM, BUFFER_BUSY_WAITS_CUM, ITL_WAITS_CUM
FROM
(
    SELECT
        G.*,
        ROW_NUMBER() OVER (ORDER BY G.PHYSICAL_READS_CUM    DESC) AS RN_PR,
        ROW_NUMBER() OVER (ORDER BY G.LOGICAL_READS_CUM      DESC) AS RN_LR,
        ROW_NUMBER() OVER (ORDER BY G.ROW_LOCK_WAITS_CUM     DESC) AS RN_RL,
        ROW_NUMBER() OVER (ORDER BY G.BUFFER_BUSY_WAITS_CUM  DESC) AS RN_BB
    FROM
    (
        SELECT
            SS.CON_ID                               AS CON_ID,
            SS.OWNER                                AS OWNER,
            SS.OBJECT_NAME                          AS OBJECT_NAME,
            NVL(SS.SUBOBJECT_NAME, ' ')             AS SUBOBJECT_NAME,
            NVL(SS.TABLESPACE_NAME, ' ')            AS TABLESPACE_NAME,
            NVL(SS.OBJECT_TYPE, ' ')                AS OBJECT_TYPE,
            MAX(CASE WHEN SS.STATISTIC_NAME = 'physical reads'          THEN SS.VALUE ELSE 0 END) AS PHYSICAL_READS_CUM,
            MAX(CASE WHEN SS.STATISTIC_NAME = 'logical reads'           THEN SS.VALUE ELSE 0 END) AS LOGICAL_READS_CUM,
            MAX(CASE WHEN SS.STATISTIC_NAME = 'physical writes'         THEN SS.VALUE ELSE 0 END) AS PHYSICAL_WRITES_CUM,
            MAX(CASE WHEN SS.STATISTIC_NAME = 'physical read requests'  THEN SS.VALUE ELSE 0 END) AS PHYS_READ_REQ_CUM,
            MAX(CASE WHEN SS.STATISTIC_NAME = 'physical write requests' THEN SS.VALUE ELSE 0 END) AS PHYS_WRITE_REQ_CUM,
            MAX(CASE WHEN SS.STATISTIC_NAME = 'row lock waits'          THEN SS.VALUE ELSE 0 END) AS ROW_LOCK_WAITS_CUM,
            MAX(CASE WHEN SS.STATISTIC_NAME = 'buffer busy waits'       THEN SS.VALUE ELSE 0 END) AS BUFFER_BUSY_WAITS_CUM,
            MAX(CASE WHEN SS.STATISTIC_NAME = 'ITL waits'               THEN SS.VALUE ELSE 0 END) AS ITL_WAITS_CUM
        FROM V$SEGMENT_STATISTICS SS
        WHERE SS.STATISTIC_NAME IN
              (
                  'physical reads',
                  'logical reads',
                  'physical writes',
                  'physical read requests',
                  'physical write requests',
                  'row lock waits',
                  'buffer busy waits',
                  'ITL waits'
              )
        GROUP BY
            SS.CON_ID,
            SS.OWNER,
            SS.OBJECT_NAME,
            SS.SUBOBJECT_NAME,
            SS.TABLESPACE_NAME,
            NVL(SS.OBJECT_TYPE, ' ')
    ) G
)
WHERE RN_PR <= 100 OR RN_LR <= 100 OR RN_RL <= 100 OR RN_BB <= 100
;

#################################
## 26. S_SGA_USAGE - 60초
#################################
[S_SGA_USAGE, Y, 60]
INSERT INTO S_SGA_USAGE
(
	con_id,
	buffer_cache_mb,
	shared_pool_mb,
	large_pool_mb,
	java_pool_mb,
	streams_pool_mb,
	free_sga_available_mb,
	shared_pool_free_mb,
	buffer_cache_free_mb,
	library_cache_mem_mb,
	sql_area_mem_mb,
	reloads_cum,
	invalidations_cum
)
SELECT
    0 AS CON_ID,
    N.BUFFER_CACHE_MB                                         AS BUFFER_CACHE_MB,
    N.SHARED_POOL_MB                                          AS SHARED_POOL_MB,
    N.LARGE_POOL_MB                                           AS LARGE_POOL_MB,
    N.JAVA_POOL_MB                                            AS JAVA_POOL_MB,
    N.STREAMS_POOL_MB                                         AS STREAMS_POOL_MB,
    N.FREE_MEMORY_MB                                          AS FREE_SGA_AVAILABLE_MB,
    NVL(S.SHARED_POOL_FREE_MB,    0)                          AS SHARED_POOL_FREE_MB,
## Oracle 19c 공식 V$ 지표로 안정적으로 산출할 수 없고 화면 SQL에서도 미사용하므로 NULL 적재
    CAST(NULL AS NUMBER)                                      AS BUFFER_CACHE_FREE_MB,
    CAST(NULL AS NUMBER)                                      AS LIBRARY_CACHE_MEM_MB,
    CAST(NULL AS NUMBER)                                      AS SQL_AREA_MEM_MB,
    NVL(L.RELOADS,                0)                          AS RELOADS_CUM,
    NVL(L.INVALIDATIONS,          0)                          AS INVALIDATIONS_CUM
FROM
(
    SELECT
        MAX(CASE WHEN NAME = 'Buffer Cache Size'         THEN ROUND(BYTES / 1048576) END) AS BUFFER_CACHE_MB,
        MAX(CASE WHEN NAME = 'Shared Pool Size'          THEN ROUND(BYTES / 1048576) END) AS SHARED_POOL_MB,
        MAX(CASE WHEN NAME = 'Large Pool Size'           THEN ROUND(BYTES / 1048576) END) AS LARGE_POOL_MB,
        MAX(CASE WHEN NAME = 'Java Pool Size'            THEN ROUND(BYTES / 1048576) END) AS JAVA_POOL_MB,
        MAX(CASE WHEN NAME = 'Streams Pool Size'         THEN ROUND(BYTES / 1048576) END) AS STREAMS_POOL_MB,
        MAX(CASE WHEN NAME = 'Free SGA Memory Available' THEN ROUND(BYTES / 1048576) END) AS FREE_MEMORY_MB
    FROM V$SGAINFO
) N
LEFT JOIN
(
    SELECT
        ROUND(SUM(CASE WHEN POOL = 'shared pool' AND NAME = 'free memory' THEN BYTES END) / 1048576) AS SHARED_POOL_FREE_MB
    FROM V$SGASTAT
) S
## [P0-2 RAC] 단일 인스턴스: 인스턴스 1개라 INST_ID 조인 불필요 → ON 1=1
  ON 1=1

LEFT JOIN
(
    SELECT
        SUM(RELOADS)       AS RELOADS,
        SUM(INVALIDATIONS) AS INVALIDATIONS
    FROM V$LIBRARYCACHE
) L
  ON 1=1
;

#################################
## 27. S_SQL_BIND - 5분
## MERGE 로 이동
#################################


#################################
## 28. S_SQL_ELAPSED_TOPN - 5분
#################################
[S_SQL_ELAPSED_TOPN, N, 300]
INSERT INTO S_SQL_ELAPSED_TOPN
(
	con_id,
	rnk,
	sql_id,
	plan_hash_value,
	parsing_schema_name,
	sql_text_preview,
	executions,
	elapsed_time_cum_us,
	cpu_time_cum_us,
	buffer_gets_cum,
	disk_reads_cum,
	avg_elapsed_ms,
	avg_cpu_ms,
	avg_wait_ms
)
SELECT
    CON_ID,
    RNK,
    SQL_ID,
    PLAN_HASH_VALUE,
    PARSING_SCHEMA_NAME,
    SQL_TEXT_PREVIEW,
    EXECUTIONS,
    ELAPSED_TIME_CUM_US,
    CPU_TIME_CUM_US,
    BUFFER_GETS_CUM,
    DISK_READS_CUM,
    AVG_ELAPSED_MS,
    AVG_CPU_MS,
    AVG_WAIT_MS
FROM
(
    SELECT
        AGG.CON_ID,
        AGG.SQL_ID,
        AGG.PARSING_SCHEMA_NAME,
        AGG.SQL_TEXT_PREVIEW,
        AGG.EXECUTIONS,
        AGG.ELAPSED_TIME AS ELAPSED_TIME_CUM_US,
        AGG.CPU_TIME     AS CPU_TIME_CUM_US,
        AGG.BUFFER_GETS  AS BUFFER_GETS_CUM,
        AGG.DISK_READS   AS DISK_READS_CUM,
        ROUND(AGG.ELAPSED_TIME / NULLIF(AGG.EXECUTIONS, 0) / 1000, 2) AS AVG_ELAPSED_MS,
        ROUND(AGG.CPU_TIME     / NULLIF(AGG.EXECUTIONS, 0) / 1000, 2) AS AVG_CPU_MS,
        ROUND(GREATEST(AGG.ELAPSED_TIME - AGG.CPU_TIME, 0) / NULLIF(AGG.EXECUTIONS, 0) / 1000, 2) AS AVG_WAIT_MS,
        AGG.PLAN_HASH_VALUE,
        ROW_NUMBER() OVER
        (
            PARTITION BY AGG.CON_ID
            ORDER BY AGG.ELAPSED_TIME / NULLIF(AGG.EXECUTIONS, 0) DESC
        ) AS RNK
    FROM
    (
        SELECT
            0 AS CON_ID,
            S.SQL_ID,
            MAX(S.PARSING_SCHEMA_NAME) AS PARSING_SCHEMA_NAME,
            MAX(SUBSTR(S.SQL_TEXT, 1, 1000)) AS SQL_TEXT_PREVIEW,
            SUM(S.EXECUTIONS) AS EXECUTIONS,
            SUM(S.ELAPSED_TIME) AS ELAPSED_TIME,
            SUM(S.CPU_TIME) AS CPU_TIME,
            SUM(S.BUFFER_GETS) AS BUFFER_GETS,
            SUM(S.DISK_READS) AS DISK_READS,
            S.PLAN_HASH_VALUE
        FROM V$SQL S
        WHERE S.EXECUTIONS >= 5
          AND S.SQL_ID IS NOT NULL
          AND S.PARSING_SCHEMA_NAME NOT IN ('SYS','SYSTEM')
          AND  PARSING_SCHEMA_NAME <> 'ITSTONE'
        GROUP BY
            S.SQL_ID,
            S.PLAN_HASH_VALUE
    ) AGG
)
WHERE RNK <= 20
;

#################################
## 29. S_SQL_LITERAL_STAT - 5분
#################################
[S_SQL_LITERAL_STAT, Y, 300]
INSERT INTO S_SQL_LITERAL_STAT
(
	con_id,
	total_sql_cnt,
	literal_sql_cnt,
	literal_group_cnt,
	max_duplicate_in_group
)
SELECT
    0            AS CON_ID,
    NVL(SUM(SUM_CNT), 0)                                          AS TOTAL_SQL_CNT,
    NVL(SUM(CASE WHEN SUM_CNT >= 2 THEN SUM_CNT END), 0)         AS LITERAL_SQL_CNT,
    NVL(SUM(CASE WHEN SUM_CNT >= 2 THEN 1       END), 0)         AS LITERAL_GROUP_CNT,
    NVL(MAX(CASE WHEN SUM_CNT >= 2 THEN SUM_CNT END), 0)          AS MAX_DUPLICATE_IN_GROUP
FROM
(
    SELECT
        FORCE_MATCHING_SIGNATURE,
        COUNT(DISTINCT SQL_ID) AS SUM_CNT
    FROM V$SQL
    WHERE FORCE_MATCHING_SIGNATURE IS NOT NULL
      AND FORCE_MATCHING_SIGNATURE <> 0  
      AND SQL_ID IS NOT NULL
      AND PARSING_SCHEMA_NAME NOT IN ('SYS', 'SYSTEM', 'ITSTONE', 'DBSNMP')
    GROUP BY FORCE_MATCHING_SIGNATURE
)
;

#################################
## 30. S_SQL_PLAN - 3분
## MERGE 로 이동
#################################


#################################
## 31. S_SQL_STAT - 60초
#################################
[S_SQL_STAT, Y, 60]
INSERT INTO ITSTONE.S_SQL_STAT
(
	con_id,
	sql_id,
	plan_hash_value,
	executions_cum,
	elapsed_time_cum_us,
	cpu_time_cum_us,
	application_wait_time_cum_us,
	concurrency_wait_time_cum_us,
	cluster_wait_time_cum_us,
	user_io_wait_time_cum_us,
	plsql_exec_time_cum_us,
	buffer_gets_cum,
	disk_reads_cum,
	direct_reads_cum,
	direct_writes_cum,
	rows_processed_cum,
	sorts_cum,
	fetches_cum,
	parse_calls_cum,
	loads_cum,
	invalidations_cum,
	version_count,
	last_active_time
)
SELECT
    ## [2026-07-19] Oracle MVP는 Non-CDB 단일 컨테이너 기준이므로 적재 CON_ID를 0으로 통일한다.
    0 AS CON_ID,
    S.SQL_ID,
    S.PLAN_HASH_VALUE,
    S.EXECUTIONS                  AS EXECUTIONS_CUM,
    S.ELAPSED_TIME                AS ELAPSED_TIME_CUM_US,
    S.CPU_TIME                    AS CPU_TIME_CUM_US,
    S.APPLICATION_WAIT_TIME       AS APPLICATION_WAIT_TIME_CUM_US,
    S.CONCURRENCY_WAIT_TIME       AS CONCURRENCY_WAIT_TIME_CUM_US,
    S.CLUSTER_WAIT_TIME           AS CLUSTER_WAIT_TIME_CUM_US,
    S.USER_IO_WAIT_TIME           AS USER_IO_WAIT_TIME_CUM_US,
    S.PLSQL_EXEC_TIME             AS PLSQL_EXEC_TIME_CUM_US,
    S.BUFFER_GETS                 AS BUFFER_GETS_CUM,
    S.DISK_READS                  AS DISK_READS_CUM,
    S.DIRECT_READS                AS DIRECT_READS_CUM,
    S.DIRECT_WRITES               AS DIRECT_WRITES_CUM,
    S.ROWS_PROCESSED              AS ROWS_PROCESSED_CUM,
    S.SORTS                       AS SORTS_CUM,
    S.FETCHES                     AS FETCHES_CUM,
    S.PARSE_CALLS                 AS PARSE_CALLS_CUM,
    S.LOADS                       AS LOADS_CUM,
    S.INVALIDATIONS               AS INVALIDATIONS_CUM,
    S.VERSION_COUNT,
    TO_CHAR(S.LAST_ACTIVE_TIME, 'YYYY-MM-DD HH24:MI:SS') AS LAST_ACTIVE_TIME
FROM V$SQLSTATS S
JOIN
(
    SELECT CON_ID, SQL_ID, PLAN_HASH_VALUE
    FROM
    (
        SELECT ST.CON_ID, ST.SQL_ID, ST.PLAN_HASH_VALUE
        FROM   V$SQLSTATS ST
        WHERE  ST.SQL_ID          IS NOT NULL
          AND  ST.PLAN_HASH_VALUE  > 0
          AND  ST.EXECUTIONS       > 0
          AND  ST.LAST_ACTIVE_TIME >= SYSDATE - (5/1440)
          AND  NOT EXISTS (
                   SELECT 1 FROM V$SQL Q
                   WHERE  Q.SQL_ID = ST.SQL_ID
                     AND (Q.PARSING_SCHEMA_NAME IN ('ITSTONE','SYS','SYSTEM','DBSNMP')
                          OR Q.COMMAND_TYPE = 0) )
        ORDER BY ST.ELAPSED_TIME DESC
    )
    WHERE ROWNUM <= 150
    UNION
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
      AND  V.PARSING_SCHEMA_NAME NOT IN ('SYS','SYSTEM','ITSTONE','DBSNMP')
) K
  ON  K.CON_ID          = S.CON_ID
  AND K.SQL_ID          = S.SQL_ID
  AND K.PLAN_HASH_VALUE = S.PLAN_HASH_VALUE
WHERE S.SQL_ID          IS NOT NULL
  AND S.PLAN_HASH_VALUE  > 0
  AND S.EXECUTIONS       > 0
;

#################################
## 32. S_SQL_TEXT - 60초
## MERGE 로 이동
#################################


#################################
## 33. S_SYS_TIME_MODEL - 5초
#################################
[S_SYS_TIME_MODEL, Y, 5]
INSERT INTO ITSTONE.S_SYS_TIME_MODEL
(
	con_id,
	stat_name,
	value_micro
)
SELECT
    0                     AS CON_ID,
    tm.STAT_NAME          AS STAT_NAME,
    tm.VALUE              AS VALUE_MICRO
FROM V$SYS_TIME_MODEL tm
WHERE tm.STAT_NAME IN
(
    'DB time',
    'DB CPU',
    'sql execute elapsed time',
    'parse time elapsed',
    'hard parse elapsed time',
    'PL/SQL execution elapsed time',
    'PL/SQL compilation elapsed time',
    'connection management call elapsed time',
    'background elapsed time',
    'background cpu time',
    'failed parse elapsed time',
    'hard parse (sharing criteria) elapsed time',
    'repeated bind elapsed time'
);

#################################
## 34. S_TABLESPACE_USAGE - 60초
#################################
[S_TABLESPACE_USAGE, Y, 60]
INSERT INTO ITSTONE.S_TABLESPACE_USAGE
(
	con_id,
	pdb_name,
	tablespace_name,
	used_percent,
	used_mb,
	total_mb,
	autoextend_yn,
	max_size_mb
)
SELECT
    0                                                                       AS CON_ID,
    NULL                                                                    AS PDB_NAME,
    M.TABLESPACE_NAME                                                       AS TABLESPACE_NAME,
    ROUND(M.USED_PERCENT, 2)                                                AS USED_PERCENT,
    ROUND(M.USED_SPACE      * T.BLOCK_SIZE / 1024 / 1024, 2)               AS USED_MB,
    ROUND(M.TABLESPACE_SIZE * T.BLOCK_SIZE / 1024 / 1024, 2)               AS TOTAL_MB,
    NVL(DF.AUTOEXTEND_YN, 'NO')                                             AS AUTOEXTEND_YN,
    ROUND(NVL(DF.MAX_SIZE_BYTES, M.TABLESPACE_SIZE * T.BLOCK_SIZE)
          / 1024 / 1024, 2)                                                 AS MAX_SIZE_MB
FROM DBA_TABLESPACE_USAGE_METRICS M
JOIN DBA_TABLESPACES T
  ON T.TABLESPACE_NAME = M.TABLESPACE_NAME
LEFT JOIN
(
    SELECT
        TABLESPACE_NAME,
        CASE
            WHEN MAX(CASE WHEN AUTOEXTENSIBLE = 'YES' THEN 1 ELSE 0 END) = 1
            THEN 'YES'
            ELSE 'NO'
        END                                                                 AS AUTOEXTEND_YN,
        SUM(
            CASE
                WHEN AUTOEXTENSIBLE = 'YES' THEN
                     CASE WHEN MAXBYTES = 0 THEN BYTES ELSE MAXBYTES END
                ELSE BYTES
            END
        )                                                                   AS MAX_SIZE_BYTES
    FROM
    (
        SELECT TABLESPACE_NAME, AUTOEXTENSIBLE, MAXBYTES, BYTES
        FROM DBA_DATA_FILES
        UNION ALL
        SELECT TABLESPACE_NAME, AUTOEXTENSIBLE, MAXBYTES, BYTES
        FROM DBA_TEMP_FILES
    )
    GROUP BY TABLESPACE_NAME
) DF
  ON DF.TABLESPACE_NAME = M.TABLESPACE_NAME
;

#################################
## 35. S_TEMP_TABLESPACE_USAGE - 30초
#################################
[S_TEMP_TABLESPACE_USAGE, Y, 30]
INSERT INTO ITSTONE.S_TEMP_TABLESPACE_USAGE
(
	con_id,
	tablespace_name,
	used_mb,
	total_mb
)
SELECT
    0                                                               AS CON_ID,
    S.TABLESPACE_NAME,
    ROUND(S.USED_BLOCKS  * T.BLOCK_SIZE / 1024 / 1024, 2)         AS USED_MB,
    ROUND(S.TOTAL_BLOCKS * T.BLOCK_SIZE / 1024 / 1024, 2)         AS TOTAL_MB
FROM V$SORT_SEGMENT S
JOIN DBA_TABLESPACES T
  ON T.TABLESPACE_NAME = S.TABLESPACE_NAME
;

#################################
## 36. S_TOP_WAIT_SESSION - 5초
#################################
[S_TOP_WAIT_SESSION, Y, 5]
INSERT INTO ITSTONE.S_TOP_WAIT_SESSION
(
	con_id,
	wait_class,
	wait_rank,
	sid,
	serial_no,
	username,
	status,
	type,
	state,
	event,
	seconds_in_wait,
	sql_id,
	sql_child_number,
	module,
	action,
	client_info,
	machine,
	program,
	blocking_session,
	blocking_status
)
SELECT
    ## [2026-07-19] 내부 순위 계산은 실제 CON_ID를 유지하고 최종 적재값만 0으로 통일한다.
    0 AS CON_ID,
    WAIT_CLASS,
    WAIT_RANK,
    SID,
    SERIAL#       AS SERIAL_NO,
    USERNAME,
    STATUS,
    TYPE,
    STATE,
    EVENT,
    SECONDS_IN_WAIT,
    SQL_ID,
    SQL_CHILD_NUMBER,
    MODULE,
    ACTION,
    CLIENT_INFO,
    MACHINE,
    PROGRAM,
    BLOCKING_SESSION,
    BLOCKING_STATUS
FROM
(
    SELECT
        AS1.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY AS1.CON_ID, AS1.WAIT_CLASS
            ORDER BY AS1.SECONDS_IN_WAIT DESC, AS1.LAST_CALL_ET DESC, AS1.SID ASC
        ) AS WAIT_RANK
    FROM
    (
        SELECT
            S.CON_ID,
            CASE
                WHEN S.STATE = 'WAITING'
                THEN NVL(S.WAIT_CLASS, 'Other')
                ELSE 'ON CPU'
            END                                     AS WAIT_CLASS,
            S.SID,
            S.SERIAL#,
            S.USERNAME,
            S.STATUS,
            S.TYPE,
            S.STATE,
            CASE
                WHEN S.STATE = 'WAITING'
                THEN S.EVENT
                ELSE 'ON CPU'
            END                                     AS EVENT,
            CASE
                WHEN S.STATE = 'WAITING'
                THEN NVL(S.SECONDS_IN_WAIT, 0)
                ELSE 0
            END                                     AS SECONDS_IN_WAIT,
            S.LAST_CALL_ET,
            S.SQL_ID,
            S.SQL_CHILD_NUMBER,
            SUBSTR(S.MODULE, 1, 64)                 AS MODULE,
            SUBSTR(S.ACTION, 1, 64)                 AS ACTION,
            SUBSTR(S.CLIENT_INFO, 1, 64)            AS CLIENT_INFO,
            SUBSTR(S.MACHINE, 1, 64)                AS MACHINE,
            SUBSTR(S.PROGRAM, 1, 48)                AS PROGRAM,
            S.BLOCKING_SESSION,
            S.BLOCKING_SESSION_STATUS               AS BLOCKING_STATUS
        FROM V$SESSION S
        CROSS JOIN
        (
            SELECT TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')) AS MY_SID
            FROM DUAL
        ) A
        WHERE S.TYPE    = 'USER'
          AND S.STATUS  = 'ACTIVE'
          AND S.SID    != A.MY_SID
          ## 모니터링 수집 계정은 고객 Top Wait 순위에서 제외한다.
          AND S.USERNAME <> 'ITSTONE'
          AND NOT (S.STATE = 'WAITING' AND S.WAIT_CLASS = 'Idle')
    ) AS1
) RANKED_SESS
WHERE WAIT_RANK <= 5
;

#################################
## 37. S_UNDO_STAT - 11분
## MERGE 로 이동
#################################


#################################
## 38. S_WAIT_EVENT - 5초
#################################
[S_WAIT_EVENT, Y, 5]
INSERT INTO ITSTONE.S_WAIT_EVENT
(
	con_id,
	event,
	wait_class,
	total_waits_cum,
	time_waited_cum,
	avg_wait_cum_cs
)
SELECT
    0                     AS CON_ID,
    e.EVENT               AS EVENT,
    e.WAIT_CLASS          AS WAIT_CLASS,
    e.TOTAL_WAITS         AS TOTAL_WAITS_CUM,
    e.TIME_WAITED         AS TIME_WAITED_CUM,
    e.AVERAGE_WAIT        AS AVG_WAIT_CUM_CS
FROM V$SYSTEM_EVENT e
WHERE e.WAIT_CLASS IS NOT NULL
  AND e.WAIT_CLASS != 'Idle'
;

#################################
## 39. S_WORKLOAD_STAT - 5초
#################################
[S_WORKLOAD_STAT, Y, 5]
INSERT INTO ITSTONE.S_WORKLOAD_STAT
(
	con_id,
	execute_cnt,
	user_commit,
	user_rollback,
	phys_read,
  phys_reads_cache,
	logical_read,
	parse_hard,
	parse_total,
	redo_size_bytes,
	user_calls
)

SELECT
    0            AS CON_ID,
    MAX(CASE WHEN NAME = 'execute count'           THEN VALUE END) AS EXECUTE_CNT,
    MAX(CASE WHEN NAME = 'user commits'            THEN VALUE END) AS USER_COMMIT,
    MAX(CASE WHEN NAME = 'user rollbacks'          THEN VALUE END) AS USER_ROLLBACK,
    MAX(CASE WHEN NAME = 'physical reads'          THEN VALUE END) AS PHYS_READ,
    MAX(CASE WHEN NAME = 'physical reads cache'    THEN VALUE END) AS PHYS_READS_CACHE,
    MAX(CASE WHEN NAME = 'session logical reads'   THEN VALUE END) AS LOGICAL_READ,
    MAX(CASE WHEN NAME = 'parse count (hard)'      THEN VALUE END) AS PARSE_HARD,
    MAX(CASE WHEN NAME = 'parse count (total)'     THEN VALUE END) AS PARSE_TOTAL,
    MAX(CASE WHEN NAME = 'redo size'               THEN VALUE END) AS REDO_SIZE_BYTES,
    MAX(CASE WHEN NAME = 'user calls'              THEN VALUE END) AS USER_CALLS
FROM V$SYSSTAT
WHERE NAME IN
(
    'execute count',
    'user commits',
    'user rollbacks',
    'physical reads',
    'physical reads cache',
    'session logical reads',
    'parse count (hard)',
    'parse count (total)',
    'redo size',
    'user calls'
)
;
