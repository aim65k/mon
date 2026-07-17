-- ============================================================================
-- Pg_create_view_ALL_v_m.sql  (v2: MariaDB 상태변수명 대문자 대응)
-- ITSTONE DB Monitor (MariaDB) — 화면 뷰 v_m_* 25개 일괄 생성
-- 실행:  psql -h 192.168.10.132 -U itstone -d mondb -f Pg_create_view_ALL_v_m.sql
-- 변경:  v_m_workload_now/trend 의 variable_name 비교를 UPPER() 로 (MariaDB가 대문자로 반환)
-- ============================================================================
SET search_path = itstone, public;


-- ───────── [PG_VIEW-v_m_workload_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_workload_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Real-Time Monitor > Workload 패널 (QPS/TPS/DML/Buffer Hit ...)
--------------------------------------------------------------------------------
-- [이 뷰가 대체하는 것]
--   기존 m_workload_stat "수집 테이블"을 폐기하고, m_global_status(02) 원시
--   누적값 위에서 LAG() 델타로 초당 지표를 "조회 시" 계산한다.
--     · 우리 원칙: 누적값은 저장만, 델타는 LAG() 로 계산 (S_TOP_SQL 폐기와 동일).
--     · 미리 굳힌 초당값을 저장하지 않음 → 재튜닝 자유 + 저장 절감.
--
-- [LAG 델타 안전장치]
--   1. GREATEST(cur - prev, 0) : 인스턴스 재기동/카운터 리셋 시 음수 방지.
--   2. NULLIF(elapsed_sec, 0)   : 동일 시각 중복 수집 시 0 division 방지.
--   3. 최신 사이클 1건만 반환(직전값과의 1쌍).
--   4. CTE 미사용, 인라인 뷰(pivot → LAG → delta) 3단 (프로젝트 표준).
--
-- [view-first 가 잡아낸 02 수집 요건]
--   ★ TPS 계산을 위해 Com_commit / Com_rollback 이 필요하다.
--     → 02 m_global_status 의 수집 변수 목록(WHERE IN)에 두 변수를 추가해야 함.
--       (빌리 원본 02 의 WHERE 목록에는 빠져 있었음 — view-first 로 발견)
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_workload_now AS
SELECT
    d.collect_time,
    d.prev_collect_time,
    ROUND(d.elapsed_sec, 3)                                            AS elapsed_sec,
    -- 처리량
    ROUND(d.queries_delta      / NULLIF(d.elapsed_sec, 0), 2)          AS qps,
    ROUND(d.questions_delta     / NULLIF(d.elapsed_sec, 0), 2)         AS questions_per_sec,
    ROUND((d.commit_delta + d.rollback_delta) / NULLIF(d.elapsed_sec, 0), 2) AS tps,
    ROUND(d.commit_delta       / NULLIF(d.elapsed_sec, 0), 2)          AS commit_per_sec,
    ROUND(d.rollback_delta      / NULLIF(d.elapsed_sec, 0), 2)         AS rollback_per_sec,
    ROUND(d.select_delta       / NULLIF(d.elapsed_sec, 0), 2)          AS select_per_sec,
    ROUND((d.insert_delta + d.update_delta + d.delete_delta) / NULLIF(d.elapsed_sec, 0), 2) AS dml_per_sec,
    ROUND(d.slow_delta         / NULLIF(d.elapsed_sec, 0), 2)          AS slow_queries_per_sec,
    -- 임시 테이블
    ROUND(d.tmp_disk_delta * 100.0 / NULLIF(d.tmp_tables_delta, 0), 2) AS tmp_disk_table_pct,
    -- 네트워크
    ROUND(d.bytes_recv_delta   / NULLIF(d.elapsed_sec, 0), 2)          AS bytes_received_per_sec,
    ROUND(d.bytes_sent_delta    / NULLIF(d.elapsed_sec, 0), 2)         AS bytes_sent_per_sec,
    -- InnoDB Buffer Pool Hit (델타 기반)
    ROUND((1 - d.bp_reads_delta::numeric / NULLIF(d.bp_read_req_delta, 0)) * 100, 2) AS innodb_buffer_hit_pct,
    ROUND(d.innodb_rows_read_delta / NULLIF(d.elapsed_sec, 0), 2)      AS innodb_rows_read_per_sec,
    -- 현재 게이지(델타 아님)
    d.threads_running,
    d.threads_connected,
    d.innodb_row_lock_current_waits,
    --========================== ▼ TUNING ▼ ==========================--
    CASE
        WHEN d.threads_running >= 50 OR d.innodb_row_lock_current_waits >= 10 THEN 'CRITICAL'
        WHEN d.threads_running >= 30
          OR (1 - d.bp_reads_delta::numeric / NULLIF(d.bp_read_req_delta, 0)) * 100 < 95
          OR d.tmp_disk_delta * 100.0 / NULLIF(d.tmp_tables_delta, 0) >= 50 THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                               AS risk_level,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN d.threads_running >= 30 THEN 'THREADS_RUNNING_HIGH' END,
        CASE WHEN d.innodb_row_lock_current_waits >= 1 THEN 'ROW_LOCK_WAITS' END,
        CASE WHEN (1 - d.bp_reads_delta::numeric / NULLIF(d.bp_read_req_delta, 0)) * 100 < 95 THEN 'BUFFER_HIT_LOW' END,
        CASE WHEN d.tmp_disk_delta * 100.0 / NULLIF(d.tmp_tables_delta, 0) >= 50 THEN 'DISK_TMP_HIGH' END
    ), '')                                                            AS risk_reason
    --========================== ▲ TUNING ▲ ==========================--
FROM
(
    -- 2단계: 델타 계산 (GREATEST 음수 가드)
    SELECT
        p.collect_time,
        p.prev_collect_time,
        EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time))     AS elapsed_sec,
        GREATEST(p.queries     - p.prev_queries,     0)                AS queries_delta,
        GREATEST(p.questions   - p.prev_questions,   0)                AS questions_delta,
        GREATEST(p.com_commit  - p.prev_com_commit,  0)                AS commit_delta,
        GREATEST(p.com_rollback- p.prev_com_rollback,0)                AS rollback_delta,
        GREATEST(p.com_select  - p.prev_com_select,  0)                AS select_delta,
        GREATEST(p.com_insert  - p.prev_com_insert,  0)                AS insert_delta,
        GREATEST(p.com_update  - p.prev_com_update,  0)                AS update_delta,
        GREATEST(p.com_delete  - p.prev_com_delete,  0)                AS delete_delta,
        GREATEST(p.slow        - p.prev_slow,        0)                AS slow_delta,
        GREATEST(p.tmp_tables  - p.prev_tmp_tables,  0)                AS tmp_tables_delta,
        GREATEST(p.tmp_disk    - p.prev_tmp_disk,    0)                AS tmp_disk_delta,
        GREATEST(p.bytes_recv  - p.prev_bytes_recv,  0)                AS bytes_recv_delta,
        GREATEST(p.bytes_sent  - p.prev_bytes_sent,  0)                AS bytes_sent_delta,
        GREATEST(p.bp_read_req - p.prev_bp_read_req, 0)                AS bp_read_req_delta,
        GREATEST(p.bp_reads    - p.prev_bp_reads,    0)                AS bp_reads_delta,
        GREATEST(p.rows_read   - p.prev_rows_read,   0)                AS innodb_rows_read_delta,
        p.threads_running,
        p.threads_connected,
        p.innodb_row_lock_current_waits
    FROM
    (
        -- 1.5단계: 각 컬럼에 LAG 적용
        SELECT
            w.collect_time,
            LAG(w.collect_time) OVER (ORDER BY w.collect_time) AS prev_collect_time,
            w.queries,      LAG(w.queries)      OVER (ORDER BY w.collect_time) AS prev_queries,
            w.questions,    LAG(w.questions)    OVER (ORDER BY w.collect_time) AS prev_questions,
            w.com_commit,   LAG(w.com_commit)   OVER (ORDER BY w.collect_time) AS prev_com_commit,
            w.com_rollback, LAG(w.com_rollback) OVER (ORDER BY w.collect_time) AS prev_com_rollback,
            w.com_select,   LAG(w.com_select)   OVER (ORDER BY w.collect_time) AS prev_com_select,
            w.com_insert,   LAG(w.com_insert)   OVER (ORDER BY w.collect_time) AS prev_com_insert,
            w.com_update,   LAG(w.com_update)   OVER (ORDER BY w.collect_time) AS prev_com_update,
            w.com_delete,   LAG(w.com_delete)   OVER (ORDER BY w.collect_time) AS prev_com_delete,
            w.slow,         LAG(w.slow)         OVER (ORDER BY w.collect_time) AS prev_slow,
            w.tmp_tables,   LAG(w.tmp_tables)   OVER (ORDER BY w.collect_time) AS prev_tmp_tables,
            w.tmp_disk,     LAG(w.tmp_disk)     OVER (ORDER BY w.collect_time) AS prev_tmp_disk,
            w.bytes_recv,   LAG(w.bytes_recv)   OVER (ORDER BY w.collect_time) AS prev_bytes_recv,
            w.bytes_sent,   LAG(w.bytes_sent)   OVER (ORDER BY w.collect_time) AS prev_bytes_sent,
            w.bp_read_req,  LAG(w.bp_read_req)  OVER (ORDER BY w.collect_time) AS prev_bp_read_req,
            w.bp_reads,     LAG(w.bp_reads)     OVER (ORDER BY w.collect_time) AS prev_bp_reads,
            w.rows_read,    LAG(w.rows_read)    OVER (ORDER BY w.collect_time) AS prev_rows_read,
            w.threads_running,
            w.threads_connected,
            w.innodb_row_lock_current_waits
        FROM
        (
            -- 1단계: tall(variable_name) → wide(pivot) per collect_time
            SELECT
                g.collect_time,
                MAX(CASE WHEN UPPER(g.variable_name) = 'QUERIES'            THEN g.variable_value_num END) AS queries,
                MAX(CASE WHEN UPPER(g.variable_name) = 'QUESTIONS'          THEN g.variable_value_num END) AS questions,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_COMMIT'         THEN g.variable_value_num END) AS com_commit,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_ROLLBACK'       THEN g.variable_value_num END) AS com_rollback,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_SELECT'         THEN g.variable_value_num END) AS com_select,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_INSERT'         THEN g.variable_value_num END) AS com_insert,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_UPDATE'         THEN g.variable_value_num END) AS com_update,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_DELETE'         THEN g.variable_value_num END) AS com_delete,
                MAX(CASE WHEN UPPER(g.variable_name) = 'SLOW_QUERIES'       THEN g.variable_value_num END) AS slow,
                MAX(CASE WHEN UPPER(g.variable_name) = 'CREATED_TMP_TABLES' THEN g.variable_value_num END) AS tmp_tables,
                MAX(CASE WHEN UPPER(g.variable_name) = 'CREATED_TMP_DISK_TABLES' THEN g.variable_value_num END) AS tmp_disk,
                MAX(CASE WHEN UPPER(g.variable_name) = 'BYTES_RECEIVED'     THEN g.variable_value_num END) AS bytes_recv,
                MAX(CASE WHEN UPPER(g.variable_name) = 'BYTES_SENT'         THEN g.variable_value_num END) AS bytes_sent,
                MAX(CASE WHEN UPPER(g.variable_name) = 'INNODB_BUFFER_POOL_READ_REQUESTS' THEN g.variable_value_num END) AS bp_read_req,
                MAX(CASE WHEN UPPER(g.variable_name) = 'INNODB_BUFFER_POOL_READS'         THEN g.variable_value_num END) AS bp_reads,
                MAX(CASE WHEN UPPER(g.variable_name) = 'INNODB_ROWS_READ'   THEN g.variable_value_num END) AS rows_read,
                MAX(CASE WHEN UPPER(g.variable_name) = 'THREADS_RUNNING'    THEN g.variable_value_num END) AS threads_running,
                MAX(CASE WHEN UPPER(g.variable_name) = 'THREADS_CONNECTED'  THEN g.variable_value_num END) AS threads_connected,
                MAX(CASE WHEN UPPER(g.variable_name) = 'INNODB_ROW_LOCK_CURRENT_WAITS' THEN g.variable_value_num END) AS innodb_row_lock_current_waits
            FROM itstone.m_global_status g
            WHERE g.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_global_status) - INTERVAL '15 seconds'
            GROUP BY g.collect_time
        ) w
    ) p
    WHERE p.prev_collect_time IS NOT NULL
) d
ORDER BY d.collect_time DESC
LIMIT 1;

-- ───────── [PG_VIEW-v_m_active_session_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_active_session_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Real-Time Monitor > Active Session 그리드 (MariaDB 대상)
--------------------------------------------------------------------------------
-- [★ 신선도 경고 — 전체 수집 중단]
--   이 뷰는 데이터 MAX(collect_time) 앵커(스큐 면역)라 수집이 멈춰도 마지막 스냅샷을 그대로 반환한다.
--   heartbeat 까지 같이 멈추면 이벤트 가드도 차이를 못 느껴 통과 → 단독 조회 시 오래된 active session 이
--   '현재'로 보일 수 있다. → C# 은 표시 전 반드시 v_m_summary_kpi.monitor_status 확인(STALE/NO_DATA 면
--   회색+"수집 지연/중단"). 상세를 summary 없이 단독 'live' 렌더 금지(원칙 27 / 7탭 계약).
--------------------------------------------------------------------------------
-- [이 파일이 증명하는 것]
--   risk_level / is_long_running_yn / is_lock_wait_yn 를 "수집 테이블"이 아니라
--   "화면 조회 뷰"에서 계산한다.
--     · C# 개발자는 risk 계산 안 함 → 뷰에서 컬럼만 SELECT (맨 아래 예시).
--     · 1초 수집 INSERT 에는 부하 없음 → 화면 열 때 CASE 1회만.
--     · 임계치 재튜닝 = 이 뷰만 CREATE OR REPLACE → 과거 데이터에도 소급 적용.
--
-- [설계 원칙]
--   1. 현재 세션 = 가장 최근 수집 사이클(MAX collect_time)의 행.
--      PK(collect_time, thread_id) → 해당 시점엔 thread 당 1행이라 별도 dedup 불필요.
--   2. 최근 10초 범위로 먼저 가지치기 → 파티션 프루닝 + 수집기 다운 시 빈 결과.
--   3. CTE 미사용, 인라인 뷰(스칼라 서브쿼리) 방식 (프로젝트 표준).
--   4. 임계치는 ▼TUNING▼ 블록 한 곳에만. v1.1 현장 검증 후 조정.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_active_session_now AS
SELECT
    s.collect_time,
    s.thread_id,
    s.processlist_id,
    s.user_name,
    s.host,
    s.db_name,
    s.command,
    s.session_state,
    s.wait_event,
    s.wait_class,
    s.wait_object,
    s.proc_state,
    s.time_sec,
    s.stmt_elapsed_ms,
    s.digest,
    s.current_schema_name,
    s.sql_text_sample,
    s.rows_examined,
    s.rows_sent,
    s.lock_time_ms,
    --========================== ▼ TUNING ▼ ==========================--
    -- 여기가 유일한 임계치 정의 지점. 사이트별 조정은 이 블록만 수정.
    CASE WHEN s.time_sec >= 300 THEN 'Y' ELSE 'N' END           AS is_long_running_yn,
    CASE WHEN s.wait_class = 'LOCK' THEN 'Y' ELSE 'N' END        AS is_lock_wait_yn,
    CASE
        WHEN s.wait_class = 'LOCK' AND s.time_sec >= 60   THEN 'CRITICAL'
        WHEN s.time_sec >= 300                            THEN 'CRITICAL'
        WHEN s.wait_class = 'LOCK'                        THEN 'WARNING'
        WHEN s.time_sec >= 60                             THEN 'WARNING'
        WHEN s.rows_examined >= 1000000                   THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                         AS risk_level,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN s.time_sec >= 300            THEN 'LONG_RUNNING_5MIN' END,
        CASE WHEN s.wait_class = 'LOCK'        THEN 'LOCK_WAIT' END,
        CASE WHEN s.rows_examined >= 1000000   THEN 'ROWS_EXAMINED_1M' END
    ), '')                                                      AS risk_reason
    --========================== ▲ TUNING ▲ ==========================--
