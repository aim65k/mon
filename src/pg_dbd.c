#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <libpq-fe.h>

#include "pg_dbd.h"
#include "string_db.h"
#include "insert_dbd.h"
#include "common_dbd.h"

extern char gcOnlyOneCycle;
extern char gcDebugMode;

/* 연결 정보 */
static const char *cpHost;
static const char *cpPort;
static const char *cpUser;
static const char *cpPass;
static const char *cpDbName;

/* ========================================================================= */
/* 유틸리티 함수                                                              */
/* ========================================================================= */

static void
daPostgresDie(qry_t *spQry, char cExitYn, PGconn *conn, const char *msg)
{
    spQry->cRslt = DEF_NO;
    spQry->sErr.iErrCd = 0;
    if (conn) {
        LOGE("POSTGRES ERROR [%s] %s\n", msg, PQerrorMessage(conn));
        snprintf(spQry->sErr.caPart, sizeof(spQry->sErr.caPart), "%s", msg);
        snprintf(spQry->sErr.caErrMsg, sizeof(spQry->sErr.caErrMsg), "%s", PQerrorMessage(conn));
    } else {
        LOGE("POSTGRES ERROR [%s]\n", msg);
        snprintf(spQry->sErr.caPart, sizeof(spQry->sErr.caPart), "%s", msg);
        snprintf(spQry->sErr.caErrMsg, sizeof(spQry->sErr.caErrMsg), "%s", "");
    }
    if(cExitYn == EXIT_YES) exit(1);
    return;
}

static void
daPostgresInit(qry_t *spQry)
{
    int i;
    
    for (i = 0; i < MAX_COLS; i++) {
        spQry->sDb.colbuf[i] = NULL;
        spQry->sDb.col_buf_size[i] = 0;
        spQry->sDb.ind[i] = 0;
    }
    
    spQry->sDb.pg_conn = NULL;
    spQry->sDb.pg_result = NULL;
    spQry->sDb.current_row = 0;
    spQry->sDb.total_rows = 0;
    
    spQry->iSelColCnt = 0;
    spQry->cpSelResult = NULL;
}

static const char *
daGetPgFieldTypeString(Oid oid)
{
    switch (oid) {
        case 16:    return "BOOL";
        case 17:    return "BYTEA";
        case 18:    return "CHAR";
        case 19:    return "NAME";
        case 20:    return "INT8";
        case 21:    return "INT2";
        case 23:    return "INT4";
        case 25:    return "TEXT";
        case 26:    return "OID";
        case 700:   return "FLOAT4";
        case 701:   return "FLOAT8";
        case 790:   return "MONEY";
        case 1042:  return "BPCHAR";
        case 1043:  return "VARCHAR";
        case 1082:  return "DATE";
        case 1083:  return "TIME";
        case 1114:  return "TIMESTAMP";
        case 1184:  return "TIMESTAMPTZ";
        case 1186:  return "INTERVAL";
        case 1700:  return "NUMERIC";
        case 2950:  return "UUID";
        case 3802:  return "JSONB";
        case 114:   return "JSON";
        default:    return "UNKNOWN";
    }
}

static int
daGetPgOutBufSize(const char *colName, Oid oid, int mod)
{
    (void)colName;  /* unused */
    
    switch (oid) {
        /* 정수형 */
        case 21:    /* INT2 */
        case 23:    /* INT4 */
        case 20:    /* INT8 */
        case 26:    /* OID */
            return 64;
        
        /* 실수형 */
        case 700:   /* FLOAT4 */
        case 701:   /* FLOAT8 */
        case 1700:  /* NUMERIC */
            return 128;
        
        /* 날짜/시간 */
        case 1082:  /* DATE */
        case 1083:  /* TIME */
        case 1114:  /* TIMESTAMP */
        case 1184:  /* TIMESTAMPTZ */
        case 1186:  /* INTERVAL */
            return 128;
        
        /* 문자열 */
        case 18:    /* CHAR */
        case 19:    /* NAME */
        case 25:    /* TEXT */
        case 1042:  /* BPCHAR */
        case 1043:  /* VARCHAR */
            if (mod > 4) {
                /* mod = 실제길이 + 4 (PostgreSQL 내부 규칙) */
                return mod;
            }
            return 8192;
        
        /* BOOL */
        case 16:
            return 8;
        
        /* UUID */
        case 2950:
            return 64;
        
        /* JSON/JSONB */
        case 114:
        case 3802:
            return 65536;
        
        /* BYTEA - 지원하지 않음 */
        case 17:
            LOGE("BYTEA type not supported\n");
            return 8192;
        
        default:
            return 8192;
    }
}

/* ========================================================================= */
/* 메모리 할당                                                                */
/* ========================================================================= */

