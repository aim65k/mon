# monitoring을 위한 실행 시나리오 1
# 작성규칙 
# 주석: 문장 앞 #
# 제목: '['으로 시작하고 제목 
# 사용유무:제목뒤 ',' 로 구분
# 반복주기: 사용유무뒤 ',' 로 구분
# query: [..] 다음줄 부터 공백줄이나 다음 '[' 만나기 전까지
#

#################################
## 1. S_ACTIVE_SESSION
#################################
[S_ACTIVE_SESSION, Y, 1]
INSERT INTO ITSTONE.S_ACTIVE_SESSION
(
	con_id,
	sid,
	serial_no,
	fixed_table_sequence,
	username,
	status,
	type,
	state,
	wait_class,
	event,
	wait_time_ms,
	sql_id,
	sql_child_number,
	prev_sql_id,
	prev_child_number,
	sql_exec_start,
	sql_exec_id,
	last_call_et,
	blocking_sid,
	blocking_session_status,
	final_blocking_sid,
	final_blocking_session_status,
	row_wait_obj_id,
	row_wait_file_no,
	row_wait_block_no,
	row_wait_row_no,
	module,
	action,
	program,
	machine,
	osuser,
	logon_time,
	phys_reads,
	block_gets,
	consistent_gets,
	logical_reads,
	block_changes,
	os_pid,
	pga_used_mem,
	pga_alloc_mem,
	pga_max_mem,
	xidusn,
	tx_start_time,
	used_ublk,
	used_urec
)
SELECT
    s.CON_ID,
    s.SID,
    s.SERIAL#                                                           AS SERIAL_NO,
    s.FIXED_TABLE_SEQUENCE,
    s.USERNAME,
    s.STATUS,
    s.TYPE,
    s.STATE,
    s.WAIT_CLASS,
    s.EVENT,
    CASE
        WHEN s.STATE = 'WAITING'
        THEN ROUND(s.WAIT_TIME_MICRO / 1000, 0)
        ELSE 0
    END                                                                 AS WAIT_TIME_MS,
    s.SQL_ID,
    s.SQL_CHILD_NUMBER,
    s.PREV_SQL_ID,
    s.PREV_CHILD_NUMBER,
    TO_CHAR(s.SQL_EXEC_START, 'YYYY-MM-DD HH24:MI:SS')                    AS SQL_EXEC_START,
    s.SQL_EXEC_ID,
    s.LAST_CALL_ET,
    s.BLOCKING_SESSION                                                  AS BLOCKING_SID,
    s.BLOCKING_SESSION_STATUS,
    s.FINAL_BLOCKING_SESSION                                            AS FINAL_BLOCKING_SID,
    s.FINAL_BLOCKING_SESSION_STATUS,
    s.ROW_WAIT_OBJ#                                                     AS ROW_WAIT_OBJ_ID,
    s.ROW_WAIT_FILE#                                                    AS ROW_WAIT_FILE_NO,
    s.ROW_WAIT_BLOCK#                                                   AS ROW_WAIT_BLOCK_NO,
    s.ROW_WAIT_ROW#                                                     AS ROW_WAIT_ROW_NO,
    s.MODULE,
    s.ACTION,
    s.PROGRAM,
    s.MACHINE,
    s.OSUSER,
    TO_CHAR(s.LOGON_TIME, 'YYYY-MM-DD HH24:MI:SS')                          AS LOGON_TIME,
    NVL(io.PHYSICAL_READS,  0)                                         AS PHYS_READS,
    NVL(io.BLOCK_GETS,      0)                                         AS BLOCK_GETS,
    NVL(io.CONSISTENT_GETS, 0)                                         AS CONSISTENT_GETS,
    NVL(io.BLOCK_GETS, 0) + NVL(io.CONSISTENT_GETS, 0)                AS LOGICAL_READS,
    NVL(io.BLOCK_CHANGES,   0)                                         AS BLOCK_CHANGES,
    p.SPID                                                              AS OS_PID,
    p.PGA_USED_MEM,
    p.PGA_ALLOC_MEM,
    p.PGA_MAX_MEM,
    tx.XIDUSN,
    TO_CHAR(TO_DATE(tx.START_TIME,'MM/DD/YY HH24:MI:SS'),'YYYY-MM-DD HH24:MI:SS') AS TX_START_TIME,
    NVL(tx.USED_UBLK, 0)                                               AS USED_UBLK,
    NVL(tx.USED_UREC, 0)                                               AS USED_UREC
FROM V$SESSION s
LEFT JOIN V$SESS_IO io
       ON io.SID = s.SID
LEFT JOIN V$PROCESS p
       ON p.ADDR = s.PADDR
LEFT JOIN V$TRANSACTION tx
       ON tx.ADDR = s.TADDR
CROSS JOIN
(
    SELECT TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')) AS AGENT_SID
    FROM DUAL
) agent
WHERE s.STATUS = 'ACTIVE'
  AND s.TYPE   = 'USER'
  AND s.SID   <> agent.AGENT_SID
  ## 모니터링(수집) 계정 제외: 실시간/스캐터에서 ITSTONE 노이즈 방지
  AND s.USERNAME <> 'ITSTONE'
;

#################################
## 2. S_ACTIVE_SESSION_DETAIL
#################################
[S_ACTIVE_SESSION_DETAIL, Y, 5]
INSERT INTO S_ACTIVE_SESSION_DETAIL
(
	con_id,
	sid,
	serial_no,
	container_name,
	service_name,
	sql_id,
	sql_child_number,
	exec_count_cum,
	cpu_used_cum,
	wait_time_ms,
	module,
	action,
	program,
	machine,
	osuser,
	logon_time,
	client_info
)
SELECT
    s.CON_ID,
    s.SID,
    s.SERIAL#                                                   AS SERIAL_NO,
    NVL(SYS_CONTEXT('USERENV', 'DB_NAME'), 'NON-CDB')          AS CONTAINER_NAME,
    NVL(s.SERVICE_NAME, 'N/A')                                 AS SERVICE_NAME,
    s.SQL_ID,
    s.SQL_CHILD_NUMBER,
    NVL(st.EXEC_COUNT_CUM, 0)                                  AS EXEC_COUNT_CUM,
    ROUND(NVL(tm.VALUE, 0) / 10000, 2)                         AS CPU_USED_CUM,
    CASE
        WHEN s.STATE = 'WAITING'
        THEN ROUND(s.WAIT_TIME_MICRO / 1000, 0)
        ELSE 0
    END                                                        AS WAIT_TIME_MS,
    s.MODULE,
    s.ACTION,
    s.PROGRAM,
    s.MACHINE,
    s.OSUSER,
    TO_CHAR(s.LOGON_TIME, 'YYYY-MM-DD HH24:MI:SS') AS LOGON_TIME,
    SUBSTR(s.CLIENT_INFO, 1, 64)                               AS CLIENT_INFO
FROM V$SESSION s
LEFT JOIN
(
    SELECT
        ss.SID,
        MAX(ss.VALUE) AS EXEC_COUNT_CUM
    FROM V$SESSTAT ss
    JOIN V$STATNAME sn
      ON sn.STATISTIC# = ss.STATISTIC#
    WHERE sn.NAME = 'execute count'
    GROUP BY ss.SID
) st
       ON st.SID = s.SID
LEFT JOIN V$SESS_TIME_MODEL tm
       ON tm.SID = s.SID
      AND tm.STAT_NAME = 'DB CPU'
CROSS JOIN
(
    SELECT TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')) AS AGENT_SID
    FROM DUAL
) agent
WHERE s.STATUS = 'ACTIVE'
  AND s.TYPE   = 'USER'
  AND s.SID   <> agent.AGENT_SID
  ## 모니터링(수집) 계정 제외: 실시간/스캐터에서 ITSTONE 노이즈 방지
  AND s.USERNAME <> 'ITSTONE'
;

#################################
## 3. S_ALERT_LOG
## MERGE 문 제거
#################################