FROM itstone.m_active_session s
WHERE s.collect_time =
(
    SELECT MAX(a.collect_time)
    FROM itstone.m_active_session a
    WHERE a.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_active_session) - INTERVAL '10 seconds'
)
-- ★ 이벤트 신선도 가드(B안): 활성세션 테이블 최신 시각이 heartbeat(global_status)보다
--   8초 이상 뒤처지면 = 직전 활동이 이미 끝난 것 → 빈 결과(과거 세션을 현재로 표시 방지).
--   active_session 은 0건이 정상(조용한 DB) → MAX 가 얼면 과거를 현재로 오인하므로 차단.
--   동일 MariaDB 시계 비교라 클럭 스큐 무관. 전체 수집 중단은 summary_kpi.data_age_sec 가 별도 포착.
  AND (SELECT MAX(collect_time) FROM itstone.m_active_session)
      >= (SELECT MAX(collect_time) FROM itstone.m_global_status) - INTERVAL '8 seconds';


--------------------------------------------------------------------------------
-- [C# 개발자가 실제로 실행하는 쿼리]  ← risk 계산 코드 0줄. 컬럼만 SELECT.
--------------------------------------------------------------------------------
-- SELECT
--     processlist_id,
--     user_name,
--     db_name,
--     session_state,
--     wait_class,
--     wait_event,
--     time_sec,
--     digest,
--     risk_level,          -- ← 뷰가 계산해서 내려줌
--     risk_reason          -- ← 뷰가 계산해서 내려줌
-- FROM itstone.v_m_active_session_now
-- ORDER BY
--     CASE risk_level WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
--     time_sec DESC;
--------------------------------------------------------------------------------

-- ───────── [PG_VIEW-v_m_processlist_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_processlist_now   (Basic Mode 세션 그리드)
-- ITSTONE DB Monitor v1  /  C# 은 이 뷰의 컬럼만 SELECT
--------------------------------------------------------------------------------
-- [설계]
--   - m_active_session(Enhanced)의 Basic 대응. 동일 '세션 그리드'를 P_S 없이 제공.
--   - MAX(collect_time) 앵커(스큐 면역). 수집 멈춰도 마지막 스냅샷 반환 →
--     C# 은 표시 전 v_m_summary_kpi.monitor_status(STALE/NO_DATA) 확인.
--   - risk/long_running 는 ▼TUNING▼ 에서 원시값으로 산출(수집 부하 없음).
--   - ★ Basic 한계: 실제 wait event 없음. lock 은 proc_state(STATE 문자열) 휴리스틱(취약).
--     Enhanced(m_active_session)는 events_waits 로 정확. 화면은 모드 배지로 구분 표기.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW itstone.v_m_processlist_now AS
SELECT
    p.id,                                                        -- 커넥션 ID
    p.user_name,
    p.host,
    p.db_name,
    p.command,
    p.time_sec,                                                  -- 현재 상태 경과(초)
    p.time_ms,
    p.proc_state,                                                -- STATE 문자열(실제 wait event 아님)
    p.info                AS sql_text,                           -- 현재 SQL 전문
    p.examined_rows,
    p.progress,
    --========================== ▼ TUNING ▼ ==========================--
    CASE WHEN p.time_sec >= 300 THEN 'Y' ELSE 'N' END            AS is_long_running_yn,
    -- ★ lock 휴리스틱(Basic 한계): STATE 문자열에 lock 류 포함 시 추정(Enhanced 의 wait_class='LOCK' 대체)
    CASE WHEN p.proc_state ILIKE '%lock%' THEN 'Y' ELSE 'N' END  AS is_lock_wait_yn,
    CASE
        WHEN p.time_sec >= 300                              THEN 'CRITICAL'
        WHEN p.proc_state ILIKE '%lock%' AND p.time_sec>=60 THEN 'CRITICAL'
        WHEN p.time_sec >= 60                               THEN 'WARNING'
        WHEN p.proc_state ILIKE '%lock%'                    THEN 'WARNING'
        WHEN p.examined_rows >= 1000000                     THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                         AS risk_level,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN p.time_sec >= 300          THEN 'LONG_RUNNING_5MIN' END,
        CASE WHEN p.proc_state ILIKE '%lock%' THEN 'LOCK_WAIT_HEURISTIC' END,
        CASE WHEN p.examined_rows >= 1000000 THEN 'ROWS_EXAMINED_1M' END
    ), '')                                                      AS risk_reason,
    --========================== ▲ TUNING ▲ ==========================--
    EXTRACT(EPOCH FROM (statement_timestamp() - p.collect_time))::int AS data_age_sec
FROM itstone.m_processlist p
WHERE p.collect_time = (SELECT MAX(collect_time) FROM itstone.m_processlist)
  -- ★ 이벤트 신선도 가드: processlist 최신 시각이 heartbeat(global_status)보다 크게 뒤지면
  --   stale 스냅샷이므로 표시 안 함(동일 MariaDB 시계 비교 → 클럭 스큐 무관).
  AND (SELECT MAX(collect_time) FROM itstone.m_processlist)
      >= (SELECT MAX(collect_time) FROM itstone.m_global_status) - INTERVAL '8 seconds'
ORDER BY p.time_sec DESC;

-- ───────── [PG_VIEW-v_m_top_sql_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_top_sql_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : SQL Analysis > Top SQL (최근 구간 델타 기준 Elapsed Top N)
--------------------------------------------------------------------------------
-- [설계 핵심]
--   events_statements_summary_by_digest 는 "누적" 통계 → 최근 구간에 무엇이
--   무거웠는지는 두 스냅샷의 LAG() 델타로 계산 (S_TOP_SQL 폐기/LAG 전환과 동일).
--
-- [델타 안전장치]
--   1. GREATEST(cur - prev, 0) : digest 테이블 TRUNCATE / 캐시 eviction 후
--      재등록 시 카운터 리셋으로 인한 음수 방지.
--   2. prev_collect_time IS NOT NULL : 직전 스냅샷 없는 신규 digest 1회 과대
--      계상 방지(다음 사이클부터 정상 집계).
--   3. delta_count > 0 : 이번 구간 실제 실행된 SQL 만 랭킹.
--   4. picosecond → ms : / 1000000000.0 (수집은 raw ps 저장, 변환은 뷰에서).
--   5. CTE 미사용. pivot 불필요(digest 테이블은 이미 wide) → LAG/delta/rank 3단 인라인 뷰.
--
-- [텍스트/통계 분리]
--   digest_text 는 m_sql_text(차원)에서 조인. m_sql_digest 는 통계만(경량 시계열).
--
-- [수집 요건 도출 결과 → m_sql_digest 가 담아야 할 raw cum]
--   count_star_cum, sum_timer_wait_ps_cum, max_timer_wait_ps, sum_lock_time_ps_cum,
--   sum_rows_examined_cum, sum_rows_sent_cum, sum_no_index_used_cum,
--   sum_created_tmp_disk_tables_cum  (+ 보조 누적)
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_top_sql_now AS
SELECT
    r.collect_time,
    r.schema_name,
    r.digest,
    t.digest_text,                                                        -- ★정규화 패턴(literal=?), 실제 원문 아님. 미수집/지연 시 NULL(정상). UI 라벨 "SQL Pattern"
    COALESCE(t.sql_type, 'UNKNOWN')                                       AS sql_type,
    r.delta_count                                                          AS exec_count,
    ROUND(r.delta_elapsed_ps / 1000000000.0, 2)                            AS elapsed_ms_total,
    ROUND(r.delta_elapsed_ps / NULLIF(r.delta_count, 0) / 1000000000.0, 3) AS avg_elapsed_ms,
    ROUND(r.max_timer_wait_ps / 1000000000.0, 3)                           AS max_elapsed_ms,   -- 누적 역대 최악 1회(P_S 리셋 후, 윈도우 아님) — 참고용, risk 미사용
    ROUND(r.delta_lock_ps / 1000000000.0, 3)                               AS lock_ms_total,
    r.delta_rows_examined,
    r.delta_rows_sent,
    ROUND(r.delta_rows_examined::numeric / NULLIF(r.delta_rows_sent, 0), 1) AS rows_examined_per_sent,
    ROUND(r.delta_rows_examined::numeric / NULLIF(r.delta_count, 0), 0)     AS avg_rows_examined,  -- 실행당 평균 스캔 행(DML 포함 절대량 risk 근거)
    r.delta_no_index_used,
    r.delta_tmp_disk,
    r.rank_elapsed,
    --========================== ▼ TUNING ▼ ==========================--
    CASE
        WHEN r.delta_elapsed_ps / NULLIF(r.delta_count, 0) / 1000000000.0 >= 1000 THEN 'CRITICAL'
        -- ★ DML 보완: 비율(rows_examined/rows_sent)은 UPDATE/DELETE/INSERT 처럼 rows_sent=0 이면
        --   NULLIF 로 NULL → BAD_SELECTIVITY 누락. 절대량(실행당 평균 스캔 행)으로 보완.
        --   윈도우 합계 아닌 '실행당 평균' 기준 → 핫한 PK 조회(1행×다회) 오탐 방지, SLOW_AVG 와 일관.
        WHEN r.delta_rows_examined::numeric / NULLIF(r.delta_count, 0) >= 10000000 THEN 'CRITICAL'
        -- ★ max_timer_wait_ps(누적 역대 최대) 는 risk 에서 제외. 윈도우가 아니라 P_S 리셋 이후
        --   해당 digest 의 역사상 최댓값이라, 과거 1회 느렸던 SQL 이 최근 정상이어도 계속
        --   CRITICAL 오탐이 난다. → 화면 참고값(max_elapsed_ms)으로만 표시, risk 는 delta(최근 구간)만.
        WHEN r.delta_elapsed_ps / NULLIF(r.delta_count, 0) / 1000000000.0 >= 100  THEN 'WARNING'
        WHEN r.delta_no_index_used > 0                                            THEN 'WARNING'
        WHEN r.delta_rows_examined::numeric / NULLIF(r.delta_rows_sent, 0) >= 1000 THEN 'WARNING'
        WHEN r.delta_rows_examined::numeric / NULLIF(r.delta_count, 0) >= 1000000  THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                                    AS risk_level,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN r.delta_elapsed_ps / NULLIF(r.delta_count, 0) / 1000000000.0 >= 100 THEN 'SLOW_AVG' END,
        CASE WHEN r.delta_no_index_used > 0                                           THEN 'NO_INDEX_USED' END,
        CASE WHEN r.delta_rows_examined::numeric / NULLIF(r.delta_rows_sent, 0) >= 1000 THEN 'BAD_SELECTIVITY' END,
        CASE WHEN r.delta_rows_examined::numeric / NULLIF(r.delta_count, 0) >= 1000000 THEN 'HIGH_ROWS_EXAMINED' END,
        CASE WHEN r.delta_tmp_disk > 0                                                THEN 'DISK_TMP' END
    ), '')                                                                 AS risk_reason
    --========================== ▲ TUNING ▲ ==========================--
FROM
(
    -- 3단계: Elapsed 델타 기준 랭킹
    SELECT z.*, ROW_NUMBER() OVER (ORDER BY z.delta_elapsed_ps DESC) AS rank_elapsed
    FROM
    (
        -- 2단계: 델타 계산 (GREATEST 음수 가드)
        SELECT
            p.collect_time,
            p.schema_name,
            p.digest,
            p.max_timer_wait_ps,
            GREATEST(p.count_star_cum               - p.prev_count,     0) AS delta_count,
            GREATEST(p.sum_timer_wait_ps_cum        - p.prev_timer,     0) AS delta_elapsed_ps,
            GREATEST(p.sum_lock_time_ps_cum         - p.prev_lock,      0) AS delta_lock_ps,
            GREATEST(p.sum_rows_examined_cum        - p.prev_rows_exam, 0) AS delta_rows_examined,
            GREATEST(p.sum_rows_sent_cum            - p.prev_rows_sent, 0) AS delta_rows_sent,
            GREATEST(p.sum_no_index_used_cum        - p.prev_no_index,  0) AS delta_no_index_used,
            GREATEST(p.sum_created_tmp_disk_tables_cum - p.prev_tmp_disk, 0) AS delta_tmp_disk
        FROM
        (
            -- 1단계: (schema, digest) 별 LAG
            SELECT
                x.collect_time, x.schema_name, x.digest, x.max_timer_wait_ps,
                x.count_star_cum,                  LAG(x.count_star_cum)                  OVER w AS prev_count,
                x.sum_timer_wait_ps_cum,           LAG(x.sum_timer_wait_ps_cum)           OVER w AS prev_timer,
                x.sum_lock_time_ps_cum,            LAG(x.sum_lock_time_ps_cum)            OVER w AS prev_lock,
                x.sum_rows_examined_cum,           LAG(x.sum_rows_examined_cum)           OVER w AS prev_rows_exam,
                x.sum_rows_sent_cum,               LAG(x.sum_rows_sent_cum)               OVER w AS prev_rows_sent,
                x.sum_no_index_used_cum,           LAG(x.sum_no_index_used_cum)           OVER w AS prev_no_index,
                x.sum_created_tmp_disk_tables_cum, LAG(x.sum_created_tmp_disk_tables_cum) OVER w AS prev_tmp_disk,
                LAG(x.collect_time) OVER w AS prev_collect_time
            FROM itstone.m_sql_digest x
            WHERE x.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_sql_digest) - INTERVAL '3 minutes'
            WINDOW w AS (PARTITION BY x.schema_name, x.digest ORDER BY x.collect_time)
        ) p
        WHERE p.prev_collect_time IS NOT NULL
          -- ★ 갭 방지: m_sql_digest 1분 주기. 수집 재개 직후 누적 delta(예: 2.5분치)가 현재 now 에
          --   잡혀 Top SQL 이 순간 과대표시되는 것을 차단. 간격 2배(120초) 초과면 제외(해당 cycle 빈 결과
          --   → 다음 정상 cycle 회복). summary stale 은 '최근 수집됨'만 봐 재개 직후 FRESH 라 여기서 따로 방어.
          AND EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time)) <= 120
          AND p.collect_time = (SELECT MAX(collect_time) FROM itstone.m_sql_digest
                                WHERE collect_time >= (SELECT MAX(collect_time) FROM itstone.m_sql_digest) - INTERVAL '3 minutes')
          AND GREATEST(p.count_star_cum - p.prev_count, 0) > 0
    ) z
) r
-- ★ LEFT JOIN: m_sql_text(차원)의 UPSERT 실패/지연으로 텍스트가 없어도 성능통계·risk 행은 유지.
--   INNER 면 텍스트 차원 장애가 SQL 성능 화면과 summary 의 SQL risk 집계까지 죽인다.
LEFT JOIN itstone.m_sql_text t
  ON t.schema_name = r.schema_name
 AND t.digest      = r.digest
-- Top-N 절단 없음: 전체 digest + risk 출력 → summary 종합 위험이 51위 이하도 포착.
-- 화면 Top-N 은 C# 이 적용: SELECT ... FROM v_m_top_sql_now WHERE rank_elapsed <= 50.
ORDER BY r.rank_elapsed;

