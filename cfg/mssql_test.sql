[test0, Y, 2]
SELECT to_char(now(), 'YYYYMMDD HH24MISS')

[test1, Y, 15:21:00]
select now()

[test2, Y, 5]
INSERT INTO mssql_query_stats 
(
    execution_count, total_cpu_time_ms, avg_cpu_time_ms, query_text
)
SELECT TOP 10
    qs.execution_count,                                    -- 2. 실행횟수
    qs.total_worker_time / 1000,                           -- 3. 총 CPU 시간
    (qs.total_worker_time / qs.execution_count) / 1000,    -- 4. 평균 CPU 시간
    st.text                                                -- 5. 실행된 쿼리
FROM 
    sys.dm_exec_query_stats qs
CROSS APPLY 
    sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY 
    qs.total_worker_time DESC;

[test3, Y, 10]
INSERT INTO mssql_query_stats 
(
    execution_count, total_cpu_time_ms, avg_cpu_time_ms, query_text
)
SELECT TOP 10
    qs.execution_count,                                    -- 2. 실행횟수
    qs.total_worker_time / 1000,                           -- 3. 총 CPU 시간
    (qs.total_worker_time / qs.execution_count) / 1000,    -- 4. 평균 CPU 시간
    st.text                                                -- 5. 실행된 쿼리
FROM 
    sys.dm_exec_query_stats qs
CROSS APPLY 
    sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY 
    qs.total_worker_time DESC;