static void
daMallocMrgRow(qry_t *spQry)
{
    int i;
    
    spQry->cppMrgRow = (char **)dcMalloc(sizeof(char *) * spQry->iSelColCnt);
    ASSERT(spQry->cppMrgRow);
    
    for (i = 0; i < spQry->iSelColCnt; i++) {
        spQry->cppMrgRow[i] = (char *)dcMalloc(spQry->sDb.col_buf_size[i]);
        ASSERT(spQry->cppMrgRow[i]);
        spQry->cppMrgRow[i][0] = '\0';
    }
}

/* ========================================================================= */
/* 공개 함수                                                                  */
/* ========================================================================= */

void
daDBEnv(void)
{
    cpHost   = ENV_REQUIRED(PG_HOST_IP);
    cpPort   = ENV_REQUIRED(PG_PORT);
    cpUser   = ENV_REQUIRED(PG_USER);
    cpPass   = ENV_REQUIRED(PG_PASS);
    cpDbName = ENV_REQUIRED(PG_DATABASE_NAME);

    return;
}

int
daDBOpen(qry_t *spQry)
{
    PGconn *conn;
    char    conninfo[1024];
    
    daPostgresInit(spQry);
    
    snprintf(conninfo, sizeof(conninfo),
             "host=%s port=%s dbname=%s user=%s password=%s",
             cpHost, cpPort, cpDbName, cpUser, cpPass);
    
    conn = PQconnectdb(conninfo);
    
    if (PQstatus(conn) != CONNECTION_OK) {
        daPostgresDie(spQry, EXIT_YES, conn, "PQconnectdb failed");
        return -1;
    }
    
    /* UTF-8 인코딩 설정 */
    PQsetClientEncoding(conn, "UTF8");
    
    spQry->sDb.pg_conn = conn;
    
    signal(SIGINT, SIG_DFL);
    
    if (gcDebugMode == DEF_YES) {
        LOGD("PostgreSQL connected: %s@%s:%s/%s\n", cpUser, cpHost, cpPort, cpDbName);
    }
    
    return 0;
}

int
daDBPrepare(qry_t *spQry)
{
    PGconn   *conn = spQry->sDb.pg_conn;
    PGresult *res;
    
    const char *sql_text = spQry->cpSelQry;
    int         col_cnt;
    int         i;
    
    /* LIMIT 0으로 메타데이터만 조회 */
    char meta_sql[8192];
    snprintf(meta_sql, sizeof(meta_sql), 
             "SELECT * FROM (%s) AS _meta_query LIMIT 0", sql_text);
    
    res = PQexec(conn, meta_sql);
    
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        LOGE("[%s] PQexec DESCRIBE failed: %s\n", spQry->caTitle, PQerrorMessage(conn));
        LOGE("[%s] sql_text: [%s]\n", spQry->caTitle, sql_text);
        PQclear(res);
        return -1;
    }
    
    if (gcDebugMode == DEF_YES) {
        LOGD("[%s] sql_text:[%s]\n", spQry->caTitle, sql_text);
    }
    
    /* 컬럼 개수 */
    col_cnt = PQnfields(res);
    
    if (col_cnt > MAX_COLS) {
        col_cnt = MAX_COLS;
    }
    
    if (col_cnt != spQry->iInsColCnt) {
        LOGE("[%s] insert(%d) 와 select(%d) 의 컬럼숫자가 다릅니다., exit\n",
             spQry->caTitle, spQry->iInsColCnt, col_cnt);
        PQclear(res);
        exit(1);
    }
    
    spQry->iSelColCnt = col_cnt;
    
    /* 컬럼별 버퍼 할당 */
    for (i = 0; i < col_cnt; i++) {
        const char *col_name = PQfname(res, i);
        Oid         col_type = PQftype(res, i);
        int         col_mod  = PQfmod(res, i);
        int         col_size = PQfsize(res, i);
        
        spQry->sDb.col_buf_size[i] = daGetPgOutBufSize(col_name, col_type, col_mod);
        spQry->sDb.colbuf[i] = (char *)dcMalloc(spQry->sDb.col_buf_size[i] + 1);
        memset(spQry->sDb.colbuf[i], 0x00, spQry->sDb.col_buf_size[i] + 1);
        
        if (gcDebugMode == DEF_YES) {
            LOGD("%d [%-30s] type=[%-5d.%-12s] size=%-5d mod=%-5d bufsize=%d\n",
                 i, col_name, col_type, daGetPgFieldTypeString(col_type),
                 col_size, col_mod, spQry->sDb.col_buf_size[i]);
        }
    }
    
    PQclear(res);
    
    if (spQry->cRunMethod == RUN_METHOD_MERGE) {
        daMallocMrgRow(spQry);
    }
    
    if (gcDebugMode == DEF_YES) {
        LOGD("PostgreSQL prepared, title:%s, cols:%d\n", spQry->caTitle, col_cnt);
    }
    
    return 0;
}