-- ───────── [PG_VIEW-v_m_innodb_trx_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_innodb_trx_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Real-Time Monitor > InnoDB Transactions / Lock Wait 패널 (전 버전 안전)
--------------------------------------------------------------------------------
-- [설계]
--   - 현재 열린 트랜잭션 = 최근 수집 사이클(MAX collect_time)의 행.
--   - trx_type / risk_level / kill_candidate 를 ▼TUNING▼ 에서 계산(C# 은 컬럼만).
--   - 08(blocker→waiter 체인)이 버전 제약으로 보류 중이라도, 본 뷰만으로
--     "누가 얼마나 오래 LOCK WAIT / Long TRX / 무거운 잠금" 패널 제공 가능.
--   - 향후 08 도입 시 blocking_thread_id 를 좌측 조인해 Lock Tree 로 확장.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_innodb_trx_now AS
SELECT
    s.collect_time,
    s.trx_id,
    s.trx_state,
    s.trx_mysql_thread_id           AS processlist_id,
    s.user_name,
    s.host,
    s.db_name,
    s.command,
    s.trx_age_sec,
    s.trx_wait_sec,
    s.trx_rows_locked,
    s.trx_rows_modified,
    s.trx_lock_structs,
    s.trx_weight,
    s.trx_isolation_level,
    s.sql_text_sample,
    --========================== ▼ TUNING ▼ ==========================--
    CASE
        WHEN s.trx_state = 'LOCK WAIT'                      THEN 'LOCK_WAIT'
        WHEN s.trx_age_sec >= 1800                          THEN 'LONG_TRX'
        WHEN COALESCE(s.trx_rows_locked, 0)   >= 10000      THEN 'HEAVY_LOCK'
        WHEN COALESCE(s.trx_rows_modified, 0) >= 10000      THEN 'HEAVY_MODIFY'
        ELSE 'NORMAL'
    END                                                     AS trx_type,
    CASE
        WHEN s.trx_state = 'LOCK WAIT' AND s.trx_wait_sec >= 60 THEN 'CRITICAL'
        WHEN s.trx_age_sec >= 1800                              THEN 'CRITICAL'
        WHEN s.trx_state = 'LOCK WAIT'                          THEN 'WARNING'
        WHEN s.trx_age_sec >= 300                               THEN 'WARNING'
        WHEN COALESCE(s.trx_rows_locked, 0)   >= 10000          THEN 'WARNING'
        WHEN COALESCE(s.trx_rows_modified, 0) >= 10000          THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                     AS risk_level,
    -- idle-in-transaction(트랜잭션 열어둔 채 Sleep) = 잠재 블로커 후보
    CASE WHEN s.command = 'Sleep' AND s.trx_age_sec >= 60 THEN 'Y' ELSE 'N' END AS idle_in_trx_yn,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN s.trx_state = 'LOCK WAIT'              THEN 'LOCK_WAIT' END,
        CASE WHEN s.trx_age_sec >= 300                   THEN 'LONG_TRX_5MIN' END,
        CASE WHEN COALESCE(s.trx_rows_locked,0)   >= 10000 THEN 'ROWS_LOCKED_HIGH' END,
        CASE WHEN COALESCE(s.trx_rows_modified,0) >= 10000 THEN 'ROWS_MODIFIED_HIGH' END,
        CASE WHEN s.command = 'Sleep' AND s.trx_age_sec >= 60 THEN 'IDLE_IN_TRX' END
    ), '')                                                 AS risk_reason
    --========================== ▲ TUNING ▲ ==========================--
FROM itstone.m_innodb_trx s
WHERE s.collect_time =
(
    SELECT MAX(a.collect_time)
    FROM itstone.m_innodb_trx a
    WHERE a.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_innodb_trx) - INTERVAL '10 seconds'
)
-- ★ 이벤트 신선도 가드(B안): 트랜잭션 테이블 최신 시각이 heartbeat(global_status)보다
--   8초 이상 뒤처지면 = 이미 종료된 것 → 빈 결과(끝난 트랜잭션을 현재로 표시 방지).
--   m_innodb_trx 는 0건이 정상(트랜잭션 없음). 동일 MariaDB 시계 비교라 클럭 스큐 무관.
--   전체 수집 중단은 summary_kpi.data_age_sec 가 별도 포착.
  AND (SELECT MAX(collect_time) FROM itstone.m_innodb_trx)
      >= (SELECT MAX(collect_time) FROM itstone.m_global_status) - INTERVAL '8 seconds';

-- ───────── [PG_VIEW-v_m_lock_tree_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_lock_tree_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Real-Time Monitor > Lock Tree (blocker → waiter 관계)
--------------------------------------------------------------------------------
-- [수집 가능 판정 — capability-check]
--   MariaDB는 버전 번호로 단정하지 않는다(11.4 LTS도 INNODB_LOCK_WAITS/LOCKS/TRX 제공).
--   설치 시 해당 I_S 테이블 존재 여부 + PROCESS 권한을 capability-check로 판정한다.
--   결과 0건='락 없음', capability 실패='수집 불가'로 별도 표시한다.
--
-- [설계]
--   - 현재 잠금 대기 = 최근 수집 사이클(MAX collect_time)의 행. 보통 0건.
--   - risk_level / kill_candidate_yn / root_blocker_yn 를 ▼TUNING▼ 에서 계산.
--   - root_blocker_yn : 해당 blocking_trx 가 같은 스냅샷에서 스스로 waiter 가
--     아니면 'Y'(체인의 뿌리). UI 트리에서 최상위 가해자 식별.
--   - kill 대상은 root_blocker 중 system user 제외 + 일정 대기 초과.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_lock_tree_now AS
SELECT
    s.collect_time,
    s.waiting_trx_id,
    s.waiting_thread_id,
    s.waiting_user,
    s.waiting_host,
    s.waiting_db,
    s.waiting_sql_sample,
    s.blocking_trx_id,
    s.blocking_thread_id,
    s.blocking_user,
    s.blocking_host,
    s.blocking_db,
    s.blocking_sql_sample,
    s.lock_object,
    s.lock_type_summary,
    s.wait_sec,
    --========================== ▼ TUNING ▼ ==========================--
    CASE WHEN NOT EXISTS (
            SELECT 1 FROM itstone.m_innodb_lock_wait w2
            WHERE w2.collect_time   = s.collect_time
              AND w2.waiting_trx_id = s.blocking_trx_id
         ) THEN 'Y' ELSE 'N' END                                       AS root_blocker_yn,
    CASE
        WHEN s.wait_sec >= 300 THEN 'CRITICAL'
        WHEN s.wait_sec >= 60  THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                                AS risk_level,
    CASE
        WHEN s.blocking_thread_id IS NOT NULL
         AND s.wait_sec >= 60
         AND COALESCE(s.blocking_user, '') <> 'system user'
         AND NOT EXISTS (
            SELECT 1 FROM itstone.m_innodb_lock_wait w3
            WHERE w3.collect_time   = s.collect_time
              AND w3.waiting_trx_id = s.blocking_trx_id
         )
        THEN 'Y' ELSE 'N'
    END                                                                AS kill_candidate_yn,
    NULLIF(CONCAT_WS(', ',
        'INNODB_LOCK_WAIT',
        CASE WHEN s.wait_sec >= 60  THEN 'WAIT_60SEC_OVER' END,
        CASE WHEN s.wait_sec >= 300 THEN 'WAIT_300SEC_OVER' END
    ), '')                                                             AS risk_reason
    --========================== ▲ TUNING ▲ ==========================--
FROM itstone.m_innodb_lock_wait s
WHERE s.collect_time =
(
    SELECT MAX(a.collect_time)
    FROM itstone.m_innodb_lock_wait a
    WHERE a.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_innodb_lock_wait) - INTERVAL '10 seconds'
)
-- ★ 이벤트 신선도 가드(B안): Lock Wait 테이블 최신 시각이 heartbeat(global_status)보다
--   8초 이상 뒤처지면 = 락이 이미 해소된 것 → 빈 결과(끝난 락을 현재 장애로 표시 방지).
--   m_innodb_lock_wait 은 0건이 정상(락 없음). 동일 MariaDB 시계 비교라 클럭 스큐 무관.
--   전체 수집 중단은 summary_kpi.data_age_sec 가 별도 포착.
  AND (SELECT MAX(collect_time) FROM itstone.m_innodb_lock_wait)
      >= (SELECT MAX(collect_time) FROM itstone.m_global_status) - INTERVAL '8 seconds'
ORDER BY s.wait_sec DESC;

-- ───────── [PG_VIEW-v_m_buffer_pool_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_buffer_pool_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Memory 탭 > InnoDB Buffer Pool 패널
--------------------------------------------------------------------------------
-- [설계]
--   - 최근 수집 사이클(MAX collect_time)의 pool 별 행.
--   - free_pct / dirty_pct / data_pct / hit_pct 파생 + risk 를 ▼TUNING▼ 에서.
--   - hit_pct = hit_rate_per_1000 / 10 (InnoDB 제공 게이지).
--   - 누적 기반 정밀 hit 가 필요하면 number_pages_get/read 에 LAG 적용 가능(주석).
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_buffer_pool_now AS
SELECT
    s.collect_time,
    s.pool_id,
    s.pool_size_pages,
    s.free_buffers,
    s.database_pages,
    s.modified_database_pages,
    ROUND(s.free_buffers            / NULLIF(s.pool_size_pages, 0) * 100, 2) AS free_pct,
    ROUND(s.database_pages          / NULLIF(s.pool_size_pages, 0) * 100, 2) AS data_pct,
    ROUND(s.modified_database_pages / NULLIF(s.database_pages, 0)  * 100, 2) AS dirty_pct,
    ROUND(s.hit_rate_per_1000 / 10.0, 2)                                     AS hit_pct,
    s.pending_reads,
    s.pending_flush_lru,
    s.pending_flush_list,
    s.pages_read_rate,
    s.pages_written_rate,
    s.pages_created_rate,
    --========================== ▼ TUNING ▼ ==========================--
    CASE
        WHEN s.hit_rate_per_1000 / 10.0 < 90 THEN 'CRITICAL'
        WHEN s.free_buffers / NULLIF(s.pool_size_pages, 0) * 100 < 1 THEN 'CRITICAL'
        WHEN s.hit_rate_per_1000 / 10.0 < 95 THEN 'WARNING'
        WHEN s.modified_database_pages / NULLIF(s.database_pages, 0) * 100 >= 75 THEN 'WARNING'
        WHEN COALESCE(s.pending_reads, 0) + COALESCE(s.pending_flush_list, 0) >= 100 THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                                     AS risk_level,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN s.hit_rate_per_1000 / 10.0 < 95 THEN 'BUFFER_HIT_LOW' END,
        CASE WHEN s.free_buffers / NULLIF(s.pool_size_pages, 0) * 100 < 1 THEN 'FREE_BUFFERS_LOW' END,
        CASE WHEN s.modified_database_pages / NULLIF(s.database_pages, 0) * 100 >= 75 THEN 'DIRTY_PAGES_HIGH' END,
        CASE WHEN COALESCE(s.pending_reads,0) + COALESCE(s.pending_flush_list,0) >= 100 THEN 'IO_PENDING_HIGH' END
    ), '')                                                                  AS risk_reason
    --========================== ▲ TUNING ▲ ==========================--
FROM itstone.m_innodb_buffer_pool s
WHERE s.collect_time =
(
    SELECT MAX(a.collect_time)
    FROM itstone.m_innodb_buffer_pool a
    WHERE a.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_innodb_buffer_pool) - INTERVAL '30 seconds'
);

-- ───────── [PG_VIEW-v_m_index_io_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_index_io_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : SQL Analysis > Index/Table I/O Hotspot (최근 1분 구간 델타)
--------------------------------------------------------------------------------
-- [설계]
--   - 누적 I/O → 두 스냅샷 LAG() 델타 → per-sec/avg wait/순위/분류/risk.
--   - GREATEST(...,0) : P_S truncate / 카운터 리셋 음수 가드.
--   - prev IS NOT NULL + delta>0 : 신규/무활동 행 제외.
--   - rank_io(전체) / rank_table_io(테이블 내) ROW_NUMBER.
--   - index_usage_type / risk 는 ▼TUNING▼ 에서. ps→ms = /1000000000.0.
--   - NO_INDEX(=INDEX_NAME NULL)는 풀스캔 read 와 INSERT/write 경로가 섞이므로
--     표시는 read 유무로 NO_INDEX_READ / INSERT_OR_WRITE_PATH 분리. risk 는 read 게이팅.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_index_io_now AS
SELECT
    r.collect_time,
    r.object_schema,
    r.table_name,
    COALESCE(r.index_name, 'NO_INDEX')                                     AS index_name,  -- 표시명. raw 는 NULL=인덱스 미사용(풀스캔) — 실제 인덱스명 'NO_INDEX'와 충돌 없음
    r.delta_count                                                          AS io_count,
    ROUND(r.delta_count       / NULLIF(r.elapsed_sec, 0), 2)               AS io_per_sec,
    ROUND(r.delta_read        / NULLIF(r.elapsed_sec, 0), 2)               AS read_per_sec,
    ROUND(r.delta_write       / NULLIF(r.elapsed_sec, 0), 2)               AS write_per_sec,
    ROUND(r.delta_wait_ps     / NULLIF(r.delta_count, 0) / 1000000000.0, 3) AS avg_wait_ms,
    ROUND(r.delta_read  * 100.0 / NULLIF(r.delta_count, 0), 1)             AS read_pct,
    ROUND(r.delta_write * 100.0 / NULLIF(r.delta_count, 0), 1)             AS write_pct,
    r.rank_io,
    ROW_NUMBER() OVER (PARTITION BY r.object_schema, r.table_name ORDER BY r.delta_count DESC) AS rank_table_io,
    --========================== ▼ TUNING ▼ ==========================--
    CASE
        -- NO_INDEX(INDEX_NAME=NULL)는 '인덱스 미사용 read(풀스캔)'와 'INSERT/write 경로'가 한 행에 섞인다.
        -- → read 유무로 표시명 분리(화면에서 INSERT 많은 테이블을 '인덱스 미사용 문제'로 오해 방지).
        --   risk 는 아래에서 delta_read 게이팅 유지(표시만 분리, 판정 변화 없음).
        WHEN r.index_name IS NULL AND r.delta_read  > 0               THEN 'NO_INDEX_READ'
        WHEN r.index_name IS NULL AND r.delta_read = 0 AND r.delta_write > 0 THEN 'INSERT_OR_WRITE_PATH'
        WHEN r.index_name IS NULL                                      THEN 'NO_INDEX'  -- read=write=0 (이론상 미발생, delta_count>0 가드)
        WHEN r.delta_read = 0 AND r.delta_write > 0                         THEN 'WRITE_ONLY_INDEX'
        WHEN r.delta_write = 0 AND r.delta_read > 0                         THEN 'READ_ONLY'
        WHEN r.delta_read >= r.delta_write * 5                              THEN 'READ_HEAVY'
        WHEN r.delta_write >= r.delta_read * 5                             THEN 'WRITE_HEAVY'
        ELSE 'MIXED'
    END                                                                    AS index_usage_type,
    CASE
        WHEN r.index_name IS NULL
         AND r.delta_read / NULLIF(r.elapsed_sec, 0) >= 100                 THEN 'CRITICAL'
        WHEN r.delta_wait_ps / NULLIF(r.delta_count, 0) / 1000000000.0 >= 10 THEN 'CRITICAL'
        WHEN r.index_name IS NULL AND r.delta_read > 0                 THEN 'WARNING'
        WHEN r.delta_wait_ps / NULLIF(r.delta_count, 0) / 1000000000.0 >= 1 THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                                    AS risk_level,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN r.index_name IS NULL AND r.delta_read > 0 THEN 'FULL_SCAN_IO' END,
        CASE WHEN r.delta_wait_ps / NULLIF(r.delta_count,0) / 1000000000.0 >= 1 THEN 'HIGH_AVG_WAIT' END
    ), '')                                                                 AS risk_reason
    --========================== ▲ TUNING ▲ ==========================--
FROM
(
    SELECT z.*, ROW_NUMBER() OVER (ORDER BY z.delta_count DESC) AS rank_io
    FROM
    (
        SELECT
            p.collect_time, p.object_schema, p.table_name, p.index_name,
            EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time))     AS elapsed_sec,
            GREATEST(p.count_star_cum        - p.prev_count, 0)            AS delta_count,
            GREATEST(p.count_read_cum        - p.prev_read,  0)            AS delta_read,
            GREATEST(p.count_write_cum       - p.prev_write, 0)           AS delta_write,
            GREATEST(p.sum_timer_wait_ps_cum - p.prev_wait,  0)            AS delta_wait_ps
        FROM
        (
            SELECT
                x.collect_time, x.object_schema, x.table_name, x.index_name,
                x.count_star_cum,        LAG(x.count_star_cum)        OVER w AS prev_count,
                x.count_read_cum,        LAG(x.count_read_cum)        OVER w AS prev_read,
                x.count_write_cum,       LAG(x.count_write_cum)       OVER w AS prev_write,
                x.sum_timer_wait_ps_cum, LAG(x.sum_timer_wait_ps_cum) OVER w AS prev_wait,
                LAG(x.collect_time) OVER w AS prev_collect_time
            FROM itstone.m_index_io_stat x
            WHERE x.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_index_io_stat) - INTERVAL '3 minutes'
            WINDOW w AS (PARTITION BY x.object_schema, x.table_name, x.index_name ORDER BY x.collect_time)
        ) p
        WHERE p.prev_collect_time IS NOT NULL
          -- ★ 갭 방지: m_index_io_stat 1분 주기. 수집 재개 직후 누적 delta 가 현재 now 에 잡혀 Index I/O
          --   순간 과대표시 차단. 간격 120초 초과면 제외(해당 cycle 빈 결과 → 다음 정상 cycle 회복).
          AND EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time)) <= 120
          AND p.collect_time = (SELECT MAX(collect_time) FROM itstone.m_index_io_stat
                                WHERE collect_time >= (SELECT MAX(collect_time) FROM itstone.m_index_io_stat) - INTERVAL '3 minutes')
          AND GREATEST(p.count_star_cum - p.prev_count, 0) > 0
    ) z
) r
-- Top-N 절단 없음: 전체 인덱스 + risk 출력 → summary 종합 위험이 51위 이하도 포착.
-- 화면 Top-N 은 C# 이 적용: SELECT ... FROM v_m_index_io_now WHERE rank_io <= 50.
ORDER BY r.rank_io;