#################################
## 4. S_ARCHIVE_DEST
#################################
[S_ARCHIVE_DEST, Y, 60]
INSERT INTO S_ARCHIVE_DEST
(
	con_id,
	log_mode,
	database_role,
	open_mode,
	dest_id,
	dest_name,
	dest_status,
	runtime_status,
	target,
	dest_type,
	param_type,
	database_mode,
	recovery_mode,
	protection_mode,
	destination,
	archiver,
	process,
	schedule,
	binding,
	transmit_mode,
	affirm,
	valid_now,
	valid_type,
	valid_role,
	db_unique_name,
	error_msg,
	fail_date,
	fail_sequence,
	failure_count,
	reopen_secs,
	log_sequence,
	archived_thread_no,
	archived_seq_no,
	applied_thread_no,
	applied_seq_no,
	synchronization_status,
	synchronized,
	gap_status,
	srl,
	quota_size_mb,
	quota_used_mb
)
SELECT
    0                                                         AS CON_ID,          
    DB.LOG_MODE                                               AS LOG_MODE,        
    DB.DATABASE_ROLE                                          AS DATABASE_ROLE,   
    DB.OPEN_MODE                                              AS OPEN_MODE,       
    D.DEST_ID                                                 AS DEST_ID,         
    D.DEST_NAME                                               AS DEST_NAME,       
    D.STATUS                                                  AS DEST_STATUS,     
    S.STATUS                                                  AS RUNTIME_STATUS,  
    D.TARGET                                                  AS TARGET,          
    S.TYPE                                                    AS DEST_TYPE,       
    D.NAME_SPACE                                              AS PARAM_TYPE,      
    S.DATABASE_MODE                                           AS DATABASE_MODE,   
    S.RECOVERY_MODE                                           AS RECOVERY_MODE,   
    S.PROTECTION_MODE                                         AS PROTECTION_MODE, 
    NVL(D.DESTINATION, S.DESTINATION)                        AS DESTINATION,      
    D.ARCHIVER                                                AS ARCHIVER,        
    D.PROCESS                                                 AS PROCESS,         
    D.SCHEDULE                                                AS SCHEDULE,        
    D.BINDING                                                 AS BINDING,         
    D.TRANSMIT_MODE                                           AS TRANSMIT_MODE,   
    D.AFFIRM                                                  AS AFFIRM,          
    D.VALID_NOW                                               AS VALID_NOW,       
    D.VALID_TYPE                                              AS VALID_TYPE,      
    D.VALID_ROLE                                              AS VALID_ROLE,      
    NVL(D.DB_UNIQUE_NAME, S.DB_UNIQUE_NAME)                  AS DB_UNIQUE_NAME,   
    SUBSTR
    (
        CASE
            WHEN D.ERROR IS NOT NULL AND S.ERROR IS NOT NULL
            THEN D.ERROR || ' / ' || S.ERROR
            ELSE NVL(D.ERROR, S.ERROR)
        END,
        1, 1000
    )                                                         AS ERROR_MSG,         
    TO_CHAR(D.FAIL_DATE, 'YYYY-MM-DD HH24:MI:SS')             AS FAIL_DATE,         
    D.FAIL_SEQUENCE                                           AS FAIL_SEQUENCE,     
    D.FAILURE_COUNT                                           AS FAILURE_COUNT,     
    D.REOPEN_SECS                                             AS REOPEN_SECS,       
    D.LOG_SEQUENCE                                            AS LOG_SEQUENCE,      
    S.ARCHIVED_THREAD#                                        AS ARCHIVED_THREAD_NO,
    S.ARCHIVED_SEQ#                                           AS ARCHIVED_SEQ_NO,   
    S.APPLIED_THREAD#                                         AS APPLIED_THREAD_NO, 
    S.APPLIED_SEQ#                                            AS APPLIED_SEQ_NO,    
    S.SYNCHRONIZATION_STATUS                                  AS SYNCHRONIZATION_STATUS,
    S.SYNCHRONIZED                                            AS SYNCHRONIZED,    
    S.GAP_STATUS                                              AS GAP_STATUS,      
    S.SRL                                                     AS SRL,             
    ROUND(D.QUOTA_SIZE / 1048576, 2)                         AS QUOTA_SIZE_MB,    
    ROUND(D.QUOTA_USED / 1048576, 2)                         AS QUOTA_USED_MB     
FROM V$ARCHIVE_DEST D
LEFT JOIN V$ARCHIVE_DEST_STATUS S
       ON S.DEST_ID = D.DEST_ID
CROSS JOIN V$DATABASE DB
WHERE D.DEST_ID BETWEEN 1 AND 31
  AND
  (
        D.STATUS      <> 'INACTIVE'
     OR S.STATUS      <> 'INACTIVE'
     OR D.DESTINATION IS NOT NULL
     OR S.DESTINATION IS NOT NULL
     OR D.ERROR       IS NOT NULL
     OR S.ERROR       IS NOT NULL
  )
;

#################################
## 5. S_BLOCKING_TX
#################################
[S_BLOCKING_TX, Y, 5]
INSERT INTO S_BLOCKING_TX
(
	con_id,
	xidusn,
	xidslot,
	xidsqn,
	addr,
	sid,
	serial_no,
	username,
	status,
	sql_id,
	module,
	machine,
	program,
	logon_time,
	start_time,
	used_ublk,
	used_urec,
	log_io,
	phy_io,
	cr_get,
	cr_change,
	elapsed_sec,
	waiter_count
)
SELECT
    NVL(T.CON_ID, 0) AS CON_ID,
    T.XIDUSN,
    T.XIDSLOT,
    T.XIDSQN,
    RAWTOHEX(T.ADDR)                AS ADDR,
    S.SID,
    S.SERIAL#        AS SERIAL_NO,
    S.USERNAME,
    S.STATUS,
    NVL(S.SQL_ID, S.PREV_SQL_ID) AS SQL_ID,
    S.MODULE,
    S.MACHINE,
    S.PROGRAM,
    TO_CHAR(S.LOGON_TIME, 'YYYY-MM-DD HH24:MI:SS') AS LOGON_TIME,
    TO_CHAR(TO_DATE(T.START_TIME,'MM/DD/YY HH24:MI:SS'),'YYYY-MM-DD HH24:MI:SS') AS START_TIME,
    T.USED_UBLK,
    T.USED_UREC,
    T.LOG_IO,
    T.PHY_IO,
    T.CR_GET,
    T.CR_CHANGE,
    ROUND((SYSDATE - TO_DATE(T.START_TIME, 'MM/DD/YY HH24:MI:SS')) * 86400) AS ELAPSED_SEC,
    NVL(W.WAITER_COUNT, 0)                                                  AS WAITER_COUNT
FROM V$TRANSACTION T
JOIN V$SESSION S ON S.TADDR = T.ADDR
                AND S.TYPE  = 'USER'
LEFT JOIN (
    SELECT BLOCKING_SESSION AS HOLDER_SID,
           COUNT(*)         AS WAITER_COUNT
    FROM V$SESSION
    WHERE BLOCKING_SESSION IS NOT NULL
    GROUP BY BLOCKING_SESSION
) W ON W.HOLDER_SID = S.SID
;

#################################
## 6. S_BUFFER_CACHE_STAT -5분주기
#################################
[S_BUFFER_CACHE_STAT, Y, 300]
INSERT INTO S_BUFFER_CACHE_STAT
(
	con_id,
	pool_name,
	block_size,
	set_msize,
	buffers_total,
	physical_reads_cum,
	physical_writes_cum,
	free_buffer_wait_cum,
	write_complete_wait_cum,
	buffer_busy_wait_cum,
	free_buf_inspected_cum,
	dirty_buf_inspected_cum,
	db_block_change_cum,
	db_block_get_cum,
	consistent_get_cum
)
SELECT
    0 AS CON_ID,
    NAME                        AS POOL_NAME,
    BLOCK_SIZE,
    SET_MSIZE,
    CNUM_SET                    AS BUFFERS_TOTAL,
    PHYSICAL_READS              AS PHYSICAL_READS_CUM,
    PHYSICAL_WRITES             AS PHYSICAL_WRITES_CUM,
    FREE_BUFFER_WAIT            AS FREE_BUFFER_WAIT_CUM,
    WRITE_COMPLETE_WAIT         AS WRITE_COMPLETE_WAIT_CUM,
    BUFFER_BUSY_WAIT            AS BUFFER_BUSY_WAIT_CUM,
    FREE_BUFFER_INSPECTED       AS FREE_BUF_INSPECTED_CUM,
    DIRTY_BUFFERS_INSPECTED     AS DIRTY_BUF_INSPECTED_CUM,
    DB_BLOCK_CHANGE             AS DB_BLOCK_CHANGE_CUM,
    DB_BLOCK_GETS               AS DB_BLOCK_GET_CUM,
    CONSISTENT_GETS             AS CONSISTENT_GET_CUM
FROM V$BUFFER_POOL_STATISTICS
;
 
