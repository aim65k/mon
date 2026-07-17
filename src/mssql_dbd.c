/*
 * mssql_dbd.c — MSSQL(FreeTDS/unixODBC) 버전
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sql.h>
#include <sqlext.h>
#include <libpq-fe.h>

#include "string_db.h"
#include "insert_dbd.h"
#include "common_dbd.h"
#include "mssql_dbd.h"

extern char gcOnlyOneCycle;
extern char gcDebugMode;

/* ------------------------------------------------------------------ */
/* 에러 출력 후 종료                                                  */
/* ------------------------------------------------------------------ */
static void
daMssqlDie(SQLHANDLE handle, SQLSMALLINT handleType, const char *msg)
{
    SQLCHAR     sqlState[6];
    SQLCHAR     errMsg[SQL_MAX_MESSAGE_LENGTH];
    SQLINTEGER  nativeErr;
    SQLSMALLINT msgLen;
    SQLRETURN   rc;

    rc = SQLGetDiagRec(handleType, handle, 1, sqlState, &nativeErr,
                       errMsg, sizeof(errMsg), &msgLen);
    if (SQL_SUCCEEDED(rc)) {
        LOGE("ODBC ERROR [%s] state=%s native=%d msg=%s\n",
             msg, sqlState, (int)nativeErr, errMsg);
    } else {
        LOGE("ODBC ERROR [%s]\n", msg);
    }
    exit(1);
}

/* ------------------------------------------------------------------ */
/* 초기화                                                             */
/* ------------------------------------------------------------------ */
static void
daMssqlInit(qry_t *spQry)
{
    memset(spQry->sDb.colbuf, 0x00, sizeof(spQry->sDb.colbuf));
    memset(spQry->sDb.ind,    0x00, sizeof(spQry->sDb.ind));

    spQry->sDb.mssql_env  = SQL_NULL_HENV;
    spQry->sDb.mssql_dbc  = SQL_NULL_HDBC;
    spQry->sDb.mssql_stmt = SQL_NULL_HSTMT;

    spQry->iSelColCnt  = 0;
    spQry->cpSelResult = NULL;
}

const char *cpDsn; 
const char *cpUser;
const char *cpPass;

void
daDBEnv()
{
    cpDsn  = ENV_REQUIRED(MSSQL_DSN);   /* ODBC DSN 이름 */
    cpUser = ENV_REQUIRED(MSSQL_USER);
    cpPass = ENV_REQUIRED(MSSQL_PASS);
    return;
}

/* ------------------------------------------------------------------ */
/* DB 연결                                                            */
/* ------------------------------------------------------------------ */
int
daDBOpen(qry_t *spQry)
{
    SQLHENV   hEnv  = SQL_NULL_HENV;
    SQLHDBC   hDbc  = SQL_NULL_HDBC;
    SQLRETURN rc;


    daMssqlInit(spQry);

    /* 1. Environment 핸들 */
    rc = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &hEnv);
    if (!SQL_SUCCEEDED(rc))
        daMssqlDie(hEnv, SQL_HANDLE_ENV, "SQLAllocHandle ENV failed");

    rc = SQLSetEnvAttr(hEnv, SQL_ATTR_ODBC_VERSION,
                       (SQLPOINTER)SQL_OV_ODBC3, 0);
    if (!SQL_SUCCEEDED(rc))
        daMssqlDie(hEnv, SQL_HANDLE_ENV, "SQLSetEnvAttr ODBC_VERSION failed");

    /* 2. Connection 핸들 */
    rc = SQLAllocHandle(SQL_HANDLE_DBC, hEnv, &hDbc);
    if (!SQL_SUCCEEDED(rc))
        daMssqlDie(hEnv, SQL_HANDLE_ENV, "SQLAllocHandle DBC failed");

    /* 3. 연결 */
    rc = SQLConnect(hDbc,
                    (SQLCHAR *)cpDsn,  SQL_NTS,
                    (SQLCHAR *)cpUser, SQL_NTS,
                    (SQLCHAR *)cpPass, SQL_NTS);
    if (!SQL_SUCCEEDED(rc)) {
        tprintf("cpDsn:[%s], cpUser:[%s], cpPass:[%s]\n", cpDsn, cpUser, cpPass);
        daMssqlDie(hDbc, SQL_HANDLE_DBC, "SQLConnect failed");
    }

    spQry->sDb.mssql_env = hEnv;
    spQry->sDb.mssql_dbc = hDbc;

    signal(SIGINT, SIG_DFL);

    return 0;
}

/* ------------------------------------------------------------------ */
/* Merge 모드용 행 버퍼 할당                                          */
/* ------------------------------------------------------------------ */
static void
daMallocMgrRow(qry_t *spQry)
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

