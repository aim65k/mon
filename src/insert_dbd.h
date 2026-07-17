#ifndef _INSERT_DBD_H
#define _INSERT_DBD_H

#include "main_dbd.h"
#include "common_dbd.h"
#include <libpq-fe.h> // PostgreSQL 라이브러리 헤더

int daPgOpen(qry_t *spQry);
int daPgCopyBegin(qry_t *spQry);
int daPgCopyPutRow(qry_t *spQry, const char *row);
int daPgCopyEnd(qry_t *spQry);

int daMrgPrepare(qry_t *spQry);
int daMrgRowToPostgre(qry_t *spQry);
void daPrintInsReslt(qry_t *spQry);
int daPgExecFunc(qry_t *spQry); 

#endif