#################################
## 7. S_DATABASE_INFO - 1일
#################################
[S_DATABASE_INFO, Y, 86400]
INSERT INTO S_DATABASE_INFO
(
	con_id,
	db_name,
	db_unique_name,
	created,
	log_mode,
	open_mode,
	database_role,
	force_logging,
	flashback_on,
	protection_mode,
	protection_level,
	switchover_status,
	dataguard_broker,
	guard_status,
	platform_id,
	platform_name,
	cdb,
	current_scn,
	controlfile_type,
	open_resetlogs,
	resetlogs_change_no,
	resetlogs_time,
	instance_number,
	instance_name,
	host_name,
	version,
	startup_time,
	instance_status,
	parallel,
	thread_no,
	archiver,
	log_switch_wait,
	logins,
	shutdown_pending,
	database_status,
	instance_role,
	active_state,
	blocked
)
SELECT
    0                     AS CON_ID,
    D.NAME                AS DB_NAME,
    D.DB_UNIQUE_NAME      AS DB_UNIQUE_NAME,
    TO_CHAR(D.CREATED, 'YYYY-MM-DD HH24:MI:SS') AS CREATED,
    D.LOG_MODE            AS LOG_MODE,
    D.OPEN_MODE           AS OPEN_MODE,
    D.DATABASE_ROLE       AS DATABASE_ROLE,
    D.FORCE_LOGGING       AS FORCE_LOGGING,
    D.FLASHBACK_ON        AS FLASHBACK_ON,
    D.PROTECTION_MODE     AS PROTECTION_MODE,
    D.PROTECTION_LEVEL    AS PROTECTION_LEVEL,
    D.SWITCHOVER_STATUS   AS SWITCHOVER_STATUS,
    D.DATAGUARD_BROKER    AS DATAGUARD_BROKER,
    D.GUARD_STATUS        AS GUARD_STATUS,
    D.PLATFORM_ID         AS PLATFORM_ID,
    D.PLATFORM_NAME       AS PLATFORM_NAME,
    D.CDB                 AS CDB,
    D.CURRENT_SCN         AS CURRENT_SCN,
    D.CONTROLFILE_TYPE    AS CONTROLFILE_TYPE,
    D.OPEN_RESETLOGS      AS OPEN_RESETLOGS,
    D.RESETLOGS_CHANGE#   AS RESETLOGS_CHANGE_NO,
    TO_CHAR(D.RESETLOGS_TIME, 'YYYY-MM-DD HH24:MI:SS') AS RESETLOGS_TIME,
    I.INSTANCE_NUMBER     AS INSTANCE_NUMBER,
    I.INSTANCE_NAME       AS INSTANCE_NAME,
    I.HOST_NAME           AS HOST_NAME,
    I.VERSION_FULL        AS VERSION,
    TO_CHAR(I.STARTUP_TIME, 'YYYY-MM-DD HH24:MI:SS') AS STARTUP_TIME,
    I.STATUS              AS INSTANCE_STATUS,
    I.PARALLEL            AS PARALLEL,
    I.THREAD#             AS THREAD_NO,
    I.ARCHIVER            AS ARCHIVER,
    I.LOG_SWITCH_WAIT     AS LOG_SWITCH_WAIT,
    I.LOGINS              AS LOGINS,
    I.SHUTDOWN_PENDING    AS SHUTDOWN_PENDING,
    I.DATABASE_STATUS     AS DATABASE_STATUS,
    I.INSTANCE_ROLE       AS INSTANCE_ROLE,
    I.ACTIVE_STATE        AS ACTIVE_STATE,
    I.BLOCKED             AS BLOCKED
FROM V$DATABASE D
CROSS JOIN V$INSTANCE I
;

#################################
## 8. S_DATAFILE_IO - 30초
#################################
[S_DATAFILE_IO, Y, 30]
INSERT INTO S_DATAFILE_IO
(
	con_id,
	file_type,
	file_no,
	tablespace_name,
	file_name,
	phyrds_cum,
	phyblkrd_cum,
	readtim_cum,
	singleblkrds_cum,
	singleblkrdtim_cum,
	phywrts_cum,
	phyblkwrt_cum,
	writetim_cum
)
SELECT
    0                           AS CON_ID,
    'DATAFILE'                  AS FILE_TYPE,
    F.FILE#                     AS FILE_NO,
    DF.TABLESPACE_NAME          AS TABLESPACE_NAME,
    DF.FILE_NAME                AS FILE_NAME,
    NVL(F.PHYRDS,          0)   AS PHYRDS_CUM,
    NVL(F.PHYBLKRD,        0)   AS PHYBLKRD_CUM,
    NVL(F.READTIM,         0)   AS READTIM_CUM,
    NVL(F.SINGLEBLKRDS,    0)   AS SINGLEBLKRDS_CUM,
    NVL(F.SINGLEBLKRDTIM,  0)   AS SINGLEBLKRDTIM_CUM,
    NVL(F.PHYWRTS,         0)   AS PHYWRTS_CUM,
    NVL(F.PHYBLKWRT,       0)   AS PHYBLKWRT_CUM,
    NVL(F.WRITETIM,        0)   AS WRITETIM_CUM
FROM V$FILESTAT F
LEFT JOIN DBA_DATA_FILES DF
  ON DF.FILE_ID = F.FILE#
UNION ALL
SELECT
    0                           AS CON_ID,
    'TEMPFILE'                  AS FILE_TYPE,
    T.FILE#                     AS FILE#,
    TF.TABLESPACE_NAME          AS TABLESPACE_NAME,
    TF.FILE_NAME                AS FILE_NAME,
    NVL(T.PHYRDS,          0)   AS PHYRDS_CUM,
    NVL(T.PHYBLKRD,        0)   AS PHYBLKRD_CUM,
    NVL(T.READTIM,         0)   AS READTIM_CUM,
    NVL(T.SINGLEBLKRDS,    0)   AS SINGLEBLKRDS_CUM,
    NVL(T.SINGLEBLKRDTIM,  0)   AS SINGLEBLKRDTIM_CUM,
    NVL(T.PHYWRTS,         0)   AS PHYWRTS_CUM,
    NVL(T.PHYBLKWRT,       0)   AS PHYBLKWRT_CUM,
    NVL(T.WRITETIM,        0)   AS WRITETIM_CUM
FROM V$TEMPSTAT T
LEFT JOIN DBA_TEMP_FILES TF
  ON TF.FILE_ID = T.FILE#
;
#################################
## 9. S_DICCACHE_STAT - 30초
#################################
[S_DICCACHE_STAT, Y, 30]
INSERT INTO S_DICCACHE_STAT
(
	con_id,
	gets_cum,
	getmisses_cum
)
SELECT
    0                  AS CON_ID,
    SUM(R.GETS)        AS GETS_CUM,
    SUM(R.GETMISSES)   AS GETMISSES_CUM
FROM V$ROWCACHE R
WHERE R.GETS > 0
;

