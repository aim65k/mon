#ifndef _ORACLE_DBD_H
#define _ORACLE_DBD_H

#include <oci.h>
#include <libpq-fe.h>
#include "common_dbd.h"

#define ORACLE_USER             "ORACLE_USER"
#define ORACLE_PASS             "ORACLE_PASS"
#define ORACLE_SERVICE_NAME     "ORACLE_SERVICE_NAME"

typedef struct {
    // for oracle oci
    void     *ora_env;
    void     *ora_err;
    void     *ora_svc;
        
    // oracle OCI Statement 관련
    void    *ora_stmt;                  // OCIStmt*
    void    *ora_defhp[MAX_COLS];       // OCIDefine*[]

    sb2     ind[MAX_COLS];              // NULL 인디케이터
    ub2     rlen[MAX_COLS];             // 실제 길이
    char    *colbuf[MAX_COLS];          // 컬럼 버퍼
    ub4     *col_buf_size;
} db_ctx_t;

void daDBEnv();
int  daOracleThreadsEnable();
char *daEscapePgCopyField(const char *src);

#endif