-- ───────── [PG_VIEW-v_m_table_lock_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_table_lock_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Real-Time Monitor > Table Lock 경합 (테이블별 잠금 대기)
--------------------------------------------------------------------------------
-- [설계]
--   - 누적 lock wait → LAG() 델타 → 초당 lock wait / 평균 대기 ms / read·write 분리.
--   - GREATEST(...,0) 음수 가드, prev IS NOT NULL + delta>0 필터.
--   - 전체 경합 순위 rank_lock. risk 는 ▼TUNING▼. ps→ms = /1000000000.0.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_table_lock_now AS
SELECT
    r.collect_time,
    r.object_schema,
    r.table_name,
    r.delta_count                                                          AS lock_wait_count,
    ROUND(r.delta_count / NULLIF(r.elapsed_sec, 0), 2)                     AS lock_wait_per_sec,
    ROUND(r.delta_read  / NULLIF(r.elapsed_sec, 0), 2)                     AS read_lock_per_sec,
    ROUND(r.delta_write / NULLIF(r.elapsed_sec, 0), 2)                     AS write_lock_per_sec,
    ROUND(r.delta_wait_ps / NULLIF(r.delta_count, 0) / 1000000000.0, 3)    AS avg_lock_wait_ms,
    r.rank_lock,
    --========================== ▼ TUNING ▼ ==========================--
    CASE
        WHEN r.delta_wait_ps / NULLIF(r.delta_count, 0) / 1000000000.0 >= 100 THEN 'CRITICAL'
        WHEN r.delta_count / NULLIF(r.elapsed_sec, 0) >= 100                  THEN 'WARNING'
        WHEN r.delta_wait_ps / NULLIF(r.delta_count, 0) / 1000000000.0 >= 10  THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                                    AS risk_level,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN r.delta_wait_ps / NULLIF(r.delta_count,0) / 1000000000.0 >= 10 THEN 'LOCK_WAIT_LATENCY_HIGH' END,
        CASE WHEN r.delta_count / NULLIF(r.elapsed_sec,0) >= 100 THEN 'LOCK_CONTENTION_HIGH' END
    ), '')                                                                 AS risk_reason
    --========================== ▲ TUNING ▲ ==========================--
FROM
(
    SELECT z.*, ROW_NUMBER() OVER (ORDER BY z.delta_wait_ps DESC) AS rank_lock
    FROM
    (
        SELECT
            p.collect_time, p.object_schema, p.table_name,
            EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time))     AS elapsed_sec,
            GREATEST(p.count_star_cum        - p.prev_count, 0)            AS delta_count,
            GREATEST(p.count_read_cum        - p.prev_read,  0)            AS delta_read,
            GREATEST(p.count_write_cum       - p.prev_write, 0)           AS delta_write,
            GREATEST(p.sum_timer_wait_ps_cum - p.prev_wait,  0)            AS delta_wait_ps
        FROM
        (
            SELECT
                x.collect_time, x.object_schema, x.table_name,
                x.count_star_cum,        LAG(x.count_star_cum)        OVER w AS prev_count,
                x.count_read_cum,        LAG(x.count_read_cum)        OVER w AS prev_read,
                x.count_write_cum,       LAG(x.count_write_cum)       OVER w AS prev_write,
                x.sum_timer_wait_ps_cum, LAG(x.sum_timer_wait_ps_cum) OVER w AS prev_wait,
                LAG(x.collect_time) OVER w AS prev_collect_time
            FROM itstone.m_table_lock_stat x
            WHERE x.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_table_lock_stat) - INTERVAL '3 minutes'
            WINDOW w AS (PARTITION BY x.object_schema, x.table_name ORDER BY x.collect_time)
        ) p
        WHERE p.prev_collect_time IS NOT NULL
          -- ★ 갭 방지: m_table_lock_stat 1분 주기. 수집 재개 직후 누적 delta 가 현재 now 에 잡혀
          --   Table Lock Wait 순간 과대표시 차단. 간격 120초 초과면 제외(다음 정상 cycle 회복).
          AND EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time)) <= 120
          AND p.collect_time = (SELECT MAX(collect_time) FROM itstone.m_table_lock_stat
                                WHERE collect_time >= (SELECT MAX(collect_time) FROM itstone.m_table_lock_stat) - INTERVAL '3 minutes')
          AND GREATEST(p.count_star_cum - p.prev_count, 0) > 0
    ) z
) r
-- Top-N 절단 없음: 전체 테이블 + risk 출력 → summary 종합 위험이 51위 이하도 포착.
-- 화면 Top-N 은 C# 이 적용: SELECT ... FROM v_m_table_lock_now WHERE rank_lock <= 50.
ORDER BY r.rank_lock;

-- ───────── [PG_VIEW-v_m_file_io_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_file_io_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Storage 탭 > 파일 유형별 I/O (File I/O by Event Type) — IOPS / MB/s / 지연
--------------------------------------------------------------------------------
-- [설계]
--   ★ grain = 이벤트 유형(EVENT_NAME / file_category: DATA/LOG/BINLOG/RELAYLOG/TEMP/OTHER).
--     파일 '경로'별 아님(source = file_summary_by_event_name). → UI 제목은 "파일 유형별 I/O"로,
--     "File I/O Hotspot" / "어느 파일이 느린가"처럼 경로 단위로 표현 금지(과장).
--     경로별 핫스팟(어느 .ibd 가 병목인가)은 file_summary_by_instance 기반 별도 수집 — v1.1.
--   - 누적 I/O → LAG() 델타 → IOPS / MB per sec / avg latency ms.
--   - GREATEST(...,0) 음수 가드, prev IS NOT NULL + (read+write+misc) delta>0 필터(misc-only 도 노출).
--   - 정렬 = 총 I/O 대기시간(read+write+misc 타이머) — fsync 무거운 이벤트 상위.
--   - ps→ms = /1000000000.0,  bytes→MB = /1048576.0.
--   - risk = 평균 read/write 지연 + fsync(misc) 지연(단 LOG/BINLOG/RELAYLOG 만) 는 ▼TUNING▼.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_file_io_now AS
SELECT
    d.collect_time,
    d.event_name,
    d.file_category,
    ROUND((d.delta_read + d.delta_write) / NULLIF(d.elapsed_sec, 0), 1)     AS iops,
    ROUND(d.delta_read  / NULLIF(d.elapsed_sec, 0), 1)                      AS read_iops,
    ROUND(d.delta_write / NULLIF(d.elapsed_sec, 0), 1)                      AS write_iops,
    ROUND(d.delta_bytes_read  / 1048576.0 / NULLIF(d.elapsed_sec, 0), 3)    AS read_mb_per_sec,
    ROUND(d.delta_bytes_write / 1048576.0 / NULLIF(d.elapsed_sec, 0), 3)    AS write_mb_per_sec,
    ROUND(d.delta_timer_read_ps  / NULLIF(d.delta_read, 0)  / 1000000000.0, 3) AS avg_read_ms,
    ROUND(d.delta_timer_write_ps / NULLIF(d.delta_write, 0) / 1000000000.0, 3) AS avg_write_ms,
    -- ★ misc(fsync/open/close/sync 등) 표면화. LOG/BINLOG/RELAYLOG 의 misc 는 사실상 fsync(커밋·복제 내구성
    --   비용) → risk 에 반영. DATA/TEMP/OTHER 의 misc 는 open/close 노이즈 혼입이라 risk 제외(표시만).
    ROUND(d.delta_misc / NULLIF(d.elapsed_sec, 0), 1)                       AS misc_iops,
    ROUND(d.delta_timer_misc_ps / NULLIF(d.delta_misc, 0) / 1000000000.0, 3) AS avg_misc_ms,
    --========================== ▼ TUNING ▼ ==========================--
    CASE
        WHEN d.delta_timer_read_ps  / NULLIF(d.delta_read, 0)  / 1000000000.0 >= 20 THEN 'CRITICAL'
        WHEN d.delta_timer_write_ps / NULLIF(d.delta_write, 0) / 1000000000.0 >= 20 THEN 'CRITICAL'
        WHEN d.file_category IN ('LOG','BINLOG','RELAYLOG')
             AND d.delta_timer_misc_ps / NULLIF(d.delta_misc, 0) / 1000000000.0 >= 20 THEN 'CRITICAL'  -- fsync
        WHEN d.delta_timer_read_ps  / NULLIF(d.delta_read, 0)  / 1000000000.0 >= 5  THEN 'WARNING'
        WHEN d.delta_timer_write_ps / NULLIF(d.delta_write, 0) / 1000000000.0 >= 5  THEN 'WARNING'
        WHEN d.file_category IN ('LOG','BINLOG','RELAYLOG')
             AND d.delta_timer_misc_ps / NULLIF(d.delta_misc, 0) / 1000000000.0 >= 5  THEN 'WARNING'   -- fsync
        ELSE 'NORMAL'
    END                                                                    AS risk_level,
    NULLIF(CONCAT_WS(', ',
        CASE WHEN d.delta_timer_read_ps  / NULLIF(d.delta_read, 0)  / 1000000000.0 >= 5 THEN 'READ_LATENCY_HIGH' END,
        CASE WHEN d.delta_timer_write_ps / NULLIF(d.delta_write, 0) / 1000000000.0 >= 5 THEN 'WRITE_LATENCY_HIGH' END,
        CASE WHEN d.file_category IN ('LOG','BINLOG','RELAYLOG')
              AND d.delta_timer_misc_ps / NULLIF(d.delta_misc, 0) / 1000000000.0 >= 5 THEN 'FSYNC_LATENCY_HIGH' END
    ), '')                                                                 AS risk_reason
    --========================== ▲ TUNING ▲ ==========================--
FROM
(
    SELECT
        p.collect_time, p.event_name, p.file_category,
        EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time))         AS elapsed_sec,
        GREATEST(p.count_read_cum         - p.prev_read,        0)         AS delta_read,
        GREATEST(p.count_write_cum        - p.prev_write,       0)         AS delta_write,
        GREATEST(p.sum_bytes_read_cum     - p.prev_bread,       0)         AS delta_bytes_read,
        GREATEST(p.sum_bytes_write_cum    - p.prev_bwrite,      0)         AS delta_bytes_write,
        GREATEST(p.sum_timer_read_ps_cum  - p.prev_tread,       0)         AS delta_timer_read_ps,
        GREATEST(p.sum_timer_write_ps_cum - p.prev_twrite,      0)         AS delta_timer_write_ps,
        GREATEST(p.count_misc_cum         - p.prev_misc,        0)         AS delta_misc,
        GREATEST(p.sum_timer_misc_ps_cum  - p.prev_tmisc,       0)         AS delta_timer_misc_ps
    FROM
    (
        SELECT
            x.collect_time, x.event_name, x.file_category,
            x.count_read_cum,         LAG(x.count_read_cum)         OVER w AS prev_read,
            x.count_write_cum,        LAG(x.count_write_cum)        OVER w AS prev_write,
            x.sum_bytes_read_cum,     LAG(x.sum_bytes_read_cum)     OVER w AS prev_bread,
            x.sum_bytes_write_cum,    LAG(x.sum_bytes_write_cum)    OVER w AS prev_bwrite,
            x.sum_timer_read_ps_cum,  LAG(x.sum_timer_read_ps_cum)  OVER w AS prev_tread,
            x.sum_timer_write_ps_cum, LAG(x.sum_timer_write_ps_cum) OVER w AS prev_twrite,
            x.count_misc_cum,         LAG(x.count_misc_cum)         OVER w AS prev_misc,
            x.sum_timer_misc_ps_cum,  LAG(x.sum_timer_misc_ps_cum)  OVER w AS prev_tmisc,
            LAG(x.collect_time) OVER w AS prev_collect_time
        FROM itstone.m_file_io_stat x
        WHERE x.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_file_io_stat) - INTERVAL '3 minutes'
        WINDOW w AS (PARTITION BY x.event_name ORDER BY x.collect_time)
    ) p
    WHERE p.prev_collect_time IS NOT NULL
      -- ★ 갭 방지: m_file_io_stat 1분 주기. 수집 재개 직후 누적 delta 가 현재 now 에 잡혀 File I/O
      --   순간 과대표시 차단. 간격 120초 초과면 제외(해당 cycle 빈 결과 → 다음 정상 cycle 회복).
      AND EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time)) <= 120
      AND p.collect_time = (SELECT MAX(collect_time) FROM itstone.m_file_io_stat
                            WHERE collect_time >= (SELECT MAX(collect_time) FROM itstone.m_file_io_stat) - INTERVAL '3 minutes')
      -- ★ misc 포함: misc-only 이벤트(fsync/open/close 로 read=write=0)도 노출. misc 를 화면 중요신호
      --   (fsync)로 올렸으므로 read/write 만으로 거르면 log/binlog 의 fsync성 대기가 누락됨.
      AND (GREATEST(p.count_read_cum  - p.prev_read,  0)
         + GREATEST(p.count_write_cum - p.prev_write, 0)
         + GREATEST(p.count_misc_cum  - p.prev_misc,  0)) > 0
) d
-- ★ 총 I/O 대기시간(read+write+misc 타이머 = delta_timer_wait) 기준 — fsync 무거운 이벤트도 상위 노출.
ORDER BY (d.delta_timer_read_ps + d.delta_timer_write_ps + d.delta_timer_misc_ps) DESC;