#################################
## 10. S_FRA_USAGE - 5분
#################################
[S_FRA_USAGE, Y, 300]
INSERT INTO S_FRA_USAGE
(
	con_id,
	fra_dest_name,
	space_limit_bytes,
	space_used_bytes,
	space_reclaimable_bytes,
	space_available_bytes,
	used_pct,
	reclaimable_pct,
	available_pct,
	total_file_count,
	archived_log_used_pct,
	archived_log_reclaimable_pct,
	archived_log_file_count,
	backup_piece_used_pct,
	backup_piece_reclaimable_pct,
	backup_piece_file_count,
	flashback_log_used_pct,
	flashback_log_reclaimable_pct,
	flashback_log_file_count,
	image_copy_used_pct,
	image_copy_reclaimable_pct,
	image_copy_file_count,
	control_file_used_pct,
	control_file_reclaimable_pct,
	control_file_file_count,
	redo_log_used_pct,
	redo_log_reclaimable_pct,
	redo_log_file_count,
	foreign_archived_log_used_pct,
	foreign_archived_log_reclaimable_pct,
	foreign_archived_log_file_count,
	other_used_pct,
	other_reclaimable_pct,
	other_file_count
)
SELECT
    RFD.CON_ID                                                              AS CON_ID,
    RFD.FRA_DEST_NAME,
    RFD.SPACE_LIMIT_BYTES,
    RFD.SPACE_USED_BYTES,
    RFD.SPACE_RECLAIMABLE_BYTES,
    CASE
        WHEN RFD.SPACE_LIMIT_BYTES > 0
        THEN RFD.SPACE_LIMIT_BYTES - RFD.SPACE_USED_BYTES + RFD.SPACE_RECLAIMABLE_BYTES
        ELSE NULL
    END                                                                     AS SPACE_AVAILABLE_BYTES,
    CASE
        WHEN RFD.SPACE_LIMIT_BYTES > 0
        THEN ROUND(RFD.SPACE_USED_BYTES / RFD.SPACE_LIMIT_BYTES * 100, 2)
        ELSE NULL
    END                                                                     AS USED_PCT,
    CASE
        WHEN RFD.SPACE_LIMIT_BYTES > 0
        THEN ROUND(RFD.SPACE_RECLAIMABLE_BYTES / RFD.SPACE_LIMIT_BYTES * 100, 2)
        ELSE NULL
    END                                                                     AS RECLAIMABLE_PCT,
    CASE
        WHEN RFD.SPACE_LIMIT_BYTES > 0
        THEN ROUND(
                 (RFD.SPACE_LIMIT_BYTES - RFD.SPACE_USED_BYTES + RFD.SPACE_RECLAIMABLE_BYTES)
                 / RFD.SPACE_LIMIT_BYTES * 100, 2)
        ELSE NULL
    END                                                                     AS AVAILABLE_PCT,
    RFD.TOTAL_FILE_COUNT,
    NVL(FAU.ARCHIVED_LOG_USED_PCT,                0)                       AS ARCHIVED_LOG_USED_PCT,
    NVL(FAU.ARCHIVED_LOG_RECLAIMABLE_PCT,         0)                       AS ARCHIVED_LOG_RECLAIMABLE_PCT,
    NVL(FAU.ARCHIVED_LOG_FILE_COUNT,              0)                       AS ARCHIVED_LOG_FILE_COUNT,
    NVL(FAU.BACKUP_PIECE_USED_PCT,                0)                       AS BACKUP_PIECE_USED_PCT,
    NVL(FAU.BACKUP_PIECE_RECLAIMABLE_PCT,         0)                       AS BACKUP_PIECE_RECLAIMABLE_PCT,
    NVL(FAU.BACKUP_PIECE_FILE_COUNT,              0)                       AS BACKUP_PIECE_FILE_COUNT,
    NVL(FAU.FLASHBACK_LOG_USED_PCT,               0)                       AS FLASHBACK_LOG_USED_PCT,
    NVL(FAU.FLASHBACK_LOG_RECLAIMABLE_PCT,        0)                       AS FLASHBACK_LOG_RECLAIMABLE_PCT,
    NVL(FAU.FLASHBACK_LOG_FILE_COUNT,             0)                       AS FLASHBACK_LOG_FILE_COUNT,
    NVL(FAU.IMAGE_COPY_USED_PCT,                  0)                       AS IMAGE_COPY_USED_PCT,
    NVL(FAU.IMAGE_COPY_RECLAIMABLE_PCT,           0)                       AS IMAGE_COPY_RECLAIMABLE_PCT,
    NVL(FAU.IMAGE_COPY_FILE_COUNT,                0)                       AS IMAGE_COPY_FILE_COUNT,
    NVL(FAU.CONTROL_FILE_USED_PCT,                0)                       AS CONTROL_FILE_USED_PCT,
    NVL(FAU.CONTROL_FILE_RECLAIMABLE_PCT,         0)                       AS CONTROL_FILE_RECLAIMABLE_PCT,
    NVL(FAU.CONTROL_FILE_FILE_COUNT,              0)                       AS CONTROL_FILE_FILE_COUNT,
    NVL(FAU.REDO_LOG_USED_PCT,                    0)                       AS REDO_LOG_USED_PCT,
    NVL(FAU.REDO_LOG_RECLAIMABLE_PCT,             0)                       AS REDO_LOG_RECLAIMABLE_PCT,
    NVL(FAU.REDO_LOG_FILE_COUNT,                  0)                       AS REDO_LOG_FILE_COUNT,
    NVL(FAU.FOREIGN_ARCHIVED_LOG_USED_PCT,        0)                       AS FOREIGN_ARCHIVED_LOG_USED_PCT,
    NVL(FAU.FOREIGN_ARCHIVED_LOG_RECLAIMABLE_PCT, 0)                       AS FOREIGN_ARCHIVED_LOG_RECLAIMABLE_PCT,
    NVL(FAU.FOREIGN_ARCHIVED_LOG_FILE_COUNT,      0)                       AS FOREIGN_ARCHIVED_LOG_FILE_COUNT,
    NVL(FAU.OTHER_USED_PCT,                       0)                       AS OTHER_USED_PCT,
    NVL(FAU.OTHER_RECLAIMABLE_PCT,                0)                       AS OTHER_RECLAIMABLE_PCT,
    NVL(FAU.OTHER_FILE_COUNT,                     0)                       AS OTHER_FILE_COUNT
FROM
(
    SELECT
        NVL(CON_ID, 0)    AS CON_ID,
        NAME              AS FRA_DEST_NAME,
        SPACE_LIMIT       AS SPACE_LIMIT_BYTES,
        SPACE_USED        AS SPACE_USED_BYTES,
        SPACE_RECLAIMABLE AS SPACE_RECLAIMABLE_BYTES,
        NUMBER_OF_FILES   AS TOTAL_FILE_COUNT
    FROM V$RECOVERY_FILE_DEST
    WHERE SPACE_LIMIT > 0
) RFD
LEFT JOIN
(
    SELECT
        NVL(CON_ID, 0)                                                      AS CON_ID,
        MAX(CASE WHEN FILE_TYPE = 'ARCHIVED LOG'        THEN PERCENT_SPACE_USED        END) AS ARCHIVED_LOG_USED_PCT,
        MAX(CASE WHEN FILE_TYPE = 'ARCHIVED LOG'        THEN PERCENT_SPACE_RECLAIMABLE END) AS ARCHIVED_LOG_RECLAIMABLE_PCT,
        MAX(CASE WHEN FILE_TYPE = 'ARCHIVED LOG'        THEN NUMBER_OF_FILES           END) AS ARCHIVED_LOG_FILE_COUNT,
        MAX(CASE WHEN FILE_TYPE = 'BACKUP PIECE'        THEN PERCENT_SPACE_USED        END) AS BACKUP_PIECE_USED_PCT,
        MAX(CASE WHEN FILE_TYPE = 'BACKUP PIECE'        THEN PERCENT_SPACE_RECLAIMABLE END) AS BACKUP_PIECE_RECLAIMABLE_PCT,
        MAX(CASE WHEN FILE_TYPE = 'BACKUP PIECE'        THEN NUMBER_OF_FILES           END) AS BACKUP_PIECE_FILE_COUNT,
        MAX(CASE WHEN FILE_TYPE = 'FLASHBACK LOG'       THEN PERCENT_SPACE_USED        END) AS FLASHBACK_LOG_USED_PCT,
        MAX(CASE WHEN FILE_TYPE = 'FLASHBACK LOG'       THEN PERCENT_SPACE_RECLAIMABLE END) AS FLASHBACK_LOG_RECLAIMABLE_PCT,
        MAX(CASE WHEN FILE_TYPE = 'FLASHBACK LOG'       THEN NUMBER_OF_FILES           END) AS FLASHBACK_LOG_FILE_COUNT,
        MAX(CASE WHEN FILE_TYPE = 'IMAGE COPY'          THEN PERCENT_SPACE_USED        END) AS IMAGE_COPY_USED_PCT,
        MAX(CASE WHEN FILE_TYPE = 'IMAGE COPY'          THEN PERCENT_SPACE_RECLAIMABLE END) AS IMAGE_COPY_RECLAIMABLE_PCT,
        MAX(CASE WHEN FILE_TYPE = 'IMAGE COPY'          THEN NUMBER_OF_FILES           END) AS IMAGE_COPY_FILE_COUNT,
        MAX(CASE WHEN FILE_TYPE = 'CONTROL FILE'        THEN PERCENT_SPACE_USED        END) AS CONTROL_FILE_USED_PCT,
        MAX(CASE WHEN FILE_TYPE = 'CONTROL FILE'        THEN PERCENT_SPACE_RECLAIMABLE END) AS CONTROL_FILE_RECLAIMABLE_PCT,
        MAX(CASE WHEN FILE_TYPE = 'CONTROL FILE'        THEN NUMBER_OF_FILES           END) AS CONTROL_FILE_FILE_COUNT,
        MAX(CASE WHEN FILE_TYPE = 'REDO LOG'            THEN PERCENT_SPACE_USED        END) AS REDO_LOG_USED_PCT,
        MAX(CASE WHEN FILE_TYPE = 'REDO LOG'            THEN PERCENT_SPACE_RECLAIMABLE END) AS REDO_LOG_RECLAIMABLE_PCT,
        MAX(CASE WHEN FILE_TYPE = 'REDO LOG'            THEN NUMBER_OF_FILES           END) AS REDO_LOG_FILE_COUNT,
        MAX(CASE WHEN FILE_TYPE = 'FOREIGN ARCHIVED LOG' THEN PERCENT_SPACE_USED        END) AS FOREIGN_ARCHIVED_LOG_USED_PCT,
        MAX(CASE WHEN FILE_TYPE = 'FOREIGN ARCHIVED LOG' THEN PERCENT_SPACE_RECLAIMABLE END) AS FOREIGN_ARCHIVED_LOG_RECLAIMABLE_PCT,
        MAX(CASE WHEN FILE_TYPE = 'FOREIGN ARCHIVED LOG' THEN NUMBER_OF_FILES           END) AS FOREIGN_ARCHIVED_LOG_FILE_COUNT,
        SUM(CASE
                WHEN FILE_TYPE NOT IN
                     ('ARCHIVED LOG', 'BACKUP PIECE', 'FLASHBACK LOG', 'IMAGE COPY',
                      'CONTROL FILE', 'REDO LOG', 'FOREIGN ARCHIVED LOG')
                THEN PERCENT_SPACE_USED    ELSE 0
            END)                                                             AS OTHER_USED_PCT,
        SUM(CASE
                WHEN FILE_TYPE NOT IN
                     ('ARCHIVED LOG', 'BACKUP PIECE', 'FLASHBACK LOG', 'IMAGE COPY',
                      'CONTROL FILE', 'REDO LOG', 'FOREIGN ARCHIVED LOG')
                THEN PERCENT_SPACE_RECLAIMABLE ELSE 0
            END)                                                             AS OTHER_RECLAIMABLE_PCT,
        SUM(CASE
                WHEN FILE_TYPE NOT IN
                     ('ARCHIVED LOG', 'BACKUP PIECE', 'FLASHBACK LOG', 'IMAGE COPY',
                      'CONTROL FILE', 'REDO LOG', 'FOREIGN ARCHIVED LOG')
                THEN NUMBER_OF_FILES       ELSE 0
            END)                                                             AS OTHER_FILE_COUNT
    FROM V$RECOVERY_AREA_USAGE
    GROUP BY NVL(CON_ID, 0)
) FAU
  ON FAU.CON_ID = RFD.CON_ID
