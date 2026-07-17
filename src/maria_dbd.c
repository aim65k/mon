/* db_mariadb.c */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <mysql/mysql.h>

#include <libpq-fe.h>
#include "string_db.h"
#include "maria_dbd.h"
#include "insert_dbd.h"
#include "common_dbd.h"

extern char gcOnlyOneCycle;

extern char gcDebugMode;

static void
daMariaDBDie(MYSQL *conn, const char *msg)
{
    if (conn) {
        LOGE("MariaDB ERROR [%s] errno=%u msg=%s\n", msg, mysql_errno(conn), mysql_error(conn));
    } else {
        LOGE("MariaDB ERROR [%s]\n", msg);
    }
    exit(1);
}

static void
daMariaDBInit(qry_t *spQry)
{
    memset(spQry->sDb.colbuf,       0x00, sizeof(spQry->sDb.colbuf));
    memset(spQry->sDb.col_buf_size, 0x00, sizeof(spQry->sDb.col_buf_size));
    memset(spQry->sDb.ind,          0x00, sizeof(spQry->sDb.ind));

    spQry->sDb.maria_conn = mysql_init(NULL);
    spQry->sDb.maria_stmt = NULL;
    spQry->sDb.bind       = NULL;
    spQry->iSelColCnt          = 0;
    spQry->cpSelResult         = NULL;
}

const char *cpHost;
const char *cpPortStr;
const char *cpUser;
const char *cpPass;
const char *cpDb;

void
daDBEnv()
{
    cpHost    = ENV_REQUIRED(MARIA_HOST_IP);
    cpPortStr = ENV_REQUIRED(MARIA_PORT);
    cpUser    = ENV_REQUIRED(MARIA_USER);
    cpPass    = ENV_REQUIRED(MARIA_PASS);
    cpDb      = ENV_REQUIRED(MARIA_DATABASE_NAME);
    return;
}

int
daDBOpen(qry_t *spQry)
{
    MYSQL *conn = NULL;


    unsigned int uiPort;


    if (!cpHost || !cpPortStr || !cpUser || !cpPass || !cpDb) {
        LOGE("cpHost, pot, cpUser, cpPass, database_name이 존재하지 않아 종료합니다. \n");
        exit(1);
    }

    daMariaDBInit(spQry);
    conn = spQry->sDb.maria_conn;

    if (conn == NULL) {
        LOGE("conn is NULL! mysql_init을 먼저 확인하세요.\n");
        daMariaDBDie(conn, "mysql conn failed");
    }

    if (cpPortStr && *cpPortStr) {
        uiPort = (unsigned int)atoi(cpPortStr);
    }

    conn = mysql_init(NULL);
    if (!conn) {
        daMariaDBDie(NULL, "mysql_init failed");
    }

    /* 재연결 옵션 */
    my_bool reconnect = 1;
    mysql_options(conn, MYSQL_OPT_RECONNECT, &reconnect);

    /* UTF-8 설정 */
    mysql_options(conn, MYSQL_SET_CHARSET_NAME, "utf8mb4");

    if (!mysql_real_connect(conn, cpHost, cpUser, cpPass, cpDb, uiPort, NULL, 0)) {
        LOGE("db con fail:[%s,%s,%s,%s,%s]\n", cpHost, cpUser, cpPass, cpDb, cpPortStr);
        daMariaDBDie(conn, "mysql_real_connect failed");
    }

    spQry->sDb.maria_conn = conn;

    signal(SIGINT, SIG_DFL);

    return 0;
}

static void
daMallocMrgRow(qry_t *spQry)
{
    int iF0;

    spQry->cppMrgRow = (char **)dcMalloc(sizeof(char *) * spQry->iSelColCnt);
    ASSERT(spQry->cppMrgRow);

    for (iF0 = 0; iF0 < spQry->iSelColCnt; iF0++) {
        spQry->cppMrgRow[iF0] = (char *)dcMalloc(spQry->sDb.col_buf_size[iF0]);
        ASSERT(spQry->cppMrgRow[iF0]);

        spQry->cppMrgRow[iF0][0] = 0x00;
    }

    return;
}

static unsigned long
daGetMariaOutBufSize(MYSQL_FIELD *field)
{
    switch (field->type) {
        case MYSQL_TYPE_TINY:
        case MYSQL_TYPE_SHORT:
        case MYSQL_TYPE_INT24:
        case MYSQL_TYPE_LONG:
        case MYSQL_TYPE_LONGLONG:
        case MYSQL_TYPE_FLOAT:
        case MYSQL_TYPE_DOUBLE:
        case MYSQL_TYPE_DECIMAL:
        case MYSQL_TYPE_NEWDECIMAL:
            return 128;

        case MYSQL_TYPE_DATE:
        case MYSQL_TYPE_TIME:
        case MYSQL_TYPE_DATETIME:
        case MYSQL_TYPE_TIMESTAMP:
        case MYSQL_TYPE_YEAR:
            return 64;

        case MYSQL_TYPE_STRING:
        case MYSQL_TYPE_VAR_STRING:
        case MYSQL_TYPE_VARCHAR:
            if (field->length > 0 && field->length < 32767)
                return field->length + 4;
            return 8192;

        case MYSQL_TYPE_BLOB:
        case MYSQL_TYPE_TINY_BLOB:
        case MYSQL_TYPE_MEDIUM_BLOB:
        case MYSQL_TYPE_LONG_BLOB:
            /* TEXT 타입도 BLOB으로 분류됨 */
            if (field->length > 0 && field->length < 65536)
                return field->length + 4;
            return 65536;

        default:
            return 8192;
    }
}