/* ------------------------------------------------------------------ */
/* 컬럼 타입에 따른 출력 버퍼 크기 결정                               */
/* ------------------------------------------------------------------ */
static SQLULEN
daGetOdbcOutBufSize(SQLSMALLINT sqlType, SQLULEN colSize)
{
    switch (sqlType) {
        case SQL_CHAR:
        case SQL_VARCHAR:
        case SQL_LONGVARCHAR:
        case SQL_WCHAR:
        case SQL_WVARCHAR:
        case SQL_WLONGVARCHAR:
            if (colSize > 0 && colSize < 32767)
                return colSize + 4;
            return 8192;

        case SQL_DECIMAL:
        case SQL_NUMERIC:
        case SQL_SMALLINT:
        case SQL_INTEGER:
        case SQL_REAL:
        case SQL_FLOAT:
        case SQL_DOUBLE:
        case SQL_BIGINT:
        case SQL_TINYINT:
            return 128;

        case SQL_TYPE_DATE:
        case SQL_TYPE_TIME:
        case SQL_TYPE_TIMESTAMP:
            return 64;

        case SQL_BINARY:
        case SQL_VARBINARY:
        case SQL_LONGVARBINARY:
            /* BLOB류 — 필요 시 확장 */
            return 8192;

        default:
            return 8192;
    }
}

/* ------------------------------------------------------------------ */
/* SQL 준비 및 컬럼 바인딩                                            */
/* ------------------------------------------------------------------ */
int
daDBPrepare(qry_t *spQry)
{
    SQLHDBC   hDbc  = spQry->sDb.mssql_dbc;
    SQLHSTMT  hStmt = SQL_NULL_HSTMT;
    SQLRETURN rc;

    SQLSMALLINT colCount = 0;
    SQLSMALLINT i;
    SQLCHAR     colName[256];
    SQLSMALLINT nameLen, sqlType, scale, nullable;
    SQLULEN     colSize;

    const char *sqlText = spQry->cpSelQry;

    /* 1. Statement 핸들 */
    rc = SQLAllocHandle(SQL_HANDLE_STMT, hDbc, &hStmt);
    if (!SQL_SUCCEEDED(rc))
        daMssqlDie(hDbc, SQL_HANDLE_DBC, "SQLAllocHandle STMT failed");

    spQry->sDb.mssql_stmt = hStmt;

    /* 2. Prepare */
    rc = SQLPrepare(hStmt, (SQLCHAR *)sqlText, SQL_NTS);
    if (!SQL_SUCCEEDED(rc))
        daMssqlDie(hStmt, SQL_HANDLE_STMT, "SQLPrepare failed");

    if (gcDebugMode == DEF_YES) {
        LOGD("[%s] sql_text:[%s]\n", spQry->caTitle, sqlText);
    }

    /* 3. 컬럼 개수 */
    rc = SQLNumResultCols(hStmt, &colCount);
    if (!SQL_SUCCEEDED(rc))
        daMssqlDie(hStmt, SQL_HANDLE_STMT, "SQLNumResultCols failed");

    if (colCount > MAX_COLS)
        colCount = MAX_COLS;

    if ((int)colCount != spQry->iInsColCnt) {
        LOGE("[%s] insert(%d) 와 select(%d)의 컬럼 수가 다릅니다. exit\n",
             spQry->caTitle, spQry->iInsColCnt, colCount);
        exit(1);
    }
    spQry->iSelColCnt = colCount;

    spQry->sDb.col_buf_size = (SQLULEN *)dcMalloc(sizeof(SQLULEN) * colCount);

    /* 4. 컬럼별 버퍼 할당 및 바인드 */
    for (i = 0; i < colCount; i++) {
        rc = SQLDescribeCol(hStmt, (SQLUSMALLINT)(i + 1),
                            colName, sizeof(colName), &nameLen,
                            &sqlType, &colSize, &scale, &nullable);
        if (!SQL_SUCCEEDED(rc))
            daMssqlDie(hStmt, SQL_HANDLE_STMT, "SQLDescribeCol failed");

        if (gcDebugMode == DEF_YES) {
            LOGD("%d [%-30s] sqlType=%d colSize=%lu scale=%d\n",
                 i, (char *)colName, sqlType, (unsigned long)colSize, scale);
        }

        spQry->sDb.col_buf_size[i] = daGetOdbcOutBufSize(sqlType, colSize);
        spQry->sDb.colbuf[i] = (char *)dcMalloc(spQry->sDb.col_buf_size[i] + 1);
        memset(spQry->sDb.colbuf[i], 0x00, spQry->sDb.col_buf_size[i] + 1);

        rc = SQLBindCol(hStmt, (SQLUSMALLINT)(i + 1), SQL_C_CHAR,
                        spQry->sDb.colbuf[i],
                        (SQLLEN)spQry->sDb.col_buf_size[i],
                        &spQry->sDb.ind[i]);
        if (!SQL_SUCCEEDED(rc))
            daMssqlDie(hStmt, SQL_HANDLE_STMT, "SQLBindCol failed");
    }

    if (spQry->cRunMethod == RUN_METHOD_MERGE) {
        daMallocMgrRow(spQry);
    }

    if (gcDebugMode == DEF_YES)
        LOGD("MSSQL prepared, title:%s, cols:%d\n", spQry->caTitle, colCount);

    return 0;
}