int
daDBSelect(qry_t *spQry)
{
    PGconn   *conn = spQry->sDb.pg_conn;
    PGresult *res;
    
    const char *sql_text = spQry->cpSelQry;
    int         row_cnt;
    int         col_cnt;
    int         row, col;
    
    size_t      cap, len;
    char       *rowbuf = NULL;
    
    spQry->iSelCnt = 0;
    
    /* 쿼리 실행 */
    res = PQexec(conn, sql_text);
    
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        LOGE("[%s] PQexec SELECT failed: %s\n", spQry->caTitle, PQerrorMessage(conn));
        daPostgresDie(spQry, EXIT_NO, conn, "PQexec SELECT failed");
        return -1;
    }
    
    row_cnt = PQntuples(res);
    col_cnt = PQnfields(res);
    
    spQry->sDb.pg_result = res;
    spQry->sDb.total_rows = row_cnt;
    
    /* Fetch loop */
    for (row = 0; row < row_cnt; row++) {
        /* 컬럼 데이터 추출 */
        for (col = 0; col < col_cnt && col < spQry->iSelColCnt; col++) {
            if (PQgetisnull(res, row, col)) {
                spQry->sDb.ind[col] = -1;  /* NULL 표시 */
                spQry->sDb.colbuf[col][0] = '\0';
            } else {
                spQry->sDb.ind[col] = 0;
                char *val = PQgetvalue(res, row, col);
                int   val_len = PQgetlength(res, row, col);
                
                if (val_len >= spQry->sDb.col_buf_size[col]) {
                    val_len = spQry->sDb.col_buf_size[col] - 1;
                }
                
                memcpy(spQry->sDb.colbuf[col], val, val_len);
                spQry->sDb.colbuf[col][val_len] = '\0';
            }
        }
        
        /* 행 데이터 구성 */
        cap = LINE_BUF_INIT;
        len = 0;
        rowbuf = (char *)dcMalloc(cap);
        rowbuf[0] = '\0';
        
        for (col = 0; col < spQry->iSelColCnt; col++) {
            if (spQry->cRunMethod == RUN_METHOD_INSERT) {
                if (col > 0) {
                    daAppendString(&rowbuf, &cap, &len, "\t");
                }
                
                if (spQry->sDb.ind[col] < 0) {
                    daAppendString(&rowbuf, &cap, &len, "\\N");
                } else {
                    spQry->sDb.colbuf[col][spQry->sDb.col_buf_size[col] - 1] = '\0';
                    dcAllTrimLen(spQry->sDb.colbuf[col], (int)strlen(spQry->sDb.colbuf[col]));
                    
                    char *esc = daEscapePgCopyField(spQry->sDb.colbuf[col]);
                    daAppendString(&rowbuf, &cap, &len, esc);
                    FREE(esc);
                }
            } else {
                /* MERGE 모드 */
                if (spQry->sDb.ind[col] < 0) {
                    spQry->cppMrgRow[col][0] = '\0';
                } else {
                    spQry->sDb.colbuf[col][spQry->sDb.col_buf_size[col] - 1] = '\0';
                    dcAllTrimLen(spQry->sDb.colbuf[col], (int)strlen(spQry->sDb.colbuf[col]));
                    snprintf(spQry->cppMrgRow[col], spQry->sDb.col_buf_size[col],
                             "%s", spQry->sDb.colbuf[col]);
                }
            }
        }
        
        daAppendString(&rowbuf, &cap, &len, "\n");
        
        if (spQry->cRunMethod == RUN_METHOD_INSERT) {
            if (daPgCopyPutRow(spQry, rowbuf) != 0) {
                daPostgresDie(spQry, EXIT_YES, conn, "PQputCopyData failed");
                FREE(rowbuf);
                PQclear(res);
                spQry->sDb.pg_result = NULL;
                return -1;
            }
        } else {
            daMrgRowToPostgre(spQry);
        }
        
        FREE(rowbuf);
        spQry->iSelCnt++;
    }
    
    PQclear(res);
    spQry->sDb.pg_result = NULL;
    
    daPrintInsReslt(spQry);
    
    return 0;
}

void
daDBClose(qry_t *spQry)
{
    int i;
    
    /* 결과 정리 */
    if (spQry->sDb.pg_result) {
        PQclear(spQry->sDb.pg_result);
        spQry->sDb.pg_result = NULL;
    }
    
    /* 연결 종료 */
    if (spQry->sDb.pg_conn) {
        PQfinish(spQry->sDb.pg_conn);
        spQry->sDb.pg_conn = NULL;
    }
    
    /* 컬럼 버퍼 해제 */
    for (i = 0; i < MAX_COLS; i++) {
        if (spQry->sDb.colbuf[i]) {
            FREE(spQry->sDb.colbuf[i]);
            spQry->sDb.colbuf[i] = NULL;
        }
    }
    
    /* MERGE 모드 버퍼 해제 */
    if (spQry->cppMrgRow) {
        for (i = 0; i < spQry->iSelColCnt; i++) {
            if (spQry->cppMrgRow[i]) {
                FREE(spQry->cppMrgRow[i]);
            }
        }
        FREE(spQry->cppMrgRow);
        spQry->cppMrgRow = NULL;
    }
    
    if (gcDebugMode == DEF_YES) {
        LOGD("PostgreSQL connection closed\n");
    }
}

