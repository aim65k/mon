[test1, Y, 2]
SELECT to_char(now(), 'YYYYMMDD HH24MISS')

[test2, Y, 15:21:00]
select now()

[test3, Y, 5]
INSERT INTO pg_active_sessions
(
    active_sessions, running_queries, idle_sessions, longest_query_sec
)
SELECT 
    COUNT(*) AS active_sessions,
    COUNT(*) FILTER (WHERE state = 'active') AS running_queries,
    COUNT(*) FILTER (WHERE state = 'idle') AS idle_sessions,
    MAX(EXTRACT(EPOCH FROM (now() - query_start)))::int AS longest_query_sec
FROM pg_stat_activity
WHERE pid <> pg_backend_pid();

[test4, Y, 5]
INSERT INTO pg_active_sessions
(
    active_sessions, running_queries, idle_sessions, longest_query_sec
)
SELECT 
    COUNT(*) AS active_sessions,
    COUNT(*) FILTER (WHERE state = 'active') AS running_queries,
    COUNT(*) FILTER (WHERE state = 'idle') AS idle_sessions,
    MAX(EXTRACT(EPOCH FROM (now() - query_start)))::int AS longest_query_sec
FROM pg_stat_activity
WHERE pid <> pg_backend_pid();