/* ------------------------------------------------------------------ */
/* 쿼리 실행 및 Fetch                                                 */
/* ------------------------------------------------------------------ */
int
daDBSelect(qry_t *spQry)
{
    SQLHSTMT  hStmt = spQry->sDb.mssql_stmt;
    SQLRETURN rc;

    int    i;
    size_t cap, len;
    char  *rowbuf = NULL;

    spQry->iSelCnt = 0;

    /* Execute */
    rc = SQLExecute(hStmt);
    if (!SQL_SUCCEEDED(rc))
        daMssqlDie(hStmt, SQL_HANDLE_STMT, "SQLExecute failed");

    /* Fetch loop */
    while (1) {
        for (i = 0; i < spQry->iSelColCnt; i++) {
            memset(spQry->sDb.colbuf[i], 0x00, spQry->sDb.col_buf_size[i]);
            spQry->sDb.ind[i] = 0;
        }

        rc = SQLFetch(hStmt);
        if (rc == SQL_NO_DATA)
            break;
        if (!SQL_SUCCEEDED(rc))
            daMssqlDie(hStmt, SQL_HANDLE_STMT, "SQLFetch failed");

        cap = LINE_BUF_INIT;
        len = 0;
        rowbuf = (char *)dcMalloc(cap);
        rowbuf[0] = '\0';

        for (i = 0; i < spQry->iSelColCnt; i++) {
            if (spQry->cRunMethod == RUN_METHOD_INSERT) {
                if (i > 0)
                    daAppendString(&rowbuf, &cap, &len, "\t");

                if (spQry->sDb.ind[i] == SQL_NULL_DATA) {
                    daAppendString(&rowbuf, &cap, &len, "\\N");
                } else {
                    spQry->sDb.colbuf[i][spQry->sDb.col_buf_size[i] - 1] = '\0';
                    dcAllTrimLen(spQry->sDb.colbuf[i],
                                 (int)strlen(spQry->sDb.colbuf[i]));

                    char *esc = daEscapePgCopyField(spQry->sDb.colbuf[i]);
                    daAppendString(&rowbuf, &cap, &len, esc);
                    FREE(esc);
                }
            } else {
                /* MERGE 모드 */
                if (spQry->sDb.ind[i] == SQL_NULL_DATA) {
                    spQry->cppMrgRow[i][0] = '\0';
                } else {
                    spQry->sDb.colbuf[i][spQry->sDb.col_buf_size[i] - 1] = '\0';
                    dcAllTrimLen(spQry->sDb.colbuf[i],
                                 (int)strlen(spQry->sDb.colbuf[i]));
                    snprintf(spQry->cppMrgRow[i],
                             (size_t)spQry->sDb.col_buf_size[i],
                             "%s", spQry->sDb.colbuf[i]);
                }
            }
        }

        daAppendString(&rowbuf, &cap, &len, "\n");

        if (spQry->cRunMethod == RUN_METHOD_INSERT) {
            if (daPgCopyPutRow(spQry, rowbuf) != 0) {
                FREE(rowbuf);
                return -1;
            }
        } else {
            daMrgRowToPostgre(spQry);
        }

        FREE(rowbuf);
        spQry->iSelCnt++;
    }
    SQLCloseCursor(hStmt);

    daPrintInsReslt(spQry);

    return 0;
}

/* ------------------------------------------------------------------ */
/* DB 연결 종료                                                       */
/* ------------------------------------------------------------------ */
int
daDBClose(qry_t *spQry)
{
    if (spQry->sDb.mssql_stmt != SQL_NULL_HSTMT) {
        SQLFreeHandle(SQL_HANDLE_STMT, spQry->sDb.mssql_stmt);
        spQry->sDb.mssql_stmt = SQL_NULL_HSTMT;
    }
    if (spQry->sDb.mssql_dbc != SQL_NULL_HDBC) {
        SQLDisconnect(spQry->sDb.mssql_dbc);
        SQLFreeHandle(SQL_HANDLE_DBC, spQry->sDb.mssql_dbc);
        spQry->sDb.mssql_dbc = SQL_NULL_HDBC;
    }
    if (spQry->sDb.mssql_env != SQL_NULL_HENV) {
        SQLFreeHandle(SQL_HANDLE_ENV, spQry->sDb.mssql_env);
        spQry->sDb.mssql_env = SQL_NULL_HENV;
    }
    return 0;
}

