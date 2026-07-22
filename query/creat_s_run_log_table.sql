-------------------------------------------------------------------------------
-- collect 테이블
-------------------------------------------------------------------------------
CREATE TABLE s_run_log_collect (
    title         VARCHAR(128) NOT NULL,
    save_time     TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    result_count  INT,           
    cycle         INT,            
    hms           VARCHAR(8),
    result        CHAR(1),
    elapsed_time  INT,           
    run_index     SMALLINT, 
    pid           INT,

    error_part    VARCHAR(64),
    error_code    SMALLINT,      
    error_msg     VARCHAR(1024),
        
    CONSTRAINT pk_s_run_log_collect PRIMARY KEY (title)
);

COMMENT ON TABLE s_run_log_collect IS 'collect log 테이블';
COMMENT ON COLUMN s_run_log_collect.title          IS '시나리오 제목';
COMMENT ON COLUMN s_run_log_collect.save_time      IS '저장시간';
COMMENT ON COLUMN s_run_log_collect.result_count   IS '수행결과 건수';
COMMENT ON COLUMN s_run_log_collect.cycle          IS '수집주기, 0이면 hms값 참조';
COMMENT ON COLUMN s_run_log_collect.hms            IS '수행시간 cycle이 0일때만 참조';
COMMENT ON COLUMN s_run_log_collect.elapsed_time   IS '처리시간 (단위:micro sec)';

COMMENT ON COLUMN s_run_log_collect.run_index      IS '실행중인 index';
COMMENT ON COLUMN s_run_log_collect.pid            IS '실행중인 process id';
COMMENT ON COLUMN s_run_log_collect.result         IS '결과 Y, N';
COMMENT ON COLUMN s_run_log_collect.error_part     IS '오류난 부분';
COMMENT ON COLUMN s_run_log_collect.error_code     IS '오류코드(없을때는 0)';
COMMENT ON COLUMN s_run_log_collect.error_msg      IS '오류내용';
