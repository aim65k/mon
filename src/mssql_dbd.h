#ifndef _MSSQL_DBD_H
#define _MSSQL_DBD_H

#include <sql.h>
#include <sqlext.h>
#include "common_dbd.h"

#define MSSQL_DSN              "MSSQL_DSN"
#define MSSQL_USER             "MSSQL_USER"
#define MSSQL_PASS             "MSSQL_PASS"

typedef struct {
    SQLHENV   mssql_env;
    SQLHDBC   mssql_dbc;
    SQLHSTMT  mssql_stmt;

    char     *colbuf[MAX_COLS];
    SQLLEN    ind[MAX_COLS];
    SQLULEN  *col_buf_size;
} db_ctx_t;

void daDBEnv();

#endif /* _MSSQL_DBD_H */