;

#################################
## 11. S_INSTANCE_STATUS - 5초
#################################
[S_INSTANCE_STATUS, Y, 5]
INSERT INTO S_INSTANCE_STATUS
(
	con_id,
	instance_name,
	host_name,
	version,
	status,
	database_status,
	logins,
	startup_time,
	uptime_hours,
	proc_current,
	proc_max,
	proc_max_utilization,
	proc_max_utilization_daily,
	proc_headroom,
	proc_usage_pct,
	active_session,
	long_idle_session,
	sess_current,
	sess_max,
	sess_max_utilization,
	sess_max_utilization_daily,
	sess_headroom,
	sess_usage_pct
)
SELECT
    0                                                                   AS CON_ID,
    I.INSTANCE_NAME,
    I.HOST_NAME,
    I.VERSION_FULL,
    I.STATUS,
    I.DATABASE_STATUS,
    I.LOGINS,
    TO_CHAR(I.STARTUP_TIME, 'YYYY-MM-DD HH24:MI:SS') AS STARTUP_TIME,
    ROUND((SYSDATE - I.STARTUP_TIME) * 24, 1)                         AS UPTIME_HOURS,
    R.PROC_CURRENT,
    R.PROC_MAX,
    NULL                                                                AS PROC_MAX_UTILIZATION,
    NULL                                                                AS PROC_MAX_UTILIZATION_DAILY,
    R.PROC_MAX - R.PROC_CURRENT                                        AS PROC_HEADROOM,
    ROUND(R.PROC_CURRENT * 100 / NULLIF(R.PROC_MAX, 0), 2)            AS PROC_USAGE_PCT,
    A.ACTIVE_SESSION,
    A.LONG_IDLE_SESSION,
    R.SESS_CURRENT,
    R.SESS_MAX,
    NULL                                                                AS SESS_MAX_UTILIZATION,
    NULL                                                                AS SESS_MAX_UTILIZATION_DAILY,
    R.SESS_MAX - R.SESS_CURRENT                                        AS SESS_HEADROOM,
    ROUND(R.SESS_CURRENT * 100 / NULLIF(R.SESS_MAX, 0), 2)            AS SESS_USAGE_PCT
FROM V$INSTANCE I
CROSS JOIN
(
    SELECT
        MAX(CASE WHEN RESOURCE_NAME = 'processes'
                 THEN CURRENT_UTILIZATION END)                         AS PROC_CURRENT,
        MAX(CASE WHEN RESOURCE_NAME = 'processes'
                 THEN TO_NUMBER(TRIM(LIMIT_VALUE)) END)                AS PROC_MAX,
        MAX(CASE WHEN RESOURCE_NAME = 'sessions'
                 THEN CURRENT_UTILIZATION END)                         AS SESS_CURRENT,
        MAX(CASE WHEN RESOURCE_NAME = 'sessions'
                 THEN TO_NUMBER(TRIM(LIMIT_VALUE)) END)                AS SESS_MAX
    FROM V$RESOURCE_LIMIT
    WHERE RESOURCE_NAME IN ('processes', 'sessions')
      AND NVL(CON_ID, 0) = 0
) R
CROSS JOIN
(
    SELECT
        COUNT(CASE WHEN STATUS = 'ACTIVE'   AND TYPE = 'USER'
                    AND SID <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))
                   THEN 1 END)                                         AS ACTIVE_SESSION,
        COUNT(CASE WHEN STATUS = 'INACTIVE' AND TYPE = 'USER'
                    AND LAST_CALL_ET >= 1800
                    AND SID <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))
                   THEN 1 END)                                         AS LONG_IDLE_SESSION
    FROM V$SESSION
) A
;

#################################
## 11-1. S_INVALID_OBJECT - 1일
##
## 소스 : DBA_INVALID_OBJECTS
##
## ★수집주기 1일인 이유
##   Invalid Object 는 DDL/패치 뒤에 생기는 '상태' 지표라 초단위 추적이 무의미하다.
##   반면 DBA_INVALID_OBJECTS 는 딕셔너리 조회가 필요하므로 1일 1회로 충분하다.
##   정기점검(주/월) 용도엔 1일 1회로 충분하다. S_PARAMETER_SNAPSHOT 과 동일 정책.
##
## ★상세행이 아니라 "요약 1행" 을 적재한다 (S_RECOVER_FILE 과 같은 이유)
##   0건일 때도 행이 남아야 "수집됨+0건(정상)" 과 "미수집(이상)" 이 구분된다.
##
## ★APP_INVALID_CNT 를 따로 세는 이유
##   SYS/SYSTEM 등 오라클 내장 스키마의 INVALID 는 패치 직후 흔하고 DBA 가
##   손댈 수 없는 경우가 많다. 업무 스키마의 INVALID 만 즉시 조치 대상이므로 분리한다.
##
## ★★[사고 기록 — 2026-07-16] LISTAGG / ON OVERFLOW TRUNCATE 사용 금지
##   최초 작성 시 object_list 를 LISTAGG(... ON OVERFLOW TRUNCATE '...' WITHOUT COUNT) 로
##   담으려 했으나, 에이전트가 이 구문에서 SQL 을 잘라먹어 기동 자체가 실패했다:
##     E oracle_dbd.c [S_INVALID_OBJECT] OCIStmtExecute DESCRIBE_ONLY failed,
##       sql_text:[WITHOUT COUNT) WITHIN GROUP (ORDER BY O.OWNER, ...]
##       ORA-24333: 반복 카운트가 영입니다
##   → 오라클에 보낸 SQL 이 "ON OVERFLOW TRUNCATE '...'" 직후부터 시작했다.
##     즉 그 앞의 SELECT ... SUBSTR(LISTAGG( 가 통째로 사라진 조각난 문장이었다.
##   [교훈] 기존 39개 블록에 없던 구문은 에이전트 파서가 처음 겪는 것이다.
##          집계 컬럼은 COUNT/SUM/MIN/MAX 등 기존 블록이 이미 쓰는 형태로만 작성할 것.
##          목록(LISTAGG)이 꼭 필요하면 에이전트(C++) 측 파서 보완이 선행되어야 한다.
##   [대안] 개수만 담는다. 어떤 오브젝트인지는 발생 시 DBA 가 직접 조회하면 된다:
##          SELECT owner, object_name, object_type FROM dba_invalid_objects;
#################################
[S_INVALID_OBJECT, Y, 86400]
INSERT INTO S_INVALID_OBJECT
(
	con_id,
	invalid_cnt,
	app_invalid_cnt,
	owner_cnt
)
SELECT
    0                                                     AS CON_ID,
    COUNT(*)                                              AS INVALID_CNT,
    COUNT(CASE WHEN O.ORACLE_MAINTAINED = 'N'
               THEN 1 END)                                AS APP_INVALID_CNT,
    COUNT(DISTINCT O.OWNER)                               AS OWNER_CNT
FROM DBA_INVALID_OBJECTS O
;