static const char * 
daGetMariaFieldTypeString(enum enum_field_types type) {
    switch (type) {
        case MYSQL_TYPE_TINY:       return "TINYINT";
        case MYSQL_TYPE_SHORT:      return "SMALLINT";
        case MYSQL_TYPE_LONG:       return "INT";
        case MYSQL_TYPE_LONGLONG:   return "BIGINT";
        case MYSQL_TYPE_FLOAT:      return "FLOAT";
        case MYSQL_TYPE_DOUBLE:     return "DOUBLE";
        case MYSQL_TYPE_DECIMAL:    return "DECIMAL";
        case MYSQL_TYPE_NEWDECIMAL: return "NEWDECIMAL";
        case MYSQL_TYPE_TIMESTAMP:  return "TIMESTAMP";
        case MYSQL_TYPE_DATE:       return "DATE";
        case MYSQL_TYPE_TIME:       return "TIME";
        case MYSQL_TYPE_DATETIME:   return "DATETIME";
        case MYSQL_TYPE_YEAR:       return "YEAR";
        case MYSQL_TYPE_STRING:     return "CHAR";
        case MYSQL_TYPE_VAR_STRING: return "VARCHAR";
        case MYSQL_TYPE_BLOB:       return "BLOB/TEXT";
        case MYSQL_TYPE_SET:        return "SET";
        case MYSQL_TYPE_ENUM:       return "ENUM";
        case MYSQL_TYPE_NULL:       return "NULL";
        default:                    return "UNKNOWN";
    }
}

int
daDBPrepare(qry_t *spQry)
{
    MYSQL           *conn   = (MYSQL *)spQry->sDb.maria_conn;
    MYSQL_STMT      *stmt   = NULL;
    MYSQL_RES       *meta   = NULL;
    MYSQL_FIELD     *fields = NULL;
    MYSQL_BIND      *bind   = NULL;

    const char      *sql_text = spQry->cpSelQry;
    unsigned int     col_cnt  = 0;
    unsigned int     i;

    /* 1. Statement 핸들 할당 */
    stmt = mysql_stmt_init(conn);
    if (!stmt) {
        daMariaDBDie(conn, "mysql_stmt_init failed");
        return -1;
    }

    spQry->sDb.maria_stmt = stmt;

    /* 2. SQL Prepare */
    if (mysql_stmt_prepare(stmt, sql_text, (unsigned long)strlen(sql_text)) != 0) {
        LOGE("[%s] mysql_stmt_prepare failed, sql_text:[%s], error:[%s]\n",
             spQry->caTitle, sql_text, mysql_stmt_error(stmt));
        daMariaDBDie(conn, "mysql_stmt_prepare failed");
        return -1;
    }

    if (gcDebugMode == DEF_YES) {
        LOGD("[%s] sql_text:[%s]\n", spQry->caTitle, sql_text);
    }

    /* 3. 메타데이터로 컬럼 정보 획득 */
    meta = mysql_stmt_result_metadata(stmt);
    if (!meta) {
        LOGE("[%s] mysql_stmt_result_metadata failed, sql_text:[%s]\n", spQry->caTitle, sql_text);
        daMariaDBDie(conn, "mysql_stmt_result_metadata failed");
        return -1;
    }

    /* 4. 컬럼 개수 확인 */
    col_cnt = mysql_num_fields(meta);

    if (col_cnt > MAX_COLS)
        col_cnt = MAX_COLS;

    if ((int)col_cnt != spQry->iInsColCnt) {
        LOGE("[%s] insert(%d) 와 select(%d) 의 컬럼숫자가 다릅니다., exit\n",
             spQry->caTitle, spQry->iInsColCnt, col_cnt);
        exit(1);
    }

    spQry->iSelColCnt = col_cnt;

    /* 필드 정보 획득 */
    fields = mysql_fetch_fields(meta);


    /* 5. 컬럼별 버퍼 할당 및 Bind 설정 */
    bind = (MYSQL_BIND *)dcMalloc(sizeof(MYSQL_BIND) * col_cnt);
    memset(bind, 0x00, sizeof(MYSQL_BIND) * col_cnt);

    for (i = 0; i < col_cnt; i++) {
        if (gcDebugMode == DEF_YES) {
            LOGD("%u [%-30s] type=[%-3u.%s] length=%-5lu\n",
                 i, fields[i].name, fields[i].type, daGetMariaFieldTypeString(fields[i].type), fields[i].length);
        } 

        spQry->sDb.col_buf_size[i] = daGetMariaOutBufSize(&fields[i]);
        spQry->sDb.colbuf[i] = (char *)dcMalloc(spQry->sDb.col_buf_size[i] + 1);
        memset(spQry->sDb.colbuf[i], 0x00, spQry->sDb.col_buf_size[i] + 1);

        bind[i].buffer_type   = MYSQL_TYPE_STRING;
        bind[i].buffer        = spQry->sDb.colbuf[i];
        bind[i].buffer_length = spQry->sDb.col_buf_size[i];
        bind[i].is_null       = &spQry->sDb.ind[i];
        bind[i].length        = &spQry->sDb.rlen[i];
    }

    spQry->sDb.bind = bind;

    /* 6. Bind 연결 */
    if (mysql_stmt_bind_result(stmt, bind) != 0) {
        daMariaDBDie(conn, "mysql_stmt_bind_result failed");
        return -1;
    }

    mysql_free_result(meta);

    if (spQry->cRunMethod == RUN_METHOD_MERGE) {
        daMallocMrgRow(spQry);
    }

    if (gcDebugMode == DEF_YES) LOGD("MariaDB prepared, title:%s, cols:%d\n", spQry->caTitle, col_cnt);

    return 0;
}