-- ───────── [PG_VIEW-v_m_instance_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_instance_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Dashboard > Instance 카드 (인스턴스 식별/접속/스레드 현황)
-- 원천 : m_instance_status (10초, Basic 모드 — 전 고객 수집)
-- [설계]
--   - 최신 1행 스냅샷. connection_usage_pct 는 자체 임계 판정(카드 배지용).
--   - data_age_sec : 순수 PG 시계(statement_timestamp) − 수집시각. 프리시니스 신호.
--   - CTE 미사용.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW itstone.v_m_instance_now AS
SELECT
    i.host_name,                                                  -- 호스트명
    i.port,                                                       -- 포트
    i.version,                                                    -- MariaDB 버전
    i.version_comment,                                            -- 버전 코멘트
    i.read_only_yn,                                               -- read_only 여부
    i.uptime_sec,                                                 -- 가동 초
    i.uptime_days,                                                -- 가동 일
    i.max_connections,                                            -- 최대 연결
    i.threads_connected,                                          -- 현재 연결
    i.threads_running,                                            -- 실행 중 스레드
    i.threads_cached,                                             -- 스레드 캐시
    i.connection_usage_pct,                                       -- 연결 사용률(%)
    i.max_used_connections,                                       -- 최대 동시 연결
    i.max_used_conn_pct,                                          -- 최대 연결 사용률(%)
    i.slow_queries_cum,                                           -- 슬로우 쿼리 누적
    i.open_tables,                                                -- Open Tables
    i.performance_schema_yn,                                      -- P_S 활성 여부
    CASE
        WHEN i.connection_usage_pct >= 90 THEN 'crit'
        WHEN i.connection_usage_pct >= 75 THEN 'warn'
        ELSE 'ok'
    END                                          AS conn_usage_status,
    EXTRACT(EPOCH FROM (statement_timestamp() - i.collect_time))::int AS data_age_sec
FROM itstone.m_instance_status i
WHERE i.collect_time = (SELECT MAX(collect_time) FROM itstone.m_instance_status);

-- ───────── [PG_VIEW-v_m_innodb_metrics_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_innodb_metrics_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Dashboard > InnoDB Metrics 카드 (INNODB_METRICS 현재 스냅샷)
-- 원천 : m_innodb_metrics (10초, Basic 모드 — I_S.INNODB_METRICS)
-- [설계]
--   - 최신 1행 스냅샷. 카테고리/서브시스템별 현재 카운트 노출.
--   - metric_count 는 활성화 후 누적, count_reset 은 리셋 이후 값(둘 다 raw 노출 —
--     델타/추이는 화면 또는 별도 trend 뷰에서 산출).
--   - CTE 미사용.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW itstone.v_m_innodb_metrics_now AS
SELECT
    m.metric_name,                                              -- 메트릭명
    m.subsystem,                                                -- 서브시스템
    m.metric_category,                                          -- 카테고리
    m.metric_count,                                             -- 누적 카운트
    m.count_reset,                                              -- 리셋 이후 카운트
    m.metric_type,                                              -- TYPE
    m.is_counter_yn,                                            -- counter 여부
    EXTRACT(EPOCH FROM (statement_timestamp() - m.collect_time))::int AS data_age_sec
FROM itstone.m_innodb_metrics m
WHERE m.collect_time = (SELECT MAX(collect_time) FROM itstone.m_innodb_metrics)
ORDER BY m.metric_category, m.metric_name;

-- ───────── [PG_VIEW-v_m_variable_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_variable_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Dashboard > Variable Snapshot 카드 (주요 설정값 현재 스냅샷)
-- 원천 : m_variable_snapshot (60분, Basic 모드)
-- [설계]
--   - 최신 스냅샷에서 운영상 중요한 전역변수만 화이트리스트로 노출(설정 카드용).
--   - 전체 변수 비교/드리프트는 v_m_variable_drift 담당(역할 분리).
--   - CTE 미사용.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW itstone.v_m_variable_now AS
SELECT
    v.variable_name,                                             -- 변수명
    v.variable_value,                                            -- 값
    v.is_numeric_yn,                                             -- 숫자형 여부
    EXTRACT(EPOCH FROM (statement_timestamp() - v.collect_time))::int AS data_age_sec
FROM itstone.m_variable_snapshot v
WHERE v.collect_time = (SELECT MAX(collect_time) FROM itstone.m_variable_snapshot)
  AND v.variable_name IN (
        'version','max_connections','innodb_buffer_pool_size','innodb_log_file_size',
        'innodb_flush_log_at_trx_commit','sync_binlog','innodb_flush_method',
        'innodb_io_capacity','innodb_read_io_threads','innodb_write_io_threads',
        'max_allowed_packet','wait_timeout','interactive_timeout',
        'table_open_cache','thread_cache_size','tmp_table_size','max_heap_table_size',
        'slow_query_log','long_query_time','performance_schema'
      )
ORDER BY v.variable_name;

-- ───────── [PG_VIEW-v_m_os_resource_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_os_resource_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Summary KPI + System 탭 > Host CPU/Memory/Swap/IO Wait 현재 카드
-- 원천 : m_os_cpu_stat + m_os_memory_stat (Host Agent 선택 수집)
--        + m_target_capability(os_agent_yn) + m_collector_health(OS_CPU/OS_MEMORY heartbeat)
-- [설계]
--   - ★ 상태 우선순위(단일 권위 컬럼 resource_status):
--       AGENT_REQUIRED > FAIL > NO_DATA > STALE > CRITICAL > WARN > PARTIAL > NORMAL
--   - ★ 모듈별 판정(멘토 5차 문제1) : heartbeat/데이터를 CPU·MEM 통합 1건이 아니라
--       각 모듈별로 본다.
--       · FAIL  : CPU heartbeat 또는 MEM heartbeat 최신값이 'FAIL' (한쪽만 실패해도 감지)
--       · STALE : CPU age 또는 MEM age 가 STALE_SEC(30s) 초과 (각 소스 개별 판정 — 한쪽만
--                 끊겨도 감지. GREATEST 단일 최신 기준 폐기)
--       · PARTIAL: CPU/MEM 중 한쪽 데이터 없음(단, 둘 다 없음은 NO_DATA) 또는 행 status='PARTIAL'
--   - ★ 대표 collect_time(문제2) : COALESCE(c,m) 아님 → GREATEST 로 실제 최신 시각.
--   - os_agent_yn 덮어쓰기 방어(4차) : capability 뿐 아니라 OS heartbeat 존재도 함께 봄.
--   - collect_time = PG 생성 → age 는 순수 PG 시계(권위값). STALE_SEC/임계값 향후 cfg 이관.
--   - ★ CTE 미사용 : 단일행 spine + LATERAL(항상 1행 → Agent 미설치도 카드 렌더).
--------------------------------------------------------------------------------
-- ★ 컬럼 구성 변경(cpu_hb_status/mem_hb_status/cpu_age_sec/mem_age_sec 추가)으로
--   기존 배포 갱신 시 CREATE OR REPLACE 가 컬럼 개명 불가 → 먼저 DROP.
DROP VIEW IF EXISTS itstone.v_m_os_resource_now;
CREATE OR REPLACE VIEW itstone.v_m_os_resource_now AS
SELECT
    -- ★ 대표 시각 = 실제 최신(문제2)
    COALESCE(GREATEST(c.collect_time, m.collect_time),
             c.collect_time, m.collect_time)                 AS collect_time,
    COALESCE(c.host_name, m.host_name)                       AS host_name,
    COALESCE(c.os_type, m.os_type)                           AS os_type,
    -- CPU
    c.cpu_usage_pct,
    c.cpu_user_pct,
    c.cpu_system_pct,
    c.cpu_iowait_pct,
    c.cpu_idle_pct,
    c.load_avg_1m,
    c.load_avg_5m,
    c.load_avg_15m,
    c.cpu_count,
    -- Memory
    m.mem_total_bytes,
    m.mem_available_bytes,
    m.mem_used_pct,
    m.swap_total_bytes,
    m.swap_used_pct,
    m.memory_risk,
    -- Agent/수집 상태(모듈별 노출)
    cap.os_agent_yn,
    c.status                                                 AS cpu_collect_status,
    m.status                                                 AS mem_collect_status,
    hbc.s                                                    AS cpu_hb_status,
    hbm.s                                                    AS mem_hb_status,
    -- 소스별 신선도(문제1 근거 — 각 age 노출)
    EXTRACT(EPOCH FROM (statement_timestamp() - c.collect_time))::int AS cpu_age_sec,
    EXTRACT(EPOCH FROM (statement_timestamp() - m.collect_time))::int AS mem_age_sec,
    -- ★ 화면 표시 상태(단일 권위 컬럼)
    CASE
        WHEN COALESCE(cap.os_agent_yn,'N') <> 'Y'
         AND hbc.t IS NULL AND hbm.t IS NULL
         AND c.collect_time IS NULL AND m.collect_time IS NULL   THEN 'AGENT_REQUIRED'
        WHEN hbc.s = 'FAIL' OR hbm.s = 'FAIL'                     THEN 'FAIL'
        WHEN c.collect_time IS NULL AND m.collect_time IS NULL    THEN 'NO_DATA'
        WHEN (c.collect_time IS NOT NULL
              AND EXTRACT(EPOCH FROM (statement_timestamp() - c.collect_time)) > 30)
          OR (m.collect_time IS NOT NULL
              AND EXTRACT(EPOCH FROM (statement_timestamp() - m.collect_time)) > 30)  THEN 'STALE'
        WHEN COALESCE(c.cpu_usage_pct,0) >= 90
          OR COALESCE(m.mem_used_pct,0) >= 90
          OR COALESCE(m.swap_used_pct,0) >= 10                   THEN 'CRITICAL'
        WHEN COALESCE(c.cpu_usage_pct,0) >= 80
          OR COALESCE(m.mem_used_pct,0) >= 80
          OR COALESCE(m.swap_used_pct,0) >  0                    THEN 'WARN'
        WHEN c.collect_time IS NULL OR m.collect_time IS NULL
          OR c.status = 'PARTIAL' OR m.status = 'PARTIAL'        THEN 'PARTIAL'
        ELSE 'NORMAL'
    END                                                      AS resource_status,
    -- 개별 보조 배지(CPU / Mem / Swap / IOWait) — C# 카드별 색상
    CASE WHEN c.cpu_usage_pct  >= 90 THEN 'crit' WHEN c.cpu_usage_pct  >= 80 THEN 'warn'
         WHEN c.cpu_usage_pct  IS NULL THEN 'neu' ELSE 'ok' END          AS cpu_status,
    CASE WHEN m.mem_used_pct   >= 90 THEN 'crit' WHEN m.mem_used_pct   >= 80 THEN 'warn'
         WHEN m.mem_used_pct   IS NULL THEN 'neu' ELSE 'ok' END          AS mem_status,
    CASE WHEN m.swap_used_pct  >= 10 THEN 'crit' WHEN m.swap_used_pct  >  0  THEN 'warn'
         WHEN m.swap_used_pct  IS NULL THEN 'neu' ELSE 'ok' END          AS swap_status,
    CASE WHEN c.cpu_iowait_pct >= 20 THEN 'crit' WHEN c.cpu_iowait_pct >= 10 THEN 'warn'
         WHEN c.cpu_iowait_pct IS NULL THEN 'neu' ELSE 'ok' END          AS iowait_status,
    -- 전체 신선도(참고) — 가장 최신 소스 기준
    EXTRACT(EPOCH FROM (statement_timestamp()
        - COALESCE(GREATEST(c.collect_time, m.collect_time),
                   c.collect_time, m.collect_time)))::int    AS data_age_sec
FROM
    (VALUES (1)) AS spine(x)
    LEFT JOIN LATERAL
    (SELECT * FROM itstone.m_os_cpu_stat    ORDER BY collect_time DESC LIMIT 1) c ON TRUE
    LEFT JOIN LATERAL
    (SELECT * FROM itstone.m_os_memory_stat ORDER BY collect_time DESC LIMIT 1) m ON TRUE
    LEFT JOIN LATERAL
    (SELECT tc.os_agent_yn FROM itstone.m_target_capability tc
       ORDER BY tc.collect_time DESC LIMIT 1) cap ON TRUE
    -- ★ 모듈별 최신 heartbeat (통합 1건 아님)
    LEFT JOIN LATERAL
    (SELECT h.collect_time AS t, h.status AS s FROM itstone.m_collector_health h
      WHERE h.module_name = 'OS_CPU'    ORDER BY h.collect_time DESC LIMIT 1) hbc ON TRUE
    LEFT JOIN LATERAL
    (SELECT h.collect_time AS t, h.status AS s FROM itstone.m_collector_health h
      WHERE h.module_name = 'OS_MEMORY' ORDER BY h.collect_time DESC LIMIT 1) hbm ON TRUE;

-- ───────── [PG_VIEW-v_m_slow_sql_now.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_slow_sql_now
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : SQL Analysis 탭 하단 > Recent Slow SQL (최근 1시간 실제 느린 개별 실행)
-- 원천 : m_slow_query_log (MVP 옵션, mysql.slow_log TABLE 방식)
-- [설계]
--   - 최근 60분 개별 slow 실행 목록(Top SQL Digest 누적패턴과 상보). start_time DESC.
--   - ▼TUNING▼ query_time_ms 기반 배지(전부 임계초과이므로 '매우느림/느림' 세분). 향후 cfg 이관.
--   - ★ 민감정보: sql_text 는 화면 절단(sql_text_display=LEFT 500). 전체는 C# 팝업이 PK 로 원문 조회. 마스킹 v1.1.
--   - CTE 미사용.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW itstone.v_m_slow_sql_now AS
SELECT
    s.start_time,
    s.user_host,
    s.query_time_ms,
    s.lock_time_ms,
    s.rows_sent,
    s.rows_examined,
    s.db_name,
    LEFT(s.sql_text, 500)                                    AS sql_text_display,   -- 화면 절단(전체=팝업)
    LENGTH(s.sql_text)                                       AS sql_text_len,
    s.sql_hash,
    --========================== ▼ TUNING ▼ ==========================--
    CASE
        WHEN s.query_time_ms >= 10000 THEN 'crit'   -- ≥10초
        WHEN s.query_time_ms >= 3000  THEN 'warn'   -- ≥3초
        ELSE 'ok'
    END                                                      AS query_time_status,
    CASE WHEN s.rows_examined >= 1000000 THEN 'warn' ELSE 'ok' END AS rows_examined_status,
    --========================== ▲ TUNING ▲ ==========================--
    EXTRACT(EPOCH FROM (statement_timestamp() - s.collect_time))::int AS data_age_sec
FROM itstone.m_slow_query_log s
WHERE s.start_time >= statement_timestamp() - INTERVAL '60 minutes'
ORDER BY s.start_time DESC
LIMIT 100;

-- ───────── [PG_VIEW-v_m_workload_trend.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_workload_trend
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : 24H Trend 탭 > Workload 시계열 (QPS/TPS/DML/Buffer Hit 추이)
--------------------------------------------------------------------------------
-- [트렌드 설계 원칙] (Oracle TRD 원칙 이식)
--   1. 버킷 = date_trunc('minute', collect_time) — 1분 단위(24h=1440점).
--      C# 은 collect_time 범위만 좁히면 1h/6h/24h 공용(별도 뷰 불필요).
--   2. 비율(rate)은 버킷별 rate 평균이 아니라 SUM(delta)/SUM(elapsed) 방식.
--      → 무활동 구간 가중 왜곡 방지(Oracle TRD AVG 원칙과 동일).
--   3. 게이지(threads)는 버킷 내 AVG.
--   4. 미완료 현재 버킷 제외: bucket < date_trunc('minute', MAX(collect_time)).
--   5. 델타 가드: GREATEST(...,0), NULLIF(elapsed,0), prev IS NOT NULL.
--   6. CTE 미사용. pivot → LAG → bucket 집계 다단 인라인 뷰.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_workload_trend AS
SELECT
    d.bucket_time,
    ROUND(SUM(d.queries_delta)  / NULLIF(SUM(d.elapsed_sec), 0), 2)         AS qps,
    ROUND(SUM(d.commit_delta + d.rollback_delta) / NULLIF(SUM(d.elapsed_sec), 0), 2) AS tps,
    ROUND(SUM(d.select_delta)   / NULLIF(SUM(d.elapsed_sec), 0), 2)         AS select_per_sec,
    ROUND(SUM(d.insert_delta + d.update_delta + d.delete_delta) / NULLIF(SUM(d.elapsed_sec), 0), 2) AS dml_per_sec,
    ROUND(SUM(d.slow_delta)     / NULLIF(SUM(d.elapsed_sec), 0), 2)         AS slow_per_sec,
    ROUND(AVG(d.threads_running), 2)                                        AS avg_threads_running,
    ROUND(AVG(d.threads_connected), 2)                                      AS avg_threads_connected,
    ROUND((SUM(d.bp_read_req_delta) - SUM(d.bp_reads_delta)) * 100.0
          / NULLIF(SUM(d.bp_read_req_delta), 0), 2)                         AS buffer_hit_pct,
    ROUND(SUM(d.bytes_sent_delta) / 1048576.0 / NULLIF(SUM(d.elapsed_sec), 0), 3) AS net_sent_mb_per_sec
FROM
(
    -- 2단계: 델타 + 버킷 라벨
    SELECT
        date_trunc('minute', p.collect_time)                              AS bucket_time,
        EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time))        AS elapsed_sec,
        GREATEST(p.queries      - p.prev_queries,      0)                 AS queries_delta,
        GREATEST(p.com_commit   - p.prev_com_commit,   0)                AS commit_delta,
        GREATEST(p.com_rollback - p.prev_com_rollback, 0)                AS rollback_delta,
        GREATEST(p.com_select   - p.prev_com_select,   0)                AS select_delta,
        GREATEST(p.com_insert   - p.prev_com_insert,   0)                AS insert_delta,
        GREATEST(p.com_update   - p.prev_com_update,   0)                AS update_delta,
        GREATEST(p.com_delete   - p.prev_com_delete,   0)                AS delete_delta,
        GREATEST(p.slow         - p.prev_slow,         0)                AS slow_delta,
        GREATEST(p.bytes_sent   - p.prev_bytes_sent,   0)                AS bytes_sent_delta,
        GREATEST(p.bp_read_req  - p.prev_bp_read_req,  0)                AS bp_read_req_delta,
        GREATEST(p.bp_reads     - p.prev_bp_reads,     0)                AS bp_reads_delta,
        p.threads_running,
        p.threads_connected
    FROM
    (
        -- 1.5단계: LAG
        SELECT
            w.collect_time,
            LAG(w.collect_time) OVER o AS prev_collect_time,
            w.queries,      LAG(w.queries)      OVER o AS prev_queries,
            w.com_commit,   LAG(w.com_commit)   OVER o AS prev_com_commit,
            w.com_rollback, LAG(w.com_rollback) OVER o AS prev_com_rollback,
            w.com_select,   LAG(w.com_select)   OVER o AS prev_com_select,
            w.com_insert,   LAG(w.com_insert)   OVER o AS prev_com_insert,
            w.com_update,   LAG(w.com_update)   OVER o AS prev_com_update,
            w.com_delete,   LAG(w.com_delete)   OVER o AS prev_com_delete,
            w.slow,         LAG(w.slow)         OVER o AS prev_slow,
            w.bytes_sent,   LAG(w.bytes_sent)   OVER o AS prev_bytes_sent,
            w.bp_read_req,  LAG(w.bp_read_req)  OVER o AS prev_bp_read_req,
            w.bp_reads,     LAG(w.bp_reads)     OVER o AS prev_bp_reads,
            w.threads_running,
            w.threads_connected
        FROM
        (
            -- 1단계: tall → wide per collect_time (24h)
            SELECT
                g.collect_time,
                MAX(CASE WHEN UPPER(g.variable_name) = 'QUERIES'      THEN g.variable_value_num END) AS queries,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_COMMIT'   THEN g.variable_value_num END) AS com_commit,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_ROLLBACK' THEN g.variable_value_num END) AS com_rollback,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_SELECT'   THEN g.variable_value_num END) AS com_select,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_INSERT'   THEN g.variable_value_num END) AS com_insert,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_UPDATE'   THEN g.variable_value_num END) AS com_update,
                MAX(CASE WHEN UPPER(g.variable_name) = 'COM_DELETE'   THEN g.variable_value_num END) AS com_delete,
                MAX(CASE WHEN UPPER(g.variable_name) = 'SLOW_QUERIES' THEN g.variable_value_num END) AS slow,
                MAX(CASE WHEN UPPER(g.variable_name) = 'BYTES_SENT'   THEN g.variable_value_num END) AS bytes_sent,
                MAX(CASE WHEN UPPER(g.variable_name) = 'INNODB_BUFFER_POOL_READ_REQUESTS' THEN g.variable_value_num END) AS bp_read_req,
                MAX(CASE WHEN UPPER(g.variable_name) = 'INNODB_BUFFER_POOL_READS'         THEN g.variable_value_num END) AS bp_reads,
                MAX(CASE WHEN UPPER(g.variable_name) = 'THREADS_RUNNING'   THEN g.variable_value_num END) AS threads_running,
                MAX(CASE WHEN UPPER(g.variable_name) = 'THREADS_CONNECTED' THEN g.variable_value_num END) AS threads_connected
            FROM itstone.m_global_status g
            WHERE g.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_global_status) - INTERVAL '24 hours'
            GROUP BY g.collect_time
        ) w
        WINDOW o AS (ORDER BY w.collect_time)
    ) p
    WHERE p.prev_collect_time IS NOT NULL
      -- ★ 갭 방지: m_global_status 5초 주기. 수집 누락 후 재개 시 catch-up delta 가
      --   재개 버킷에 섞여 rate 가 '갭 평균+현재' 혼합으로 오염되는 것을 차단.
      --   임계 15초(≈3주기) 초과 간격은 갭으로 보고 제외 → 빈 버킷=갭 정직 표시.
      AND EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time)) <= 15
) d
WHERE d.bucket_time < date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_global_status))   -- 미완료 현재 버킷 제외
GROUP BY d.bucket_time
ORDER BY d.bucket_time;