#################################
## 12. S_IO_PATH_STAT - 60초
#################################
[S_IO_PATH_STAT, Y, 60]
INSERT INTO S_IO_PATH_STAT
(
	con_id,
	phys_reads_cum,
	phys_reads_cache_cum,
	phys_reads_direct_cum,
	phys_reads_direct_temp_cum,
	phys_reads_direct_lob_cum,
	phys_writes_cum,
	phys_writes_cache_cum,
	phys_writes_direct_cum,
	phys_writes_direct_temp_cum,
	phys_writes_direct_lob_cum,
	phys_read_total_bytes_cum,
	phys_write_total_bytes_cum,
	phys_read_total_io_req_cum,
	phys_write_total_io_req_cum
)
SELECT
    0            AS CON_ID,
    NVL(MAX(CASE WHEN S.NAME = 'physical reads'
                 THEN S.VALUE END), 0)                        AS PHYS_READS_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical reads cache'
                 THEN S.VALUE END), 0)                        AS PHYS_READS_CACHE_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical reads direct'
                 THEN S.VALUE END), 0)                        AS PHYS_READS_DIRECT_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical reads direct temporary tablespace'
                 THEN S.VALUE END), 0)                        AS PHYS_READS_DIRECT_TEMP_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical reads direct (lob)'
                 THEN S.VALUE END), 0)                        AS PHYS_READS_DIRECT_LOB_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical writes'
                 THEN S.VALUE END), 0)                        AS PHYS_WRITES_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical writes from cache'
                 THEN S.VALUE END), 0)                        AS PHYS_WRITES_CACHE_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical writes direct'
                 THEN S.VALUE END), 0)                        AS PHYS_WRITES_DIRECT_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical writes direct temporary tablespace'
                 THEN S.VALUE END), 0)                        AS PHYS_WRITES_DIRECT_TEMP_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical writes direct (lob)'
                 THEN S.VALUE END), 0)                        AS PHYS_WRITES_DIRECT_LOB_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical read total bytes'
                 THEN S.VALUE END), 0)                        AS PHYS_READ_TOTAL_BYTES_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical write total bytes'
                 THEN S.VALUE END), 0)                        AS PHYS_WRITE_TOTAL_BYTES_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical read total IO requests'
                 THEN S.VALUE END), 0)                        AS PHYS_READ_TOTAL_IO_REQ_CUM,
    NVL(MAX(CASE WHEN S.NAME = 'physical write total IO requests'
                 THEN S.VALUE END), 0)                        AS PHYS_WRITE_TOTAL_IO_REQ_CUM
FROM V$SYSSTAT S
WHERE S.NAME IN
(
    'physical reads',
    'physical reads cache',
    'physical reads direct',
    'physical reads direct temporary tablespace',
    'physical reads direct (lob)',
    'physical writes',
    'physical writes from cache',
    'physical writes direct',
    'physical writes direct temporary tablespace',
    'physical writes direct (lob)',
    'physical read total bytes',
    'physical write total bytes',
    'physical read total IO requests',
    'physical write total IO requests'
)
;

#################################
## 13. S_LATCH_STAT - 5분
#################################
[S_LATCH_STAT, Y, 300]
INSERT INTO S_LATCH_STAT
(
	con_id,
	latch_no,
	latch_level,
	latch_name,
	latch_category,
	gets_cum,
	misses_cum,
	sleeps_cum,
	immediate_gets_cum,
	immediate_misses_cum,
	spin_gets_cum,
	waiters_woken_cum,
	waits_holding_latch_cum
)
SELECT
    0                                                         AS CON_ID,
    L.LATCH#                                                  AS LATCH_NO,
    L.LEVEL#                                                  AS LATCH_LEVEL,
    L.NAME                                                    AS LATCH_NAME,
    CASE
        WHEN L.NAME = 'shared pool'                    THEN 'SHARED_POOL'
        WHEN L.NAME LIKE 'library cache%'              THEN 'LIBRARY_CACHE'
        WHEN L.NAME LIKE 'row cache%'                  THEN 'ROW_CACHE'
        WHEN L.NAME IN
             (
                 'cache buffers chains',
                 'cache buffers lru chain',
                 'cache buffer handles'
             )                                         THEN 'BUFFER_CACHE'
        WHEN L.NAME IN
             (
                 'redo allocation',
                 'redo copy',
                 'redo writing'
             )                                         THEN 'REDO'
        WHEN L.NAME LIKE '%enqueue%'                   THEN 'ENQUEUE'
        WHEN L.NAME IN
             (
                 'session allocation',
                 'process allocation'
             )                                         THEN 'PROCESS_SESSION'
        WHEN L.NAME = 'object queue header operation'  THEN 'OBJECT_QUEUE'
        ELSE 'OTHER'
    END                                                      AS LATCH_CATEGORY,
    NVL(L.GETS,                0)                            AS GETS_CUM,
    NVL(L.MISSES,              0)                            AS MISSES_CUM,
    NVL(L.SLEEPS,              0)                            AS SLEEPS_CUM,
    NVL(L.IMMEDIATE_GETS,      0)                            AS IMMEDIATE_GETS_CUM,
    NVL(L.IMMEDIATE_MISSES,    0)                            AS IMMEDIATE_MISSES_CUM,
    NVL(L.SPIN_GETS,           0)                            AS SPIN_GETS_CUM,
    NVL(L.WAITERS_WOKEN,       0)                            AS WAITERS_WOKEN_CUM,
    NVL(L.WAITS_HOLDING_LATCH, 0)                            AS WAITS_HOLDING_LATCH_CUM
FROM V$LATCH L
WHERE
       L.NAME = 'shared pool'
    OR L.NAME LIKE 'library cache%'
    OR L.NAME LIKE 'row cache%'
    OR L.NAME IN
       (
           'cache buffers chains',
           'cache buffers lru chain',
           'cache buffer handles',
           'redo allocation',
           'redo copy',
           'redo writing',
           'enqueue hash chains',
           'object queue header operation',
           'session allocation',
           'process allocation'
       )
;

#################################
## 14. S_LIBCACHE_STAT - 30초
#################################
[S_LIBCACHE_STAT, Y, 30]
INSERT INTO S_LIBCACHE_STAT
(
	con_id,
	namespace,
	pins_cum,
	reloads_cum,
	invalidations_cum
)
SELECT
    L.CON_ID       AS CON_ID,
    L.NAMESPACE    AS NAMESPACE,
    L.PINS         AS PINS_CUM,
    L.RELOADS      AS RELOADS_CUM,
   INVALIDATIONS   AS INVALIDATIONS_CUM
FROM V$LIBRARYCACHE L
WHERE L.NAMESPACE IN
(
    'SQL AREA',
    'TABLE/PROCEDURE',
    'BODY',
    'TRIGGER'
)
  AND L.CON_ID != 2
;

#################################
## 15. S_LOCK_SESSION - 5초
##
## HOLDER_SQL_ID      : 홀더가 "현재" 실행 중인 SQL (V$SESSION.SQL_ID)
##                      → 락을 잡은 문장이 아닐 수 있음.
##                        홀더가 idle 이면 NULL, PL/SQL 안이면 익명블록(phv=0, 원문 미수집)
## HOLDER_PREV_SQL_ID : 홀더가 "직전"에 실행한 SQL (V$SESSION.PREV_SQL_ID)
##                      → 홀더가 idle(INACTIVE) 일 때 대개 이것이 락을 잡은 그 문장.
##                        실환경 락 사고의 대표 케이스(UPDATE 후 커밋 없이 idle)를 커버.
##                      → 화면(Blocking Tree) "직전 SQL_ID" 컬럼
## ※ 본 컬럼 추가 시 PG DDL 선행 필요:
##    PG_ALTER-s_lock_session_add_holder_prev_sql_id.sql
#################################
[S_LOCK_SESSION, Y, 5]
INSERT INTO S_LOCK_SESSION
(
	con_id,
	waiter_sid,
	waiter_serial_no,
	waiter_username,
	waiter_status,
	waiter_sql_id,
	waiter_event,
	waiter_wait_class,
	waiter_seconds_in_wait,
	holder_sid,
	holder_serial_no,
	holder_username,
	holder_status,
	holder_sql_id,
	holder_prev_sql_id,
	holder_module,
	holder_machine,
	holder_program,
	blocking_session_status,
	final_blocking_sid,
	final_blocking_session_status,
	row_wait_obj_id,
	lock_type,
	lock_mode,
	p1,
	p2,
	p3,
	p1text,
	p2text,
	p3text
)
SELECT
    W.CON_ID                  AS CON_ID,
    W.SID                     AS WAITER_SID,
    W.SERIAL#                 AS WAITER_SERIAL_NO,
    W.USERNAME                AS WAITER_USERNAME,
    W.STATUS                  AS WAITER_STATUS,
    W.SQL_ID                  AS WAITER_SQL_ID,
    W.EVENT                   AS WAITER_EVENT,
    W.WAIT_CLASS              AS WAITER_WAIT_CLASS,
    W.SECONDS_IN_WAIT         AS WAITER_SECONDS_IN_WAIT,
    W.BLOCKING_SESSION        AS HOLDER_SID,
    H.SERIAL#                 AS HOLDER_SERIAL_NO,
    H.USERNAME                AS HOLDER_USERNAME,
    H.STATUS                  AS HOLDER_STATUS,
    H.SQL_ID                  AS HOLDER_SQL_ID,
    H.PREV_SQL_ID             AS HOLDER_PREV_SQL_ID,
    H.MODULE                  AS HOLDER_MODULE,
    H.MACHINE                 AS HOLDER_MACHINE,
    H.PROGRAM                 AS HOLDER_PROGRAM,
    W.BLOCKING_SESSION_STATUS,
    W.FINAL_BLOCKING_SESSION  AS FINAL_BLOCKING_SID,
    W.FINAL_BLOCKING_SESSION_STATUS,
    W.ROW_WAIT_OBJ#           AS ROW_WAIT_OBJ_ID,
    WL.TYPE                   AS LOCK_TYPE,
    DECODE
    (
        HL.LMODE,
        0, 'None',
        1, 'Null',
        2, 'Row-S',
        3, 'Row-X',
        4, 'Share',
        5, 'S/Row-X',
        6, 'Exclusive',
        TO_CHAR(HL.LMODE)
    )  AS LOCK_MODE,
    W.P1,
    W.P2,
    W.P3,
    W.P1TEXT,
    W.P2TEXT,
    W.P3TEXT
