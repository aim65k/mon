#ifndef _MAIN_DBD_H
#define _MAIN_DBD_H

#include <libpq-fe.h> 
#include <sys/time.h>
#ifdef  ORACLE
#include "oracle_dbd.h"
#elif   MARIA
#include "maria_dbd.h"
#elif   MSSQL
#include "mssql_dbd.h"
#elif   PG
#include "pg_dbd.h"
#endif

extern int giTermFd;

#define     PRJ_NAME                "dbd"

#define     DBD_QUERY_MAX_CNT        (30)
#define     DBD_THD_MAX_CNT          DBD_QUERY_MAX_CNT
#define     DBD_QUERY_MAX_LEN        (1024*500)

#define     DBD_COL_MAX_CNT          (50)
#define     DBD_COL_NM_MAX_LEN       (64+1)
#define     DBD_TBL_NM_MAX_LEN       (64)
#define     DBD_COPY_CMD_MAX_LEN     (1024)

#define     DBD_LOGDIR               "DBD_LOGDIR"
#define     DBD_CFGDIR               "DBD_CFGDIR"
#define     DBD_DATDIR               "DBD_DATDIR"
#define     DBD_BINDIR               "DBD_BINDIR"
#define     DBD_ADMIN_FILE           "DBD_ADMIN_FILE"

#define     INS_PG_HOST_IP           "INS_PG_HOST_IP"
#define     INS_PG_PORT              "INS_PG_PORT"
#define     INS_PG_DATABASE_NAME     "INS_PG_DATABASE_NAME"
#define     INS_PG_USER              "INS_PG_USER"
#define     INS_PG_PASS              "INS_PG_PASS"

#define     EXIT(...)               { LOGE(__VA_ARGS__); exit(1); }
#define     ABORT(...)              { LOGE(__VA_ARGS__); abort(); }

#ifndef my_bool
#ifndef MYSQL_VERSION_ID
typedef char my_bool;
#endif
#endif

#define     RUN_METHOD_INSERT           'I'
#define     RUN_METHOD_MERGE            'M'
#define     RUN_METHOD_SELECT           'S'

typedef struct _qry_t {
    char    caTitle[128];                       // 제목
    char    cRunYn;                             // 기동중, 멈춤(y/n)
    int     iCycle;                             // 시간(초) 주기 0:특정시간, 0<: 반복주기(초)
    struct {
        int     iH;
        int     iM;
        int     iS;
    } sHms;

    char    *cpOrgQuery;                        // original query
    char    *cpQuery;                           // query
    char    *cpInsQry;                          // insert문장 
    char    *cpSelQry;                          // select문장 
    char    *cpMrgQry;                          // merge의 upsert 문장

    char    caMrgStmtName[256];
    char    cMrgWhenMatchYn;

    char    cRunMethod;                         // 'I', 'M', 'S'
    // target
    char    caInsTblNm[DBD_TBL_NM_MAX_LEN];     // 테이블 이름
    int     iInsColCnt;                         // 컬럼 건수
    char    ca2InsColNm[DBD_COL_MAX_CNT][DBD_COL_NM_MAX_LEN];   // 컬럼 이름(전체)
    int     iKeyColCnt;                         // 컬럼 건수
    char    ca2KeyColNm[DBD_COL_MAX_CNT][DBD_COL_NM_MAX_LEN];   // key 컬럼 이름
    int     iNoKeyColCnt;                       // merge 에서 키 컬럼 제외한  컬럼 건수
    char    ca2NoKeyColNm[DBD_COL_MAX_CNT][DBD_COL_NM_MAX_LEN];   // merge에서 키 컬럼 제외한 컬럼 이름

    char    *cpCopyCmd;                         // copy command에 들어갈 문장들

    // select
    int     iSelCnt;                            // select한 건수
    char    *cpSelResult;                       // insert용 select 한 결과
    int     iSelColCnt;
    char    **cppMrgRow;             

    PGconn  *spPgConn;

    db_ctx_t    sDb;
} qry_t;

typedef struct _qry_info_t {
    int     iLstIdx;                        // 마지막 query index
    qry_t   saQry[DBD_QUERY_MAX_CNT];        // 실행할 query 정보
} qry_info_t;

#endif