-- ───────── [PG_VIEW-v_m_session_trend.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_session_trend
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : 24H Trend 탭 > Active Session Breakdown
--        (시간대별 평균 활성 세션을 ON CPU / 대기 클래스별로 분해)
--------------------------------------------------------------------------------
-- [설계]
--   - AAS(Average Active Sessions) = 버킷 내 활성 세션 샘플 수 / 공칭 60(1초 수집).
--     무세션 스냅샷은 05 에 행이 없으므로 공칭 60 분모로 무활동을 0 에 수렴시킴.
--   - ★ 무활동 분 0 출력(차트 시간축 끊김 방지):
--     05(m_active_session)는 Active 만 저장 → 어떤 1분에 Active 가 전혀 없으면 그 분의
--     행 자체가 없어, 단순 GROUP BY 면 그 버킷이 결과에서 누락(차트가 끊기거나 압축됨).
--     → 분(minute) 스파인 × 클래스 그리드를 generate_series 로 만들고 실제 집계를
--        LEFT JOIN + COALESCE(...,0) → 모든 분이 0 으로라도 반드시 출력된다.
--   - ★ 스파인 기준 = heartbeat(m_global_status, 항상 수집)의 MAX(collect_time).
--     05 의 MAX 가 아니라 heartbeat 기준이라, 활동이 오래 없어도 시간축이 현재까지 완전.
--     (05 MAX 기준이면 무활동 시 축이 과거에서 멈춤.) 동일 MariaDB 시계라 스큐 무관.
--   - activity_class : ON CPU / IO / LOCK / CONCURRENCY / OTHER (스택 영역 차트).
--   - 미완료 현재 버킷 제외: 스파인 상한 = date_trunc('minute', heartbeat MAX) - 1분.
--   - long 포맷(버킷×클래스 1행) → C# 에서 클래스별 스택.
--   - ★ Basic 모드 보완: P_S OFF 고객은 05 미수집 → 06(m_processlist) fallback UNION ALL.
--     세션쌍은 Enhanced(05) XOR Basic(06) 로 배타 수집(Manifest §1.3)이라 이중계상 없음.
--     Basic 은 wait_class 부재 → STATE 문자열 휴리스틱(lock→LOCK, 그 외 활동→ON CPU).
--   - CTE 미사용. generate_series + VALUES + 인라인 뷰.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_session_trend AS
SELECT
    spine.bucket_time,
    spine.activity_class,
    COALESCE(agg.avg_active_sessions, 0)    AS avg_active_sessions
FROM
(
    -- 분 스파인 × 클래스 그리드 (무활동 분도 0 으로 반드시 출력)
    SELECT g.bucket_time, cls.activity_class
    FROM generate_series(
             date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_global_status)) - INTERVAL '24 hours',
             date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_global_status)) - INTERVAL '1 minute',
             INTERVAL '1 minute'
         ) AS g(bucket_time)
    CROSS JOIN (VALUES ('ON CPU'),('IO'),('LOCK'),('CONCURRENCY'),('OTHER')) AS cls(activity_class)
) spine
LEFT JOIN
(
    -- 실제 활성 세션 집계 (AAS = 샘플 수 / 공칭 60)
    SELECT
        c.bucket_time,
        c.activity_class,
        ROUND(COUNT(*) / 60.0, 2)           AS avg_active_sessions
    FROM
    (
        -- ── Enhanced(P_S ON) : m_active_session — 실제 wait_class 기반 정확 분류
        SELECT
            date_trunc('minute', s.collect_time)    AS bucket_time,
            CASE
                WHEN s.session_state = 'ON CPU'                          THEN 'ON CPU'
                WHEN s.wait_class IN ('IO_FILE','IO_TABLE','IO')         THEN 'IO'
                WHEN s.wait_class = 'LOCK'                               THEN 'LOCK'
                WHEN s.wait_class IN ('MUTEX','RWLOCK','COND','SYNCH')   THEN 'CONCURRENCY'
                ELSE 'OTHER'
            END                                     AS activity_class
        FROM itstone.m_active_session s
        WHERE s.collect_time >= date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_global_status)) - INTERVAL '24 hours'
          AND s.collect_time <  date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_global_status))

        UNION ALL

        -- ── Basic(P_S OFF) : m_processlist fallback (세션쌍 XOR — 이중계상 없음)
        --    wait_class 부재(Basic 한계) → STATE 문자열 휴리스틱: lock 류→LOCK, 그 외 활동→ON CPU.
        --    Sleep/미실행 커넥션 제외(활성 세션 추이 목적).
        SELECT
            date_trunc('minute', p.collect_time)    AS bucket_time,
            CASE
                WHEN p.proc_state ILIKE '%lock%'    THEN 'LOCK'
                ELSE 'ON CPU'
            END                                     AS activity_class
        FROM itstone.m_processlist p
        WHERE p.collect_time >= date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_global_status)) - INTERVAL '24 hours'
          AND p.collect_time <  date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_global_status))
          AND p.command IS NOT NULL
          AND p.command NOT IN ('Sleep','Binlog Dump','Daemon')
    ) c
    GROUP BY c.bucket_time, c.activity_class
) agg
  ON  agg.bucket_time    = spine.bucket_time
  AND agg.activity_class = spine.activity_class
ORDER BY spine.bucket_time, spine.activity_class;

-- ───────── [PG_VIEW-v_m_buffer_pool_trend.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_buffer_pool_trend
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : 24H Trend 탭 > Buffer Pool (hit_pct / dirty_pct / disk read 추이)
--------------------------------------------------------------------------------
-- [설계 — 3단계 집계(다중 buffer pool 인스턴스 안전 + 크기 가중)]
--   Lv1 : pool_id 별 LAG → delta + elapsed_sec + raw 게이지(가중 평균용). 갭 가드(≤30초).
--   Lv2 : ★snapshot(collect_time)별 전 pool 합산. elapsed_sec 는 pool 무관 동일하므로
--         MAX 로 1회만 사용(분모 중복 제거, 원칙 25). 게이지 비율은 raw 합으로 재계산 →
--         ★크기 가중(원칙 26): dirty=SUM(modified)/SUM(db_pages), free=SUM(free)/SUM(pool_size).
--         단순 AVG 면 작은 pool 1개가 큰 pool 들과 동등 가중되어 대표값 왜곡.
--   Lv3 : bucket_time(분) 집계.
--   - hit_pct : 델타 비율 (1 - SUM(reads)/SUM(gets))*100 — 이미 활동량(gets) 가중. pool 수 상쇄.
--   - dirty_pct / free_pct : snapshot 크기가중 비율 → 버킷 시간평균(AVG over snapshot).
--   - disk_reads_per_sec / pages_written_per_sec : SUM(pool delta) / 단일 elapsed_sec.
--   - 미완료 현재 버킷 제외. CTE 미사용(LAG → 인라인 뷰 3단).
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_buffer_pool_trend AS
SELECT
    s.bucket_time,
    ROUND((1 - SUM(s.reads_delta_snap)::numeric / NULLIF(SUM(s.get_delta_snap), 0)) * 100, 2) AS hit_pct,
    ROUND(AVG(s.dirty_pct_snap), 2)                                         AS avg_dirty_pct,
    ROUND(AVG(s.free_pct_snap), 2)                                          AS avg_free_pct,
    ROUND(SUM(s.reads_delta_snap)   / NULLIF(SUM(s.elapsed_sec_snap), 0), 2) AS disk_reads_per_sec,
    ROUND(SUM(s.written_delta_snap) / NULLIF(SUM(s.elapsed_sec_snap), 0), 2) AS pages_written_per_sec
FROM
(
    -- Lv2: snapshot(collect_time)별 전 pool 합산. elapsed 1회(MAX). 게이지는 raw 합 → 크기가중 비율.
    SELECT
        d.bucket_time,
        SUM(d.reads_delta)   AS reads_delta_snap,
        SUM(d.get_delta)     AS get_delta_snap,
        SUM(d.written_delta) AS written_delta_snap,
        MAX(d.elapsed_sec)   AS elapsed_sec_snap,
        ROUND(SUM(d.modified_database_pages)::numeric / NULLIF(SUM(d.database_pages), 0)  * 100, 2) AS dirty_pct_snap,
        ROUND(SUM(d.free_buffers)::numeric            / NULLIF(SUM(d.pool_size_pages), 0) * 100, 2) AS free_pct_snap
    FROM
    (
        -- Lv1: pool_id 별 델타 + elapsed_sec + raw 게이지(가중 평균 분자/분모)
        SELECT
            p.collect_time,
            date_trunc('minute', p.collect_time)                              AS bucket_time,
            EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time))        AS elapsed_sec,
            GREATEST(p.number_pages_read_cum    - p.prev_read,    0)          AS reads_delta,
            GREATEST(p.number_pages_get_cum     - p.prev_get,     0)          AS get_delta,
            GREATEST(p.number_pages_written_cum - p.prev_written, 0)         AS written_delta,
            p.modified_database_pages,
            p.database_pages,
            p.free_buffers,
            p.pool_size_pages
        FROM
        (
            SELECT
                x.collect_time, x.pool_id,
                x.modified_database_pages, x.database_pages, x.free_buffers, x.pool_size_pages,
                x.number_pages_read_cum,    LAG(x.number_pages_read_cum)    OVER w AS prev_read,
                x.number_pages_get_cum,     LAG(x.number_pages_get_cum)     OVER w AS prev_get,
                x.number_pages_written_cum, LAG(x.number_pages_written_cum) OVER w AS prev_written,
                LAG(x.collect_time) OVER w AS prev_collect_time
            FROM itstone.m_innodb_buffer_pool x
            WHERE x.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_innodb_buffer_pool) - INTERVAL '24 hours'
            WINDOW w AS (PARTITION BY x.pool_id ORDER BY x.collect_time)
        ) p
        WHERE p.prev_collect_time IS NOT NULL
          -- ★ 갭 방지: m_innodb_buffer_pool 10초 주기. 갭 후 재개 catch-up delta 차단(pool_id 별 LAG).
          --   임계 30초(≈3주기) 초과 간격은 갭으로 보고 제외 → 빈 버킷=갭 정직 표시.
          AND EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time)) <= 30
    ) d
    GROUP BY d.collect_time, d.bucket_time
) s
WHERE s.bucket_time < date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_innodb_buffer_pool))
GROUP BY s.bucket_time
ORDER BY s.bucket_time;

-- ───────── [PG_VIEW-v_m_sql_trend.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_sql_trend
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : 24H Trend / SQL Analysis > SQL 부하(DB Time) 추이
--------------------------------------------------------------------------------
-- [설계]
--   - m_sql_digest(1분 수집) 의 (schema,digest)별 누적 → LAG() 델타.
--   - 버킷(1분) 내 전 digest 델타를 합산하여 SQL 총부하 시계열 생성.
--   - 핵심 지표 avg_active_sql = 버킷 내 SQL 총 수행시간(초) / 60(공칭 버킷폭).
--     → "평균 동시 SQL"(DB Time 밀도). 세션 활동(AAS) 차트와 짝.
--     ★ digest 별 elapsed_sec 합산은 digest 수만큼 부풀려지므로 사용 금지 →
--        공칭 버킷폭 60초로 나눔(수집=버킷=1분 정렬). 1초 세션 trend 의 /60 과 동일.
--   - exec_per_sec / no_index_per_sec 도 /60 공칭.
--   - avg_elapsed_ms 는 실행수 가중(SUM(elapsed)/SUM(count)) → 벽시계 불필요.
--   - 델타 가드 GREATEST/prev IS NOT NULL. 미완료 버킷 제외. CTE 미사용.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_sql_trend AS
SELECT
    d.bucket_time,
    SUM(d.delta_count)                                                      AS exec_count,
    ROUND(SUM(d.delta_count) / 60.0, 2)                                     AS exec_per_sec,
    ROUND(SUM(d.delta_elapsed_ps) / 1000000000000.0 / 60.0, 3)             AS avg_active_sql,
    ROUND(SUM(d.delta_elapsed_ps) / 1000000000.0
          / NULLIF(SUM(d.delta_count), 0), 3)                              AS avg_elapsed_ms,
    ROUND(SUM(d.delta_no_index) / 60.0, 2)                                 AS no_index_per_sec
FROM
(
    SELECT
        date_trunc('minute', p.collect_time)                              AS bucket_time,
        GREATEST(p.count_star_cum         - p.prev_count,    0)           AS delta_count,
        GREATEST(p.sum_timer_wait_ps_cum  - p.prev_timer,    0)           AS delta_elapsed_ps,
        GREATEST(p.sum_no_index_used_cum  - p.prev_no_index, 0)          AS delta_no_index
    FROM
    (
        SELECT
            x.collect_time,
            x.count_star_cum,        LAG(x.count_star_cum)        OVER w AS prev_count,
            x.sum_timer_wait_ps_cum, LAG(x.sum_timer_wait_ps_cum) OVER w AS prev_timer,
            x.sum_no_index_used_cum, LAG(x.sum_no_index_used_cum) OVER w AS prev_no_index,
            LAG(x.collect_time) OVER w AS prev_collect_time
        FROM itstone.m_sql_digest x
        WHERE x.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_sql_digest) - INTERVAL '24 hours'
        WINDOW w AS (PARTITION BY x.schema_name, x.digest ORDER BY x.collect_time)
    ) p
    WHERE p.prev_collect_time IS NOT NULL
      -- ★ 수집 갭 delta 제외: 한 delta 의 실제 간격이 기대주기(1분)의 2배(120초)를 넘으면
      --   갭 동안 누적분이 한 버킷에 뭉쳐 /60 분모로 spike 가 되므로 trend 에서 제외.
      --   (해당 구간은 빈 버킷=갭으로 정직하게 표시. 모든 digest 가 같은 갭이라 함께 제외됨.)
      AND EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time)) <= 120
) d
WHERE d.bucket_time < date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_sql_digest))
GROUP BY d.bucket_time
ORDER BY d.bucket_time;