FROM V$SESSION W
LEFT JOIN V$SESSION H
       ON H.SID    = W.BLOCKING_SESSION
      AND H.CON_ID = W.CON_ID
JOIN V$LOCK WL
       ON WL.SID     = W.SID
      AND WL.REQUEST > 0
LEFT JOIN V$LOCK HL
       ON HL.SID   = W.BLOCKING_SESSION
      AND HL.TYPE  = WL.TYPE
      AND HL.ID1   = WL.ID1
      AND HL.ID2   = WL.ID2
      AND HL.LMODE > 0
WHERE W.BLOCKING_SESSION IS NOT NULL
  AND W.TYPE = 'USER'
;

#################################
## 16. S_LONGOPS - 10초
#################################
[S_LONGOPS, Y, 10]
INSERT INTO S_LONGOPS
(
	con_id,
	sid,
	serial_no,
	username,
	sql_id,
	opname,
	target,
	sofar,
	totalwork,
	units,
	start_time,
	sql_exec_id,
	sql_plan_line_id,
	operation_context,
	elapsed_seconds,
	time_remaining,
	percent_complete,
	message
)
SELECT
    0                                                                       AS CON_ID,
    L.SID,
    L.SERIAL#                                                               AS SERIAL_NO,
    NVL(S.USERNAME, NVL(L.USERNAME, 'BACKGROUND'))                         AS USERNAME,
    NVL(L.SQL_ID, S.SQL_ID)                                                AS SQL_ID,
    L.OPNAME,
    NVL(L.TARGET, NVL(L.TARGET_DESC, ' '))                                 AS TARGET,
    L.SOFAR,
    L.TOTALWORK,
    L.UNITS,
    TO_CHAR(NVL(L.START_TIME, DATE '1970-01-01'), 'YYYY-MM-DD HH24:MI:SS') AS START_TIME,
    NVL(L.SQL_EXEC_ID, -1)                                                  AS SQL_EXEC_ID,
    NVL(L.SQL_PLAN_LINE_ID, -1)                                             AS SQL_PLAN_LINE_ID,
    NVL(L.CONTEXT, -1)                                                      AS OPERATION_CONTEXT,
    L.ELAPSED_SECONDS,
    L.TIME_REMAINING,
    ROUND(L.SOFAR * 100 / NULLIF(L.TOTALWORK, 0), 2)                      AS PERCENT_COMPLETE,
    L.MESSAGE
FROM V$SESSION_LONGOPS L
LEFT JOIN V$SESSION S
       ON S.SID     = L.SID
      AND S.SERIAL# = L.SERIAL#
WHERE L.TOTALWORK > 0
  AND L.SOFAR < L.TOTALWORK
;

#################################
## 17. S_OS_CPU_STAT - 5초
#################################
[S_OS_CPU_STAT, Y, 5]
INSERT INTO S_OS_CPU_STAT
(
	con_id,
	busy_time_cum,
	idle_time_cum,
	user_time_cum,
	sys_time_cum,
	nice_time_cum,
	iowait_time_cum,
	total_time_cum,
	cpu_count
)
SELECT
    0                                                                       AS CON_ID,
    OSSTAT.BUSY_TIME                                                        AS BUSY_TIME_CUM,
    OSSTAT.IDLE_TIME                                                        AS IDLE_TIME_CUM,
    OSSTAT.USER_TIME                                                        AS USER_TIME_CUM,
    OSSTAT.SYS_TIME                                                         AS SYS_TIME_CUM,
    OSSTAT.NICE_TIME                                                        AS NICE_TIME_CUM,
    OSSTAT.IOWAIT_TIME                                                      AS IOWAIT_TIME_CUM,
    CASE
        WHEN OSSTAT.BUSY_TIME IS NOT NULL AND OSSTAT.IDLE_TIME IS NOT NULL
        THEN OSSTAT.BUSY_TIME + OSSTAT.IDLE_TIME
    END                                                                     AS TOTAL_TIME_CUM,
    OSSTAT.CPU_COUNT                                                        AS CPU_COUNT
FROM
(
    SELECT
        MAX(CASE WHEN STAT_NAME = 'BUSY_TIME'   THEN VALUE END) AS BUSY_TIME,
        MAX(CASE WHEN STAT_NAME = 'IDLE_TIME'   THEN VALUE END) AS IDLE_TIME,
        MAX(CASE WHEN STAT_NAME = 'USER_TIME'   THEN VALUE END) AS USER_TIME,
        MAX(CASE WHEN STAT_NAME = 'SYS_TIME'    THEN VALUE END) AS SYS_TIME,
        MAX(CASE WHEN STAT_NAME = 'NICE_TIME'   THEN VALUE END) AS NICE_TIME,
        MAX(CASE WHEN STAT_NAME = 'IOWAIT_TIME' THEN VALUE END) AS IOWAIT_TIME,
        MAX(CASE WHEN STAT_NAME = 'NUM_CPUS'    THEN VALUE END) AS CPU_COUNT
    FROM V$OSSTAT
    WHERE STAT_NAME IN
    (
        'BUSY_TIME',
        'IDLE_TIME',
        'USER_TIME',
        'SYS_TIME',
        'NICE_TIME',
        'IOWAIT_TIME',
        'NUM_CPUS'
    )
) OSSTAT
;

