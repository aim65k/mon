#ifndef _PG_DBD_H
#define _PG_DBD_H

#include <libpq-fe.h>
#include "common_dbd.h"

#define     PG_HOST_IP           "PG_HOST_IP"
#define     PG_PORT              "PG_PORT"
#define     PG_USER              "PG_USER"
#define     PG_PASS              "PG_PASS"
#define     PG_DATABASE_NAME     "PG_DATABASE_NAME"

/* DB 구조체 (PostgreSQL용) */
typedef struct {
    PGconn   *pg_conn;          /* PostgreSQL 연결 */
    PGresult *pg_result;        /* 쿼리 결과 */
    
    char     *colbuf[MAX_COLS]; /* 컬럼 데이터 버퍼 */
    int       col_buf_size[MAX_COLS];
    int       ind[MAX_COLS];    /* NULL 표시자 (-1: NULL) */
    
    int       current_row;      /* 현재 fetch 중인 행 */
    int       total_rows;       /* 전체 행 수 */
} db_ctx_t;

/* 함수 선언 */
void daDBEnv(void);

#endif /* _PG_DBD_H */