-- ───────── [PG_VIEW-v_m_file_io_trend.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_file_io_trend
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : 24H Trend 탭 > 파일 유형별 I/O (by Event Type) — IOPS / MB/s / 지연 추이
--------------------------------------------------------------------------------
-- [설계]
--   ★ grain = 이벤트 유형(파일 경로별 아님). UI 제목 "파일 유형별" — "Hotspot/어느 파일" 금지(원칙 22).
--   - m_file_io_stat(1분, event별 누적) → LAG() 델타 → 버킷 합산.
--   - rate 는 /60 공칭(1분=버킷). 이벤트별 elapsed 합산 금지(부풀림).
--   - latency(avg_*_ms)는 SUM(timer)/SUM(count) 가중 → 벽시계 불필요.
--   - 전체 파일 합산 추이. category 분해가 필요하면 GROUP BY 에 file_category 추가.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_file_io_trend AS
SELECT
    d.bucket_time,
    ROUND((SUM(d.delta_read) + SUM(d.delta_write)) / 60.0, 1)               AS iops,
    ROUND(SUM(d.delta_read)  / 60.0, 1)                                     AS read_iops,
    ROUND(SUM(d.delta_write) / 60.0, 1)                                     AS write_iops,
    ROUND(SUM(d.delta_bytes_read)  / 1048576.0 / 60.0, 3)                   AS read_mb_per_sec,
    ROUND(SUM(d.delta_bytes_write) / 1048576.0 / 60.0, 3)                   AS write_mb_per_sec,
    ROUND(SUM(d.delta_timer_read_ps)  / NULLIF(SUM(d.delta_read), 0)  / 1000000000.0, 3) AS avg_read_ms,
    ROUND(SUM(d.delta_timer_write_ps) / NULLIF(SUM(d.delta_write), 0) / 1000000000.0, 3) AS avg_write_ms,
    -- ★ misc(fsync/open/close 등) — 이미 수집중 값. LOG/DATA 는 사실상 fsync 지연 추이.
    ROUND(SUM(d.delta_misc) / 60.0, 1)                                     AS misc_iops,
    ROUND(SUM(d.delta_timer_misc_ps) / NULLIF(SUM(d.delta_misc), 0) / 1000000000.0, 3) AS avg_misc_ms
FROM
(
    SELECT
        date_trunc('minute', p.collect_time)                              AS bucket_time,
        GREATEST(p.count_read_cum         - p.prev_read,   0)             AS delta_read,
        GREATEST(p.count_write_cum        - p.prev_write,  0)            AS delta_write,
        GREATEST(p.sum_bytes_read_cum     - p.prev_bread,  0)            AS delta_bytes_read,
        GREATEST(p.sum_bytes_write_cum    - p.prev_bwrite, 0)            AS delta_bytes_write,
        GREATEST(p.sum_timer_read_ps_cum  - p.prev_tread,  0)            AS delta_timer_read_ps,
        GREATEST(p.sum_timer_write_ps_cum - p.prev_twrite, 0)           AS delta_timer_write_ps,
        GREATEST(p.count_misc_cum         - p.prev_misc,   0)            AS delta_misc,
        GREATEST(p.sum_timer_misc_ps_cum  - p.prev_tmisc,  0)            AS delta_timer_misc_ps
    FROM
    (
        SELECT
            x.collect_time,
            x.count_read_cum,         LAG(x.count_read_cum)         OVER w AS prev_read,
            x.count_write_cum,        LAG(x.count_write_cum)        OVER w AS prev_write,
            x.sum_bytes_read_cum,     LAG(x.sum_bytes_read_cum)     OVER w AS prev_bread,
            x.sum_bytes_write_cum,    LAG(x.sum_bytes_write_cum)    OVER w AS prev_bwrite,
            x.sum_timer_read_ps_cum,  LAG(x.sum_timer_read_ps_cum)  OVER w AS prev_tread,
            x.sum_timer_write_ps_cum, LAG(x.sum_timer_write_ps_cum) OVER w AS prev_twrite,
            x.count_misc_cum,         LAG(x.count_misc_cum)         OVER w AS prev_misc,
            x.sum_timer_misc_ps_cum,  LAG(x.sum_timer_misc_ps_cum)  OVER w AS prev_tmisc,
            LAG(x.collect_time) OVER w AS prev_collect_time
        FROM itstone.m_file_io_stat x
        WHERE x.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_file_io_stat) - INTERVAL '24 hours'
        WINDOW w AS (PARTITION BY x.event_name ORDER BY x.collect_time)
    ) p
    WHERE p.prev_collect_time IS NOT NULL
      -- ★ 수집 갭 delta 제외: 한 delta 의 실제 간격이 기대주기(1분)의 2배(120초)를 넘으면
      --   갭 동안 누적분이 한 버킷에 뭉쳐 /60 분모로 spike 가 되므로 trend 에서 제외(빈 버킷=갭).
      AND EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time)) <= 120
) d
WHERE d.bucket_time < date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_file_io_stat))
GROUP BY d.bucket_time
ORDER BY d.bucket_time;

-- ───────── [PG_VIEW-v_m_table_lock_trend.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_table_lock_trend
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : 24H Trend 탭 > Table Lock 경합 추이
--------------------------------------------------------------------------------
-- [설계]
--   - m_table_lock_stat(1분, 테이블별 누적) → LAG() 델타 → 버킷 합산.
--   - lock_wait_per_sec 등 rate 는 /60 공칭. avg_lock_wait_ms 는 SUM/SUM 가중.
--   - 전체 테이블 합산 추이. 테이블별이 필요하면 별도 Top-N 뷰.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_table_lock_trend AS
SELECT
    d.bucket_time,
    ROUND(SUM(d.delta_count) / 60.0, 2)                                    AS lock_wait_per_sec,
    ROUND(SUM(d.delta_read)  / 60.0, 2)                                    AS read_lock_per_sec,
    ROUND(SUM(d.delta_write) / 60.0, 2)                                    AS write_lock_per_sec,
    ROUND(SUM(d.delta_wait_ps) / NULLIF(SUM(d.delta_count), 0) / 1000000000.0, 3) AS avg_lock_wait_ms
FROM
(
    SELECT
        date_trunc('minute', p.collect_time)                              AS bucket_time,
        GREATEST(p.count_star_cum        - p.prev_count, 0)               AS delta_count,
        GREATEST(p.count_read_cum        - p.prev_read,  0)               AS delta_read,
        GREATEST(p.count_write_cum       - p.prev_write, 0)              AS delta_write,
        GREATEST(p.sum_timer_wait_ps_cum - p.prev_wait,  0)               AS delta_wait_ps
    FROM
    (
        SELECT
            x.collect_time,
            x.count_star_cum,        LAG(x.count_star_cum)        OVER w AS prev_count,
            x.count_read_cum,        LAG(x.count_read_cum)        OVER w AS prev_read,
            x.count_write_cum,       LAG(x.count_write_cum)       OVER w AS prev_write,
            x.sum_timer_wait_ps_cum, LAG(x.sum_timer_wait_ps_cum) OVER w AS prev_wait,
            LAG(x.collect_time) OVER w AS prev_collect_time
        FROM itstone.m_table_lock_stat x
        WHERE x.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_table_lock_stat) - INTERVAL '24 hours'
        WINDOW w AS (PARTITION BY x.object_schema, x.table_name ORDER BY x.collect_time)
    ) p
    WHERE p.prev_collect_time IS NOT NULL
      -- ★ 수집 갭 delta 제외: 한 delta 의 실제 간격이 기대주기(1분)의 2배(120초)를 넘으면
      --   갭 동안 누적분이 한 버킷에 뭉쳐 /60 분모로 spike 가 되므로 trend 에서 제외(빈 버킷=갭).
      AND EXTRACT(EPOCH FROM (p.collect_time - p.prev_collect_time)) <= 120
) d
WHERE d.bucket_time < date_trunc('minute', (SELECT MAX(collect_time) FROM itstone.m_table_lock_stat))
GROUP BY d.bucket_time
ORDER BY d.bucket_time;