#################################
## 18. S_OS_MEMORY_STAT - 30초
##
## PHYSICAL/FREE/AVAILABLE/SWAP 항목은 순간값이므로 CPU처럼 LAG 델타를 계산하지 않는다.
## AVAILABLE_MEMORY_BYTES가 있으면 OS가 계산한 실제 사용 가능 메모리로 우선 사용한다.
## 없으면 FREE_MEMORY_BYTES + INACTIVE_MEMORY_BYTES를 사용하며, 둘 다 없으면 NULL이다.
## V$OSSTAT 메모리/Swap 항목은 OS별로 일부만 제공될 수 있다.
## Swap 총량과 Free가 모두 유효할 때만 사용량과 경보를 계산한다.
## 미지원 또는 불완전한 Swap 통계는 정상(NORMAL)이 아니라 측정 불가(NULL/N)이다.
#################################
[S_OS_MEMORY_STAT, Y, 30]
INSERT INTO S_OS_MEMORY_STAT
(
	con_id,
	physical_memory_bytes,
	free_memory_bytes,
	used_memory_bytes,
	physical_memory_gb,
	free_memory_gb,
	memory_usage_pct,
	swap_total_bytes,
	swap_free_bytes,
	swap_used_bytes,
	swap_usage_pct,
	swap_alert_level,
	swap_data_available
)
SELECT
    0                                                                       AS CON_ID,
    OSSTAT.PHYSICAL_MEMORY_BYTES                                            AS PHYSICAL_MEMORY_BYTES,
    OSSTAT.REAL_FREE_BYTES                                                  AS FREE_MEMORY_BYTES,
    OSSTAT.PHYSICAL_MEMORY_BYTES - OSSTAT.REAL_FREE_BYTES                  AS USED_MEMORY_BYTES,
    ROUND(OSSTAT.PHYSICAL_MEMORY_BYTES / 1073741824, 1)                    AS PHYSICAL_MEMORY_GB,
    ROUND(OSSTAT.REAL_FREE_BYTES       / 1073741824, 1)                    AS FREE_MEMORY_GB,
    ROUND(
        (OSSTAT.PHYSICAL_MEMORY_BYTES - OSSTAT.REAL_FREE_BYTES) * 100
        / NULLIF(OSSTAT.PHYSICAL_MEMORY_BYTES, 0),
        2
    )                                                                       AS MEMORY_USAGE_PCT,
    OSSTAT.SWAP_TOTAL_BYTES                                                 AS SWAP_TOTAL_BYTES,
    OSSTAT.SWAP_FREE_BYTES                                                  AS SWAP_FREE_BYTES,
    CASE
        WHEN OSSTAT.SWAP_TOTAL_BYTES IS NULL OR OSSTAT.SWAP_FREE_BYTES IS NULL THEN NULL
        WHEN OSSTAT.SWAP_TOTAL_BYTES < 0
          OR OSSTAT.SWAP_FREE_BYTES < 0
          OR OSSTAT.SWAP_FREE_BYTES > OSSTAT.SWAP_TOTAL_BYTES THEN NULL
        ELSE OSSTAT.SWAP_TOTAL_BYTES - OSSTAT.SWAP_FREE_BYTES
    END                                                                     AS SWAP_USED_BYTES,
    CASE
        WHEN OSSTAT.SWAP_TOTAL_BYTES IS NULL OR OSSTAT.SWAP_FREE_BYTES IS NULL THEN NULL
        WHEN OSSTAT.SWAP_TOTAL_BYTES <= 0
          OR OSSTAT.SWAP_FREE_BYTES < 0
          OR OSSTAT.SWAP_FREE_BYTES > OSSTAT.SWAP_TOTAL_BYTES THEN NULL
        ELSE ROUND(
                 (OSSTAT.SWAP_TOTAL_BYTES - OSSTAT.SWAP_FREE_BYTES) * 100
                 / OSSTAT.SWAP_TOTAL_BYTES,
                 2)
    END                                                                     AS SWAP_USAGE_PCT,
    CASE
        WHEN OSSTAT.SWAP_TOTAL_BYTES IS NULL OR OSSTAT.SWAP_FREE_BYTES IS NULL THEN NULL
        WHEN OSSTAT.SWAP_TOTAL_BYTES < 0
          OR OSSTAT.SWAP_FREE_BYTES < 0
          OR OSSTAT.SWAP_FREE_BYTES > OSSTAT.SWAP_TOTAL_BYTES THEN NULL
        WHEN OSSTAT.SWAP_TOTAL_BYTES = 0 THEN 'NORMAL'
        WHEN (OSSTAT.SWAP_TOTAL_BYTES - OSSTAT.SWAP_FREE_BYTES)
             / OSSTAT.SWAP_TOTAL_BYTES >= 0.30 THEN 'CRITICAL'
        WHEN (OSSTAT.SWAP_TOTAL_BYTES - OSSTAT.SWAP_FREE_BYTES)
             / OSSTAT.SWAP_TOTAL_BYTES >= 0.10 THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                                     AS SWAP_ALERT_LEVEL,
    CASE
        WHEN OSSTAT.SWAP_TOTAL_BYTES IS NOT NULL
         AND OSSTAT.SWAP_FREE_BYTES IS NOT NULL
         AND OSSTAT.SWAP_TOTAL_BYTES >= 0
         AND OSSTAT.SWAP_FREE_BYTES >= 0
         AND OSSTAT.SWAP_FREE_BYTES <= OSSTAT.SWAP_TOTAL_BYTES THEN 'Y'
        ELSE 'N'
    END                                                                     AS SWAP_DATA_AVAILABLE
FROM
(
    SELECT
        PHYSICAL_MEMORY_BYTES,
      NVL(AVAILABLE_MEMORY_BYTES,
          FREE_MEMORY_BYTES + NVL(INACTIVE_MEMORY_BYTES, 0)) AS REAL_FREE_BYTES,

        SWAP_TOTAL_BYTES,
        SWAP_FREE_BYTES
    FROM
    (
        SELECT
            MAX(CASE WHEN STAT_NAME = 'PHYSICAL_MEMORY_BYTES'  THEN VALUE END) AS PHYSICAL_MEMORY_BYTES,
            MAX(CASE WHEN STAT_NAME = 'FREE_MEMORY_BYTES'      THEN VALUE END) AS FREE_MEMORY_BYTES,
            MAX(CASE WHEN STAT_NAME='INACTIVE_MEMORY_BYTES'  THEN VALUE END) AS INACTIVE_MEMORY_BYTES,
            MAX(CASE WHEN STAT_NAME = 'AVAILABLE_MEMORY_BYTES' THEN VALUE END) AS AVAILABLE_MEMORY_BYTES,
            MAX(CASE WHEN STAT_NAME = 'SWAP_TOTAL_BYTES'       THEN VALUE END) AS SWAP_TOTAL_BYTES,
            MAX(CASE WHEN STAT_NAME = 'SWAP_FREE_BYTES'        THEN VALUE END) AS SWAP_FREE_BYTES
        FROM V$OSSTAT
        WHERE STAT_NAME IN
        (
            'PHYSICAL_MEMORY_BYTES',
            'FREE_MEMORY_BYTES',
            'INACTIVE_MEMORY_BYTES',
            'AVAILABLE_MEMORY_BYTES',
            'SWAP_TOTAL_BYTES',
            'SWAP_FREE_BYTES'
        )
    )
) OSSTAT
;

#################################
## 19. S_PARAMETER_SNAPSHOT - 1일
##
## DB 설정 변경감지 목적이므로 수집 세션 값인 V$PARAMETER를 사용하지 않는다.
## 인스턴스 전체에 적용된 초기화 파라미터 값은 V$SYSTEM_PARAMETER에서 수집한다.
## ALTER SESSION으로 바뀐 NLS 등 수집계정 세션값은 스냅샷 및 변경감지 대상이 아니다.
#################################
[S_PARAMETER_SNAPSHOT, Y, 86400]
INSERT INTO S_PARAMETER_SNAPSHOT
(
	con_id,
	name,
	value,
	display_value,
	default_value,
	isdefault,
	isses_modifiable,
	issys_modifiable,
	ispdb_modifiable,
	isinstance_modifiable,
	ismodified,
	isadjusted,
	isdeprecated,
	isbasic,
	description,
	type_no,
	type_desc
)
SELECT
    CON_ID,
    NAME,
    VALUE,
    DISPLAY_VALUE,
    DEFAULT_VALUE,
    ISDEFAULT,
    ISSES_MODIFIABLE,
    ISSYS_MODIFIABLE,
    ISPDB_MODIFIABLE,
    ISINSTANCE_MODIFIABLE,
    ISMODIFIED,
    ISADJUSTED,
    ISDEPRECATED,
    ISBASIC,
    DESCRIPTION,
    TYPE          AS TYPE_NO,
    DECODE(TYPE,
        1, 'Boolean',
        2, 'String',
        3, 'Integer',
        4, 'File Name',
        5, 'Reserved',
        6, 'Big Integer',
        'Unknown'
    )              AS TYPE_DESC
FROM V$SYSTEM_PARAMETER
;

#################################
## 20. S_PDB_STATUS - 30초 [수집 보류]
## Oracle MVP는 Non-CDB 단일 인스턴스 기준이므로 PDB 상태를 수집하지 않는다.
## 재개할 때 아래 블록의 각 줄 맨 앞 ## 를 제거하고 설정값 N을 Y로 변경한다.
#################################
## [S_PDB_STATUS, N, 30]
## INSERT INTO S_PDB_STATUS
## (
## 	con_id,
## 	pdb_name,
## 	open_mode,
## 	restricted,
## 	open_time,
## 	total_size_mb,
## 	block_size,
## 	recovery_status,
## 	snapshot_parent_con_id,
## 	application_root,
## 	application_pdb,
## 	is_proxy_pdb,
## 	con_uid,
## 	guid
## )
## SELECT
##     CON_ID,
##     NAME                               AS PDB_NAME,
##     OPEN_MODE,
##     RESTRICTED,
##     TO_CHAR(OPEN_TIME, 'YYYY-MM-DD HH24:MI:SS') AS OPEN_TIME,
##     ROUND(TOTAL_SIZE / 1048576)        AS TOTAL_SIZE_MB,
##     BLOCK_SIZE,
##     RECOVERY_STATUS,
##     SNAPSHOT_PARENT_CON_ID,
##     APPLICATION_ROOT,
##     APPLICATION_PDB,
##     PROXY_PDB                          AS IS_PROXY_PDB,
##     CON_UID,
##     RAWTOHEX(GUID)                     AS GUID
## FROM V$PDBS
## WHERE CON_ID != 2
## ;