int
daDBSelect(qry_t *spQry)
{
    MYSQL_STMT  *stmt;
    int          i;
    int          rc;
    size_t       cap, len;
    char        *rowbuf = NULL;

    stmt = (MYSQL_STMT *)spQry->sDb.maria_stmt;

    spQry->iSelCnt = 0;

    /* Execute */
    rc = mysql_stmt_execute(stmt);
    if (rc != 0) {
        LOGE("mysql_stmt_execute failed: %s\n", mysql_stmt_error(stmt));
        daMariaDBDie((MYSQL *)spQry->sDb.maria_conn, "mysql_stmt_execute failed");
        return -1;
    }

    /* Store result (전체 결과셋을 클라이언트로 가져옴) */
    if (mysql_stmt_store_result(stmt) != 0) {
        daMariaDBDie((MYSQL *)spQry->sDb.maria_conn, "mysql_stmt_store_result failed");
        return -1;
    }

    /* Fetch loop */
    while (1) {
        for (i = 0; i < spQry->iSelColCnt; i++) {
            memset(spQry->sDb.colbuf[i], 0x00, spQry->sDb.col_buf_size[i]);
            spQry->sDb.ind[i] = 0;
            spQry->sDb.rlen[i] = 0;
        }

        rc = mysql_stmt_fetch(stmt);

        if (rc == MYSQL_NO_DATA)
            break;

        if (rc != 0 && rc != MYSQL_DATA_TRUNCATED) {
            LOGE("mysql_stmt_fetch failed: %s\n", mysql_stmt_error(stmt));
            daMariaDBDie((MYSQL *)spQry->sDb.maria_conn, "mysql_stmt_fetch failed");
            FREE(rowbuf);
            return -1;
        }

        cap = LINE_BUF_INIT;
        len = 0;
        rowbuf = (char *)dcMalloc(cap);
        rowbuf[0] = 0x00;

        for (i = 0; i < spQry->iSelColCnt; i++) {
            if (spQry->cRunMethod == RUN_METHOD_INSERT) {
                if (i > 0)
                    daAppendString(&rowbuf, &cap, &len, "\t");

                if (spQry->sDb.ind[i]) {
                    /* NULL */
                    daAppendString(&rowbuf, &cap, &len, "\\N");
                } else {
                    spQry->sDb.colbuf[i][spQry->sDb.col_buf_size[i] - 1] = 0x00;
                    dcAllTrimLen(spQry->sDb.colbuf[i], (int)strlen(spQry->sDb.colbuf[i]));

                    char *esc = daEscapePgCopyField(spQry->sDb.colbuf[i]);
                    daAppendString(&rowbuf, &cap, &len, esc);
                    FREE(esc);
                }
            } else {
                /* MERGE 모드 */
                if (spQry->sDb.ind[i]) {
                    spQry->cppMrgRow[i][0] = 0x00;
                } else {
                    spQry->sDb.colbuf[i][spQry->sDb.col_buf_size[i] - 1] = 0x00;
                    dcAllTrimLen(spQry->sDb.colbuf[i], (int)strlen(spQry->sDb.colbuf[i]));

                    snprintf(spQry->cppMrgRow[i], spQry->sDb.col_buf_size[i], "%s",
                             spQry->sDb.colbuf[i]);
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

    /* 결과셋 해제 */
    mysql_stmt_free_result(stmt);

    daPrintInsReslt(spQry);

    return 0;
}