-- ───────── [PG_VIEW-v_m_os_resource_trend.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_os_resource_trend
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : System 탭 > Host Resource 최근 60분 추이(Line)
-- 원천 : m_os_cpu_stat + m_os_memory_stat
-- [설계]
--   - 5초 수집. ★ CPU/MEM INSERT 시각이 소수초 어긋나도 같은 사이클이 조인되도록
--     '초 단위' 대신 '5초 버킷'으로 정렬(멘토 4.1). date_trunc(min)+floor(sec/5)*5s.
--   - Host Agent 미설치 시 원천이 비어 결과 0행 → 화면은 now 뷰 기준 'Agent 필요'.
--   - ★ CTE 미사용. 인라인 파생테이블 FULL OUTER JOIN.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW itstone.v_m_os_resource_trend AS
SELECT
    COALESCE(c.bkt, m.bkt)      AS bucket_time,
    c.cpu_usage_pct,
    c.cpu_iowait_pct,
    c.load_avg_1m,
    m.mem_used_pct,
    m.swap_used_pct
FROM
    (SELECT date_trunc('minute', collect_time)
              + floor(EXTRACT(SECOND FROM collect_time)::int / 5) * INTERVAL '5 seconds' AS bkt,
            AVG(cpu_usage_pct)  AS cpu_usage_pct,
            AVG(cpu_iowait_pct) AS cpu_iowait_pct,
            AVG(load_avg_1m)    AS load_avg_1m
     FROM itstone.m_os_cpu_stat
     WHERE collect_time >= statement_timestamp() - INTERVAL '60 minutes'
     GROUP BY 1) c
    FULL OUTER JOIN
    (SELECT date_trunc('minute', collect_time)
              + floor(EXTRACT(SECOND FROM collect_time)::int / 5) * INTERVAL '5 seconds' AS bkt,
            AVG(mem_used_pct)  AS mem_used_pct,
            AVG(swap_used_pct) AS swap_used_pct
     FROM itstone.m_os_memory_stat
     WHERE collect_time >= statement_timestamp() - INTERVAL '60 minutes'
     GROUP BY 1) m
    ON m.bkt = c.bkt
ORDER BY bucket_time;

-- ───────── [PG_VIEW-v_m_variable_drift.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_variable_drift
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : System 탭 > 설정 드리프트 (GLOBAL_VARIABLES 변경 로그)
--------------------------------------------------------------------------------
-- [설계]
--   - m_variable_snapshot(60분, tall) 을 변수별 LAG 비교 → 직전 스냅샷과
--     값이 달라진 시점만 변경 이벤트로 노출(설정 변경 로그).
--   - IS DISTINCT FROM : NULL 안전 비교(NULL↔값 변경도 포착).
--   - 최근 30일 윈도우(필요 시 C# 에서 change_time 범위 조정).
--   - prev_value IS NOT NULL : 변수 최초 등장(비교 대상 없음)은 변경 아님.
--   - CTE 미사용. LAG 인라인 뷰.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_variable_drift AS
SELECT
    p.collect_time          AS change_time,
    p.variable_name,
    p.prev_value            AS old_value,
    p.variable_value        AS new_value,
    p.prev_collect_time     AS prev_time
FROM
(
    SELECT
        x.collect_time,
        x.variable_name,
        x.variable_value,
        LAG(x.variable_value) OVER w AS prev_value,
        LAG(x.collect_time)   OVER w AS prev_collect_time
    FROM itstone.m_variable_snapshot x
    WHERE x.collect_time >= (SELECT MAX(collect_time) FROM itstone.m_variable_snapshot) - INTERVAL '30 days'
    WINDOW w AS (PARTITION BY x.variable_name ORDER BY x.collect_time)
) p
WHERE p.prev_value IS NOT NULL
  AND p.variable_value IS DISTINCT FROM p.prev_value
ORDER BY p.collect_time DESC, p.variable_name;

-- ───────── [PG_VIEW-v_m_slow_sql_status.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_slow_sql_status
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : SQL Analysis 탭 Recent Slow SQL 헤더 배너(수집 가능/불가 안내)
-- 원천 : m_target_capability(slow_log_*) + m_slow_query_log(최근 건수)
-- [설계]
--   - 단일행 항상 반환(spine) → 목록이 비어도 배너로 상태 안내.
--   - 상태 우선순위: NOT_SUPPORTED > SLOW_LOG_OFF > TABLE_NOT_SET > OK.
--     · NOT_SUPPORTED : mysql.slow_log 미지원 또는 SELECT 권한 없음
--     · SLOW_LOG_OFF  : slow_query_log=OFF
--     · TABLE_NOT_SET : log_output 에 TABLE 미포함
--   - ★ MVP 는 고객 DB 설정을 자동 변경하지 않음 → 안내만.
--   - CTE 미사용(spine + LATERAL).
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW itstone.v_m_slow_sql_status AS
SELECT
    cap.slow_log_enabled_yn,
    cap.slow_log_output,
    cap.slow_log_table_yn,
    cap.slow_log_query_time,
    cnt.recent_slow_count,
    CASE
        WHEN COALESCE(cap.slow_log_table_yn,'N')   = 'N'            THEN 'NOT_SUPPORTED'
        WHEN COALESCE(cap.slow_log_enabled_yn,'N') = 'N'            THEN 'SLOW_LOG_OFF'
        WHEN COALESCE(cap.slow_log_output,'') NOT ILIKE '%TABLE%'   THEN 'TABLE_NOT_SET'
        ELSE 'OK'
    END                                                            AS slow_sql_status,
    CASE
        WHEN COALESCE(cap.slow_log_table_yn,'N')   = 'N'            THEN 'mysql.slow_log 미지원 또는 SELECT 권한 없음'
        WHEN COALESCE(cap.slow_log_enabled_yn,'N') = 'N'            THEN 'Slow Log OFF — slow_query_log=ON 설정 시 Recent Slow SQL 수집'
        WHEN COALESCE(cap.slow_log_output,'') NOT ILIKE '%TABLE%'   THEN 'TABLE 출력 미설정 — log_output=TABLE 설정 시 수집'
        ELSE 'Recent Slow SQL 수집 중'
    END                                                            AS slow_sql_message
FROM (VALUES (1)) AS spine(x)
LEFT JOIN LATERAL
    (SELECT tc.slow_log_enabled_yn, tc.slow_log_output, tc.slow_log_table_yn, tc.slow_log_query_time
       FROM itstone.m_target_capability tc ORDER BY tc.collect_time DESC LIMIT 1) cap ON TRUE
LEFT JOIN LATERAL
    (SELECT count(*) AS recent_slow_count FROM itstone.m_slow_query_log s
       WHERE s.start_time >= statement_timestamp() - INTERVAL '60 minutes') cnt ON TRUE;

-- ───────── [PG_VIEW-v_m_summary_kpi.sql] ─────────
--------------------------------------------------------------------------------
-- PG_VIEW-v_m_summary_kpi
-- ITSTONE DB Monitor v1  /  수집 서버 : PostgreSQL (itstone 스키마)
-- 용도 : Summary 탭 헤드라인 KPI + 전 도메인 종합 위험 (단일 행)
--------------------------------------------------------------------------------
-- [설계]
--   - 항상 정확히 1행 반환(첫 화면). 수집기 다운 시 헤드라인은 NULL, 위험은 0.
--     → 헤드라인은 스칼라 서브쿼리(빈 소스 시 NULL), 위험 롤업은 집계(항상 1행).
--   - overall_status = 전 9개 _now 뷰의 risk_level 중 최악.
--     CRITICAL 1건↑ → CRITICAL, WARNING 1건↑ → WARNING, 그 외 NORMAL.
--   - critical_count / warning_count = 위험 '항목(행)' 수(전 도메인 합). Top-N 절단 제거로
--     커질 수 있음(예: Top SQL 80 + Index 30 = 110). UI 라벨 "항목 수"(도메인 수 아님).
--   - critical_domains / warning_domains = 위험 '도메인(영역)' 수(COUNT DISTINCT). 배너 헤드라인 권장.
--   - 각 _now 뷰가 risk 를 이미 계산하므로, 여기서는 모으기만(중복 임계 없음).
--   - CTE 미사용. UNION ALL 인라인 뷰 + as-of LATERAL join 만.
--   - [item 5] 신선도(data_age_sec/data_freshness)는 순수 PG 시계로 산출 —
--     m_collector_health.GLOBAL_STATUS 모듈의 '마지막 성공(collect_time FILTER status=OK)'.
--     기존 m_global_status.MAX(collect_time)(MariaDB 시계) 사용을 폐기(시계 교차 제거).
--     ※ m_global_status.collect_time 자체는 다른 뷰의 MariaDB 델타 계산용으로 존치(제거 금지).
--   - [item 2] 모듈 상태(failed_modules/stale_modules)는 m_collector_health 를 모듈별
--     as-of LATERAL join(최신 heartbeat 1행)해 파생. '수집기 사이클 성공/실패/정체' 관측.
--     활동 게이팅 테이블도 collector 는 매 사이클 heartbeat 를 남기므로 '표본 없음' 오탐 소멸
--     (기존 no_sample_modules 개념은 status='SKIP' = capability 부재 의도적 미수집으로 흡수).
--   - [item 3] performance_schema_yn / digest_capable_yn / lock_tree_supported /
--     collection_mode 는 m_target_capability 최신 1행에서 노출(하드코딩 'Y' 및 인스턴스행 파생 폐기).
--   - [item 4] monitor_status precedence 에 PARTIAL 추가:
--     NO_DATA > CRITICAL > CONFIG > STALE > PARTIAL > WARNING > NORMAL.
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW itstone.v_m_summary_kpi AS
-- ★ monitor_status: 배너 단일 권위 컬럼. overall_status(순수 risk)만 보면 capability OFF/수집 지연 시
--   '정상(녹색)' 거짓 안심 → 모니터링 도구 최악 실패. 관측가능성(CONFIG/STALE/PARTIAL/NO_DATA)을 함께 접어
--   'never green when blind' 보장. precedence 핵심: 실데이터 CRITICAL 은 맹점/지연보다 위(묻지 않음 —
--   예: P_S OFF 라도 workload 는 global_status 기반이라 커넥션 포화 CRITICAL 이 진짜일 수 있음).
--   단 수집 완전 중단(NO_DATA = GLOBAL_STATUS 성공 heartbeat 자체 없음)은 risk 신뢰 불가라 최상위.
--   PARTIAL = 일부 consumer OFF(collection_mode='PARTIAL') — CONFIG(P_S 전역 OFF)보다는 약하나
--   일부 상세(digest/wait/io) 맹점이 있으므로 WARNING 위에 노출.
--   overall_status(순수 risk)는 그대로 병행 노출 — 위험 차원만 필요한 소비자용.
SELECT
    s.*,
    CASE
        WHEN s.data_freshness = 'NO_DATA'                                THEN 'NO_DATA'   -- GLOBAL_STATUS 성공 heartbeat 없음 → risk 신뢰 불가, 최상위
        WHEN s.critical_count > 0                                        THEN 'CRITICAL'  -- 실데이터 위험은 맹점/지연보다 먼저 노출(STALE 에 묻지 않음)
        WHEN s.performance_schema_yn = 'N'                               THEN 'CONFIG'    -- P_S 전역 OFF → SQL/Session/Lock/IO 맹점
        WHEN s.data_freshness <> 'FRESH'
             OR s.stale_modules  IS NOT NULL
             OR s.failed_modules IS NOT NULL                             THEN 'STALE'     -- heartbeat 지연 / 일부 모듈 정체 / 사이클 실패
        WHEN s.collection_mode = 'PARTIAL'                              THEN 'PARTIAL'   -- [item 4] 일부 consumer OFF → 상세 부분 맹점
        WHEN s.warning_count > 0                                         THEN 'WARNING'
        ELSE 'NORMAL'                                                                     -- FRESH + P_S ON + 모듈 정상 + PARTIAL 아님 + risk 없음 → 진짜 all-clear
    END                                                                 AS monitor_status
FROM (
SELECT
    -- 인스턴스 (최근 스냅샷)
    (SELECT i.version             FROM itstone.m_instance_status i
       WHERE i.collect_time = (SELECT MAX(collect_time) FROM itstone.m_instance_status
                               WHERE collect_time >= (SELECT MAX(collect_time) FROM itstone.m_instance_status) - INTERVAL '60 seconds')) AS version,
    (SELECT i.uptime_days         FROM itstone.m_instance_status i
       WHERE i.collect_time = (SELECT MAX(collect_time) FROM itstone.m_instance_status
                               WHERE collect_time >= (SELECT MAX(collect_time) FROM itstone.m_instance_status) - INTERVAL '60 seconds')) AS uptime_days,
    (SELECT i.threads_connected   FROM itstone.m_instance_status i
       WHERE i.collect_time = (SELECT MAX(collect_time) FROM itstone.m_instance_status
                               WHERE collect_time >= (SELECT MAX(collect_time) FROM itstone.m_instance_status) - INTERVAL '60 seconds')) AS threads_connected,
    (SELECT i.max_connections     FROM itstone.m_instance_status i
       WHERE i.collect_time = (SELECT MAX(collect_time) FROM itstone.m_instance_status
                               WHERE collect_time >= (SELECT MAX(collect_time) FROM itstone.m_instance_status) - INTERVAL '60 seconds')) AS max_connections,
    (SELECT i.connection_usage_pct FROM itstone.m_instance_status i
       WHERE i.collect_time = (SELECT MAX(collect_time) FROM itstone.m_instance_status
                               WHERE collect_time >= (SELECT MAX(collect_time) FROM itstone.m_instance_status) - INTERVAL '60 seconds')) AS connection_usage_pct,
    -- ★ [item 3] 수집 가능성(capability) — m_target_capability 최신 1행(설치 시 + 1일 점검).
    --   하드코딩 'Y' 및 인스턴스행 파생(performance_schema_yn/collection_mode) 폐기, capability 권위로 일원화.
    --   performance_schema_yn 'N' → P_S 전역 OFF(SQL/Session/Index·Table·File I/O 상세 수집 불가, 해당 뷰 빈 결과).
    --   digest_capable_yn      → P_S ON AND digest consumer ON 종합. 'N' 이면 SQL digest 화면 비활성 안내.
    --   lock_tree_supported    = I_S.INNODB_LOCK_WAITS/INNODB_LOCKS 존재(lock_wait_table_yn). v_m_lock_tree_now 0건='락 없음'.
    --   collection_mode        = ENHANCED / PARTIAL / BASIC. C# 헤더 모드 배지 + monitor_status PARTIAL 근거.
    (SELECT c.performance_schema_yn FROM itstone.m_target_capability c ORDER BY c.collect_time DESC LIMIT 1) AS performance_schema_yn,
    (SELECT c.digest_capable_yn     FROM itstone.m_target_capability c ORDER BY c.collect_time DESC LIMIT 1) AS digest_capable_yn,
    (SELECT c.lock_wait_table_yn    FROM itstone.m_target_capability c ORDER BY c.collect_time DESC LIMIT 1) AS lock_tree_supported,
    (SELECT c.collection_mode       FROM itstone.m_target_capability c ORDER BY c.collect_time DESC LIMIT 1) AS collection_mode,
    -- 워크로드 / 메모리 (단일행 _now 뷰)
    (SELECT w.qps             FROM itstone.v_m_workload_now w)              AS qps,
    (SELECT w.tps             FROM itstone.v_m_workload_now w)              AS tps,
    (SELECT w.threads_running FROM itstone.v_m_workload_now w)             AS threads_running,
    -- 크기 가중 평균(단순 AVG 면 작은 pool 이 큰 pool 과 동등 가중 → 대표값 왜곡). hit 는 활동량(gets)
    --   가중이 이상적이나 _now 는 InnoDB 게이지(hit_rate_per_1000) 라 pool_size 로 근사. (정밀 활동량 가중은
    --   trend 가 델타 기반으로 제공: v_m_buffer_pool_trend.hit_pct.)
    (SELECT ROUND(SUM(b.hit_pct * b.pool_size_pages)::numeric
                  / NULLIF(SUM(b.pool_size_pages), 0), 2)
       FROM itstone.v_m_buffer_pool_now b)                                 AS buffer_hit_pct,
    -- 활동 / 잠금 카운트  (active_session=Enhanced, processlist=Basic — 모드 배타라 합산=현재 모드값)
    ((SELECT COUNT(*) FROM itstone.v_m_active_session_now)
     + (SELECT COUNT(*) FROM itstone.v_m_processlist_now))                  AS active_sessions,
    (SELECT COUNT(*) FROM itstone.v_m_lock_tree_now)                        AS lock_waits,
    (SELECT COUNT(*) FROM itstone.v_m_innodb_trx_now WHERE trx_state = 'LOCK WAIT') AS lock_wait_trx,
    -- 종합 위험 롤업 — *_count = 위험 '항목(행)' 수, *_domains = 위험 '도메인(영역)' 수.
    --   ★ UI 주의: count 는 행 수(예: Top SQL WARNING 80 + Index 30 = 110). "경고 항목 수"로 라벨,
    --     "경고 도메인 수"로 쓰지 말 것(과장 오해). 배너 헤드라인은 *_domains 권장("3개 영역 경고").
    rk.critical_count,
    rk.warning_count,
    rk.critical_domains,
    rk.warning_domains,
    CASE
        WHEN rk.critical_count > 0 THEN 'CRITICAL'
        WHEN rk.warning_count  > 0 THEN 'WARNING'
        ELSE 'NORMAL'
    END                                                                    AS overall_status,
    -- ★ [item 5] 데이터 신선도 — 순수 PG 시계. NOW() − GLOBAL_STATUS 모듈 '마지막 성공'(collector_health).
    --   data_age_sec = PG 현재시각 − m_collector_health(module='GLOBAL_STATUS', status='OK') 최신 collect_time.
    --   두 시각 모두 PG statement_timestamp() 라 MariaDB↔PG 시계 오차(NTP)에 면역(기존 교차 비교 폐기).
    --   ※ MariaDB 델타는 여전히 m_global_status.collect_time 사용(타 뷰) — 그 컬럼은 존치.
    GREATEST(EXTRACT(EPOCH FROM (NOW()
        - (SELECT MAX(h.collect_time) FROM itstone.m_collector_health h
            WHERE h.module_name = 'GLOBAL_STATUS' AND h.status = 'OK')))::int, 0) AS data_age_sec,
    CASE
        WHEN (SELECT MAX(h.collect_time) FROM itstone.m_collector_health h
               WHERE h.module_name = 'GLOBAL_STATUS' AND h.status = 'OK') IS NULL THEN 'NO_DATA'
        WHEN EXTRACT(EPOCH FROM (NOW()
             - (SELECT MAX(h.collect_time) FROM itstone.m_collector_health h
                 WHERE h.module_name = 'GLOBAL_STATUS' AND h.status = 'OK'))) > 60 THEN 'STALE'
        ELSE 'FRESH'
    END                                                                    AS data_freshness,
    -- ★ [item 2] 모듈별 수집기 헬스 (as-of LATERAL join) — failed_modules / stale_modules.
    mh.failed_modules,
    mh.stale_modules
FROM
(
    SELECT
        COUNT(*) FILTER (WHERE ar.risk_level = 'CRITICAL')                  AS critical_count,
        COUNT(*) FILTER (WHERE ar.risk_level = 'WARNING')                   AS warning_count,
        COUNT(DISTINCT ar.domain) FILTER (WHERE ar.risk_level = 'CRITICAL') AS critical_domains,
        COUNT(DISTINCT ar.domain) FILTER (WHERE ar.risk_level = 'WARNING')  AS warning_domains
    FROM
    (
        -- ★ 종합 위험은 전체 행 기준. top_sql/index_io/table_lock 의 Top-N 절단을 제거했으므로
        --   51위 이하의 WARNING/CRITICAL 도 누락 없이 집계(→ count 는 커질 수 있음 = 행 수).
        --   domain 태그로 '도메인(영역)' 수도 별도 집계(배너 헤드라인용, 과장 방지).
        SELECT 'WORKLOAD' AS domain, risk_level FROM itstone.v_m_workload_now
        UNION ALL SELECT 'SESSION',  risk_level FROM itstone.v_m_active_session_now
        UNION ALL SELECT 'SESSION',  risk_level FROM itstone.v_m_processlist_now
        UNION ALL SELECT 'TRX',      risk_level FROM itstone.v_m_innodb_trx_now
        UNION ALL SELECT 'LOCK',     risk_level FROM itstone.v_m_lock_tree_now
        UNION ALL SELECT 'BUFPOOL',  risk_level FROM itstone.v_m_buffer_pool_now
        UNION ALL SELECT 'TBLLOCK',  risk_level FROM itstone.v_m_table_lock_now
        UNION ALL SELECT 'SQL',      risk_level FROM itstone.v_m_top_sql_now
        UNION ALL SELECT 'INDEX',    risk_level FROM itstone.v_m_index_io_now
        UNION ALL SELECT 'FILEIO',   risk_level FROM itstone.v_m_file_io_now
    ) ar
) rk
CROSS JOIN
(
    -- ★ [item 2] 모듈별 수집기 헬스 파생 (as-of LATERAL join).
    --   각 모듈의 최신 heartbeat 1행을 collect_time <= NOW() 과거방향 ORDER BY DESC LIMIT 1 로 집음.
    --   failed_modules : 최신 status='FAIL'(사이클 실패, 능동 장애).
    --   stale_modules  : heartbeat 존재하나 임계초 이상 늙음(수집기 정체·중단). status='SKIP'(capability
    --                    부재 의도적 미수집)·미관측(NULL, 설치 직후 race)은 제외 → 오탐 방지.
    --   heartbeat 를 추적하므로 활동 게이팅 테이블(INDEX/TBLLOCK)도 '표본 없음' 오탐 없음(collector 는 매 사이클 기록).
    --   ▲▲ 확인요망 (배포 전 필수) ▲▲
    --     (1) module_name 코드는 Agent 수집모듈 레지스트리와 문자열 정확히 일치해야 함. 불일치 시 해당 모듈이
    --         LATERAL 에서 항상 미관측(NULL) 처리 → stale/failed 영구 미탐지(조용한 맹점). DDL 은
    --         GLOBAL_STATUS/INSTANCE/ACTIVE_SESSION 3종만 예시 → 나머지 코드는 대조 확인 필수.
    --     (2) stale_thr_sec 원칙 = '해당 모듈 수집주기 × 2~3배'(한두 사이클 누락은 정체 아님, 3배는 여유).
    --         현재 하드코딩(상시 30s 주기→30, 저빈도 120s 주기→120)은 주기 가정치. Agent 실제 주기로 재확인.
    --     (3) 상시 모듈만 나열(활동성 SESSION/TRX/LOCK 제외 — 정상적으로 0건일 수 있어 stale 부적합).
    --     ※ 코드/임계초의 cfg 테이블 이관(하드코딩 제거)은 v1.1 로 분리(KNOWN_ISSUES 참조).
    SELECT
        string_agg(hm.module_name, ',' ORDER BY hm.module_name) FILTER (WHERE hm.status = 'FAIL') AS failed_modules,
        string_agg(hm.module_name, ',' ORDER BY hm.module_name) FILTER (WHERE hm.is_stale)        AS stale_modules
    FROM
    (
        SELECT
            md.module_name,
            hc.status,
            (hc.collect_time IS NOT NULL                                    -- 미관측(NULL)은 stale 로 단정 안 함(설치 직후 race)
             AND hc.status <> 'SKIP'                                        -- SKIP=capability 부재 의도적 미수집 → stale 아님
             AND hc.collect_time < NOW() - make_interval(secs => md.stale_thr_sec)) AS is_stale
        FROM
        (
            SELECT 'GLOBAL_STATUS' AS module_name,  30 AS stale_thr_sec  -- ▲ 코드=Agent 레지스트리 대조 / 임계=주기×2~3배 (cfg 이관 v1.1)
            UNION ALL SELECT 'INSTANCE',     30
            UNION ALL SELECT 'BUFFER_POOL',  30
            UNION ALL SELECT 'SQL_DIGEST',  120
            UNION ALL SELECT 'INDEX_IO',    120
            UNION ALL SELECT 'TABLE_LOCK',  120
            UNION ALL SELECT 'FILE_IO',     120
        ) md
        LEFT JOIN LATERAL
        (
            SELECT h.status, h.collect_time
            FROM itstone.m_collector_health h
            WHERE h.module_name = md.module_name
              AND h.collect_time <= NOW()
            ORDER BY h.collect_time DESC
            LIMIT 1
        ) hc ON true
    ) hm
) mh
) s;

\echo 'ITSTONE MariaDB 화면 뷰(v_m_*) 25개 생성 완료.'
